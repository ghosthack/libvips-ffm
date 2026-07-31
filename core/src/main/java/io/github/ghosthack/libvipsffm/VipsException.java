package io.github.ghosthack.libvipsffm;

/** Reports a failed libvips operation together with libvips' error buffer. */
public final class VipsException extends RuntimeException {
    public VipsException(String message) {
        super(message);
    }
}

