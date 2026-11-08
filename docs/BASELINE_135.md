# Complete build-135 baseline consolidation

Date: 2026-11-08. Sole development/default branch: `dogreader-oct22-update`.

## Sources and safety

- Accepted application source: `cdf4227dc6a966b20e24f61179ac953b22689024`.
- Previous default: `704d619d664ec1113f893a09ee58b3fa49029db9`.
- Agent instructions PR #20: `4a6dffc36c8578819da3a67dae84cccc7c5200db`.
- Before consolidation, build 135 was 82 commits ahead and one behind the default,
  with common ancestor `d2675a3f4b07087eb90e033e897c8c4db39f81cd`.
- The default-only change is the build-134 delivery retry workflow. Its exact blob
  is archived along with all eight workflows from build 135, preserving provenance
  without activating the old build-124 fallback or hourly delivery schedule.
- Consolidation uses the complete build-135 tree and retains all three source
  histories through merge parents. PR #20 differs from the former default only
  in `AGENTS.md`; its guidance is incorporated with explicit canonical-base rules.
- Every blob outside root `README.md`, `PROJECT_STATUS.md`, `AGENTS.md`,
  `docs/` and `.github/workflows/` must have the same path, mode and SHA as build
  135 before and after merging. This includes all app/playback/signing/package,
  persisted-data, dependency, asset, regression and tool files. Any violation
  blocks consolidation; no playback/signing/data conflict may be resolved by guessing.
- No historical branch or release is deleted. The existing `v135` release, tag,
  APK asset ID 718512468, size 171410635 and SHA-256 remain unchanged.
- Only `release-apk.yml` remains active, with `workflow_dispatch` as its sole
  event. No APK or deployment is initiated by consolidation or PR closure.

## PR disposition evidence

The following work is already present in the complete source. Ancestor PRs need
no independent merge or replay; non-ancestor equivalents were checked directly.

| PR | Incorporation evidence |
| --- | --- |
| [#1](https://github.com/timpac/dogreader/pull/1) | PR head 1f99f6ca65624d854ae3ea3fe8b190f4deabf81e is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#2](https://github.com/timpac/dogreader/pull/2) | PR head c010dbd28202388cc5f55ecede1cb5a966f0ac85 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#3](https://github.com/timpac/dogreader/pull/3) | The equivalent library cleanup is carried by ancestor commit 9f81cf742bb96213af6a1439dc60096e0d4253c5. Build 135 contains the normal progress indicator and omits both the promotional feature copy and joke placeholder. |
| [#4](https://github.com/timpac/dogreader/pull/4) | PR head cc058a23ffd29e26f20218e64f5471d805e3eb84 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#6](https://github.com/timpac/dogreader/pull/6) | PR head dda43c6d46a6ede20a8a60d6703b0472bbd066ce is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#7](https://github.com/timpac/dogreader/pull/7) | PR head 4f99362a77a2ad79154690cdf1554ab7136bc951 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#8](https://github.com/timpac/dogreader/pull/8) | PR head e549eecf8cd6b1142952036097cf38665e7d6549 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#9](https://github.com/timpac/dogreader/pull/9) | Publisher scene spacing is implemented and expanded in build 124 (ancestor 6aadd2a12d17a4842d9d5b7015dbc24a24e56640), retained in build 135's lib/reader_content.dart. The parser preserves blank scene spacing and handles inline, embedded and linked stylesheet cues. The older candidate's limited parser/build-121 workflow is not needed. |
| [#10](https://github.com/timpac/dogreader/pull/10) | PR head e3d1a307103618161b1ecffd7511618a0d74f103 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#11](https://github.com/timpac/dogreader/pull/11) | PR head 1ab1257bda89c6aece84c7f57e507b76c646f750 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#12](https://github.com/timpac/dogreader/pull/12) | PR head 6aadd2a12d17a4842d9d5b7015dbc24a24e56640 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#13](https://github.com/timpac/dogreader/pull/13) | PR #13's handler and core regression files (audio_handler_test.dart, fake_player.dart, system_media_controls_test.dart) are byte-identical in build 129, which is an ancestor of build 135. Its older native probe/workflows are superseded by build 134/135 verification and are not restored. |
| [#14](https://github.com/timpac/dogreader/pull/14) | PR head 4822792c8d2c20e0e052a9b84858757d354df829 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#15](https://github.com/timpac/dogreader/pull/15) | PR head 26fd3ef70978c686a2ac09ca0bf655ac7add600e is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#17](https://github.com/timpac/dogreader/pull/17) | PR head 91f30bba93810a8f90bcc2a347196016ff692e55 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#18](https://github.com/timpac/dogreader/pull/18) | PR head c0f6bc28f86aba8f23aa2d9bbd0546ec76314311 is an ancestor of build 135; the complete build-135 application tree is retained. |
| [#19](https://github.com/timpac/dogreader/pull/19) | PR head 69016ca19c86be1dafa53b65a7624094ebc73c61 is an ancestor of build 135; the complete build-135 application tree is retained. |

PR #20's instructions are incorporated and updated, rather than discarded as
obsolete. Closure comments refer to the canonical consolidation commit and this
record. No age/PR-number heuristic is used to decide obsolescence.

## Verification limits

Existing [build evidence](https://github.com/timpac/dogreader/actions/runs/42289882251)
includes analysis, 81 regressions, compilation, original identity/signature and
Release download/hash verification. Static workflow/shell/JavaScript checks and
Git object comparisons are sufficient for this documentation/history-only merge;
Flutter builds, suites and emulator tests are not repeated. The manual release
workflow has not produced a new APK during consolidation and must be inspected on
its first explicitly authorized build. Physical sustained Pixel/headset/lock-screen
acceptance and current backend operation are separate, unverified checks here.

