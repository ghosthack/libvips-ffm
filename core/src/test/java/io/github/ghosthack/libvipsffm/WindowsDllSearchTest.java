package io.github.ghosthack.libvipsffm;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Bundled DLLs load their dependencies from the bundle, not from
 * {@code PATH}. A decoy directory on the child process's {@code PATH} holds
 * copies of every bundled DLL; with a {@code PATH}-searching load, a bundled
 * DLL whose dependency is not loaded yet binds to the decoy copy (with a
 * different build on a real host — MSYS2, a libvips install — that is the
 * "specified procedure could not be found" failure).
 */
@EnabledOnOs(OS.WINDOWS)
class WindowsDllSearchTest {

    @Test
    void bundledDependenciesNeverResolveFromPath(@TempDir Path temp) throws Exception {
        Path decoy = Files.createDirectory(temp.resolve("decoy"));
        Path cache = Files.createDirectory(temp.resolve("cache"));
        List<String> names = manifest();
        for (String name : names) {
            try (InputStream dll = resource("libvips-natives/windows-x64/" + name)) {
                Files.copy(dll, decoy.resolve(name));
            }
        }

        String classPath = System.getProperty("java.class.path");
        String modulePath = System.getProperty("jdk.module.path");
        if (modulePath != null && !modulePath.isBlank()) {
            classPath = classPath + File.pathSeparator + modulePath;
        }
        String java = ProcessHandle.current().info().command().orElseThrow();
        ProcessBuilder builder = new ProcessBuilder(java, "--enable-native-access=ALL-UNNAMED",
                "-Dlibvipsffm.cachedir=" + cache, "-cp", classPath,
                WindowsDllProbe.class.getName())
                .redirectErrorStream(true);
        // The inherited key is spelled "Path"; set that one, never a second copy.
        var environment = builder.environment();
        String pathKey = environment.keySet().stream()
                .filter(key -> key.equalsIgnoreCase("PATH")).findFirst().orElse("Path");
        environment.put(pathKey, decoy + File.pathSeparator + environment.getOrDefault(pathKey, ""));
        Process child = builder.start();
        String output = new String(child.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        assertTrue(child.waitFor(60, TimeUnit.SECONDS), "probe finished");
        assertEquals(0, child.exitValue(), output);

        Path realDecoy = decoy.toRealPath();
        List<String> fromDecoy = new ArrayList<>();
        int bundled = 0;
        Path bundle = cache.resolve(Version.VERSION + "-windows-x64").toRealPath();
        for (String line : output.lines().toList()) {
            String[] parts = line.split("\t", 2);
            if (parts.length != 2 || !parts[0].equals("module")) continue;
            Path loaded = Path.of(parts[1]).toRealPath();
            if (loaded.startsWith(realDecoy)) fromDecoy.add(loaded.getFileName().toString());
            if (loaded.startsWith(bundle)) bundled++;
        }
        assertTrue(bundled >= names.size() - 1, "bundled modules found: " + bundled + "\n" + output);
        assertTrue(output.contains("version\t8.18."), output);
        assertEquals(List.of(), fromDecoy, "DLLs loaded from the PATH decoy instead of the bundle");
    }

    private static List<String> manifest() throws Exception {
        try (InputStream manifest = resource("libvips-natives/windows-x64/manifest.txt")) {
            return new String(manifest.readAllBytes(), StandardCharsets.UTF_8)
                    .lines().map(String::trim).filter(l -> !l.isEmpty()).toList();
        }
    }

    private static InputStream resource(String name) {
        InputStream stream = WindowsDllSearchTest.class.getClassLoader().getResourceAsStream(name);
        if (stream == null) throw new IllegalStateException("missing test resource " + name);
        return stream;
    }
}
