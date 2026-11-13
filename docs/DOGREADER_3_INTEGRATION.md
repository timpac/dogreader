# Dogreader 3.0: isolated offline chapter milestone

Independent experimental target; do not merge. The numbered GitHub Release page is the APK delivery authority. Physical Pixel acceptance is separate from automated checks.

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


## Implementation and retained behavior

The new target is a deliberate application fork in `apps/dogreader3`, not a flavor switch in the production project. Cloud delivery/request code, EPUB parsing, dictionary rules and cloud narrator controls are byte-identical to the canonical baseline. The only playback-handler change resolves an explicitly selected offline WAV for automatic chapter transition; its media-session lifecycle is retained. Root production dependencies and source remain unchanged.

The reader's existing archive 3.6.1 dependency is preserved for EPUB compatibility. The probe installer needs two small API adaptations (`BZip2Decoder.decodeStream` returns void; `TarDecoder.decodeBuffer` accepts a file stream). No EPUB dependency upgrade or runtime migration is introduced. The installer has a tiny local-HTTP/archive test, including failed-hash preservation of installed files.

Offline jobs never enter `dogreader_queue.json` or cloud submission/reconciliation. `files/generation-jobs/<id>/request.json` freezes chapter identity, transformed text, dictionary/offset snapshot, source/spoken hashes, exact model and frontend, voice, speed and CPU threads. Each converted PCM16 chunk is flushed to a temporary file then renamed; its fingerprint, frame bytes and SHA-256 are committed separately. The worker journal distinguishes actual inference from checkpoint restoration. Explicit Retry uses the frozen request, verifies every reused chunk and regenerates any uncommitted chunk. Corrupt/mismatched chunks stop visibly. There is no automatic restart or claim of recovery after every Android termination.

The generation service alone writes its atomic progress/report and offline-recording index. It never writes reader/cloud metadata. On UI reconnection, a newly completed recording is promoted once using the existing serialized narration-metadata writer, after unloading that chapter from the player. Completed WAVs have unique job paths; prior offline WAVs and all cloud MP3s remain on disk. Chunk checkpoints are retained for retry, so completed local audio can temporarily occupy roughly twice its PCM size. Cleanup/library-wide job management remains future work.

## Install and first Pixel milestone

1. Open the numbered **Dogreader 3.0** GitHub Release and install its APK under Assets. Existing Dogreader and Kokoro Offline Probe remain installed. Do not uninstall or clear any app.
2. Open **Dogreader 3.0**. Its library/settings start empty. Import an EPUB explicitly, then open **Chapters and narration → Generate narration → Kokoro Offline**.
3. Tap **Download offline files (372 MB)** once. This independently downloads the pinned FP32 package (349.9 MB) and Misaki frontend (22.2 MB); the existing probe's files are not reused or migrated. Allow about 1.5 GB free during installation and keep the app open for this setup step.
4. Choose one chapter, **af_heart**, **two threads**. Allow notifications, then enable airplane mode and turn Wi-Fi off. Tap **Generate chapter offline**, wait for chunk progress and lock the screen. The notification shows progress and Cancel.
5. After completion, reopen the app and tap **Play completed chapter**. This opens the existing chapter player. Save the offline WAV and generation diagnostics. Verify native chunk-end timestamps fall strictly between screen-off and screen-on events; eventual completion alone does not prove continuous background inference.
6. Test notification cancellation separately. A cancelled/failed chapter is not selected as completed. **Retry saved chapter job** uses verified committed PCM chunks and frozen text/settings. A fresh generation takes a new dictionary/settings snapshot.

Chirp HD and cloud Kokoro remain on the existing narration screen. Connect cloud credentials manually if wanted; none are copied automatically. Offline pronunciation uses the existing narration dictionary, with the build-148 Misaki handling/limitations. Names remain best-effort; generation success is not a claim of pronunciation correctness. Source/component notices are accessible from the offline screen and attached to the release.

## Verification scope

Targeted checks cover private identities/storage boundaries, unchanged cloud/EPUB/Misaki/PCM source, existing playback/reader/cloud/file/dictionary regressions, hash-verified chunk persistence, local request separation, permission refusal, and completion metadata. Existing dependency versions must remain unchanged. Kotlin generation/bridge code is checked against real Android/Flutter APIs, using a small host Activity stub; the actual retained AudioServiceActivity host is compiled by the single APK build.

The same ARM64+x86-64 APK is used for a disposable Android 15 emulator milestone: install production build 135 and probe 148 beside the new package; retain private sentinels; import a small EPUB through the system picker; generate its complete 391-word chapter with the screen locked; verify timestamps, final WAV, all chunk checkpoints, service/wake-lock shutdown, isolated engine metadata, and observed playback position through the existing player. Optional model fixtures are hash-verified and installed only on the disposable emulator, not bundled. No paid cloud generation or deployment is used.

This controlled emulator test does not measure Pixel listening quality, speed, RAM, battery, heat or prolonged Doze/OEM behavior. Build-148 corpus evidence is reused because the English frontend/model/audio conversion are unchanged; new integration inference is tested separately. Android six-hour foreground-service quotas, force-stop and battery restrictions still apply. Full-book scheduling, storage cleanup, word-level alignment, robust OS-termination scheduling and a separate long-term signing/release policy remain beyond this first milestone.

## Build 151 acceptance evidence

The [same signed build-151 APK](https://github.com/timpac/dogreader/actions/runs/43453714650) passed the full Android 15 x86-64 emulator milestone. [Recorded observations](DOGREADER_3_RESULTS.json) show three independent private UIDs, successful EPUB picker import, and complete generation of the 391-word chapter into 29 chunks. Seventeen actual native inference completions occurred strictly inside a measured 30-second screen-off interval; the screen stayed off until chapter completion. The verified output contains 2,525,499 frames at 24 kHz (105.23 seconds), mono PCM16. The generation process exited and released its wake lock. The existing player started and paused the WAV, preserving an observed playback position of 5,912 ms.

The original APK was compiled once from `d9eb8926d2945296f4f1351825c8816d08f2e9e4`. Acceptance reused those signed bytes without recompilation or re-signing; the test captures Play/Pause coordinates before playback because the live position slider prevents UIAutomator from becoming idle. Publication reuses the complete retained assets after verifying their checksums and acceptance report. These observations establish the controlled emulator milestone only. Pixel listening, inference performance, RAM, battery, temperature and prolonged background behavior remain unmeasured for this application.

Build 151 is published at https://github.com/timpac/dogreader/releases/tag/v151-dogreader3. Install **Dogreader-151-3.0-Offline.apk** under Assets (125,842,717 bytes; SHA-256 `c4c1ae8ed2da5f074dd35f86c4753c9caa3ab35dc9131f5e84f00674551140b4`). The release also contains MILESTONE.json, TESTING.md, BUILD.txt, dependency/license notices and SHA256SUMS. Candidates 149 and 150 remain withheld.

Publication-only run https://github.com/timpac/dogreader/actions/runs/43454894837 verified the retained assets and uploaded/download-verified every release asset. Its final tag check failed because publication selected GitHub's temporary draft tag. The release metadata was then explicitly assigned `v151-dogreader3` and the compiled source; independent API reads verified the published numbered release, nonempty assets/digests and matching Git tag. No build, re-signing, asset replacement or inference was repeated for this metadata correction.
