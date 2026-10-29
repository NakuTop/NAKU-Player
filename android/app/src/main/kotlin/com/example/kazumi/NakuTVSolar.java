package com.example.kazumi;

import java.util.Calendar;
import java.util.GregorianCalendar;
import java.util.Locale;
import java.util.TimeZone;

/** Pure UTC solar geometry, ported from Home Display's NOAA approximation.
 * Geographic daylight is independent of the viewer's camera/model rotation.
 * Visual day/night only; not a navigation or astronomical precision API.
 */
public final class NakuTVSolar {
    public static final int MIN_TEXTURE_TIER = 2048;
    public static final int MAX_TEXTURE_TIER = 8192;
    public static final long MEMORY_RESERVE_BYTES = 128L * 1024L * 1024L;
    private static final long MIB = 1024L * 1024L;
    private NakuTVSolar() {}

    /** Native Earth-local basis: x=cos(lat)*sin(lon), y=sin(lat), z=cos(lat)*cos(lon). */
    public static double[] earthFixedSunDirection(long utcEpochMillis) {
        GregorianCalendar utc = new GregorianCalendar(TimeZone.getTimeZone("UTC"), Locale.ROOT);
        utc.setTimeInMillis(utcEpochMillis);
        double days = utc.getActualMaximum(Calendar.DAY_OF_YEAR);
        double minutes = utc.get(Calendar.HOUR_OF_DAY) * 60.0
                + utc.get(Calendar.MINUTE) + utc.get(Calendar.SECOND) / 60.0;
        double gamma = 2.0 * Math.PI / days
                * (utc.get(Calendar.DAY_OF_YEAR) - 1.0 + (minutes / 60.0 - 12.0) / 24.0);
        double equationMinutes = 229.18 * (0.000075 + 0.001868 * Math.cos(gamma)
                - 0.032077 * Math.sin(gamma) - 0.014615 * Math.cos(2.0 * gamma)
                - 0.040849 * Math.sin(2.0 * gamma));
        double declination = 0.006918 - 0.399912 * Math.cos(gamma)
                + 0.070257 * Math.sin(gamma) - 0.006758 * Math.cos(2.0 * gamma)
                + 0.000907 * Math.sin(2.0 * gamma) - 0.002697 * Math.cos(3.0 * gamma)
                + 0.001480 * Math.sin(3.0 * gamma);
        double degrees = (720.0 - minutes - equationMinutes) / 4.0;
        double longitude = (((degrees + 180.0) % 360.0 + 360.0) % 360.0 - 180.0)
                * Math.PI / 180.0;
        double radius = Math.cos(declination);
        return new double[] {
                radius * Math.sin(longitude), Math.sin(declination), radius * Math.cos(longitude)
        };
    }

    /** Exact two RGBA mip chains plus one temporary decoded RGBA bitmap. */
    public static long texturePeakBytes(int tier) {
        if (tier <= 0 || tier > MAX_TEXTURE_TIER || (tier & (tier - 1)) != 0) {
            throw new IllegalArgumentException("Texture tier must be a bounded power of two");
        }
        long base = (long) tier * Math.max(1, tier / 2) * 4L;
        long mip = 0;
        int width = tier, height = Math.max(1, tier / 2);
        while (true) {
            mip += (long) width * height * 4L;
            if (width == 1 && height == 1) break;
            width = Math.max(1, width / 2);
            height = Math.max(1, height / 2);
        }
        return 2L * mip + base;
    }

    /** availableBytes is current free/reclaimable system RAM (ActivityManager.availMem).
     * Reserve >=128 MiB for 8K/4K, >=32 MiB for 2K, or 25% free RAM.
     * Low-RAM devices increase that fixed reserve by 50% and retain 33% RAM,
     * without forcing a lower tier when the highest tier still fits.
     * A bitmap decode may consume at most half the advertised Java heap.
     * Unknown system RAM permits 2K only when the known heap can decode it.
     * A zero result means no supported complete day/night pair fits safely.
     */
    public static int textureTier(int maxTextureSize, long availableBytes,
            int memoryClassMb, boolean lowRam) {
        long heap = Math.max(0L, (long) memoryClassMb) * MIB;
        for (int tier : new int[] {8192, 4096, 2048}) {
            long decode = (long) tier * (tier / 2) * 4L;
            if (maxTextureSize < tier || decode > heap / 2L) continue;
            if (availableBytes <= 0) {
                if (tier == MIN_TEXTURE_TIER) return tier;
                continue;
            }
            long reserve = textureReserveBytes(tier, availableBytes, lowRam);
            long usable = Math.max(0L, availableBytes - reserve);
            if (texturePeakBytes(tier) <= usable) return tier;
        }
        return 0;
    }

    public static long textureReserveBytes(int tier, long availableBytes, boolean lowRam) {
        long fixed = tier >= 4096 ? MEMORY_RESERVE_BYTES : MEMORY_RESERVE_BYTES / 4L;
        if (lowRam) fixed += fixed / 2L;
        return Math.max(fixed, Math.max(0L, availableBytes) / (lowRam ? 3L : 4L));
    }
}
