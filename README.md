# Dogreader

## Cloud narration (build 130 candidate)

Open **Generate narration**, choose **Google Chirp** or **Kokoro**, then a voice.
Google Chirp and Achernar remain the default; existing saved Google voices are
preserved. Kokoro offers British male voices **George, Fable, Daniel and Lewis**.
Tap **Preview voice** for a short sample before selecting chapters. Previews use
the existing cloud job queue and cache, so the first preview needs connectivity
and may wait for a worker. Stop preview stops playback/polling, not the submitted
cloud job. Changing engine never changes a queued job or an existing recording.
The chosen engine and voice are remembered for future chapters across books.

Recording rows show the engine and voice stored with that job. Historical jobs
without engine metadata are Google; missing historical voice metadata is shown
as unknown rather than guessed. Use **Download audio** to repair a private local
download, **Play** and the existing seek slider to listen, or explicitly confirm
**Regenerate narration** to use another engine/voice. The old local file remains
until the new transfer succeeds. Regeneration with exactly the same engine,
voice, model/settings and text reuses the server cache. No recording is silently
regenerated. Model/provider credentials remain on the server; the existing app
connection still uses its private Dogreader API access token.

Requires the matching [backend change](https://github.com/timpac/dogreader-cloud/pull/5)
and an approved Kokoro-enabled deployment. An older server reports an unsupported
voice/error; the app never switches back to Google after a Kokoro failure.
Backend deployment and real chapter validation are pending. No measured speed or
cloud cost is claimed. Download means the app's existing private narration
storage, not export to Android's public Downloads folder.

This change starts from the repository's default branch
`dogreader-oct22-update` (`d2675a3`); there is no main branch. Builds 124–129 are
separate unmerged branches and were not folded into this implementation. In
particular the default branch has its original dark theme and playback behavior.
The new selector uses inherited theme colors; its tests also render it in a light
theme for compatibility with the independent theme work.

## Validation and APK delivery

GitHub Actions builds numbered APK **130**, signed with the original app key,
and verifies certificate, package/version and uploaded bytes before private draft
release delivery. It does not replace previous APK assets or publish a release.
Rendered control screenshots in dark and light themes accompany that release;
they show the actual controls with a sample recording row, not device playback.

Focused checks: `flutter test test/narration_options_test.dart` and
`flutter analyze lib/main.dart lib/narration_options.dart lib/dogreader_audio_handler.dart test/`.
The screenshot command is
`flutter test --update-goldens test/narration_screenshots_test.dart`.
CI builds the APK because Flutter is unavailable in the implementation workspace.

After backend approval: generate one complete Kokoro chapter, confirm stored
engine/voice, download, play, seek at 10%/50%/90%, restart, interrupt/resume the
download, retry generation and verify cache reuse. Verify old Google recordings
still play and no engine switch occurs on errors. Physical Android checks are
required for in-place update/data preservation, decoder seeking/duration,
background playback, screen-lock/notification controls and audio interruptions.

## Original project setup

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

