package com.ryanheise.audioservice;

import android.content.Context;
import android.os.Process;
import android.os.SystemClock;
import org.json.JSONObject;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/** Bounded, independent native evidence. Callers pass fixed labels, never media data. */
public final class MediaTransportDiagnostics {
    private static final int LIMIT = 64 * 1024;
    private static final AtomicInteger dropped = new AtomicInteger();
    private static final AtomicInteger failures = new AtomicInteger();
    private static final AtomicLong sequence = new AtomicLong();
    private static final ThreadPoolExecutor writer = new ThreadPoolExecutor(
            1, 1, 30, TimeUnit.SECONDS, new ArrayBlockingQueue<>(64), task -> {
                Thread thread = new Thread(task, "audio-service-transport-diagnostics");
                thread.setDaemon(true);
                return thread;
            });
    private static volatile File directory;
    static { writer.allowCoreThreadTimeOut(true); }

    static void initialize(Context context) {
        directory = new File(context.getFilesDir(), "media_transport_diagnostics");
    }

    static void record(String event, String command, int service, int token,
                       boolean listener, boolean ready) {
        if (directory == null) return;
        try {
            String line = new JSONObject()
                    .put("timeMs", System.currentTimeMillis())
                    .put("elapsedMs", SystemClock.elapsedRealtime())
                    .put("pid", Process.myPid()).put("sequence", sequence.incrementAndGet())
                    .put("event", event).put("command", command)
                    .put("service", service).put("token", token)
                    .put("listener", listener).put("flutterReady", ready)
                    .put("dropped", dropped.get()).put("ioFailures", failures.get()) + "\n";
            writer.execute(() -> {
                try { append(line); }
                catch (Exception ignored) { failures.incrementAndGet(); }
            });
        } catch (Exception ignored) { dropped.incrementAndGet(); }
    }

    private static synchronized void append(String line) throws Exception {
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException();
        File current = new File(directory, "transport.jsonl");
        File previous = new File(directory, "transport.previous.jsonl");
        byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
        if (current.length() + bytes.length > LIMIT) {
            if (previous.exists() && !previous.delete()) throw new IllegalStateException();
            if (!current.renameTo(previous)) throw new IllegalStateException();
        }
        try (FileOutputStream stream = new FileOutputStream(current, true)) { stream.write(bytes); }
    }

    /** Called on the app's export worker, never from transport. Pending writes may be omitted. */
    public static synchronized String snapshot() {
        StringBuilder result = new StringBuilder("\nNative command transport: dropped=" + dropped.get()
                + "; ioFailures=" + failures.get() + "\n");
        if (directory == null) return result.append("Not initialized\n").toString();
        for (String name : new String[]{"transport.previous.jsonl", "transport.jsonl"}) {
            File file = new File(directory, name);
            if (!file.exists()) continue;
            try (FileInputStream stream = new FileInputStream(file)) {
                byte[] bytes = new byte[LIMIT];
                int length = 0, read;
                while (length < bytes.length && (read = stream.read(bytes, length, bytes.length - length)) != -1)
                    length += read;
                result.append("\n--- ").append(name).append(" ---\n")
                        .append(new String(bytes, 0, length, StandardCharsets.UTF_8));
            } catch (Exception ignored) { result.append("Transport journal unavailable\n"); }
        }
        return result.toString();
    }
}
