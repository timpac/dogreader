# Dogreader — Project status and handoff

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

## Next exact action
Inspect successful Actions run #13 for its source SHA and inspect `feature/read-to-audio-seek` code. Compare it to experimental reader changes before proposing a new branch and fixes. Preserve the working workflow and signing identity.
