# Current Dogreader baseline — 2026-11-08

- Sole development/default branch: `dogreader-oct22-update`; start new task
  branches from its current remote tip.
- Accepted app source: complete build 135,
  `cdf4227dc6a966b20e24f61179ac953b22689024`.
- Canonical consolidation retains that source, default delivery commit
  `704d619d664ec1113f893a09ee58b3fa49029db9`, and agent-instructions PR #20
  (`4a6dffc36c8578819da3a67dae84cccc7c5200db`) in Git history.
- All files outside root documentation, `docs/`, and `.github/workflows/`
  match build 135 exactly. No application, playback, signing, package,
  persisted-data, dependency, asset, regression or tooling change.
- Existing APK: [v135](https://github.com/timpac/dogreader/releases/tag/v135).
  Existing successful build evidence: run 42289882251, analysis and 81 tests,
  identity/signature checks and release-download SHA-256 verification.
- Historical workflows, including the default's hourly build-134 delivery
  retry, are retained inert under `docs/workflows/archive/`.
- Only active workflow: manual-only `release-apk.yml`. No cleanup-triggered
  build, emulator test, release publication or deployment is intended.
- No backend changes or production narration were requested or performed.
  Backend deployment evidence is historical; current queue/recovery operation
  and production narration remain unverified.
- Physical acceptance: owner reports build 135 appears to resolve the audio
  failure; sustained device testing is not a new consolidation result.

Read [AGENTS.md](AGENTS.md), [baseline evidence](docs/BASELINE_135.md) and
[release instructions](docs/RELEASING.md). Earlier handoff notes are preserved
as [historical status](docs/history/PROJECT_STATUS_before_consolidation.md);
their old branch/build/workflow instructions are obsolete.

Next development work must use a fresh branch from the current default and
preserve the build-135 audio-session lifecycle correction. No rebuild is needed
to use this documentation/history-only consolidation.
