package io.github.ghosthack.libvipsffm.jpmstest;

import io.github.ghosthack.libvipsffm.LibVips;

public final class Main {
    private Main() {}

    public static void main(String[] args) {
        String version = LibVips.version();
        if (!version.startsWith("8.18.")) {
            throw new AssertionError("unexpected libvips version: " + version);
        }
        System.out.println("JPMS libvips " + version);
    }
}

