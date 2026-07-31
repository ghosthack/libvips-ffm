package io.github.ghosthack.libvipsffm;

import io.github.ghosthack.libvipsffm.libvips.Vips;

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Arena;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;

/** Process-wide libvips initialization and diagnostics. */
public final class LibVips {
    private static final MethodHandle TYPE_FIND = Linker.nativeLinker().downcallHandle(
            LibVipsLibs.lookup().find("vips_type_find")
                    .orElseThrow(() -> new IllegalStateException(
                            "libvips does not export vips_type_find")),
            FunctionDescriptor.of(
                    ValueLayout.JAVA_LONG,
                    ValueLayout.ADDRESS,
                    ValueLayout.ADDRESS));

    private LibVips() {}

    /** Initializes libvips once and returns its runtime version. */
    public static String initialize() {
        return Initialization.VERSION;
    }

    /** Returns the version reported by the loaded native library. */
    public static String version() {
        return initialize();
    }

    /** Returns one numeric version component: 0=major, 1=minor, 2=micro. */
    public static int version(int component) {
        initialize();
        if (component < 0 || component > 2) {
            throw new IllegalArgumentException("version component must be 0, 1, or 2");
        }
        return Vips.vips_version(component);
    }

    /**
     * Returns whether the loaded libvips registered an operation nickname.
     *
     * <p>This reports the actual runtime build, including an explicitly
     * supplied replacement library; it does not infer capabilities from file
     * names or compile-time metadata.
     */
    public static boolean hasOperation(String nickname) {
        initialize();
        if (nickname == null || nickname.isBlank()) {
            throw new IllegalArgumentException("operation nickname must not be blank");
        }
        try (Arena arena = Arena.ofConfined()) {
            long type = (long) TYPE_FIND.invokeExact(
                    arena.allocateFrom("VipsOperation"),
                    arena.allocateFrom(nickname));
            return type != 0;
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable e) {
            throw new IllegalStateException(
                    "failed to query libvips operation " + nickname, e);
        }
    }

    /** Returns and clears the current thread's libvips error buffer. */
    public static String takeError() {
        MemorySegment pointer = Vips.vips_error_buffer();
        String message = pointer.address() == 0
                ? "unknown libvips error"
                : pointer.reinterpret(64 * 1024).getString(0).strip();
        Vips.vips_error_clear();
        return message.isEmpty() ? "unknown libvips error" : message;
    }

    static void requireSuccess(int result, String operation) {
        if (result != 0) {
            throw new VipsException(operation + " failed: " + takeError());
        }
    }

    static MemorySegment requireImage(MemorySegment image, String operation) {
        if (image.address() == 0) {
            throw new VipsException(operation + " failed: " + takeError());
        }
        return image;
    }

    private static final class Initialization {
        private static final String VERSION = initializeNative();

        private static String initializeNative() {
            try (Arena arena = Arena.ofConfined()) {
                int result = Vips.vips_init(arena.allocateFrom("libvips-ffm"));
                requireSuccess(result, "vips_init");
            }
            MemorySegment version = Vips.vips_version_string();
            if (version.address() == 0) {
                throw new VipsException("vips_version_string returned NULL");
            }
            return version.reinterpret(256).getString(0);
        }
    }
}
