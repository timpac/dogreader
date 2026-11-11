# Dog Reader 2.0 experimental installation

This branch starts from integrated canonical build 137
`eca7c65412c1c174557224b1522b7dbabfa559c7`. It delivers the dictionary and
article import as a separate Android application. It does not change the
canonical branch, original releases, production backend or playback engine.

## One build switch, isolated installation

`DOGREADER_EXPERIMENTAL=true` selects both Dart identity/policy and the Gradle
application ID suffix. It is an isolated build configuration, without adding
flavors that would change the original APK task/output. Without this switch,
the original package, label, icon and cloud behavior remain selected.

| Identity | Original | Experimental |
| --- | --- | --- |
| Application ID | `com.example.audiobook_app` | `com.example.audiobook_app.experimental` |
| Launcher | Dogreader | Dog Reader 2.0 |
| Icon | Original icon | Purple book with orange 2 |
| Notification channel | `com.example.audiobook_app.audio` | `com.example.audiobook_app.experimental.audio` |
| Android signing certificate | Existing original key | Same known key, distinct application ID |

There is no shared UID, shared storage path or automatic migration. Existing
path_provider documents/cache storage is Android-package private, including
EPUBs, articles, dictionary/preferences, queue/cloud credentials, recordings,
reading positions and narration state. Import books/audio explicitly into the
new app. Existing recordings and data in the original app are untouched.

The audio handler and its build-135 lifecycle correction are byte-identical.
Services, receivers, pending intents and media sessions belong to their own
Android package/process; notification channels also have distinct IDs, names
and icons. Android audio focus remains shared system behavior, so simultaneous
playback is not promised. Physical dual-app notification/Bluetooth acceptance
remains separate from static APK checks.

## Paid operations

Experimental chapter generation requires approval for one chapter/request.
That permission is consumed at submission, is never persisted, and is cleared
when the operation/screen ends. Cancellation creates no submission. Automatic
queue polling may read job status/download existing audio, but cannot resubmit
a missing job or start waiting paid work without fresh consent. Network policy
is enforced before creating the narration HTTP client, alongside UI controls.

Voice/dictionary previews also require one explicit paid-request approval.
Whole-book/batch selection is disabled and generation rejects multiple selected
chapters. Future non-chapter mutation endpoints are blocked even with a chapter
approval. Pure whole-book planning helpers remain unused library code.

AI summary requests are hard-disabled for the experimental app, even if the
summary compile flag or an injected client setting is true. Cached summaries
remain readable. Cloud credentials start empty and are never copied from the
original app. There is no backend change or live paid acceptance call.

## Build and release

The branch-specific version of the already registered manual
`.github/workflows/release-apk.yml` runs only on
`experimental/dog-reader-2-installation`, restricted to the owner. It pins the
reviewed full source SHA, checks build-135/integration ancestry, unused
sequential numbering, locked dependencies, analysis and regressions, then builds
once with experimental mode true and summaries false. The ordinary release
workflow on the canonical branch remains unchanged. Do not merge this
branch-specific delivery workflow into the canonical branch as-is.

The next unused number at preparation is **138**. The intended delivery is
**Dog Reader 2.0 — Experimental build 138**, tag `v138-dog-reader-2.0`, asset
`Dogreader-138-Dog-Reader-2.0.apk`, versionName `2.0.0`. It is a prerelease and
does not replace the latest stable release.

Before publication, CI verifies the original signing fingerprint
`c5cc08d9757c0e92893a716204a26feb6157f5350a00dbb0b7962049d6d9d177`,
experimental package/version/launcher label/icon, and compares both compiled
manifests against the immutable, hash-verified v135 APK. It rejects shared UIDs,
conflicting provider authorities or declared permissions, and an incorrectly
resolved launcher activity. This verifies the package identities needed for
side-by-side installation without an emulator or phone installation. APK bytes
downloaded from the release must match the built SHA-256 before publication.

CI tests use mock/local HTTP and fake audio only. No production narration or
summary request is part of release acceptance. On-device checks still include
installation alongside v135, independent libraries/progress/audio, both launcher
icons and media cards, explicit cloud-request consent, Share import and sustained
background/lock-screen/Bluetooth behavior.

Pre-build checks: clean Flutter analysis; 14 focused default-mode regressions;
27 experimental policy/queue/lifecycle/media-control tests (including summaries
forcibly enabled to prove the experimental guard); three manifest collision
regressions; workflow shell/JavaScript syntax and whitespace checks. All pass
using fake/local HTTP and audio. CI repeats its required acceptance gates before
publication.
