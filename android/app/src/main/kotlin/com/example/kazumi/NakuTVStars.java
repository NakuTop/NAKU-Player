package com.example.kazumi;

import java.util.Arrays;

/** Frozen original Home Display starfield geometry, prepared only on resize.
 * No clock, model rotation, random device seed or input state enters this API.
 */
public final class NakuTVStars {
    public static final int MAX_CANDIDATES = 960;
    public static final int STRIDE = 5; // clip x/y, fixed light, warmth, pixel size
    private static final long MASK = 0xffffffffL;
    private NakuTVStars() {}

    public static float[] geometry(int width, int height) {
        if (width <= 0 || height <= 0 || width > 32768 || height > 32768) {
            throw new IllegalArgumentException("A bounded positive viewport is required");
        }
        double shortest = Math.min(width, height);
        double aspectX = width / shortest, aspectY = height / shortest;
        float[] values = new float[MAX_CANDIDATES * STRIDE];
        long seed = 0x4f524249L;
        int at = 0;
        for (int star = 0; star < MAX_CANDIDATES; star++) {
            // Original starSeeds uses a Float32Array, so round before geometry.
            seed = (seed * 1664525L + 1013904223L) & MASK;
            double x = (float) (seed / 4294967296.0);
            seed = (seed * 1664525L + 1013904223L) & MASK;
            double y = (float) (seed / 4294967296.0);
            seed = (seed * 1664525L + 1013904223L) & MASK;
            double z = (float) (seed / 4294967296.0);
            seed = (seed * 1664525L + 1013904223L) & MASK;
            double w = (float) (seed / 4294967296.0);

            // Freeze the original entrance-complete, time-zero, input-free view.
            double radius = .68 + Math.pow(x, .72) * 1.85;
            double phase = Math.floor(y * 3.0) * 2.0943951 + radius * 1.86;
            double spread = (z - .5) * (.15 + radius * .16);
            double orbitX = Math.cos(phase) * (radius + spread);
            double orbitY = Math.sin(phase) * .53 * (radius + spread);
            double positionX = .956 * orbitX - .292 * orbitY;
            double positionY = .292 * orbitX + .956 * orbitY
                    + .06 * Math.sin(phase * 2.0 + w * 6.28);
            boolean distant = w < .45;
            if (distant) {
                positionX = (x * 2.0 - 1.0) * aspectX * 1.08;
                positionY = (y * 2.0 - 1.0) * aspectY * 1.08;
            }
            double clipX = positionX / aspectX, clipY = positionY / aspectY;
            if (Math.abs(clipX) > 1.0 || Math.abs(clipY) > 1.0) continue;
            double centralQuiet = .28 + .72 * smooth(.35, .88,
                    Math.sqrt(positionX * positionX + positionY * positionY));
            double brightness = distant ? .21 + z * .29 : .32 + z * .48;
            double frozenLight = brightness * (.93 + .07 * Math.sin(x * 70.0)) * centralQuiet;
            // Keep flight/clock text readable without another overlay/filter.
            double textQuiet = .52 + .48 * smooth(-.15, .25, clipX);
            values[at++] = (float) clipX;
            values[at++] = (float) clipY;
            values[at++] = (float) (frozenLight * textQuiet);
            values[at++] = (float) y;
            values[at++] = (float) (2.0 + z * 2.3 + (z >= .988 ? 3.8 : 0.0));
        }
        return Arrays.copyOf(values, at);
    }

    private static double smooth(double low, double high, double value) {
        double t = Math.max(0, Math.min(1, (value - low) / (high - low)));
        return t * t * (3.0 - 2.0 * t);
    }
}
