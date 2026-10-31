package com.example.kazumi;

import java.security.MessageDigest;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/** Reads only certificates verified by Android's package manager. */
public final class NakuTVUpdateSignatures {
    public interface Reader {
        byte[][] read(boolean modern) throws Exception;
    }

    private NakuTVUpdateSignatures() {}

    public static Set<String> read(boolean modernSupported, Reader reader) {
        if (modernSupported) {
            Set<String> modern = attempt(reader, true);
            if (!modern.isEmpty()) return modern;
        }
        // Some TV firmware leaves SigningInfo empty for an APK archive. Ask
        // PackageManager again with GET_SIGNATURES; never accept an empty set.
        return attempt(reader, false);
    }

    private static Set<String> attempt(Reader reader, boolean modern) {
        try {
            byte[][] certificates = reader.read(modern);
            if (certificates == null || certificates.length == 0) return Collections.emptySet();
            Set<String> result = new HashSet<>();
            char[] hex = "0123456789abcdef".toCharArray();
            for (byte[] certificate : certificates) {
                if (certificate == null || certificate.length == 0) return Collections.emptySet();
                byte[] digest = MessageDigest.getInstance("SHA-256").digest(certificate);
                StringBuilder fingerprint = new StringBuilder(64);
                for (byte value : digest) {
                    fingerprint.append(hex[(value & 255) >>> 4]).append(hex[value & 15]);
                }
                result.add(fingerprint.toString());
            }
            return Collections.unmodifiableSet(result);
        } catch (Exception unavailable) {
            return Collections.emptySet();
        }
    }
}
