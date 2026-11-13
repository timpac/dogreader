# Experimental Kokoro: background generation

Baseline: working build 147. The owner successfully generated the full 1,000-word passage with Misaki. This change moves job ownership out of the Flutter Activity; it does not change the FP32 graph, Misaki implementation, voice data, speed or PCM/WAV conversion. Production Dogreader remains untouched. PR #39 is not merged.

## Service and Android requirements

The native `GenerationService` owns a headless Flutter engine in the app's dedicated `:kokoro_generation` process. Its Dart root owns the inference isolate. Closing/recreating the Activity only disconnects the UI; it does not kill the inference isolate or native model. State, completed-recording indexes and reports are persisted so the UI can reconnect.

On Android 15+ the service uses **mediaProcessing** for local narration-file rendering. Older supported versions use **dataSync**, whose documented use cases include local-file processing. It declares `FOREGROUND_SERVICE`, both corresponding type permissions, `WAKE_LOCK` and `POST_NOTIFICATIONS`. It starts only from a visible, user-initiated Generate action, promptly calls `startForeground`, and requires notification permission. The notification is ongoing, reports chunk progress and has a Cancel action. It does not claim mediaPlayback while no audio is playing. See [Android service types](https://developer.android.com/develop/background-work/services/fgs/service-types).

The service acquires a non-reference-counted **partial CPU wake lock** for the active job, including preparation/loading, and releases it for completion, failure, cancellation, destruction and timeout. Generation does not keep the screen lit. Downloads retain their existing foreground-only behavior. Notification permission refusal starts no job/wake lock.

Current Android limits background mediaProcessing services to six hours per 24-hour budget. `onTimeout` stops promptly; a conservative internal session deadline also stops before six hours. There is no sticky restart, boot receiver or retry loop. Jobs are not automatically resumed after OS termination. These limits are documented in [Android foreground-service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout).

Cancellation first sets an app-private file checked at chunk boundaries, so it does not depend on a message reaching a busy FFI isolate. A completed native call returns through the normal cleanup path. If it has not stopped within 15 seconds, only the dedicated generation process is terminated; its native allocations are reclaimed by the OS. Timeout/unexpected service destruction use the same bounded shutdown. Incomplete WAVs are removed and never presented as successful recordings. Existing successful WAVs/indexes are retained.

Doze, battery-restricted settings and user force-stop remain Android controls. A foreground service is not a blanket Doze exemption; [Doze can ignore wake locks](https://developer.android.com/training/monitoring-device-state/doze-standby). No exemption, fake playback, alarm workaround or cloud wake-up is used. Telemetry records device-idle state and battery-optimization exemption status. Powered-emulator screen-off tests do not establish indefinite unplugged/Doze behavior; prolonged Pixel testing is required before a stronger reliability claim.

## Evidence written during inference

The inference isolate synchronously appends and flushes a JSONL journal around each actual `tts.generate` call:

- `chunkStart`: run/chunk number, UTC/unix time, worker monotonic elapsed time and process ID;
- `chunkInferenceEnd`: actual return time and generated frame count;
- `chunkWritten`: PCM written and cumulative frames;
- `nativeResourcesReleased`: normal cleanup after TTS disposal.

This file is written by the worker while the UI is absent, rather than generated from buffered UI updates on resume. The service separately records screen-off/on, unlock, UI pause/resume, progress and shutdown with Android elapsed-realtime/uptime clocks, interactive/keyguard state, wake-lock state and PID. Persistent Activity visibility also covers a pause racing service startup. The two journals are included in exported diagnostics, including cancelled/interrupted sessions.

**Save generation diagnostics…** exports the latest terminal report even when no new WAV completed. Existing per-recording WAV/measurement export remains available. CPU/PSS samples now describe the generation process, excluding the separate UI process; do not compare that PSS directly with build 147's combined-process sample as a memory improvement. Sampling is not a guaranteed peak. No new Pixel speed, RAM, battery, heat or audio-quality result is claimed.

## Targeted automated procedure

Prebuild checks run the probe's small Flutter suite (including journal/cancellation tests), analysis, the existing English corpus and native bridge checks. Kotlin is compiled against real Android/Flutter APIs without an APK. There is no production test suite or local APK build.

One GitHub Actions APK build includes ARM64 for the Pixel and x86-64 for testing the **same APK** on a disposable Android 15 emulator. No model is bundled. The device script verifies hashes and installs existing FP32/frontend fixtures, grants notification permission, then disables guest Wi-Fi/data. Inference is started through the real visible UI, not a synthetic worker or an ADB service-start exemption.

The release workflow publishes only after these separate cases pass:

1. **Normal completion:** short FP32/Misaki narration produces a readable 24 kHz mono PCM16 WAV; the wake lock and service process stop.
2. **App switching:** Home leaves the screen on. At least two native chunk completions must be timestamped inside a 30-second interval before reopening the UI. Killing only the UI process must leave the worker progressing. UI cancellation must stop the service/wake lock and preserve the prior valid WAV.
3. **Screen locking:** the screen is explicitly turned off. At least two chunk completions must occur inside a separate 30-second interval, with service events recording a noninteractive display and hidden UI. The notification's service cancellation action must stop the worker/wake lock. The journals are read while the screen remains off.

`BACKGROUND.json` contains the observed outcomes and intervals after a successful run. Full journals, service/power dumps, completion WAV and logcat are retained in the `kokoro-background-device-checks` Actions artifact for 14 days. These are short emulator observations, not a physical Pixel endurance benchmark. If a device check fails, no release is published and the already-compiled APK is retained for inspection; do not rebuild blindly.

## Build 148 results — measured on the emulator

[Build 148 release and APK](https://github.com/timpac/dogreader/releases/tag/v148-kokoro-offline) are published. The APK is 114,763,461 bytes; SHA-256 `b101e58ccd819df8f354ae31b8231f869864ee32b0bc303afe3dd47def051275`. Its immutable compiled source/tag is `57042ff146f8363b6bcc555e2b713e1a4228ec8b`; later commits only repair verification/publication and record results.

The same APK passed real FP32/Misaki checks on an Android 15 (API 35), x86-64 emulator with guest network disabled:

| Check | Observed result |
| --- | --- |
| Short normal completion | 298,490 frames; 24 kHz mono PCM16; service exited and wake lock released |
| App switching, screen on | **5 native chunk completions** strictly inside the separate 30-second interval, before UI return |
| UI process killed during that job | Further native chunk completion observed after UI-process death; generation process survived |
| Separate screen-off job | **11 native chunk completions** strictly inside its 30-second interval; hidden UI, noninteractive display and held wake lock recorded before UI return |
| Cancellation | UI action and the exact service action used by the notification both stopped generation, released the wake lock and removed incomplete WAVs; prior successful recording remained |

[Exact machine-readable results](KOKORO_BACKGROUND_RESULTS.json) match the release's `BACKGROUND.json` byte for byte. The full journals and system dumps are retained in [the passing device-check run](https://github.com/timpac/dogreader/actions/runs/43409543061). These short powered-emulator observations do not measure Pixel performance, listening quality, battery consumption, heat or prolonged Doze reliability. Notification cancellation was dispatched through its service action; an actual notification tap remains part of the Pixel procedure.

[Targeted prebuild checks](https://github.com/timpac/dogreader/actions/runs/43407284165) passed analysis, nine probe tests, the existing 16-case English corpus (17 locale executions), native bridge checks and Kotlin/API/manifest compilation. [Exactly one APK compilation](https://github.com/timpac/dogreader/actions/runs/43408345801) succeeded. Its initial emulator setup stopped on an Android UID diagnostic-format assumption. The corrected harness reused the retained APK; a first recovery stopped before testing on missing generated license receipts. The successful device run then encountered a release-creation permission error. An owner-created empty draft allowed [publication using retained APK and test evidence](https://github.com/timpac/dogreader/actions/runs/43410898437), with no further compilation or inference. All published assets were downloaded again and hash-verified by Actions.

## Pixel 8 Pro checks

Install the new experimental APK in place; do not uninstall/clear storage. Keep existing FP32 and English frontend downloads. Select FP32, Misaki English, af_heart, two threads and one run. Allow the new notification permission, then enable airplane mode with Wi-Fi off.

Run the scenarios separately, allowing the phone to return to a similar initial temperature:

1. **App switching:** start the 1,000-word passage, wait for chunk progress, press Home and use another app for at least 60 seconds. Check the progress notification before returning. Save the completed WAV and generation diagnostics.
2. **Screen lock:** start the same passage, wait for progress, press Power and leave the screen off for at least 90 seconds. Unlock, then save the WAV/diagnostics. Compare worker chunk-end timestamps with native screen-off/on timestamps; require several completions strictly inside the off interval.
3. **Cancel:** cancel one job from the notification and another from the UI. The notification should disappear within the bounded stop period, no partial WAV should be advertised, and the previous good WAV should still play.

Listen for the retained FP32 quality. For an unplugged longer test, record battery-optimization settings and any idle-state changes; do not infer continuous execution solely from eventual completion. OS force-stop or exhausted foreground-service quota is reported as interruption/timeout, not success. Production integration, resumable jobs and full-book scheduling remain out of scope.
