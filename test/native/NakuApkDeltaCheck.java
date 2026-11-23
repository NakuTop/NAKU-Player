package com.example.kazumi;

import java.io.File;
import java.nio.file.Files;

/** Run the APK's production patch reader against the final signed release. */
public class NakuApkDeltaCheck {
    public static void main(String[] args) throws Exception {
        File base = new File(args[0]), delta = new File(args[1]);
        File result = new File(args[2]), expected = new File(args[3]);
        NakuApkDelta.apply(base, delta, result, expected.length(), () -> false);
        if (Files.mismatch(result.toPath(), expected.toPath()) != -1)
            throw new AssertionError("Reconstructed APK differs from signed release");
    }
}
