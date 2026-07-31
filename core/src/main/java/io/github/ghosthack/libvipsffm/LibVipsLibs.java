package io.github.ghosthack.libvipsffm;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.lang.foreign.Arena;
import java.lang.foreign.Linker;
import java.lang.foreign.SymbolLookup;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;

/**
 * Resolves the libvips shared library used by the generated bindings.
 *
 * <p>Resolution order is an explicit directory, this platform's classified
 * native jar, then a host installation visible through {@code java.library.path}.
 */
public final class LibVipsLibs {
    private static final Arena LIBRARY_ARENA = Arena.ofAuto();
    private static volatile SymbolLookup lookup;

    private LibVipsLibs() {}

    /** Returns the process-lifetime symbol lookup, resolving it on first use. */
    public static SymbolLookup lookup() {
        SymbolLookup current = lookup;
        if (current == null) {
            synchronized (LibVipsLibs.class) {
                current = lookup;
                if (current == null) {
                    lookup = current = resolve();
                }
            }
        }
        return current;
    }

    /** Returns the Maven native classifier for the current operating system. */
    public static String classifier() {
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        String arch = System.getProperty("os.arch", "").toLowerCase(Locale.ROOT);
        String architecture = switch (arch) {
            case "aarch64", "arm64" -> "arm64";
            case "amd64", "x86_64", "x64" -> "x64";
            default -> throw unsupported(os, arch);
        };

        if (os.contains("mac") && architecture.equals("arm64")) {
            return "macos-arm64";
        }
        if (os.contains("win") && architecture.equals("x64")) {
            return "windows-x64";
        }
        if (os.contains("linux") && architecture.equals("x64")) {
            return "linux-x64";
        }
        throw unsupported(os, arch);
    }

    private static SymbolLookup resolve() {
        String override = System.getProperty("libvipsffm.libdir");
        if (override == null || override.isBlank()) {
            override = System.getenv("LIBVIPS_FFM_LIBDIR");
        }
        if (override != null && !override.isBlank()) {
            return requireVips(fromDirectory(Path.of(override)),
                    "no usable libvips shared library in " + override);
        }

        SymbolLookup bundled = fromBundle();
        if (bundled != null) {
            return requireVips(bundled, "bundled native does not export vips_init");
        }

        SymbolLookup system = fromSystem();
        if (system != null) {
            return system;
        }

        throw new IllegalStateException(
                "libvips is unavailable for " + classifier()
                        + "; add io.github.ghosthack:libvips-ffm-natives:"
                        + Version.VERSION + ":" + classifier()
                        + " at runtime, or set LIBVIPS_FFM_LIBDIR");
    }

    private static SymbolLookup fromDirectory(Path directory) {
        if (!Files.isDirectory(directory)) {
            throw new IllegalStateException("libvipsffm.libdir is not a directory: " + directory);
        }
        try (var files = Files.list(directory)) {
            List<Path> libraries = files
                    .filter(LibVipsLibs::isVipsLibrary)
                    .sorted()
                    .toList();
            if (libraries.isEmpty()) {
                throw new IllegalStateException("no libvips shared library found in " + directory);
            }
            return chain(libraries);
        } catch (IOException e) {
            throw new UncheckedIOException("cannot inspect " + directory, e);
        }
    }

    private static boolean isVipsLibrary(Path path) {
        String name = path.getFileName().toString().toLowerCase(Locale.ROOT);
        boolean sharedLibrary = name.endsWith(".dll")
                || name.endsWith(".dylib")
                || name.contains(".so");
        return sharedLibrary && name.contains("vips") && !name.contains("module");
    }

    private static SymbolLookup fromBundle() {
        String platform = classifier();
        String resourceBase = "libvips-natives/" + platform + "/";
        List<String> manifest = readLines(resourceBase + "manifest.txt");
        if (manifest == null) {
            return null;
        }
        if (manifest.isEmpty()) {
            throw new IllegalStateException("empty bundled native manifest for " + platform);
        }
        List<String> libraries = manifest.stream()
                .map(LibVipsLibs::safeFileName)
                .distinct()
                .toList();
        List<String> mainLines = readLines(resourceBase + "main-library.txt");
        String mainLibrary;
        if (mainLines == null && libraries.size() == 1) {
            // Backward compatibility with the original single-library jars.
            mainLibrary = libraries.getFirst();
        } else if (mainLines != null && mainLines.size() == 1) {
            mainLibrary = safeFileName(mainLines.getFirst());
        } else {
            throw new IllegalStateException(
                    "expected exactly one bundled main library for " + platform);
        }
        if (!libraries.contains(mainLibrary)) {
            throw new IllegalStateException(
                    "bundled main library is absent from manifest: " + mainLibrary);
        }
        Path cacheDirectory = cacheRoot().resolve(Version.VERSION + "-" + platform);

        try {
            Files.createDirectories(cacheDirectory);
            Path lockFile = cacheDirectory.resolve(".extract.lock");
            try (FileChannel channel = FileChannel.open(lockFile,
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE);
                 var ignored = channel.lock()) {
                for (String library : libraries) {
                    extractVerified(
                            resourceBase + library,
                            cacheDirectory.resolve(library),
                            readExpectedHash(resourceBase, library));
                }
            }
            if (platform.equals("windows-x64")) {
                preloadWindowsDependencies(
                        cacheDirectory, libraries, mainLibrary);
            }
            return SymbolLookup.libraryLookup(
                    cacheDirectory.resolve(mainLibrary).toAbsolutePath(),
                    LIBRARY_ARENA);
        } catch (IOException e) {
            throw new UncheckedIOException(
                    "failed to extract bundled libvips native to " + cacheDirectory, e);
        }
    }

    private static void preloadWindowsDependencies(
            Path directory, List<String> libraries, String mainLibrary) {
        List<String> pending = new ArrayList<>(libraries);
        pending.remove(mainLibrary);
        UnsatisfiedLinkError lastFailure = null;
        while (!pending.isEmpty()) {
            int countBefore = pending.size();
            for (Iterator<String> iterator = pending.iterator();
                 iterator.hasNext(); ) {
                String library = iterator.next();
                try {
                    System.load(directory.resolve(library)
                            .toAbsolutePath().toString());
                    iterator.remove();
                } catch (UnsatisfiedLinkError e) {
                    // A dependency later in the manifest may not be loaded yet.
                    lastFailure = e;
                }
            }
            if (pending.size() == countBefore) {
                throw new IllegalStateException(
                        "cannot preload bundled Windows native dependencies: "
                                + pending,
                        lastFailure);
            }
        }
    }

    private static SymbolLookup fromSystem() {
        for (String candidate : List.of("vips", "vips-42", "libvips-42", "vips-cpp")) {
            try {
                System.loadLibrary(candidate);
                SymbolLookup loaded = SymbolLookup.loaderLookup();
                if (loaded.find("vips_init").isPresent()) {
                    return loaded.or(Linker.nativeLinker().defaultLookup());
                }
            } catch (LinkageError ignored) {
                // Try the next platform naming convention.
            }
        }
        SymbolLookup fallback = SymbolLookup.loaderLookup()
                .or(Linker.nativeLinker().defaultLookup());
        return fallback.find("vips_init").isPresent() ? fallback : null;
    }

    private static SymbolLookup chain(List<Path> libraries) {
        SymbolLookup result = null;
        for (Path library : libraries) {
            SymbolLookup next = SymbolLookup.libraryLookup(
                    library.toAbsolutePath(), LIBRARY_ARENA);
            result = result == null ? next : result.or(next);
        }
        return result;
    }

    private static SymbolLookup requireVips(SymbolLookup candidate, String message) {
        if (candidate.find("vips_init").isEmpty()) {
            throw new IllegalStateException(message);
        }
        return candidate.or(SymbolLookup.loaderLookup())
                .or(Linker.nativeLinker().defaultLookup());
    }

    private static List<String> readLines(String resource) {
        try (InputStream stream = LibVipsLibs.class.getClassLoader()
                .getResourceAsStream(resource)) {
            if (stream == null) {
                return null;
            }
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8)
                    .lines()
                    .map(String::trim)
                    .filter(line -> !line.isEmpty())
                    .toList();
        } catch (IOException e) {
            throw new UncheckedIOException("cannot read " + resource, e);
        }
    }

    private static String readExpectedHash(String resourceBase, String library) {
        List<String> lines = readLines(resourceBase + "manifest.sha256");
        if (lines == null) {
            throw new IllegalStateException("missing native hash manifest for " + classifier());
        }
        return lines.stream()
                .map(line -> line.split("\\s+", 2))
                .filter(parts -> parts.length == 2)
                .filter(parts -> parts[1].replaceFirst("^\\*", "").equals(library))
                .map(parts -> parts[0].toLowerCase(Locale.ROOT))
                .findFirst()
                .orElseThrow(() -> new IllegalStateException(
                        "missing SHA-256 for bundled native " + library));
    }

    private static void extractVerified(
            String resource, Path target, String expectedHash) throws IOException {
        if (Files.isRegularFile(target) && sha256(target).equals(expectedHash)) {
            return;
        }
        Path temporary = Files.createTempFile(
                target.getParent(), target.getFileName().toString(), ".tmp");
        try {
            try (InputStream stream = LibVipsLibs.class.getClassLoader()
                    .getResourceAsStream(resource)) {
                if (stream == null) {
                    throw new IOException("missing classpath resource " + resource);
                }
                Files.copy(stream, temporary, StandardCopyOption.REPLACE_EXISTING);
            }
            String actualHash = sha256(temporary);
            if (!actualHash.equals(expectedHash)) {
                throw new IOException("SHA-256 mismatch for " + resource
                        + ": expected " + expectedHash + ", got " + actualHash);
            }
            try {
                Files.move(temporary, target,
                        StandardCopyOption.REPLACE_EXISTING,
                        StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    private static String sha256(Path path) throws IOException {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            try (InputStream stream = Files.newInputStream(path)) {
                byte[] buffer = new byte[64 * 1024];
                for (int count; (count = stream.read(buffer)) >= 0; ) {
                    digest.update(buffer, 0, count);
                }
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (NoSuchAlgorithmException e) {
            throw new AssertionError("JDK must provide SHA-256", e);
        }
    }

    private static Path cacheRoot() {
        String override = System.getProperty("libvipsffm.cachedir");
        if (override != null && !override.isBlank()) {
            return Path.of(override);
        }
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        if (os.contains("win")) {
            String localAppData = System.getenv("LOCALAPPDATA");
            if (localAppData != null && !localAppData.isBlank()) {
                return Path.of(localAppData, "libvips-ffm");
            }
        } else if (os.contains("mac")) {
            return Path.of(System.getProperty("user.home"), "Library", "Caches", "libvips-ffm");
        } else {
            String xdgCache = System.getenv("XDG_CACHE_HOME");
            if (xdgCache != null && !xdgCache.isBlank()) {
                return Path.of(xdgCache, "libvips-ffm");
            }
        }
        return Path.of(System.getProperty("user.home"), ".cache", "libvips-ffm");
    }

    private static String safeFileName(String value) {
        Path name = Path.of(value);
        if (name.getNameCount() != 1 || !name.getFileName().toString().equals(value)) {
            throw new IllegalStateException("unsafe native manifest entry: " + value);
        }
        return value;
    }

    private static IllegalStateException unsupported(String os, String arch) {
        return new IllegalStateException(
                "unsupported libvips-ffm platform: os.name=" + os + ", os.arch=" + arch);
    }
}
