package com.example.audiobook_app;

import android.app.Instrumentation;
import android.app.KeyguardManager;
import android.app.UiAutomation;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Rect;
import android.media.browse.MediaBrowser;
import android.media.AudioManager;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.session.MediaController;
import android.media.session.PlaybackState;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import com.ryanheise.audioservice.AudioService;
import com.ryanheise.audioservice.AudioServicePlugin;
import com.ryanheise.audioservice.MediaTransportDiagnostics;
import io.flutter.embedding.engine.FlutterEngine;
import java.lang.reflect.Method;

import static org.junit.Assert.*;

/** Real own-session transport and native output; isolated synthetic audio.
 * System UI touch delivery is established on the user device; this test checks
 * completion after delivery without relying on emulator System UI selectors. */
@RunWith(AndroidJUnit4.class)
public class MediaControlDeliveryTest {
    private static final String PACKAGE = "com.example.audiobook_app.test";
    private final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    private final Context context = instrumentation.getTargetContext();
    private final UiAutomation automation = instrumentation.getUiAutomation();
    private MediaController controller;
    private int checks;
    private AudioManager audio;

    interface Condition { boolean met(JSONObject state) throws Exception; }

    private JSONObject state() throws Exception {
        File file = new File(context.getDataDir(), "app_flutter/media-control-probe.json");
        assertTrue("Unexpected probe snapshot size", file.length() < 65536);
        JSONObject value = new JSONObject(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8));
        assertTrue("Probe fatal error: " + value, value.isNull("fatal"));
        return value;
    }

    private JSONObject await(Condition condition) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 25000;
        JSONObject last = null;
        while (SystemClock.uptimeMillis() < deadline) {
            try {
                last = state();
                if (condition.met(last)) return last;
            } catch (java.io.IOException ignored) {
                // The first atomic snapshot may not have been created yet.
            }
            SystemClock.sleep(100);
        }
        throw new AssertionError("Timed out; state=" + last + "; native=" +
                (controller == null ? null : controller.getPlaybackState()));
    }

    private void result(String stage, JSONObject observed) throws Exception {
        checks++;
        Bundle status = new Bundle();
        status.putString("stream", "\nMEDIA_CONTROL_RESULT " + new JSONObject()
                .put("stage", stage).put("state", observed) + "\n");
        instrumentation.sendStatus(2, status);
    }

    private void shell(String command) throws Exception {
        try (ParcelFileDescriptor.AutoCloseInputStream input =
                     new ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command))) {
            byte[] buffer = new byte[4096];
            while (input.read(buffer) != -1) { /* Drain the bounded shell command. */ }
        }
    }

    private void ownController() throws Exception {
        controller = null;
        CountDownLatch connected = new CountDownLatch(1);
        MediaBrowser[] browser = new MediaBrowser[1];
        new Handler(Looper.getMainLooper()).post(() -> {
            browser[0] = new MediaBrowser(context, new ComponentName(PACKAGE,
                    "com.ryanheise.audioservice.AudioService"), new MediaBrowser.ConnectionCallback() {
                @Override public void onConnected() {
                    controller = new MediaController(context, browser[0].getSessionToken());
                    connected.countDown();
                }
                @Override public void onConnectionFailed() { connected.countDown(); }
            }, null);
            browser[0].connect();
        });
        assertTrue("Own media session did not connect", connected.await(20, TimeUnit.SECONDS));
        assertNotNull("Own media session unavailable", controller);
        assertEquals(PACKAGE, controller.getPackageName());
        // Do not retain an extra service binding during lifecycle checks.
        new Handler(Looper.getMainLooper()).post(() -> browser[0].disconnect());
    }

    private static String text(CharSequence value) { return value == null ? "" : value.toString(); }

    private boolean nativeStateIs(int expected) {
        PlaybackState state = controller == null ? null : controller.getPlaybackState();
        return state != null && state.getState() == expected;
    }

    private List<AccessibilityNodeInfo> roots() {
        List<AccessibilityNodeInfo> roots = new ArrayList<>();
        AccessibilityNodeInfo active = automation.getRootInActiveWindow();
        if (active != null) roots.add(active);
        for (AccessibilityWindowInfo window : automation.getWindows()) {
            AccessibilityNodeInfo root = window.getRoot();
            if (root != null) roots.add(root);
        }
        return roots;
    }

    private AccessibilityNodeInfo find(AccessibilityNodeInfo root, String label) {
        List<AccessibilityNodeInfo> pending = new ArrayList<>();
        pending.add(root);
        for (int i = 0; i < pending.size() && i < 4000; i++) {
            AccessibilityNodeInfo node = pending.get(i);
            if (node.isVisibleToUser() && node.isEnabled() &&
                    (label.equalsIgnoreCase(text(node.getText())) ||
                     label.equalsIgnoreCase(text(node.getContentDescription())))) return node;
            for (int child = 0; child < node.getChildCount(); child++) {
                AccessibilityNodeInfo next = node.getChild(child);
                if (next != null) pending.add(next);
            }
        }
        return null;
    }

    private Rect bounds(String label, boolean system) {
        for (AccessibilityNodeInfo root : roots()) {
            if (system) {
                // Anchor to our own media card, rather than another app's Play.
                AccessibilityNodeInfo title = find(root, "Control probe");
                for (int depth = 0; title != null && depth < 12; depth++, title = title.getParent()) {
                    AccessibilityNodeInfo control = find(title, label);
                    if (control != null && "com.android.systemui".equals(text(control.getPackageName()))) {
                        Rect bounds = new Rect();
                        control.getBoundsInScreen(bounds);
                        if (!bounds.isEmpty()) return bounds;
                    }
                }
            } else {
                AccessibilityNodeInfo control = find(root, label);
                if (control != null && PACKAGE.equals(text(control.getPackageName()))) {
                    Rect bounds = new Rect();
                    control.getBoundsInScreen(bounds);
                    if (!bounds.isEmpty()) return bounds;
                }
            }
        }
        return null;
    }

    private void tap(String label, boolean system) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 20000;
        Rect target = null;
        while (target == null && SystemClock.uptimeMillis() < deadline) {
            target = bounds(label, system);
            if (target == null) SystemClock.sleep(100);
        }
        assertNotNull("Visible control absent: " + label + "; state=" + state(), target);
        long down = SystemClock.uptimeMillis();
        MotionEvent press = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN,
                target.centerX(), target.centerY(), 0);
        press.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        assertTrue("Touch down not injected", automation.injectInputEvent(press, true));
        SystemClock.sleep(60);
        MotionEvent release = MotionEvent.obtain(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP,
                target.centerX(), target.centerY(), 0);
        release.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        assertTrue("Touch up not injected", automation.injectInputEvent(release, true));
        press.recycle();
        release.recycle();
    }

    private void command(String stage, String label, String method, Boolean playing,
                         int direction, boolean system) throws Exception {
        int before = state().getJSONObject("commands").optInt(method);
        tap(label, system);
        JSONObject observed = await(value -> {
            if (value.getJSONObject("commands").optInt(method) <= before) return false;
            if (playing != null && (value.getBoolean("playing") != playing ||
                    value.getBoolean("sessionPlaying") != playing)) return false;
            if (system && playing != null) {
                PlaybackState nativeState = controller.getPlaybackState();
                int expected = playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED;
                if (nativeState == null || nativeState.getState() != expected) return false;
            }
            if (direction != 0) {
                long origin = value.getJSONObject("commandPositionsMs").getLong(method);
                return direction * (value.getLong("positionMs") - origin) >= 10000;
            }
            return true;
        });
        if (playing != null) {
            assertNativeOutput(playing);
        }
        result(stage, observed);
    }

    private void externalCommand(String stage, String method, Boolean playing, int direction) throws Exception {
        int before = state().getJSONObject("commands").optInt(method);
        switch (method) {
            case "pause": controller.getTransportControls().pause(); break;
            case "play": controller.getTransportControls().play(); break;
            case "rewind": controller.getTransportControls().rewind(); break;
            case "fastForward": controller.getTransportControls().fastForward(); break;
            default: throw new AssertionError("Unsupported external command " + method);
        }
        JSONObject observed = await(value -> {
            if (value.getJSONObject("commands").optInt(method) <= before) return false;
            if (playing != null && (value.getBoolean("playing") != playing ||
                    value.getBoolean("sessionPlaying") != playing ||
                    !nativeStateIs(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED))) return false;
            if (direction != 0) {
                long origin = value.getJSONObject("commandPositionsMs").getLong(method);
                return direction * (value.getLong("positionMs") - origin) >= 10000;
            }
            return true;
        });
        if (playing != null) assertNativeOutput(playing);
        result(stage, observed);
    }

    private void pluginBinding(FlutterEngine engine, String method) {
        instrumentation.runOnMainSync(() -> {
            try {
                Object plugin = engine.getPlugins().get(AudioServicePlugin.class);
                Method binding = AudioServicePlugin.class.getDeclaredMethod(method);
                binding.setAccessible(true);
                binding.invoke(plugin);
            } catch (Exception error) { throw new AssertionError(error); }
        });
    }

    private void awaitService(boolean present) {
        long deadline = SystemClock.uptimeMillis() + 15000;
        while ((service() != null) != present && SystemClock.uptimeMillis() < deadline)
            SystemClock.sleep(100);
        assertEquals("Framework service lifecycle did not complete", present, service() != null);
    }

    private AudioService service() {
        try {
            java.lang.reflect.Field instance = AudioService.class.getDeclaredField("instance");
            instance.setAccessible(true);
            return (AudioService) instance.get(null);
        } catch (Exception error) { throw new AssertionError(error); }
    }

    @Test public void serviceRecreationRetainsCommandDelivery() throws Exception {
        assertEquals(PACKAGE, context.getPackageName());
        audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        instrumentation.startActivitySync(new Intent().setComponent(new ComponentName(PACKAGE,
                "com.example.audiobook_app.MainActivity")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        await(value -> value.getBoolean("playing") && value.optLong("durationMs") > 200000);
        ownController();
        controller.getTransportControls().seekTo(60000);
        await(value -> value.getLong("positionMs") >= 60000 && value.getLong("positionMs") < 65000);
        controller.getTransportControls().pause();
        JSONObject paused = await(value -> !value.getBoolean("playing") &&
                value.getString("processing").equals("idle"));
        long position = paused.getLong("positionMs");
        long handlerStarted = paused.getLong("handlerStarted");
        Object oldToken = controller.getSessionToken();
        FlutterEngine[] engine = new FlutterEngine[1];
        instrumentation.runOnMainSync(() -> engine[0] = AudioServicePlugin.getFlutterEngine(context));
        controller.getTransportControls().stop();
        await(value -> !value.getBoolean("playing") && value.getBoolean("stopped"));
        // Reproduce the last-binding release while an Activity has already
        // reattached. Only the private test harness releases that binding;
        // Android itself destroys/recreates the actual service and session.
        pluginBinding(engine[0], "disconnect");
        awaitService(false);
        FlutterEngine[] surviving = new FlutterEngine[1];
        instrumentation.runOnMainSync(() -> surviving[0] = AudioServicePlugin.getFlutterEngine(context));
        assertSame("The owning Flutter engine must survive", engine[0], surviving[0]);
        pluginBinding(engine[0], "connect");
        awaitService(true);
        ownController();
        assertNotEquals("Android must create a new session", oldToken, controller.getSessionToken());
        int plays = state().getJSONObject("commands").optInt("play");
        controller.getTransportControls().play();
        boolean baseline = InstrumentationRegistry.getArguments().getString("expectListenerLoss", "false").equals("true");
        if (baseline) {
            SystemClock.sleep(1500);
            JSONObject observed = state();
            assertEquals(plays, observed.getJSONObject("commands").optInt("play"));
            assertFalse(observed.getBoolean("playing"));
            boolean dropped = false;
            for (String line : MediaTransportDiagnostics.snapshot().split("\n")) {
                if (!line.startsWith("{")) continue;
                JSONObject entry = new JSONObject(line);
                if (entry.optString("event").equals("native_command") &&
                        entry.optString("command").equals("play") && !entry.getBoolean("listener")) dropped = true;
            }
            assertTrue("Baseline must receive native Play with a missing listener", dropped);
            result("baseline-native-command-dropped", observed);
            return;
        }
        JSONObject resumed = await(value -> value.getJSONObject("commands").optInt("play") > plays &&
                value.getBoolean("playing") && nativeStateIs(PlaybackState.STATE_PLAYING));
        assertEquals(handlerStarted, resumed.getLong("handlerStarted"));
        assertTrue("Retained source must resume near its saved position", resumed.getLong("positionMs") >= position - 500 &&
                resumed.getLong("positionMs") < position + 5000);
        assertNativeOutput(true);
        result("recreated-session-play", resumed);
        externalCommand("recreated-session-pause", "pause", false, 0);
        controller.dispatchMediaButtonEvent(new android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN,
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE));
        controller.dispatchMediaButtonEvent(new android.view.KeyEvent(android.view.KeyEvent.ACTION_UP,
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE));
        result("recreated-media-key-play", await(value -> value.getBoolean("playing")));
        assertNativeOutput(true);
        controller.dispatchMediaButtonEvent(new android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN,
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE));
        controller.dispatchMediaButtonEvent(new android.view.KeyEvent(android.view.KeyEvent.ACTION_UP,
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE));
        result("recreated-media-key-pause", await(value -> !value.getBoolean("playing")));
        assertNativeOutput(false);
        long pauseMs = Long.parseLong(InstrumentationRegistry.getArguments().getString("pauseMs", "1000"));
        shell("input keyevent KEYCODE_HOME");
        shell("input keyevent KEYCODE_SLEEP");
        long deadline = SystemClock.uptimeMillis() + pauseMs;
        while (SystemClock.uptimeMillis() < deadline) {
            assertFalse("Extended Pause must remain silent", state().getBoolean("playing"));
            SystemClock.sleep(1000);
        }
        externalCommand("extended-pause-resume", "play", true, 0);
        controller.getTransportControls().stop();
        shell("input keyevent KEYCODE_WAKEUP");
        shell("wm dismiss-keyguard");
    }

    private void assertNativeOutput(boolean playing) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 5000;
        while (audio.isMusicActive() != playing && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(100);
        }
        assertEquals("Android audio output activity must match the command", playing, audio.isMusicActive());
        if (!playing) {
            // A Dart playing=false flag alone cannot pass this native output check.
            SystemClock.sleep(700);
            assertFalse("Paused output restarted", audio.isMusicActive());
        }
    }

    private AudioFocusRequest interrupt() throws Exception {
        AudioFocusRequest request = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener(change -> {}, new Handler(Looper.getMainLooper())).build();
        assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, audio.requestAudioFocus(request));
        await(value -> !value.getBoolean("playing"));
        assertNativeOutput(false);
        return request;
    }

    private void focusAndRapidCommands() throws Exception {
        shell("cmd statusbar collapse");
        AudioFocusRequest transientFocus = interrupt();
        audio.abandonAudioFocusRequest(transientFocus);
        result("focus-automatic-resume", await(value -> value.getBoolean("playing") && value.getBoolean("sessionPlaying")));
        assertNativeOutput(true);

        transientFocus = interrupt();
        int pauses = state().getJSONObject("commands").optInt("pause");
        controller.getTransportControls().pause();
        await(value -> value.getJSONObject("commands").optInt("pause") > pauses && !value.getBoolean("playing"));
        audio.abandonAudioFocusRequest(transientFocus);
        // Regression: just_audio 0.10.6 retains _playInterrupted when pause()
        // is called while already paused, and then resumes outside the handler.
        for (int i = 0; i < 25; i++) {
            SystemClock.sleep(100);
            assertFalse("Focus regain overrode deliberate external Pause: " + state(), state().getBoolean("playing"));
            assertFalse("Audio output resumed after deliberate Pause", audio.isMusicActive());
        }
        result("focus-pause-stays-paused", state());

        for (int i = 0; i < 12; i++) {
            controller.getTransportControls().play();
            SystemClock.sleep(35);
            controller.getTransportControls().pause();
            SystemClock.sleep(35);
        }
        await(value -> !value.getBoolean("playing") && !value.getBoolean("sessionPlaying"));
        assertNativeOutput(false);
        result("rapid-commands-final-pause", state());
        controller.getTransportControls().play();
        await(value -> value.getBoolean("playing") && value.getBoolean("sessionPlaying"));
        assertNativeOutput(true);
        context.startActivity(new Intent().setComponent(new ComponentName(PACKAGE,
                "com.example.audiobook_app.MainActivity")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP));
        SystemClock.sleep(1000);
        controller.getTransportControls().pause();
        await(value -> !value.getBoolean("playing") && !value.getBoolean("sessionPlaying"));
        assertNativeOutput(false);
        result("foreground-final-pause", state());
    }

    @Test public void nativeDeliveryAndActualSystemTouches() throws Exception {
        assertEquals("Only the isolated test package is allowed", PACKAGE, context.getPackageName());
        audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        AccessibilityServiceInfo info = automation.getServiceInfo();
        info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
        automation.setServiceInfo(info);
        Intent launch = new Intent().setComponent(new ComponentName(PACKAGE,
                "com.example.audiobook_app.MainActivity")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        instrumentation.startActivitySync(launch);
        try {
            JSONObject ready = await(value -> value.getBoolean("playing") &&
                    value.getBoolean("sessionPlaying") && value.optLong("durationMs") > 200000);
            // The player's synchronous playing flag can precede focus/session activation.
            long initial = ready.getLong("positionMs");
            await(value -> value.getLong("positionMs") > initial + 1500);
            ownController();
            int paused = state().getJSONObject("commands").optInt("pause");
            controller.getTransportControls().pause();
            result("own-session-pause", await(value -> !value.getBoolean("playing") &&
                    value.getJSONObject("commands").optInt("pause") > paused &&
                    nativeStateIs(PlaybackState.STATE_PAUSED)));
            int plays = state().getJSONObject("commands").optInt("play");
            controller.getTransportControls().play();
            result("own-session-play", await(value -> value.getBoolean("playing") &&
                    value.getJSONObject("commands").optInt("play") > plays &&
                    nativeStateIs(PlaybackState.STATE_PLAYING)));
            assertEquals(PlaybackState.STATE_PLAYING, controller.getPlaybackState().getState());

            focusAndRapidCommands();
            controller.getTransportControls().play();
            await(value -> value.getBoolean("playing") && value.getBoolean("sessionPlaying"));
            assertNativeOutput(true);
            // Seek may be buffering when Pause releases the native engine.
            // A lost native Seek reply must not block the subsequent Play.
            for (int i = 0; i < 6; i++) {
                int seeks = state().getJSONObject("commands").optInt("seek");
                controller.getTransportControls().seekTo(200000 + i * 1000);
                controller.getTransportControls().pause();
                await(value -> value.getJSONObject("commands").optInt("seek") > seeks && !value.getBoolean("playing"));
                assertNativeOutput(false);
                controller.getTransportControls().play();
                await(value -> value.getBoolean("playing") && value.getBoolean("sessionPlaying"));
                assertNativeOutput(true);
            }
            result("seek-pause-play-no-deadlock", state());
            shell("input keyevent KEYCODE_HOME");
            shell("cmd statusbar expand-notifications");
            command("shade-touch-pause", "Pause", "pause", false, 0, true);
            command("shade-touch-play", "Play", "play", true, 0, true);
            shell("cmd statusbar collapse");
            externalCommand("background-session-pause", "pause", false, 0);
            externalCommand("background-session-play", "play", true, 0);
            externalCommand("background-rewind", "rewind", null, -1);
            externalCommand("background-forward", "fastForward", null, 1);

            shell("cmd statusbar collapse");
            shell("locksettings set-disabled false");
            shell("settings put secure lock_screen_lock_after_timeout 0");
            shell("settings put secure lock_screen_show_notifications 1");
            shell("input keyevent KEYCODE_SLEEP");
            SystemClock.sleep(700);
            shell("input keyevent KEYCODE_WAKEUP");
            KeyguardManager keyguard = (KeyguardManager) context.getSystemService(Context.KEYGUARD_SERVICE);
            long lockDeadline = SystemClock.uptimeMillis() + 5000;
            while (!keyguard.isKeyguardLocked() && SystemClock.uptimeMillis() < lockDeadline) {
                SystemClock.sleep(100);
            }
            assertTrue("Lock-screen check requires a locked emulator", keyguard.isKeyguardLocked());
            command("lock-touch-pause", "Pause", "pause", false, 0, true);
            command("lock-touch-play", "Play", "play", true, 0, true);
            externalCommand("lock-session-pause", "pause", false, 0);
            externalCommand("lock-session-play", "play", true, 0);

            shell("wm dismiss-keyguard");
            context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP));
            command("app-stop", "In-app Stop", "stop", false, 0, false);
            command("app-restart", "In-app Play", "play", true, 0, false);
            ownController();
            shell("input keyevent KEYCODE_HOME");
            externalCommand("restart-background-pause", "pause", false, 0);
            externalCommand("restart-background-play", "play", true, 0);
            assertEquals("Every transport/touch/focus check must run", 21, checks);
        } finally {
            shell("cmd statusbar collapse");
            if (controller != null) controller.getTransportControls().stop();
        }
    }
}
