package io.github.ghosthack.libvipsffm;

import io.github.ghosthack.libvipsffm.libvips.Vips;
import org.junit.jupiter.api.Test;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.Base64;
import java.util.HashSet;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LibVipsSmokeTest {
    @Test
    void bundledLibraryLoadsAndReportsExpectedAbi() {
        assertTrue(LibVips.version().startsWith("8.18."));
        assertEquals(8, LibVips.version(0));
        assertEquals(18, LibVips.version(1));
        assertTrue(Set.of("macos-arm64", "windows-x64", "linux-x64")
                .contains(LibVipsLibs.classifier()));
    }

    @Test
    void reviewedFormatOperationsAreRegisteredAndMagickIsAbsent() {
        for (String operation : Set.of(
                "jpegload", "jpegsave",
                "pngload", "pngsave",
                "tiffload", "tiffsave",
                "webpload", "webpsave",
                "gifload",
                "heifload",
                "uhdrload",
                "jxlload", "jxlsave",
                "svgload",
                "pdfload",
                "jp2kload", "jp2ksave")) {
            assertTrue(LibVips.hasOperation(operation),
                    () -> "expected native operation " + operation);
        }
        assertTrue(!LibVips.hasOperation("magickload"));
        assertTrue(!LibVips.hasOperation("magicksave"));
        assertTrue(!LibVips.hasOperation("gifsave"));
    }

    @Test
    void loadsTransformsAndEncodesInMemory() {
        byte[] pixels = rgbPixels(64, 48);
        byte[] png;

        try (VipsImage source = VipsImage.fromPixels(
                     pixels, 64, 48, 3, Vips.VIPS_FORMAT_UCHAR());
             VipsImage thumbnail = source.thumbnail(16);
             VipsImage inverted = thumbnail.invert()) {
            assertEquals(64, source.width());
            assertEquals(48, source.height());
            assertEquals(3, source.bands());
            assertEquals(16, thumbnail.width());
            assertEquals(12, thumbnail.height());
            png = inverted.writeToBuffer(".png");
        }

        assertTrue(png.length > 64);
        try (VipsImage decoded = VipsImage.fromBytes(png)) {
            assertEquals(16, decoded.width());
            assertEquals(12, decoded.height());
        }
    }

    @Test
    void additionalPixelPipelineBindingsAreCallable() {
        var extractBand = Vips.vips_extract_band.makeInvoker(ValueLayout.ADDRESS);
        var bandjoin = Vips.vips_bandjoin.makeInvoker(ValueLayout.ADDRESS);
        var bandjoinConst1 = Vips.vips_bandjoin_const1.makeInvoker(ValueLayout.ADDRESS);
        var unpremultiply = Vips.vips_unpremultiply.makeInvoker(ValueLayout.ADDRESS);

        MemorySegment joinedConst = MemorySegment.NULL;
        MemorySegment alpha = MemorySegment.NULL;
        MemorySegment joined = MemorySegment.NULL;
        MemorySegment unpremultiplied = MemorySegment.NULL;
        try (VipsImage source = VipsImage.fromPixels(
                     rgbPixels(8, 6), 8, 6, 3, Vips.VIPS_FORMAT_UCHAR());
             Arena arena = Arena.ofConfined()) {
            assertEquals(0, Vips.vips_image_hasalpha(source.address()));

            MemorySegment output = arena.allocate(ValueLayout.ADDRESS);
            assertEquals(0, bandjoinConst1.apply(
                    source.address(), output, 255.0, MemorySegment.NULL));
            joinedConst = output.get(ValueLayout.ADDRESS, 0);
            assertEquals(4, Vips.vips_image_get_bands(joinedConst));
            assertEquals(1, Vips.vips_image_hasalpha(joinedConst));

            assertEquals(0, extractBand.apply(
                    joinedConst, output, 3, MemorySegment.NULL));
            alpha = output.get(ValueLayout.ADDRESS, 0);
            assertEquals(1, Vips.vips_image_get_bands(alpha));

            MemorySegment inputs = arena.allocate(ValueLayout.ADDRESS, 2);
            inputs.setAtIndex(ValueLayout.ADDRESS, 0, source.address());
            inputs.setAtIndex(ValueLayout.ADDRESS, 1, alpha);
            assertEquals(0, bandjoin.apply(
                    inputs, output, 2, MemorySegment.NULL));
            joined = output.get(ValueLayout.ADDRESS, 0);
            assertEquals(4, Vips.vips_image_get_bands(joined));

            assertEquals(0, unpremultiply.apply(
                    joined, output, MemorySegment.NULL));
            unpremultiplied = output.get(ValueLayout.ADDRESS, 0);
            assertEquals(4, Vips.vips_image_get_bands(unpremultiplied));
        } finally {
            unref(unpremultiplied);
            unref(joined);
            unref(alpha);
            unref(joinedConst);
        }
    }

    @Test
    void profileAwareColorBindingsAreCallable() {
        assertTrue(LibVips.hasOperation("icc_import"));
        assertTrue(LibVips.hasOperation("icc_transform"));
        assertNotNull(Vips.vips_icc_import.makeInvoker(ValueLayout.ADDRESS));
        assertNotNull(Vips.vips_icc_transform.makeInvoker(ValueLayout.ADDRESS));
    }

    @Test
    void metadataBindingsAreCallable() {
        byte[] encoded = Base64.getDecoder().decode(TINY_AVIF);
        try (VipsImage image = VipsImage.fromBytes(encoded);
             Arena arena = Arena.ofConfined()) {
            MemorySegment fields = Vips.vips_image_get_fields(image.address());
            assertTrue(fields.address() != 0);
            Set<String> names = new HashSet<>();
            try {
                MemorySegment entries = fields.reinterpret(
                        256L * ValueLayout.ADDRESS.byteSize());
                for (long index = 0; index < 256; index++) {
                    MemorySegment field = entries.getAtIndex(
                            ValueLayout.ADDRESS, index);
                    if (field.address() == 0) {
                        break;
                    }
                    names.add(field.reinterpret(1024).getString(0));
                }
            } finally {
                Vips.g_strfreev(fields);
            }
            assertTrue(names.containsAll(Set.of("width", "xres", "exif-data")));

            MemorySegment width = arena.allocateFrom("width");
            MemorySegment xres = arena.allocateFrom("xres");
            MemorySegment exifData = arena.allocateFrom("exif-data");
            assertTrue(Vips.vips_image_get_typeof(image.address(), width) != 0);
            assertEquals(Vips.vips_blob_get_type(),
                    Vips.vips_image_get_typeof(image.address(), exifData));

            MemorySegment stringOut = arena.allocate(ValueLayout.ADDRESS);
            assertEquals(0, Vips.vips_image_get_as_string(
                    image.address(), width, stringOut));
            MemorySegment string = stringOut.get(ValueLayout.ADDRESS, 0);
            assertTrue(string.address() != 0);
            try {
                assertEquals("4", string.reinterpret(64).getString(0));
            } finally {
                Vips.g_free(string);
            }

            MemorySegment intOut = arena.allocate(ValueLayout.JAVA_INT);
            assertEquals(0, Vips.vips_image_get_int(
                    image.address(), width, intOut));
            assertEquals(4, intOut.get(ValueLayout.JAVA_INT, 0));

            MemorySegment doubleOut = arena.allocate(ValueLayout.JAVA_DOUBLE);
            assertEquals(0, Vips.vips_image_get_double(
                    image.address(), xres, doubleOut));
            assertTrue(doubleOut.get(ValueLayout.JAVA_DOUBLE, 0) > 0.0);

            MemorySegment blobOut = arena.allocate(ValueLayout.ADDRESS);
            MemorySegment lengthOut = arena.allocate(ValueLayout.JAVA_LONG);
            assertEquals(0, Vips.vips_image_get_blob(
                    image.address(), exifData, blobOut, lengthOut));
            assertTrue(blobOut.get(ValueLayout.ADDRESS, 0).address() != 0);
            assertTrue(lengthOut.get(ValueLayout.JAVA_LONG, 0) > 0);
        }
    }

    @Test
    void reviewedRasterEncodersRoundTripInMemory() {
        byte[] pixels = rgbPixels(24, 18);
        try (VipsImage source = VipsImage.fromPixels(
                pixels, 24, 18, 3, Vips.VIPS_FORMAT_UCHAR())) {
            for (String suffix : Set.of(
                    ".jpg", ".png", ".tif", ".webp", ".jxl", ".jp2")) {
                byte[] encoded = source.writeToBuffer(suffix);
                assertTrue(encoded.length > 16,
                        () -> suffix + " encoder returned too little data");
                try (VipsImage decoded = VipsImage.fromBytes(encoded)) {
                    assertEquals(24, decoded.width(), suffix);
                    assertEquals(18, decoded.height(), suffix);
                }
            }
        }
    }

    @Test
    void avifAndGifAreDecodeOnly() {
        assertDecodedDimensions(TINY_AVIF, 4, 3);
        assertDecodedDimensions(TINY_GIF, 4, 3);

        byte[] pixels = rgbPixels(4, 3);
        try (VipsImage source = VipsImage.fromPixels(
                pixels, 4, 3, 3, Vips.VIPS_FORMAT_UCHAR())) {
            assertThrows(VipsException.class,
                    () -> source.writeToBuffer(".avif"));
            assertThrows(VipsException.class,
                    () -> source.writeToBuffer(".gif"));
        }
    }

    @Test
    void rawPixelsAndClosedHandleChecksWork() {
        byte[] pixels = new byte[8 * 6 * 3];
        VipsImage image = VipsImage.fromPixels(
                pixels, 8, 6, 3, Vips.VIPS_FORMAT_UCHAR());
        assertEquals(8, image.width());
        image.close();
        assertThrows(IllegalStateException.class, image::width);
        image.close();
    }

    private static byte[] rgbPixels(int width, int height) {
        byte[] pixels = new byte[width * height * 3];
        int index = 0;
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                pixels[index++] = (byte) (x * 255 / (width - 1));
                pixels[index++] = (byte) (y * 255 / (height - 1));
                pixels[index++] = 80;
            }
        }
        return pixels;
    }

    private static void assertDecodedDimensions(
            String base64, int width, int height) {
        byte[] encoded = Base64.getDecoder().decode(base64);
        try (VipsImage decoded = VipsImage.fromBytes(encoded)) {
            assertEquals(width, decoded.width());
            assertEquals(height, decoded.height());
        }
    }

    private static void unref(MemorySegment image) {
        if (image.address() != 0) {
            Vips.g_object_unref(image);
        }
    }

    private static final String TINY_AVIF =
            "AAAAHGZ0eXBhdmlmAAAAAG1pZjFhdmlmbWlhZgAAARdtZXRhAAAAAAAAACFoZGxy"
            + "AAAAAAAAAABwaWN0AAAAAAAAAAAAAAAAAAAAADRpbG9jAAAAAERAAAIAAQAAAAABOwAB"
            + "AAAAAAAAAB8AAgAAAAABWgABAAAAAAAAAL4AAAA4aWluZgAAAAAAAgAAABVpbmZlAgAA"
            + "AAABAABhdjAxAAAAABVpbmZlAgAAAQACAABFeGlmAAAAAA5waXRtAAAAAAABAAAAVmlw"
            + "cnAAAAA4aXBjbwAAAAxhdjFDgQAMAAAAABRpc3BlAAAAAAAAAAQAAAADAAAAEHBpeGkA"
            + "AAAAAwgICAAAABZpcG1hAAAAAAAAAAEAAQOBAgMAAAAaaXJlZgAAAAAAAAAOY2RzYwAC"
            + "AAEAAQAAAOVtZGF0EgAKCBgEeaICGg0IMhEZR4eGIYAAaAAAkEDOl7ddEgAAAAZFeGlm"
            + "AABJSSoACAAAAAYAEgEDAAEAAAABAAAAGgEFAAEAAABWAAAAGwEFAAEAAABeAAAAKAED"
            + "AAEAAAACAAAAEwIDAAEAAAABAAAAaYcEAAEAAABmAAAAAAAAADhjAADoAwAAOGMAAOgD"
            + "AAAGAACQBwAEAAAAMDIxMAGRBwAEAAAAAQIDAACgBwAEAAAAMDEwMAGgAwABAAAA//8A"
            + "AAKgBAABAAAABAAAAAOgBAABAAAAAwAAAAAAAAA=";

    private static final String TINY_GIF =
            "R0lGODlhBAADAIAAAExpcQAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFAAAAACwAAAAA"
            + "BAADAAACA4yPVgA7";
}
