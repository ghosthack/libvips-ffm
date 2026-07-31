package io.github.ghosthack.libvipsffm;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.Properties;

/** Binding and libvips versions. */
public final class Version {
    public static final String VERSION;
    public static final String LIBVIPS_VERSION;

    static {
        Properties properties = new Properties();
        try (InputStream stream = Version.class.getResourceAsStream("version.properties")) {
            if (stream == null) {
                throw new IllegalStateException("missing version.properties");
            }
            properties.load(stream);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        VERSION = required(properties, "version");
        LIBVIPS_VERSION = required(properties, "libvips.version");
    }

    private Version() {}

    private static String required(Properties properties, String key) {
        String value = properties.getProperty(key);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("missing version property " + key);
        }
        return value;
    }
}
