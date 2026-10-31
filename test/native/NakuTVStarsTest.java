package com.example.kazumi;

import java.util.Arrays;
import java.util.TimeZone;

/** Checks production frozen-star geometry without an Android or GL dependency. */
public final class NakuTVStarsTest {
    private static int assertions;
    public static void main(String[] args) {
        float[] standard = NakuTVStars.geometry(1280, 720);
        validate(standard, "1280x720");
        for (int i = 0; i < 40; i++) {
            check(Arrays.equals(standard, NakuTVStars.geometry(1280, 720)),
                    "same viewport keeps every position and brightness stable");
        }
        check(Arrays.equals(standard, NakuTVStars.geometry(1920, 1080)),
                "same aspect ratio retains normalized star layout");
        check(Arrays.equals(standard, NakuTVStars.geometry(3840, 2160)),
                "4K does not alter density or introduce a larger per-frame workload");
        float[] wide = NakuTVStars.geometry(1280, 360);
        validate(wide, "ultrawide");
        check(!Arrays.equals(standard, wide), "viewport reshaping prepares an aspect-correct layout");
        validate(NakuTVStars.geometry(960, 540), "960x540");
        validate(NakuTVStars.geometry(720, 1280), "portrait");
        validate(NakuTVStars.geometry(32768, 32768), "bounded maximum");
        for (int[] invalid : new int[][] {{0,720}, {1280,0}, {-1,1}, {1,-1}, {32769,720}}) {
            boolean rejected = false;
            try { NakuTVStars.geometry(invalid[0], invalid[1]); }
            catch (IllegalArgumentException expected) { rejected = true; }
            check(rejected, "invalid viewport is rejected before allocation");
        }
        TimeZone original = TimeZone.getDefault();
        try {
            for (String zone : new String[] {"UTC", "Asia/Shanghai", "America/Los_Angeles"}) {
                TimeZone.setDefault(TimeZone.getTimeZone(zone));
                check(Arrays.equals(standard, NakuTVStars.geometry(1280, 720)),
                        "timezone cannot move or brighten stars");
            }
        } finally { TimeZone.setDefault(original); }
        double left = 0, right = 0;
        int leftCount = 0, rightCount = 0;
        for (int i = 0; i < standard.length; i += NakuTVStars.STRIDE) {
            if (standard[i] < -.2f) { left += standard[i+2]; leftCount++; }
            if (standard[i] > .25f) { right += standard[i+2]; rightCount++; }
        }
        check(leftCount > 50 && rightCount > 50, "both sides retain visible static stars");
        check(left / leftCount < right / rightCount * .85,
                "flight and clock side remains quieter than open sky");
        System.out.println("PASS: NakuTVStars production geometry; " + assertions
                + " assertions; " + standard.length / NakuTVStars.STRIDE + " stars at 1280x720");
    }

    private static void validate(float[] points, String name) {
        check(points.length % NakuTVStars.STRIDE == 0, name + " complete vertices");
        int count = points.length / NakuTVStars.STRIDE;
        check(count >= 80 && count <= NakuTVStars.MAX_CANDIDATES, name + " bounded visible density");
        for (int i = 0; i < points.length; i += NakuTVStars.STRIDE) {
            for (int k = 0; k < NakuTVStars.STRIDE; k++) {
                check(Float.isFinite(points[i+k]), name + " finite data");
            }
            check(Math.abs(points[i]) <= 1 && Math.abs(points[i+1]) <= 1,
                    name + " no offscreen buffer entries");
            check(points[i+2] > 0 && points[i+2] <= 1.0, name + " bounded brighter base light");
            check(points[i+3] >= 0 && points[i+3] <= 1, name + " original cool/warm mix range");
            check(points[i+4] >= 3.1 && points[i+4] <= 10.61, name + " bounded larger point sizes");
        }
    }
    private static void check(boolean result, String message) {
        assertions++;
        if (!result) throw new AssertionError(message);
    }
}
