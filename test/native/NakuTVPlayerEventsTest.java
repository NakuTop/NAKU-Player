package com.example.kazumi;

import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class NakuTVPlayerEventsTest {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static NakuTVPlayerEvents.Snapshot state(long position, long buffer,
            boolean playing, boolean buffering, boolean ended, boolean first) {
        return new NakuTVPlayerEvents.Snapshot(position, 7_200_000L, buffer,
                playing, buffering, ended, first, 3840, 2160);
    }
    private static Map<String, Object> full(NakuTVPlayerEvents.Snapshot s) {
        Map<String, Object> expected = new HashMap<>();
        expected.put("id", 7);
        expected.put("positionMs", s.positionMs);
        expected.put("durationMs", s.durationMs);
        expected.put("bufferMs", s.bufferMs);
        expected.put("playing", s.playing);
        expected.put("buffering", s.buffering);
        expected.put("completed", s.completed);
        expected.put("firstFrame", s.firstFrame);
        expected.put("width", s.width);
        expected.put("height", s.height);
        return expected;
    }
    public static void main(String[] args) {
        int gateChecks = 0;
        for (int bits = 0; bits < 128; bits++) {
            boolean playing = (bits & 1) != 0, intent = (bits & 2) != 0;
            boolean buffering = (bits & 4) != 0, foreground = (bits & 8) != 0;
            boolean visible = (bits & 16) != 0, listening = (bits & 32) != 0;
            boolean closed = (bits & 64) != 0;
            long interval = NakuTVPlayerEvents.pollIntervalMs(playing, intent, buffering,
                    foreground, visible, listening, closed);
            long expected = closed || !foreground || !visible || !listening ? 0L
                    : playing ? 250L : intent && buffering ? 1000L : 0L;
            check(interval == expected, "poll lifecycle/intent gate " + bits);
            gateChecks++;
        }
        NakuTVPlayerEvents packets = new NakuTVPlayerEvents();
        Map<String, Object> reconstructed = new HashMap<>();
        int fields = 0;
        for (int frame = 0; frame < 240; frame++) {
            NakuTVPlayerEvents.Snapshot s = state(frame * 250L, 30_000L + frame * 250L,
                    true, false, false, true);
            Map<String, Object> delta = packets.packet(7, s, Collections.emptyMap(), false);
            check(delta != null, "250ms playback clock never coalesced away");
            fields += delta.size() - 1;
            reconstructed.putAll(delta);
            check(reconstructed.equals(full(s)), "delta reconstructs exact playback state " + frame);
        }
        check(fields == 487, "static metadata excluded from 239 following clock packets");
        int baseline = 240 * 9;
        check(fields * 4 < baseline, "state serialization fields reduced by over 75 percent");
        NakuTVPlayerEvents.Snapshot paused = state(60_000L, 90_000L, false, false, false, true);
        check(packets.packet(7, paused, Collections.emptyMap(), false) != null, "pause immediate");
        for (int sample = 0; sample < 600; sample++) {
            check(packets.packet(7, paused, Collections.emptyMap(), false) == null, "idle produces no packet");
        }
        NakuTVPlayerEvents.Snapshot seek = state(120_000L, 120_000L, false, true, false, true);
        Map<String, Object> sought = packets.packet(7, seek, Collections.emptyMap(), false);
        check(Long.valueOf(120_000L).equals(sought.get("positionMs")), "paused seek emitted immediately");
        check(Boolean.TRUE.equals(sought.get("buffering")), "paused seek buffering state emitted");
        NakuTVPlayerEvents.Snapshot stalled = state(120_000L, 135_000L, true, true, false, true);
        Map<String, Object> ramp = packets.packet(7, stalled, Collections.emptyMap(), false);
        check(Long.valueOf(135_000L).equals(ramp.get("bufferMs")), "buffer progress preserved");
        NakuTVPlayerEvents.Snapshot ended = state(7_200_000L, 7_200_000L, false, false, true, true);
        Map<String, Object> end = packets.packet(7, ended, Collections.emptyMap(), false);
        check(Boolean.TRUE.equals(end.get("completed")), "completion immediate");
        check(Boolean.FALSE.equals(end.get("playing")), "end clears playback intent state");
        Map<String, Object> tracks = Map.of("tracks", List.of(Map.of("id", "2:0", "label", "中文")),
                "cues", List.of("字幕"));
        Map<String, Object> replay = packets.packet(7, ended, tracks, true);
        check(replay.keySet().containsAll(full(ended).keySet()), "resume forces every state key");
        check(replay.get("tracks").equals(tracks.get("tracks")), "resume replays native track metadata");
        check(replay.get("cues").equals(tracks.get("cues")), "resume replays current cues");
        check(packets.packet(7, ended, tracks, false) == null, "repeated metadata is suppressed");
        check(packets.packet(7, ended, Map.of("error", "4005"), false) != null, "terminal error immediate");
        check(packets.packet(7, ended, Map.of("error", "4005"), false) != null, "repeat error not lost");
        packets.invalidate();
        check(packets.packet(7, paused, tracks, false).size() == 12, "new open invalidates metadata cache");
        System.out.println("PASS " + checks + " native bridge checks; lifecycle table=" + gateChecks
                + "; 60s clock fields " + baseline + " -> " + fields
                + "; idle duplicate packets=0/600; subtitle clock=250ms; buffering=1000ms.");
    }
}
