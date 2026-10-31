package com.example.kazumi;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Output compatibility, independent of codec size support. Never re-label DV5 as HDR10. */
public final class NakuTVColorPolicy {
    private static final Pattern DV = Pattern.compile("(?:^|[, ])(?:dvhe|dvh1|dvav|dva1|dav1)\\.(\\d{2})\\.", Pattern.CASE_INSENSITIVE);
    public static final int SDR = 0, HDR10 = 1, HLG = 2, DOLBY_VISION = 3,
            BASE_LAYER = 4, UNSUPPORTED = -1;
    private NakuTVColorPolicy() {}

    public static boolean legacyHuawei(String model) {
        return model != null && model.toUpperCase(Locale.ROOT).replaceAll("[^A-Z0-9]", "").equals("HEGE570");
    }

    public static int dolbyProfile(String codecs) {
        Matcher match = DV.matcher(codecs == null ? "" : codecs);
        return match.find() ? Integer.parseInt(match.group(1)) : -1;
    }

    public static boolean allowDecoder(String mime, boolean hardware, boolean softwareOnly,
            boolean displayDolbyVision) {
        if (mime == null || !mime.startsWith("video/")) return true;
        return hardware && !softwareOnly &&
                (!"video/dolby-vision".equals(mime) || displayDolbyVision);
    }

    /** transfer is Android/Media3 COLOR_TRANSFER: PQ=6, HLG=7; full range=1. */
    public static int mode(String mime, String codecs, int transfer, int range,
            boolean displayKnown, boolean dolbyVision, boolean hdr10, boolean hlg) {
        int profile = dolbyProfile(codecs);
        boolean dv = "video/dolby-vision".equals(mime) || profile >= 0;
        if (dv && dolbyVision) return DOLBY_VISION;
        if (dv) {
            // Media3's supported base-layer profiles. Profile 4/5/unknown must
            // never be sent to an ordinary HEVC decoder. DV10 ICtCp is not SDR.
            if (profile != 7 && profile != 8 && profile != 9 && profile != 10) return UNSUPPORTED;
            if (profile == 10 && transfer == 6 && range == 1) return UNSUPPORTED;
            if (profile == 7 && displayKnown && !hdr10) return UNSUPPORTED;
        }
        if (displayKnown && ((transfer == 6 && !hdr10) || (transfer == 7 && !hlg))) return UNSUPPORTED;
        if (dv) return BASE_LAYER;
        return transfer == 6 ? HDR10 : transfer == 7 ? HLG : SDR;
    }
}
