# Dogreader

Dogreader is a Flutter Android EPUB reader with cloud-generated narration,
offline chapter audio, saved reading/listening positions, background and
continuous playback, Android media controls, and Light / Dark / Follow system
appearance settings. Reader page jumps, publisher scene spacing, read-to-audio
seeking, chapter repair/download/deletion and narration engine/voice selection
are retained from the complete build-135 source.

## Narration Dictionary

Open **Settings → Narration Dictionary**, or **Narration Dictionary** on a book's
Generate narration screen. Choose Global or This Book to add, edit, disable or
delete pronunciation and Do Not Narrate rules. Per-book entries override matching
global entries; a disabled book entry opts out of that global entry. Matches are
literal, case-sensitive and bounded at word edges. The global decorative-separator
setting defaults on, keeping standalone `***`, `⁂` and common EPUB ornaments
visible while silencing them in newly generated narration. Prose punctuation and
inline emphasis remain intact.

Preview an unsaved pronunciation or a short sample with the selected narration
engine/voice. Settings uses the last saved narration voice; choose another on the
book's Generate narration screen. Preview requires the existing Cloud connection
and engine support. It submits at most 300 characters and uses temporary audio.

Changes affect new jobs only. Affected recordings say **Dictionary changed —
regenerate to apply**. Use the existing Regenerate narration confirmation to
replace audio; the current download survives until its replacement downloads
successfully. See [implementation and alignment notes](docs/NARRATION_DICTIONARY.md).
This feature has no APK or backend deployment yet.

## Article import and integration status

Paste an article URL from the library or share a URL from Android. Saved articles
and cached summaries use the existing reader and narration queue, with separate
reading positions, audio and dictionary scopes. AI summary generation stays
disabled pending separately approved backend integration and rollout.

Whole-book planning helpers are included as inactive library code only. There is
no new whole-book UI, submission or recovery workflow. PR #22's reverse
synchronization routes remain deferred until reviewed timing maps can compose
with frozen dictionary transformations. Existing text-to-audio seeking remains.
See [integration status and backend handoff](docs/INTEGRATION_BUILD135.md).

## Development baseline

Use **`dogreader-oct22-update`**, the repository's sole development/default
branch. Create new task branches from its current remote tip. Historical feature,
build, fix and delivery branches are retained for reference, not as development
bases. Read [AGENTS.md](AGENTS.md) before making changes.

The accepted app source is build **135**:
`cdf4227dc6a966b20e24f61179ac953b22689024`. Consolidation preserves its ancestry
and every application, Android/signing, asset, dependency, tool and regression
file byte-for-byte. Only documentation and workflow organization change.
The default branch also retains its former delivery commit and PR #20's history.

Build 135 prevents accidental terminal media-session idle during decoder
recovery and chapter preparation. Preserve that lifecycle correction and the
existing playback architecture. See [the investigation](docs/BUILD_135_MEDIA_SESSION.md).

## Install the existing build

Open [GitHub Release v135](https://github.com/timpac/dogreader/releases/tag/v135)
and tap **Dogreader-135.apk** under **Assets**. Install as an update; never
uninstall or clear storage. Package: `com.example.audiobook_app`.

APK SHA-256:
`48af8661b9287c225479a5dafb0a786b2c2fad4343f0b8d3b0bd432368351d1b`.
The release, tag, asset and signing identity are preserved; consolidation does
not create a new APK or alter data on any phone.

## Verification and releases

[Build 135 run 42289882251](https://github.com/timpac/dogreader/actions/runs/42289882251)
passed analysis, 81 regression tests, compilation, original signing/package/
version verification and downloaded release-asset hash verification. Actions
artifact storage failed; the verified Release asset is the delivery record.
The owner reports build 135 appears to resolve the delayed external-control
failure. Sustained Pixel/Bluetooth/lock-screen acceptance remains separate from
automated evidence; no new physical-device result is claimed by consolidation.

Future APKs use the manual-only [release process](docs/RELEASING.md).
Pushes and PRs do not automatically build, test, publish or deploy. Historical
workflow definitions are archived outside the Actions workflow directory.

The backend is maintained separately in `timpac/dogreader-cloud`. An app build
does not deploy it. This consolidation changes no backend code or infrastructure;
current queue operation and real production narration are not verified here.
See [project status](PROJECT_STATUS.md) and [baseline evidence](docs/BASELINE_135.md).
