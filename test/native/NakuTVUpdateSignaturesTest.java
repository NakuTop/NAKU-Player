package com.example.kazumi;

import java.nio.charset.StandardCharsets;
import java.util.Set;

public final class NakuTVUpdateSignaturesTest {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static final byte[][] A = {"abc".getBytes(StandardCharsets.UTF_8)};
    private static final byte[][] B = {"other-certificate".getBytes(StandardCharsets.UTF_8)};
    public static void main(String[] args) {
        Set<String> expected = Set.of("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        check(NakuTVUpdateSignatures.read(true, modern -> {
            if (!modern) throw new AssertionError("available modern cert must not fall back");
            return A;
        }).equals(expected), "modern SHA-256 uses complete certificate bytes");
        int[] calls = {0, 0};
        check(NakuTVUpdateSignatures.read(true, modern -> {
            calls[modern ? 0 : 1]++;
            return modern ? null : A;
        }).equals(expected), "missing SigningInfo recovers from legacy package manager query");
        check(calls[0] == 1 && calls[1] == 1, "fallback actually repeats the package manager query");
        check(NakuTVUpdateSignatures.read(true, modern -> {
            if (modern) throw new IllegalStateException("firmware cannot read SigningInfo");
            return A;
        }).equals(expected), "firmware API exception recovers from legacy query");
        check(NakuTVUpdateSignatures.read(false, modern -> {
            if (modern) throw new AssertionError("pre-28 must never query SigningInfo");
            return A;
        }).equals(expected), "older Android uses GET_SIGNATURES directly");
        check(NakuTVUpdateSignatures.read(true, modern -> new byte[0][]).isEmpty(), "empty certificates grant no match");
        check(NakuTVUpdateSignatures.read(true, modern -> { throw new Exception("unavailable"); }).isEmpty(), "both API failures stay unreadable");
        check(NakuTVUpdateSignatures.read(true, modern -> new byte[][]{A[0], null}).isEmpty(), "partial certificate set is rejected");
        check(NakuTVUpdateSignatures.read(true, modern -> new byte[][]{new byte[0]}).isEmpty(), "empty certificate is rejected");
        Set<String> different = NakuTVUpdateSignatures.read(true, modern -> B);
        check(!different.equals(expected), "different signer still fails equality");
        Set<String> both = NakuTVUpdateSignatures.read(true, modern -> new byte[][]{A[0], B[0]});
        check(both.size() == 2 && !both.equals(expected), "additional signer cannot match a single signer");
        check(both.equals(NakuTVUpdateSignatures.read(true, modern -> new byte[][]{B[0], A[0]})), "signer order is irrelevant");
        System.out.println("PASS " + checks + " production certificate-read checks; real TV installation remains manual acceptance.");
    }
}
