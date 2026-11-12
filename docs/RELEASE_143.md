# Combined narration delivery and build-142 audio controls

This integration starts at default commit
`85ccae6274a29b10dc576e7f8fee6f5ca6e4170d`, which contains the reviewed
narration-delivery changes, and ports the published build-142 runtime from
`5ea8b4d810377f0c831d3afa61eb41e5e7089fe0` (`v142`). The original
`fix/audio-controls-142` branch and its unmerged PR are not changed or merged.

All 79 native, vendor, dependency, test/tool and supporting files selected from
142 are byte-identical to that release. Only `lib/main.dart` and
`lib/dogreader_audio_handler.dart` combine the two changes: delivery/lifecycle
reconciliation and serialized narration-position storage remain present together
with 142's native-command ownership fix and bounded diagnostics. The canonical
manual release workflow stays unchanged; the branch-specific 142 workflow is
not ported. Package, original signing identity, recording paths, library and
saved reading/listening state are retained.

Local verification: clean Flutter analysis and 38 focused delivery, file,
playback, service-lifecycle, diagnostics and book/article queue tests passed.
The full Flutter regression suite also passed all 142 tests. Required Actions
release checks and APK/signature verification are still separate release gates. Build 142's Android service-recreation and System UI evidence applies
to its unchanged native files; it is not a new physical Pixel verification of the
combined build. Physical Pixel/Bluetooth/network-interruption acceptance remains
outstanding.

Next release number is 143 only if a fresh releases/drafts/tags check still finds
142 highest. Build/publish once through the default branch's existing
`release-apk.yml`, with an exact reviewed reachable commit, original signing key,
full tests and downloaded Release-asset hash verification. Do not replace 142 or
use a historical branch workflow. An APK is delivered only after its numbered
Release contains the verified APK under Assets.
