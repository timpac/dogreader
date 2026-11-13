# Dogreader 3.0: isolated offline chapter milestone

Status: inspection complete; implementation in progress. No APK yet. Do not merge.

The integration branch starts from the current canonical application tip, `30e92ca871bad697b19637488b085a8ecd03f1a3`, and ports only the independently tested Kokoro pipeline from build 148 (`57042ff146f8363b6bcc555e2b713e1a4228ec8b`). It does not merge the old experimental branch chain or PR #27.

## Identity and storage inspection

| Application | Android application ID | Visible name |
| --- | --- | --- |
| Existing production | `com.example.audiobook_app` | Dogreader |
| Existing probe | `com.dogreader.kokoro_probe` | Kokoro Offline Probe |
| New independent target | `com.dogreader.v3` | Dogreader 3.0 |

The new app lives in `apps/dogreader3`, starting with copies of the current Flutter reader/library/cloud/playback source and Android host. Root production source, Android configuration, dependencies and media-service fork stay unchanged. The Java/Kotlin namespace may remain the original source namespace; the installed identity is the distinct application ID. Its FileProvider authority uses `${applicationId}.media_diagnostics`, so it does not collide with either existing app. No shared UID is declared. Reusing the established signing certificate does not merge private storage or replace an app with a different ID.

Production stores imported EPUBs, reading positions, narration settings/credentials, dictionary, queue and narration metadata in `path_provider` documents/support directories, using JSON and files rather than a shared database. Generated recordings live below those private directories. The independent package obtains independent directories and settings. No production/probe directory is read, scanned, migrated or modified. EPUB import is explicit. Cloud configuration starts empty; no credentials or job IDs are copied. Android backup is disabled for this milestone target.

## Native dependencies and services

The current application has no ONNX/FONNX/Sherpa runtime. Add the exact probe Sherpa-ONNX 2.0.1 dependency only to the new target, retaining ORT 1.28.2 and the API-28 Misaki helper. No alternate ONNX library, model precision change or dependency upgrade is needed. Existing audio_service/just_audio playback and the retained native media-session fix remain in place.

The new foreground generation service runs in `:kokoro_generation` with its own Flutter engine, without automatically registering unrelated playback/UI plugins. Inference uses Dart FFI and the service's explicit method channel. The main app retains its existing AudioServiceActivity and playback service. Generation uses mediaProcessing on Android 15+, dataSync for older local-file processing, notification permission and an active-only partial CPU wake lock. It does not pretend to be media playback. Build-148 per-chunk journals, cancellation and timeout behavior are retained.

## Milestone scope

Import an EPUB, select one chapter, optionally download FP32/model frontend once, generate locally with the screen locked, and play the completed WAV through Dogreader 3.0's existing chapter player. Offline engine/model/voice/settings/dictionary/source identity and durable progress are kept separately from cloud jobs. Completed offline WAVs cannot overwrite cloud MP3 files; an incomplete chapter is never advertised as completed. Cloud Chirp and cloud Kokoro retain their routes and controls.

Focused checks must pass before one numbered GitHub Actions APK build. Device evidence will distinguish emulator checks from physical Pixel acceptance. Full-book scheduling, OS-force-stop recovery guarantees and production migration are outside the first milestone. Android foreground-service quotas and Doze controls still apply.
