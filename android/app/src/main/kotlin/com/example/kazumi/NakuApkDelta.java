package com.example.kazumi;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.io.RandomAccessFile;
import java.util.function.BooleanSupplier;
import java.util.zip.GZIPInputStream;

/** Streaming GDIFF v4 reader for signed universal APKs. */
public final class NakuApkDelta {
    private NakuApkDelta() {}
    private static final long LIMIT = 500L * 1024 * 1024;

    public static void apply(File base, File patch, File output, long size, BooleanSupplier cancelled)
            throws IOException {
        if (size <= 0 || size > LIMIT || !output.createNewFile())
            throw new IOException("更新包大小或临时文件无效");
        boolean complete = false;
        try {
            try (RandomAccessFile old = new RandomAccessFile(base, "r");
                 FileInputStream raw = new FileInputStream(patch);
                 DataInputStream in = new DataInputStream(new BufferedInputStream(new GZIPInputStream(raw, 65536), 65536));
                 FileOutputStream out = new FileOutputStream(output)) {
                if (in.readInt() != 0xd1ffd1ff || in.readUnsignedByte() != 4)
                    throw new IOException("差分格式不匹配");
                byte[] buffer = new byte[65536];
                long remaining = size, oldSize = old.length();
                for (int operations = 0; ; operations++) {
                    checkCancelled(cancelled);
                    int op = in.readUnsignedByte();
                    if (op == 0) {
                        if (remaining != 0 || in.read() != -1) throw new IOException("差分内容不完整");
                        break;
                    }
                    if (operations >= 1000000) throw new IOException("差分指令过多");
                    long offset = -1;
                    int length;
                    if (op <= 248) {
                        length = op <= 246 ? op : op == 247 ? in.readUnsignedShort() : in.readInt();
                    } else {
                        offset = op <= 251 ? in.readUnsignedShort() : op <= 254 ? in.readInt() : in.readLong();
                        length = op == 249 || op == 252 ? in.readUnsignedByte()
                                : op == 250 || op == 253 ? in.readUnsignedShort() : in.readInt();
                        if (offset < 0 || offset > oldSize - length) throw new IOException("旧安装包范围不匹配");
                        old.seek(offset);
                    }
                    if (length <= 0 || length > remaining) throw new IOException("差分长度不正确");
                    remaining -= length;
                    while (length > 0) {
                        checkCancelled(cancelled);
                        int count = Math.min(buffer.length, length);
                        if (offset < 0) in.readFully(buffer, 0, count); else old.readFully(buffer, 0, count);
                        out.write(buffer, 0, count);
                        length -= count;
                    }
                }
            }
            complete = true;
        } finally {
            if (!complete) output.delete();
        }
    }

    private static void checkCancelled(BooleanSupplier cancelled) throws InterruptedIOException {
        if (cancelled.getAsBoolean() || Thread.currentThread().isInterrupted())
            throw new InterruptedIOException("已取消更新");
    }
}
