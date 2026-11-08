# Android APK releases

## Existing working release

Build 135 is immutable reference evidence:
- Source: `cdf4227dc6a966b20e24f61179ac953b22689024`.
- Release: https://github.com/timpac/dogreader/releases/tag/v135.
- Asset: `Dogreader-135.apk`, 171,410,635 bytes.
- APK SHA-256: `48af8661b9287c225479a5dafb0a786b2c2fad4343f0b8d3b0bd432368351d1b`.
- Original certificate SHA-256: `c5cc08d9757c0e92893a716204a26feb6157f5350a00dbb0b7962049d6d9d177`.
- Package: `com.example.audiobook_app`; versionCode: 135.
- Successful build: https://github.com/timpac/dogreader/actions/runs/42289882251.

Do not move its tag, replace its APK, rebuild under number 135, change signing
secrets or uninstall/clear phone storage. A source-only consolidation does not
require a new APK. `pubspec.yaml` is not the release-number authority: CI passes
both `--build-number` and `DOGREADER_BUILD` explicitly.

## An explicitly requested future build

1. Start from the current `dogreader-oct22-update` tip. Review relevant open work,
   changes and targeted verification before merging. Preserve build-135 ancestry.
2. Inspect Releases, draft releases and tags. Select the next unused sequential
   Android versionCode above every existing numbered APK. Never derive it from
   `github.run_number`; 136 is only next if no higher number has since been used.
3. The repository owner manually dispatches **Release Dogreader APK**
   (`release-apk.yml`) on **dogreader-oct22-update**, providing the exact reviewed
   40-character `release_commit` reachable from that branch and `build_number`.
   Leave `publish` false to retain a draft for review, or set true only when
   publication of this build is authorized. Dispatch incurs a real build/test
   job; never do it as routine documentation or PR cleanup.
4. The workflow checks provenance and an unused number, uses Flutter 3.47.7,
   enforces the lockfile, runs analysis/regressions and builds one original-key
   update APK. It verifies certificate, package, versionCode and APK bytes after
   downloading the Release asset. No emulator or cloud generation is invoked.
5. The workflow creates a new `v<number>` Release with APK, `SHA256SUMS` and
   `BUILD.txt` provenance. It publishes only after asset verification when
   `publish=true`; otherwise explicitly publish that verified draft later using
   GitHub Releases after review. Publication of retained bytes needs no rebuild.
6. Verify the final Release is published with its intended nonempty APK. Give
   the stable Release page URL and instruct the owner to tap the APK under
   Assets. CI success or an expiring Actions artifact is insufficient delivery.
7. Install in place and report remaining feature/device checks honestly.

The workflow refuses existing release/tag numbers and never overwrites assets.
If a run fails after retaining a draft or tag, inspect its logs and existing
APK/provenance before deciding recovery. Do not delete/recreate it or rerun a
build blindly; reuse verified retained bytes where possible. A number already
used by any retained draft APK remains reserved.

## Workflow safety

`release-apk.yml` has only `workflow_dispatch`, is restricted to the owner and
default branch, and never deploys the backend. There are no active automatic
push, PR, tag, schedule, workflow-run or release-event jobs. Historical workflow
definitions are stored verbatim under `docs/workflows/archive/`; GitHub does
not execute files there. Historical branches still contain their historical
workflows: do not push, dispatch or rerun them. Close superseded PRs without
updating their branches. Never restore an archived workflow as a shortcut.

The new release workflow is statically checked during consolidation but has
not been exercised by a new APK build. Its first authorized build must be
inspected before claiming delivery. Existing v135's successful evidence remains
the proof for the unchanged application baseline.
