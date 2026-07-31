package io.github.ghosthack.libvipsffm;

import io.github.ghosthack.libvipsffm.libvips.Vips;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * An owned {@code VipsImage*}.
 *
 * <p>Instances must be closed. Derived images retain any Java-owned encoded
 * input buffer required by libvips' lazy evaluation, even if the source image
 * is closed first.
 */
public final class VipsImage implements AutoCloseable {
    private static final Vips.vips_image_new_from_file NEW_FROM_FILE =
            Vips.vips_image_new_from_file.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_image_new_from_buffer NEW_FROM_BUFFER =
            Vips.vips_image_new_from_buffer.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_image_write_to_file WRITE_TO_FILE =
            Vips.vips_image_write_to_file.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_image_write_to_buffer WRITE_TO_BUFFER =
            Vips.vips_image_write_to_buffer.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_thumbnail THUMBNAIL_FILE =
            Vips.vips_thumbnail.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_thumbnail_buffer THUMBNAIL_BUFFER =
            Vips.vips_thumbnail_buffer.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_thumbnail_image THUMBNAIL_IMAGE =
            Vips.vips_thumbnail_image.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_resize RESIZE =
            Vips.vips_resize.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_crop CROP =
            Vips.vips_crop.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_autorot AUTOROT =
            Vips.vips_autorot.makeInvoker(ValueLayout.ADDRESS);
    private static final Vips.vips_invert INVERT =
            Vips.vips_invert.makeInvoker(ValueLayout.ADDRESS);

    private MemorySegment image;
    private final List<RetainedInput> retainedInputs;

    private VipsImage(MemorySegment image, List<RetainedInput> retainedInputs) {
        this.image = LibVips.requireImage(image, "create image");
        this.retainedInputs = retainedInputs;
    }

    /** Lazily opens an image from a filesystem path. */
    public static VipsImage fromFile(Path path) {
        Objects.requireNonNull(path, "path");
        LibVips.initialize();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment image = NEW_FROM_FILE.apply(
                    arena.allocateFrom(path.toAbsolutePath().toString()),
                    MemorySegment.NULL);
            return owned(image);
        }
    }

    /**
     * Lazily opens an encoded image from memory.
     *
     * <p>The bytes are copied once into native memory and retained until this
     * image and every image derived from it have been closed.
     */
    public static VipsImage fromBytes(byte[] encoded) {
        Objects.requireNonNull(encoded, "encoded");
        LibVips.initialize();
        RetainedInput input = RetainedInput.copyOf(encoded);
        try (Arena arguments = Arena.ofConfined()) {
            MemorySegment image = NEW_FROM_BUFFER.apply(
                    input.segment(), encoded.length, arguments.allocateFrom(""),
                    MemorySegment.NULL);
            LibVips.requireImage(image, "vips_image_new_from_buffer");
            return new VipsImage(image, List.of(input));
        } catch (RuntimeException | Error e) {
            input.release();
            throw e;
        }
    }

    /** Copies interleaved raw pixels into a new libvips image. */
    public static VipsImage fromPixels(
            byte[] pixels, int width, int height, int bands, int bandFormat) {
        Objects.requireNonNull(pixels, "pixels");
        if (width <= 0 || height <= 0 || bands <= 0) {
            throw new IllegalArgumentException("width, height, and bands must be positive");
        }
        LibVips.initialize();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment data = arena.allocateFrom(ValueLayout.JAVA_BYTE, pixels);
            MemorySegment image = Vips.vips_image_new_from_memory_copy(
                    data, pixels.length, width, height, bands, bandFormat);
            return owned(image);
        }
    }

    /** Efficiently loads and thumbnails a file to fit within {@code width}. */
    public static VipsImage thumbnail(Path path, int width) {
        Objects.requireNonNull(path, "path");
        requirePositive(width, "width");
        LibVips.initialize();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment output = arena.allocate(ValueLayout.ADDRESS);
            int result = THUMBNAIL_FILE.apply(
                    arena.allocateFrom(path.toAbsolutePath().toString()),
                    output, width, MemorySegment.NULL);
            LibVips.requireSuccess(result, "vips_thumbnail");
            return owned(output.get(ValueLayout.ADDRESS, 0));
        }
    }

    /** Efficiently loads and thumbnails encoded bytes to fit within {@code width}. */
    public static VipsImage thumbnail(byte[] encoded, int width) {
        Objects.requireNonNull(encoded, "encoded");
        requirePositive(width, "width");
        LibVips.initialize();
        RetainedInput input = RetainedInput.copyOf(encoded);
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment output = arena.allocate(ValueLayout.ADDRESS);
            int result = THUMBNAIL_BUFFER.apply(
                    input.segment(), encoded.length, output, width, MemorySegment.NULL);
            LibVips.requireSuccess(result, "vips_thumbnail_buffer");
            return new VipsImage(output.get(ValueLayout.ADDRESS, 0), List.of(input));
        } catch (RuntimeException | Error e) {
            input.release();
            throw e;
        }
    }

    /** Returns a lazy thumbnail of this image. */
    public VipsImage thumbnail(int width) {
        requirePositive(width, "width");
        return unary("vips_thumbnail_image",
                (source, output) -> THUMBNAIL_IMAGE.apply(
                        source, output, width, MemorySegment.NULL));
    }

    /** Returns a lazy resize using libvips' default high-quality kernel. */
    public VipsImage resize(double scale) {
        if (!Double.isFinite(scale) || scale <= 0.0) {
            throw new IllegalArgumentException("scale must be finite and positive");
        }
        return unary("vips_resize",
                (source, output) -> RESIZE.apply(
                        source, output, scale, MemorySegment.NULL));
    }

    /** Extracts a rectangular region. */
    public VipsImage crop(int left, int top, int width, int height) {
        if (left < 0 || top < 0) {
            throw new IllegalArgumentException("left and top must be non-negative");
        }
        requirePositive(width, "width");
        requirePositive(height, "height");
        return unary("vips_crop",
                (source, output) -> CROP.apply(
                        source, output, left, top, width, height, MemorySegment.NULL));
    }

    /** Applies embedded orientation metadata, if present. */
    public VipsImage autorotate() {
        return unary("vips_autorot",
                (source, output) -> AUTOROT.apply(
                        source, output, MemorySegment.NULL));
    }

    /** Inverts every image band. */
    public VipsImage invert() {
        return unary("vips_invert",
                (source, output) -> INVERT.apply(
                        source, output, MemorySegment.NULL));
    }

    public int width() {
        return Vips.vips_image_get_width(requireOpen());
    }

    public int height() {
        return Vips.vips_image_get_height(requireOpen());
    }

    public int bands() {
        return Vips.vips_image_get_bands(requireOpen());
    }

    public int bandFormat() {
        return Vips.vips_image_get_format(requireOpen());
    }

    public int interpretation() {
        return Vips.vips_image_get_interpretation(requireOpen());
    }

    /** Writes the image; the suffix of {@code path} selects the saver. */
    public void writeToFile(Path path) {
        Objects.requireNonNull(path, "path");
        try (Arena arena = Arena.ofConfined()) {
            int result = WRITE_TO_FILE.apply(
                    requireOpen(), arena.allocateFrom(path.toAbsolutePath().toString()),
                    MemorySegment.NULL);
            LibVips.requireSuccess(result, "vips_image_write_to_file");
        }
    }

    /**
     * Encodes the image to memory. The suffix includes the leading dot, for
     * example {@code ".jpg"}, {@code ".png"}, or {@code ".webp"}.
     */
    public byte[] writeToBuffer(String suffix) {
        Objects.requireNonNull(suffix, "suffix");
        if (!suffix.startsWith(".") || suffix.length() < 2) {
            throw new IllegalArgumentException("suffix must look like .png or .jpg");
        }
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment bufferOut = arena.allocate(ValueLayout.ADDRESS);
            MemorySegment sizeOut = arena.allocate(ValueLayout.JAVA_LONG);
            int result = WRITE_TO_BUFFER.apply(
                    requireOpen(), arena.allocateFrom(suffix),
                    bufferOut, sizeOut, MemorySegment.NULL);
            LibVips.requireSuccess(result, "vips_image_write_to_buffer");
            MemorySegment buffer = bufferOut.get(ValueLayout.ADDRESS, 0);
            long size = sizeOut.get(ValueLayout.JAVA_LONG, 0);
            if (size > Integer.MAX_VALUE) {
                Vips.g_free(buffer);
                throw new IllegalStateException("encoded image exceeds Java array limit: " + size);
            }
            try {
                return buffer.reinterpret(size).toArray(ValueLayout.JAVA_BYTE);
            } finally {
                Vips.g_free(buffer);
            }
        }
    }

    /** Exposes the raw pointer for APIs not covered by this convenience class. */
    public MemorySegment address() {
        return requireOpen();
    }

    @Override
    public void close() {
        MemorySegment current = image;
        if (current.address() != 0) {
            image = MemorySegment.NULL;
            Vips.g_object_unref(current);
            retainedInputs.forEach(RetainedInput::release);
        }
    }

    private VipsImage unary(String operation, UnaryOperation function) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment output = arena.allocate(ValueLayout.ADDRESS);
            int result = function.apply(requireOpen(), output);
            LibVips.requireSuccess(result, operation);
            return derived(output.get(ValueLayout.ADDRESS, 0));
        }
    }

    private VipsImage derived(MemorySegment pointer) {
        List<RetainedInput> resources = new ArrayList<>(retainedInputs.size());
        retainedInputs.forEach(input -> resources.add(input.retain()));
        try {
            return new VipsImage(pointer, List.copyOf(resources));
        } catch (RuntimeException | Error e) {
            resources.forEach(RetainedInput::release);
            throw e;
        }
    }

    private MemorySegment requireOpen() {
        if (image.address() == 0) {
            throw new IllegalStateException("VipsImage is closed");
        }
        return image;
    }

    private static VipsImage owned(MemorySegment image) {
        return new VipsImage(
                LibVips.requireImage(image, "create image"), List.of());
    }

    private static void requirePositive(int value, String name) {
        if (value <= 0) {
            throw new IllegalArgumentException(name + " must be positive");
        }
    }

    @FunctionalInterface
    private interface UnaryOperation {
        int apply(MemorySegment source, MemorySegment output);
    }

    private static final class RetainedInput {
        private final Arena arena;
        private final MemorySegment segment;
        private final AtomicInteger references = new AtomicInteger(1);

        private RetainedInput(Arena arena, MemorySegment segment) {
            this.arena = arena;
            this.segment = segment;
        }

        static RetainedInput copyOf(byte[] bytes) {
            Arena arena = Arena.ofShared();
            try {
                return new RetainedInput(
                        arena, arena.allocateFrom(ValueLayout.JAVA_BYTE, bytes));
            } catch (RuntimeException | Error e) {
                arena.close();
                throw e;
            }
        }

        RetainedInput retain() {
            for (int count = references.get(); ; count = references.get()) {
                if (count == 0) {
                    throw new IllegalStateException("cannot retain released native input");
                }
                if (references.compareAndSet(count, count + 1)) {
                    return this;
                }
            }
        }

        void release() {
            int count = references.decrementAndGet();
            if (count == 0) {
                arena.close();
            } else if (count < 0) {
                throw new IllegalStateException("native input released twice");
            }
        }

        MemorySegment segment() {
            return segment;
        }
    }
}
