package io.github.ghosthack.libvipsffm;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.StructLayout;
import java.lang.foreign.SymbolLookup;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.VarHandle;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_CHAR;
import static java.lang.foreign.ValueLayout.JAVA_INT;

/**
 * Loads bundled Windows DLLs so that each one's dependencies resolve from the
 * directory it sits in, never from {@code PATH}.
 *
 * <p>{@link System#load} is {@code LoadLibraryW}: a DLL's dependencies are
 * searched through the standard order, which includes {@code PATH} but not
 * the DLL's own directory. A host with MSYS2, a libvips install or another
 * GTK stack on {@code PATH} then supplies a same-named but different build of
 * a dependency (say {@code libintl-8.dll}) whenever the bundled one is not
 * loaded yet; Windows keeps that module for its base name, and a later
 * bundled DLL that needs a newer function fails with "The specified
 * procedure could not be found". {@code LoadLibraryExW} with
 * {@code LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS}
 * searches the DLL's directory first and leaves {@code PATH} out.</p>
 *
 * <p>One thing no flag changes: a module already loaded under the same base
 * name, from any directory, satisfies every later import of that name. The
 * failure message names any such module so the conflict is visible.</p>
 */
final class WindowsDllLoader {
    private static final int LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x00000100;
    private static final int LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = 0x00001000;
    private static final int MAX_PATH_CHARS = 32_768;

    private static final StructLayout CAPTURE = Linker.Option.captureStateLayout();
    private static final VarHandle LAST_ERROR =
            CAPTURE.varHandle(MemoryLayout.PathElement.groupElement("GetLastError"));

    private final MethodHandle loadLibraryExW;
    private final MethodHandle getModuleHandleW;
    private final MethodHandle getModuleFileNameW;

    WindowsDllLoader() {
        Linker linker = Linker.nativeLinker();
        SymbolLookup kernel32 = SymbolLookup.libraryLookup("kernel32", Arena.global());
        loadLibraryExW = linker.downcallHandle(kernel32.findOrThrow("LoadLibraryExW"),
                FunctionDescriptor.of(ADDRESS, ADDRESS, ADDRESS, JAVA_INT),
                Linker.Option.captureCallState("GetLastError"));
        getModuleHandleW = linker.downcallHandle(kernel32.findOrThrow("GetModuleHandleW"),
                FunctionDescriptor.of(ADDRESS, ADDRESS));
        getModuleFileNameW = linker.downcallHandle(kernel32.findOrThrow("GetModuleFileNameW"),
                FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT));
    }

    /**
     * Loads {@code dll} (an absolute path), resolving its dependencies from
     * its own directory first.
     *
     * @return 0 on success, otherwise the Windows error code
     */
    int load(Path dll) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = arena.allocate(CAPTURE);
            MemorySegment handle = (MemorySegment) loadLibraryExW.invokeExact(state,
                    wide(arena, dll.toString()), MemorySegment.NULL,
                    LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
            if (handle.address() != 0) {
                return 0;
            }
            int error = (int) LAST_ERROR.get(state, 0L);
            return error == 0 ? -1 : error;
        } catch (Throwable t) {
            throw new IllegalStateException("LoadLibraryExW failed for " + dll, t);
        }
    }

    /** Where the module loaded under {@code baseName} lives, or null when none is loaded. */
    Path loadedPath(String baseName) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment module = (MemorySegment) getModuleHandleW.invokeExact(wide(arena, baseName));
            if (module.address() == 0) {
                return null;
            }
            MemorySegment buffer = arena.allocate(JAVA_CHAR, MAX_PATH_CHARS);
            int length = (int) getModuleFileNameW.invokeExact(module, buffer, MAX_PATH_CHARS);
            if (length <= 0) {
                return null;
            }
            char[] chars = buffer.asSlice(0, length * 2L).toArray(JAVA_CHAR);
            return Path.of(new String(chars));
        } catch (Throwable t) {
            throw new IllegalStateException("cannot query loaded module " + baseName, t);
        }
    }

    /** A short reading of the Windows errors a DLL load produces. */
    static String describe(int error) {
        String meaning = switch (error) {
            case 126 -> "a DLL it depends on was not found";
            case 127 -> "a function it imports is missing from a DLL it depends on";
            case 193 -> "not a valid 64-bit Windows DLL";
            case 1114 -> "a DLL initialization routine failed";
            default -> "see the Windows system error code";
        };
        return "Windows error " + error + " (" + meaning + ")";
    }

    private static MemorySegment wide(Arena arena, String value) {
        return arena.allocateFrom(value, StandardCharsets.UTF_16LE);
    }
}
