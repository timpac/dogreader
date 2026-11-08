# Dogreader — instructions for coding agents

## Project and priorities
Dogreader is a Flutter/Dart Android EPUB reader with cloud-generated narration. The app has reading progress, chapter navigation, narration queues/downloads, background playback, and Android media controls. Its cloud backend is maintained separately in `timpac/dogreader-cloud` (Google Cloud Run, Tasks, Storage).

Priorities, in order:
1. Do not break working reading, narration, progress, or playback.
2. Solve the user's actual request, including real-device behavior where relevant.
3. Keep changes small, understandable, and reversible.
4. Minimize unnecessary agent usage, test expense, and rebuilds.
5. Deliver a clearly identifiable APK when an APK is requested.

## Before changing anything
- Inspect the current branch, recent relevant changes, and the files actually involved. Do not start from an old feature branch or assume an earlier build is the baseline. Identify the intended base branch; if ambiguous or there are conflicting active changes, ask before branching.
- Check for an existing implementation and relevant tests before proposing new architecture.
- For straightforward changes, implement directly. For high-risk changes, briefly state the approach and main risk, then proceed unless a product decision is needed.
- Do not claim to have run tests, deployed, or reproduced a device issue unless that actually happened.

## Scope and compatibility
- Prefer targeted fixes over broad refactors or rewrites.
- Preserve EPUB reading, publisher styling and scene breaks, library ordering, saved positions, narration queue states, downloaded audio, continuous/background playback, Android notification/lock-screen/headset controls, and read-to-audio seeking.
- Avoid changing persisted data formats, API contracts, audio storage paths, or backend behavior without an explicit migration/compatibility plan.
- Treat the Flutter client and cloud backend as distinct deployable systems. Do not imply that building an APK deploys backend changes.
- Never deploy to production, alter cloud IAM/billing, delete user data, or merge a PR without explicit authorization.

## Debugging and verification
- For intermittent bugs, establish a concrete failure signature and reproduction steps before guessing at root causes. Distinguish hypotheses from confirmed findings.
- Use existing logs and diagnostics first. Add focused instrumentation if needed; avoid repeatedly shipping speculative fixes.
- Test the failure mode, not just whether the code compiles. For background audio, consider pause/resume, lock screen, headphones, app backgrounding, Android service lifecycle, and long idle periods.
- A short automated test cannot prove a bug that historically appears after 30+ minutes is fixed. State what remains unverified on a real device.
- If a fix fails, preserve what was learned; do not repeat an already disproven approach without new evidence.

## Compute and test budget
- Default to frugal investigation: targeted file reads, static analysis of changed areas, and the smallest meaningful tests first.
- Avoid broad repository sweeps, redundant test runs, and repeated full APK builds unless justified by risk or failures.
- Run broader tests for shared infrastructure, data compatibility, or high-risk changes; do not skip essential safety checks just to save usage.
- Explain any unusually expensive test/build before doing it when there is a cheaper credible alternative.
- Batch related fixes into one build when practical, but do not bundle unrelated changes.

## Git, releases, and delivery
- Work from the correct up-to-date base and use a task-specific branch and PR. Do not silently merge.
- Preserve other in-progress work; check for overlapping PRs and likely conflicts.
- Use GitHub Actions for Android APK builds; do not ask the user to build locally.
- Use clear, sequential build/release numbers consistent with the repository's current convention. Never assume a number without checking.
- Verify that the APK artifact or release asset actually exists before announcing it as downloadable.
- Provide the exact GitHub Actions artifact or release asset link, plus short install instructions when needed. A release page with no APK is not a successful delivery.
- Keep README and screenshots accurate when a user-facing feature or workflow changes.

## Communication
- The owner is the product decision-maker and should not need to interpret lengthy terminal output.
- Be concise: what changed, why, tests actually run, what remains uncertain, and the exact next action.
- Ask only for decisions or access genuinely needed; handle routine technical choices independently.
- Give one terminal command at a time when asking the owner to perform manual steps.
- Prefer plain English over implementation jargon; distinguish code complete, CI passing, APK available, merged, and deployed.
- Do not declare intermittent Android media-control failures fixed until sustained real-device testing supports that claim.
