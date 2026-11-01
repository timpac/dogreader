# Build 131 baseline correction (2026-11-01)

- User-selected base: build 129, `26fd3ef70978c686a2ac09ca0bf655ac7add600e`.
- Comparison confirmed build 130 omitted 61 commits and reader/theme/audio modules.
- New branch: `feature/kokoro-narration-131`, created directly from the pinned base.
- Only Kokoro settings, preview, immutable job metadata/recording attribution and
  explicit regeneration are ported into the existing narration screen.
- Local baseline guard passes: ancestry, 53 protected baseline files and all
  book/reader/player screen code outside narration are retained unchanged.
- Existing repair/delete helper, audio handler, reader parser/seek and theme
  modules and every baseline regression test remain byte-for-byte unchanged.
- CI must pass strict full analysis and all tests, original signing/package/code
  verification, and actual signed APK book/chapter/reader/theme/narration checks
  on Android 13 before publication. Native screenshots are required for review.
- Initial CI 41329209236 passed full strict analysis, all 48 tests, APK compilation
  and original certificate/package/version verification. The emulator failed
  before app launch: 7,349.6 MB free versus 7,372.8 MB required for userdata.
- The retry uses a 2 GiB test userdata disk and removes build-only NDK/CMake/Gradle
  caches after compilation. A private signed-candidate artifact permits recovery
  without losing the built APK if device checks fail. No release was uploaded.
- Actual Android screen verification remains pending; no device success is claimed.
- Backend PR #5 is unchanged. No deployment, generation, IAM or billing change.
- Next: inspect the new CI run, fix failures, review actual APK screenshots, then
  publish verified APK 131. Physical phone checks remain as documented below.

# Dogreader — Project status and handoff

## Build 124 review (2026-10-30)

- Active branch: `feature/124-css-audio-seek`; PR #12 remains draft and unmerged.
- Reviewed against build 123 base `1ab1257bda89c6aece84c7f57e507b76c646f750` and previous build 124 head `64decec7eca8030289af8f75835ed9e13950b021`.
- Confirmed defects: linked publisher CSS was ignored; collapsed whitespace shifted style offsets; font/viewport pagination could leave saved offsets inside the visible page; near-zero seek targets skipped verification; retry failure was silent; asynchronous restore could continue after navigation; replacing a loaded recording reused the old audio source.
- Parser/model extraction retains the exported `ReaderChapter` and `StyledRange` interfaces from `main.dart`. Empty scene breaks use blank space, repeated separators coalesce, and textual publisher ornaments remain. EPUB stylesheet links and CSS imports resolve inside the archive. Reading and narration JSON formats and Android identity/signing configuration are retained.
- Added regression tests for parsing/offsets, actual widget pagination reflow, seek preparation/metadata/retries/cancellation, safe recording recovery/deletion, saved audio progress and background chapter advance.
- Validation uses the existing Actions workflow with Flutter 3.47.7: dependency resolution, strict Flutter analysis, regression tests, APK compilation with build number/define 124, original certificate verification, and APK identity/version verification. Tests now block APK compilation. Consult the final commit's Actions run for results; the prior artifact is superseded by these source changes.
- Local Flutter execution is unavailable: no Flutter SDK is installed and the environment HTTP proxy rejects shell connections. GitHub connector access is available; validation runs on GitHub Actions.
- Physical Android checks remain outstanding: scene rendering, font-size/viewport changes, saved reading locations after reflow, read-to-audio seeking on newly/already loaded chapters, navigation during metadata/seek work, background playback and recording recovery/deletion. Automated tests do not establish device behavior.
- Run `41018647111` on `44fe2314b2b929fee0ec37e71781b4d2f51f14d4` passed strict analysis and all 24 tests. Final review also guarded a retained app-bar callback during pagination and expanded the widget test to paginate parsed scene breaks and styled text. The final commit requires its own successful workflow/artifact.
- Run `41018965390` passed analysis and 23 tests, but the expanded widget test selected Flutter's tooltip wrapper instead of its IconButton. APK compilation/publication were skipped. The finder is corrected to select the IconButton explicitly.
- First review validation run `41018361685` on `45d358e3937c86df81135de3e10696cf8ae2ce91` stopped at analysis on a regression-test callback signature; APK compilation and publication were correctly skipped. The callback is corrected in the follow-up commit. Final results must be taken from the final commit's run.
- Next exact action: inspect the final feature-branch Actions run and artifact, then install the verified original-key build 124 as an update and perform the outstanding Android checks. Do not merge PR #12 until device validation is complete.

Updated: 2026-10-24. This is a verified starting point, not a substitute for checking GitHub before changes.

## Mandatory new-chat startup
1. Read this file **from the branch used for the last successful Android update**, then inspect current GitHub branches, workflow, recent commits and open work before giving build commands.
2. Treat this file as a handoff, not proof of live state. Reconcile against repository and the user's installed build number.
3. Do not assume the default branch is the latest app. Do not replace the existing APK pipeline or signing identity.
4. Work on a dedicated feature branch, commit reversible changes, and validate before creating a new installable build.
5. After each meaningful session update this file with tested facts, commit IDs, unresolved issues and next step.

## Last verified installed build
- **Build 113**, shown on the user's Pixel phone (2026-10-24), with library data intact.
- GitHub Actions workflow run **#13** (successful) on **feature/read-to-audio-seek**. GitHub run number and app build number differ.
- Confirm exact commit from run #13 before basing changes on it.

## Official Android APK delivery
- Workflow: `.github/workflows/android-apk.yml` on `feature/read-to-audio-seek`.
- Workflow name: **Build Dogreader Android APK**.
- Manual workflow dispatch supported.
- Uses restored original Chromebook debug signing key from GitHub secret `DOGREADER_KEYSTORE_B64`; validates the original app certificate fingerprint before publishing.
- Command in workflow: `flutter build apk --debug --build-number $((100 + GITHUB_RUN_NUMBER)) --dart-define=DOGREADER_BUILD=$((100 + GITHUB_RUN_NUMBER))`.
- Artifact name: `dogreader-update-build-<run number>-apk`; contains `app-debug.apk`. Artifacts expire after 14 days.
- **Never uninstall the existing app** to resolve a signing conflict: doing so can destroy locally imported books, narration, and reading state.
- Local `flutter build apk --release` or `--debug` is **not** the official distribution process. Do not direct user to hunt for local APKs when a CI update is intended.
- GitHub Actions runs: https://github.com/timpac/dogreader/actions

## Repository / branches
- Repository: `timpac/dogreader`.
- Repository default branch at last inspection: `dogreader-oct22-update`; it **does not contain** the verified Actions workflow. Do not assume it is the latest source.
- Latest known successfully installed branch: `feature/read-to-audio-seek`.
- Previous CI branch: `feature/github-apk-build`.
- Experimental reader fixes: `fix/reader-pagination-scene-breaks`, commit `080d9b9f7bcb105e11ec37970341e1c29264b64f`, branched from older default branch. **Do not blindly merge into latest branch**; port and review changes after checking differences.

## Pending engineering work
- UI occasionally freezes / Android ANR during navigation while narration continues. Diagnose and fix without guessing.
- Reader page turns and chapter opening can be slow: synchronous full-chapter pagination / TextPainter measurement is suspected; needs profiling and safe refactor.
- Preserve EPUB scene/POV breaks, including CSS-defined spacing, not only explicit markers.
- Verify reader controls, chapter advance and narration position behavior against newest source.
- Batch coherent fixes, test, and produce one clearly numbered CI build rather than repeated tiny builds.

## Collaboration rules
- User prefers one terminal command at a time, with short explanation, only when needed.
- Prefer direct GitHub edits and commits, with checkpoints before risky refactors.
- Be candid about unverified assumptions and build results. Do not claim CI ran or an APK installs unless verified.
- At end of session record current branch, commits, successful/failed tests, last build, and the **next exact action**.

## Current work (2026-10-24)
- Created `fix/reader-stability-from-113` from `feature/read-to-audio-seek` (the successful Build 113 workflow branch).
- Commits `7aec2ee`, `a9dfe22`: optimized `styledPage` to scan only intersecting style ranges, and preserved empty semantic scene separators. These are **preliminary** improvements, not a confirmed freeze fix.
- **Not tested** with Flutter analyzer, APK build, or on-device navigation. No new APK has been issued.
- Commit `e523acc`: replaced synchronous whole-chapter pagination with cancellable, batched asynchronous pagination and a loading indicator. Uses bounded candidate spans to avoid repeatedly laying out entire remaining chapters. **Untested**; check compilation, navigation, font-size changes, and rapid chapter switching on device.
- Build workflow and original signing configuration are unchanged.

## Next exact action
Validate the reader changes with Flutter analyzer and an APK build. Check scene markers and test page navigation, font-size changes, and rapid chapter switching. The existing workflow can be manually dispatched on this branch from GitHub Actions, but no workflow run has been started. Verify its signing check and build number before installing. Confirm source commit of run #13 if accessible.

