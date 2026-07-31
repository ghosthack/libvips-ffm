package io.github.ghosthack.libvipsffm;

import io.github.ghosthack.libvipsffm.libvips.Vips;
import org.junit.jupiter.api.Test;

import java.util.Base64;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
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
