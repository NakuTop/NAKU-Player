package com.example.kazumi;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TimeZone;

/** Tests the production helper against executed original-TS snapshots.
 * No second implementation of the NOAA solar equations lives in this test.
 */
public final class NakuTVSolarTest {
    private static final double TOL = 2e-12;
    private static final long MIB = 1024L * 1024L;
    private static int assertions;
    private static final Map<String, double[]> VECTORS = new HashMap<>();

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Pass original-TS fixture TSV");
        int cases = 0;
        for (String line : Files.readAllLines(Path.of(args[0]), StandardCharsets.UTF_8)) {
            if (line.isBlank() || line.startsWith("#")) continue;
            String[] cells = line.split("\\t");
            String name = cells[0];
            long epoch = Long.parseLong(cells[1]);
            double[] actual = NakuTVSolar.earthFixedSunDirection(epoch);
            check(actual.length == 3, name + " has exactly xyz");
            for (int component = 0; component < 3; component++) {
                check(Double.isFinite(actual[component]), name + " finite component " + component);
                near(actual[component], Double.parseDouble(cells[component + 2]), TOL,
                        name + " original TS native-basis component " + component);
                check(Math.abs(actual[component]) <= 1.0 + TOL, name + " unit component range");
            }
            near(length(actual), 1.0, TOL, name + " unit direction");
            double latitude = Math.toDegrees(Math.asin(actual[1]));
            double longitude = Math.toDegrees(Math.atan2(actual[0], actual[2]));
            near(latitude, Double.parseDouble(cells[5]), 2e-10, name + " original declination");
            near(longitude, Double.parseDouble(cells[6]), 2e-10, name + " original longitude");
            check(Math.abs(latitude) < 24.5, name + " seasonal declination range");
            check(longitude >= -180 && longitude < 180, name + " wrapped longitude");
            double[] shanghai = normalAt(31.23, 121.47);
            double altitude = Math.toDegrees(Math.asin(clamp(dot(actual, shanghai))));
            near(altitude, Double.parseDouble(cells[7]), 2e-10, name + " Shanghai original altitude");
            String phase = altitude >= -0.833 ? "day" : altitude >= -6 ? "twilight" : "night";
            check(phase.equals(cells[8]), name + " Shanghai original day/night phase");
            for (double yaw : new double[] {-180, -90, -15, 0, 83, 180, 721}) {
                near(dot(rotateY(actual, yaw), rotateY(shanghai, yaw)), dot(actual, shanghai),
                        TOL, name + " geographic daylight invariant under display yaw " + yaw);
            }
            TimeZone initial = TimeZone.getDefault();
            try {
                for (String zone : List.of("UTC", "Asia/Shanghai", "America/Los_Angeles", "Pacific/Auckland")) {
                    TimeZone.setDefault(TimeZone.getTimeZone(zone));
                    double[] changed = NakuTVSolar.earthFixedSunDirection(epoch);
                    for (int i = 0; i < 3; i++) near(changed[i], actual[i], 0,
                            name + " independent of JVM default timezone " + zone);
                }
            } finally {
                TimeZone.setDefault(initial);
            }
            VECTORS.put(name, actual);
            cases++;
        }
        check(cases >= 20, "equinox/solstices/leap/year/current-day fixtures exist");
        check(dot(VECTORS.get("equinox-midnight"), VECTORS.get("equinox-noon")) < -0.999,
                "twelve UTC hours rotates daylight approximately to opposite hemisphere");
        check(VECTORS.get("summer-solstice")[1] > 0.39, "northern summer solar declination");
        check(VECTORS.get("winter-solstice")[1] < -0.39, "northern winter solar declination");
        double[] china = normalAt(31.23, 121.47);
        check(dot(VECTORS.get("current-shanghai-noon"), china) > 0,
                "2026-10-29 local noon lights China");
        check(dot(VECTORS.get("current-shanghai-midnight"), china) < 0,
                "2026-10-29 local midnight darkens China");
        double[] second = VECTORS.get("current-fractional-minute");
        double[] subSecond = VECTORS.get("current-milliseconds-ignored-like-original");
        for (int i = 0; i < 3; i++) near(second[i], subSecond[i], 0,
                "subseconds ignored exactly like original TS");
        long wallTime = Instant.parse("2026-10-29T04:00:00Z").toEpochMilli();
        double[] resumed = NakuTVSolar.earthFixedSunDirection(wallTime + 12L * 3600_000L);
        for (int i = 0; i < 3; i++) near(resumed[i], VECTORS.get("current-shanghai-midnight")[i], 0,
                "recompute after 12-hour wall-clock advance, without animation time");
        texturePolicy();
        System.out.println("PASS: " + cases + " original-TS solar cases, " + assertions
                + " checks; JVM zone=" + System.getProperty("user.timezone"));
    }

    private static void texturePolicy() {
        equal(NakuTVSolar.texturePeakBytes(1), 12L, "1x1: two RGBA textures + bitmap");
        equal(NakuTVSolar.texturePeakBytes(2), 32L, "2x1: complete mip chains");
        equal(NakuTVSolar.texturePeakBytes(4), 120L, "4x2: complete mip chains");
        equal(NakuTVSolar.texturePeakBytes(2048), 30_758_232L, "2K pair + all mipmaps + decode");
        equal(NakuTVSolar.texturePeakBytes(4096), 123_032_920L, "4K pair + all mipmaps + decode");
        equal(NakuTVSolar.texturePeakBytes(8192), 492_131_672L, "8K pair + all mipmaps + decode");
        equal(NakuTVSolar.textureReserveBytes(8192, 256*MIB, false), 128*MIB,
                "normal high-tier fixed reserve128MiB");
        equal(NakuTVSolar.textureReserveBytes(2048, 64*MIB, false), 32*MIB,
                "normal2K fixed reserve32MiB");
        equal(NakuTVSolar.textureReserveBytes(8192, 256*MIB, true), 192*MIB,
                "low-RAM high-tier fixed reserve192MiB");
        equal(NakuTVSolar.textureReserveBytes(2048, 64*MIB, true), 48*MIB,
                "low-RAM2K fixed reserve48MiB");
        equal(NakuTVSolar.textureReserveBytes(8192, 2048*MIB, false), 512*MIB,
                "ample RAM still reserves25percent");
        for (int invalid : new int[] {-1, 0, 3, 5000, 16384}) {
            boolean threw = false;
            try { NakuTVSolar.texturePeakBytes(invalid); }
            catch (IllegalArgumentException expected) { threw = true; }
            check(threw, "reject invalid or unbounded texture tier " + invalid);
        }
        equal(NakuTVSolar.textureTier(1024, 2048 * MIB, 512, false), 0,
                "driver below2K disables textured Earth safely");
        equal(NakuTVSolar.textureTier(2048, 2048 * MIB, 512, false), 2048, "2K GPU ceiling");
        equal(NakuTVSolar.textureTier(4096, 2048 * MIB, 512, false), 4096, "4K GPU ceiling");
        equal(NakuTVSolar.textureTier(8192, 2048 * MIB, 512, false), 8192,
                "8K stays8K when both day/night and transient decode fit");
        equal(NakuTVSolar.textureTier(16384, 2048 * MIB, 512, false), 8192,
                "asset highest supported tier remains8K");
        equal(NakuTVSolar.textureTier(8192, 256 * MIB, 512, false), 4096,
                "system budget admits4K but not8K");
        equal(NakuTVSolar.textureTier(8192, 160 * MIB, 512, false), 2048,
                "system budget admits2K but not4K");
        equal(NakuTVSolar.textureTier(8192, 2048 * MIB, 64, false), 4096,
                "heap64MiB admits one4K decode, not8K");
        equal(NakuTVSolar.textureTier(8192, 2048 * MIB, 63, false), 2048,
                "heap63MiB cannot admit one4K decode");
        equal(NakuTVSolar.textureTier(8192, 2048 * MIB, 512, true), 8192,
                "low-RAM flag alone must not force2K when reported budgets fit8K");
        equal(NakuTVSolar.textureTier(8192, 1, 512, false), 0,
                "known insufficient RAM cannot allocate even2K");
        equal(NakuTVSolar.textureTier(8192, 2048 * MIB, 1, false), 0,
                "known insufficient heap cannot decode even2K");
        equal(NakuTVSolar.textureTier(8192, 600*MIB, 512, false), 4096,
                "8K total working set does not fit below available boundary");
        equal(NakuTVSolar.textureTier(8192, 640*MIB, 512, false), 8192,
                "8K total working set fits above available boundary");
        equal(NakuTVSolar.textureTier(8192, 0, 128, false), 2048,
                "unknown free RAM stays conservative with adequate known heap");
        equal(NakuTVSolar.textureTier(8192, 2048*MIB, 0, false), 0,
                "unknown heap cannot safely decode a bitmap");
        for (boolean lowRam : new boolean[] {false, true}) {
            for (long available : new long[] {1, 127*MIB, 128*MIB, 160*MIB, 256*MIB, 512*MIB, 768*MIB, 2048*MIB}) {
                for (int memoryClass : new int[] {1, 16, 32, 64, 128, 256, 512}) {
                    int tier = NakuTVSolar.textureTier(8192, available, memoryClass, lowRam);
                    check(tier == 0 || tier == 2048 || tier == 4096 || tier == 8192,
                            "bounded known tier for available/heap/lowRam");
                    if (tier == 0) continue;
                    long reserve = NakuTVSolar.textureReserveBytes(tier, available, lowRam);
                    check(NakuTVSolar.texturePeakBytes(tier) <= Math.max(0, available-reserve),
                            "both textures+mips+decode fit available RAM minus reserve: available="
                                    + available + ", heap=" + memoryClass + ", tier=" + tier + ", lowRam=" + lowRam);
                    long decode = (long)tier*(tier/2)*4;
                    check(decode <= (long)memoryClass*MIB/2,
                            "single bitmap fits half advertised heap");
                }
            }
        }
        // This validates the production selection budget, not GPU allocation/OOM
        // behavior itself; the GLES renderer must still retry/skip failed loads.
    }

    private static double[] normalAt(double lat, double lon) {
        double a = Math.toRadians(lat), b = Math.toRadians(lon);
        return new double[] {Math.cos(a)*Math.sin(b), Math.sin(a), Math.cos(a)*Math.cos(b)};
    }
    private static double[] rotateY(double[] v, double degrees) {
        double a = Math.toRadians(degrees), c = Math.cos(a), s = Math.sin(a);
        return new double[] {c*v[0]+s*v[2], v[1], -s*v[0]+c*v[2]};
    }
    private static double dot(double[] a, double[] b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
    private static double length(double[] v) { return Math.sqrt(dot(v,v)); }
    private static double clamp(double x) { return Math.max(-1, Math.min(1,x)); }
    private static void equal(long actual, long expected, String label) {
        check(actual == expected, label + ": expected " + expected + ", got " + actual);
    }
    private static void near(double actual, double expected, double tolerance, String label) {
        check(Double.isFinite(actual) && Math.abs(actual-expected) <= tolerance,
                label + ": expected " + expected + ", got " + actual);
    }
    private static void check(boolean condition, String label) {
        assertions++;
        if (!condition) throw new AssertionError(label);
    }
}
