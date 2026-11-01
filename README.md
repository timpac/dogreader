# Dogreader

Build 131 starts from build 129, commit
`26fd3ef70978c686a2ac09ca0bf655ac7add600e`, and ports the Kokoro narration
changes only. Build 130 used an older baseline and is superseded.

The full build-129 ancestry, reader and EPUB styling, page jump, read-to-audio
seeking, Light / Dark / Follow system themes, recording repair/deletion,
background audio handler and continuous playback are retained. The existing
reader/theme/audio modules, Android identity/signing files, dependencies and
all existing regression test files are unchanged. CI checks these against the
pinned baseline before building.

## Narration

Open a book's chapters and **Generate narration**. Choose **Google Chirp** or
**Kokoro**, then a voice. Google retains Achernar, Charon, Kore, Puck and the
existing Oliver (Cheap) option; backend voice availability is unchanged. Kokoro
provides George, Fable, Daniel and Lewis. The preview button uses the cloud
queue and cached samples. Engine and voice defaults persist across launches.
Existing jobs keep their original engine, voice, model and settings during retries.
Missing engine fields retain Google behavior. Each recording row identifies its
stored engine/voice; imported audio without provenance remains labeled unknown.

The original **Repair audio from cloud** and **Delete chapter audio** controls
remain. Explicit **Regenerate narration** retains the previous local recording
until the complete replacement downloads successfully. Failed generation never
changes engines or voices. Existing local playback and seeking work offline.
Credentials for synthesis stay on the server; the app retains its existing
private API access token for the Dogreader endpoint.

Kokoro requires the matching [backend PR](https://github.com/timpac/dogreader-cloud/pull/5)
and separately approved deployment/generation. This app release does not deploy
or run cloud generation. No Kokoro generation measurements are claimed here.

## Build and verification

GitHub Actions runs strict full Flutter analysis, the full build-129 regression
suite plus the new narration tests, then builds signed APK **131** with the
original signing identity. Certificate, package, version and uploaded bytes are
verified. `python3 tools/check_build129.py` checks baseline ancestry, 53 unchanged
baseline files and unchanged book/reader/player screen code outside narration.

Before a release asset is uploaded, `tools/verify_android_screens.py` installs
that exact APK on an isolated Android 13 emulator, opens a real two-chapter EPUB,
checks the actual library/chapter/reader/page-jump/player/narration screens,
Light/Dark/Follow system settings, persisted engine/voice and restart behavior.
It uses local synthetic tone audio for real decoder playback/pause/seeking.
It never submits a preview or generation job and has no cloud host/token.
Actual APK screenshots, UI hierarchies and a verification report are retained
as an Actions artifact for review before publication.

Physical phone checks remain for Pixel/Android-beta behavior, notification and
lock-screen delivery, interruptions, installed-user data and in-place updates.
Install as an update; do not uninstall or clear storage. Emulator checks do not
establish actual Kokoro cloud generation or every physical-device behavior.
