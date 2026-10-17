package io.github.ghosthack.libvipsffm;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.invoke.MethodHandle;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_CHAR;
import static java.lang.foreign.ValueLayout.JAVA_INT;

/**
 * Child-process half of {@link WindowsDllSearchTest}: loads libvips, then
 * prints the file of every module in the process, one {@code module<TAB>path}
 * line each — all of them, since two same-named DLLs from different folders
 * can be loaded at once and a by-name query reports only one.
 */
final class WindowsDllProbe {
    public static void main(String[] args) throws Throwable {
        System.out.println("version\t" + LibVips.version());
        Linker linker = Linker.nativeLinker();
        SymbolLookup kernel32 = SymbolLookup.libraryLookup("kernel32", Arena.global());
        MethodHandle currentProcess = linker.downcallHandle(
                kernel32.findOrThrow("GetCurrentProcess"), FunctionDescriptor.of(ADDRESS));
        MethodHandle enumModules = linker.downcallHandle(
                kernel32.findOrThrow("K32EnumProcessModules"),
                FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS));
        MethodHandle fileName = linker.downcallHandle(
                kernel32.findOrThrow("GetModuleFileNameW"),
                FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment process = (MemorySegment) currentProcess.invokeExact();
            int capacity = 4096;
            MemorySegment modules = arena.allocate(ADDRESS, capacity);
            MemorySegment needed = arena.allocate(JAVA_INT);
            int ok = (int) enumModules.invokeExact(process, modules,
                    (int) (capacity * ADDRESS.byteSize()), needed);
            if (ok == 0) throw new IllegalStateException("K32EnumProcessModules failed");
            int count = (int) (needed.get(JAVA_INT, 0) / ADDRESS.byteSize());
            MemorySegment buffer = arena.allocate(JAVA_CHAR, 32_768);
            for (int i = 0; i < Math.min(count, capacity); i++) {
                MemorySegment module = modules.getAtIndex(ADDRESS, i);
                int length = (int) fileName.invokeExact(module, buffer, 32_768);
                if (length > 0) {
                    String path = new String(buffer.asSlice(0, length * 2L).toArray(JAVA_CHAR));
                    System.out.println("module\t" + path);
                }
            }
        }
    }
}
