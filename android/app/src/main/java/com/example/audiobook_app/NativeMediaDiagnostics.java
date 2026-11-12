package com.example.audiobook_app;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.support.v4.media.session.MediaControllerCompat;
import android.support.v4.media.session.PlaybackStateCompat;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Read-only observer of the existing session. Never binds/starts/stops a service,
 * creates a media session, requests focus, or requests Bluetooth permissions. */
public final class NativeMediaDiagnostics {
    private static NativeMediaDiagnostics instance;
    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ThreadPoolExecutor writer = new ThreadPoolExecutor(
            1, 1, 30, TimeUnit.SECONDS, new ArrayBlockingQueue<>(64), runnable -> {
                Thread thread = new Thread(runnable, "dogreader-diagnostics");
                thread.setDaemon(true);
                return thread;
            });
    private final DiagnosticJournal journal;
    private final AtomicInteger dropped = new AtomicInteger();
    private final AtomicInteger failures = new AtomicInteger();
    private final String process = Process.myPid() + "-" + System.currentTimeMillis();
    private MediaControllerCompat controller;
    private boolean started;
    private String lastState;
    private String lastService;
    private String lastRoutes;

    private final MediaControllerCompat.Callback callback = new MediaControllerCompat.Callback() {
        @Override public void onPlaybackStateChanged(PlaybackStateCompat state) {
            if (recordState(state)) observeService();
        }
        @Override public void onSessionDestroyed() {
            event("session_destroyed", "token", token());
        }
        @Override public void onSessionReady() {
            event("session_ready", "token", token());
        }
    };

    private NativeMediaDiagnostics(Context context) {
        this.context = context.getApplicationContext();
        journal = new DiagnosticJournal(new File(this.context.getFilesDir(), "media_diagnostics"), 64 * 1024);
        writer.allowCoreThreadTimeOut(true);
        event("native_process_started", "sdk", Build.VERSION.SDK_INT);
    }

    public static synchronized NativeMediaDiagnostics get(Context context) {
        if (instance == null) instance = new NativeMediaDiagnostics(context);
        return instance;
    }

    private void enqueue(Runnable action) {
        try {
            writer.execute(action);
        } catch (RejectedExecutionException ignored) {
            dropped.incrementAndGet();
        }
    }

    // Callers supply fixed event/field names and numeric/boolean values only.
    void event(String name, Object... fields) {
        try {
            JSONObject value = new JSONObject();
            value.put("timeMs", System.currentTimeMillis());
            value.put("elapsedMs", SystemClock.elapsedRealtime());
            value.put("process", process);
            value.put("event", name);
            value.put("dropped", dropped.get());
            value.put("ioFailures", failures.get());
            for (int i = 0; i + 1 < fields.length; i += 2) {
                Object field = fields[i + 1];
                if (field instanceof Number || field instanceof Boolean) value.put((String) fields[i], field);
            }
            String line = value.toString();
            enqueue(() -> {
                try { journal.append(line); }
                catch (Exception ignored) { failures.incrementAndGet(); }
            });
        } catch (Exception ignored) {
            failures.incrementAndGet();
        }
    }

    public void start(MediaControllerCompat existingController) {
        if (!started) {
            started = true;
            try {
                AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
                audio.registerAudioDeviceCallback(new AudioDeviceCallback() {
                    @Override public void onAudioDevicesAdded(AudioDeviceInfo[] added) { recordRoutes(audio); }
                    @Override public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) { recordRoutes(audio); }
                }, main);
                recordRoutes(audio);
            } catch (Exception ignored) { event("route_observer_unavailable"); }
            if (Build.VERSION.SDK_INT >= 30) {
                enqueue(() -> {
                    try {
                        ActivityManager manager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
                        for (ApplicationExitInfo exit : manager.getHistoricalProcessExitReasons(context.getPackageName(), 0, 3)) {
                            event("previous_process_exit", "pid", exit.getPid(), "reason", exit.getReason(),
                                    "importance", exit.getImportance(), "exitTimeMs", exit.getTimestamp());
                        }
                    } catch (Exception ignored) { event("exit_history_unavailable"); }
                });
            }
        }
        observe(existingController);
    }

    public void observe(MediaControllerCompat existingController) {
        try {
            if (existingController != null && (controller == null ||
                    !controller.getSessionToken().equals(existingController.getSessionToken()))) {
                if (controller != null) controller.unregisterCallback(callback);
                controller = existingController;
                lastState = null;
                controller.registerCallback(callback, main);
                event("session_observed", "token", token());
            }
            if (controller == null) event("session_not_observed");
            else recordState(controller.getPlaybackState());
            observeService();
        } catch (Exception ignored) { event("session_observer_unavailable"); }
    }

    private int token() { return controller == null ? 0 : controller.getSessionToken().hashCode(); }

    private boolean recordState(PlaybackStateCompat state) {
        if (state == null) return false;
        String key = token() + ":" + state.getState() + ":" + state.getActions() + ":" + state.getErrorCode();
        if (key.equals(lastState)) return false;
        lastState = key;
        event("native_playback_state", "token", token(), "state", state.getState(),
                "actions", state.getActions(), "positionMs", state.getPosition(), "errorCode", state.getErrorCode());
        return true;
    }

    @SuppressWarnings("deprecation")
    private void observeService() {
        try {
            ActivityManager manager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
            for (ActivityManager.RunningServiceInfo service : manager.getRunningServices(100)) {
                if (service.service.getPackageName().equals(context.getPackageName()) &&
                        service.service.getClassName().equals("com.ryanheise.audioservice.AudioService")) {
                    String key = service.pid + ":" + service.activeSince + ":" + service.foreground + ":" + service.started;
                    if (!key.equals(lastService)) {
                        lastService = key;
                        event("service_observed", "pid", service.pid, "activeSinceMs", service.activeSince,
                                "foreground", service.foreground, "started", service.started);
                    }
                    return;
                }
            }
            if (!"absent".equals(lastService)) { lastService = "absent"; event("service_not_observed"); }
        } catch (Exception ignored) { event("service_observer_unavailable"); }
    }

    private void recordRoutes(AudioManager audio) {
        try {
            int[] types = Arrays.stream(audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS))
                    .mapToInt(AudioDeviceInfo::getType).distinct().sorted().toArray();
            String key = Arrays.toString(types);
            if (key.equals(lastRoutes)) return;
            lastRoutes = key;
            event("output_devices_changed", "count", types.length);
            // Available output types, not proof of the route actually playing.
            for (int type : types) event("available_output_type", "type", type);
        } catch (Exception ignored) { event("route_snapshot_unavailable"); }
    }

    public interface ExportCallback { void complete(File file, String error); }

    public void export(String dartLog, ExportCallback callback) {
        // Reject rather than enqueue indefinitely when diagnostics are saturated.
        try {
            writer.execute(() -> {
                try {
                    File directory = new File(context.getCacheDir(), "media_diagnostics");
                    if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException();
                    File file = new File(directory, "dogreader-media-diagnostics.txt");
                    String header = "\nNative diagnostics: dropped=" + dropped.get() + "; ioFailures=" + failures.get() + "\n";
                    try (FileOutputStream stream = new FileOutputStream(file)) {
                        stream.write(dartLog.getBytes(StandardCharsets.UTF_8));
                        stream.write(header.getBytes(StandardCharsets.UTF_8));
                        stream.write(journal.snapshot().getBytes(StandardCharsets.UTF_8));
                        stream.write(com.ryanheise.audioservice.MediaTransportDiagnostics.snapshot().getBytes(StandardCharsets.UTF_8));
                    }
                    main.post(() -> callback.complete(file, null));
                } catch (Exception ignored) { main.post(() -> callback.complete(null, "storage_unavailable")); }
            });
        } catch (RejectedExecutionException ignored) { callback.complete(null, "diagnostics_busy"); }
    }
}
