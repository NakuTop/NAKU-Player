package com.example.kazumi;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/** Main-thread-confined Media3 -> Flutter state deltas. No media URLs/headers. */
public final class NakuTVPlayerEvents {
    public static final long PLAYING_INTERVAL_MS = 250L;
    public static final long BUFFERING_INTERVAL_MS = 1000L;

    public static long pollIntervalMs(boolean actuallyPlaying, boolean playIntent,
            boolean buffering, boolean foreground, boolean visible,
            boolean listening, boolean closed) {
        if (closed || !foreground || !visible || !listening) return 0L;
        if (actuallyPlaying) return PLAYING_INTERVAL_MS;
        return playIntent && buffering ? BUFFERING_INTERVAL_MS : 0L;
    }

    public static final class Snapshot {
        public final long positionMs, durationMs, bufferMs;
        public final boolean playing, buffering, completed, firstFrame;
        public final int width, height;
        public Snapshot(long positionMs, long durationMs, long bufferMs,
                boolean playing, boolean buffering, boolean completed,
                boolean firstFrame, int width, int height) {
            this.positionMs = positionMs;
            this.durationMs = durationMs;
            this.bufferMs = bufferMs;
            this.playing = playing;
            this.buffering = buffering;
            this.completed = completed;
            this.firstFrame = firstFrame;
            this.width = width;
            this.height = height;
        }
    }

    private Snapshot last;
    private final Map<String, Object> metadata = new HashMap<>();

    public void invalidate() {
        last = null;
        metadata.clear();
    }

    /** Null means no state changed. Full snapshots are forced on reconnect/resume. */
    public Map<String, Object> packet(int id, Snapshot next,
            Map<String, ?> extra, boolean full) {
        boolean all = full || last == null;
        Map<String, Object> out = new LinkedHashMap<>(12);
        out.put("id", id);
        if (all || next.positionMs != last.positionMs) out.put("positionMs", next.positionMs);
        if (all || next.durationMs != last.durationMs) out.put("durationMs", next.durationMs);
        if (all || next.bufferMs != last.bufferMs) out.put("bufferMs", next.bufferMs);
        if (all || next.playing != last.playing) out.put("playing", next.playing);
        if (all || next.buffering != last.buffering) out.put("buffering", next.buffering);
        if (all || next.completed != last.completed) out.put("completed", next.completed);
        if (all || next.firstFrame != last.firstFrame) out.put("firstFrame", next.firstFrame);
        if (all || next.width != last.width) out.put("width", next.width);
        if (all || next.height != last.height) out.put("height", next.height);
        last = next;
        for (Map.Entry<String, ?> entry : extra.entrySet()) {
            String key = entry.getKey();
            Object value = entry.getValue();
            // Every terminal error occurrence matters, even if its code repeats.
            if (all || "error".equals(key) || !metadata.containsKey(key)
                    || !Objects.equals(metadata.get(key), value)) out.put(key, value);
            if (!"error".equals(key)) metadata.put(key, value);
        }
        return out.size() == 1 ? null : out;
    }
}
