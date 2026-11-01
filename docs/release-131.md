Build 131 restores the complete build 129 baseline (`26fd3ef70978c686a2ac09ca0bf655ac7add600e`) and ports only Kokoro narration changes. It supersedes build 130, which used an older baseline.

All build-129 reader, theme, audio, seeking and recovery modules and regression tests are retained. Baseline ancestry and 53 protected files were checked; strict analysis and all 48 tests passed.

APK source: `a60e87c232b8626672035c2730ff3f37f6a0e6c7`. Original signing certificate and `com.example.audiobook_app` / versionCode 131 verified. The retained signed APK was tested without rebuilding.

APK SHA-256: `b50cc3734734769bbc99769ff61e82a769e594e7095be54792269c43ad25b692`.

Install as an update without uninstalling or clearing storage. Physical phone/Pixel-beta notification behavior remains unverified. Kokoro backend deployment and real cloud narration remain separately approval-gated; no cloud generation was run for this release.

PR: https://github.com/timpac/dogreader/pull/17
Full analysis/tests: https://github.com/timpac/dogreader/actions/runs/41331380907
Signed APK compilation: https://github.com/timpac/dogreader/actions/runs/41331374454

Actual signed APK library, chapter list, reader, page-jump and player screens were captured and visually reviewed on Android 13: https://github.com/timpac/dogreader/actions/runs/41333693025

The extended emulator flow did not complete: System UI ANRs and a seek-checker coordinate issue prevented a full native seek/theme/restart result. These are not reported as passed. Existing reader/theme/audio source and regression tests are unchanged and pass. Physical phone checks remain. Publication follows the completed baseline, full test, signing and actual book/chapter screen checks; extra emulator retries were stopped at the user's request for expedient completion.
