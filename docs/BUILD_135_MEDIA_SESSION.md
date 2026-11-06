# Build 135: retained media-session lifecycle

This is a test candidate, not a confirmed repair of the delayed Pixel failure.
Build 134 still fails on the user's device: in-app Pause always stops audible
narration, while shade/lock-screen controls eventually stop working permanently.
The supplied screenshots show external commands after an in-app Pause; those
entries do not establish completion of an external Pause during audible playback.

## Reproduced defect and correction

`DogreaderAudioHandler._broadcastPlaybackState` allowed the native player's
`ProcessingState.idle` to become the session's `AudioProcessingState.idle` during
nonterminal operations. In audio_service 0.18.19, `_observePlaybackState` sends
`stopService` on a transition to idle. Its Android `AudioService.setState` also
calls `stop()`, deactivating the MediaSession and calling `stopSelf()`. If the
service is destroyed, it releases the session and clears its callback listener.
This is a lifecycle instruction, not an innocuous player-state update.

The concrete app path reproduced without synthetic player-idle injection is:
start playback, hold a native Seek reply, then navigate chapters. `loadChapter`
releases that engine to cancel the outstanding Seek. Before Build 135, that
release publishes idle and the real audio_service Dart bridge sends a native
`stopService` request even though the chapter/session is retained. The bridge
test fails against Build 134's state mapping and passes with the correction.

Only explicit handler Stop now publishes terminal idle. A retained player idle
maps to loading during preparation, or ready/paused otherwise. Loading, decoder
release/recovery and chapter transitions therefore cannot inadvertently stop the
media service. Explicit Stop/unload/disposal retain their shutdown semantics.
Play without a source returns to stopped rather than publishing endless loading.
No player, dependency runtime version, cloud interface or progress format changes.

`AudioService.asyncError` is also recorded separately in diagnostics. Previously,
native media-service publication errors could be absent from “Last error,” which
only recorded playback-engine failures. Headset-disconnect Pause now has its own
origin, so it cannot be mistaken for evidence of a notification callback.

## Validation and limits

`session_lifecycle_test.dart` checks idle-before-decoder-error ordering, recovery,
chapter loading, Pause during loading, continuous transition and explicit Stop.
The first three lifecycle cases fail against unchanged Build 134.
`session_bridge_test.dart` uses the real audio_service Dart bridge with mocked
Android MethodChannels and player. It verifies that navigation/release and Pause
do not send stopService, external-channel Play/Pause still work, bridge failures
are captured independently, and explicit Stop still sends stopService.

These are deterministic mocked regressions. They prove an unsafe shutdown request
and its removal; they do not prove Android service destruction happened on the
Pixel, actual notification touch delivery, Bluetooth behavior, or long-running
audible playback. Existing Build 134 emulator results cannot be counted as native
verification of Build 135. A wholesale replacement with just_audio_background
would use the same underlying stack and is not justified by this evidence.

Local validation: `flutter analyze --no-pub` reports no issues; the complete
`flutter test --no-pub --reporter expanded` suite passes **81 tests**. No Android
APK was built during investigation. The state-mapping baseline bridge regression
fails with `Actual: MethodCall(stopService, {})` during chapter navigation.

The dedicated Build 135 Actions workflow checks out its exact source commit,
runs analysis and the full Flutter suite, builds one APK with version code 135,
checks the original package/signing identity, uploads `Dogreader-135-apk`, then
downloads it and compares bytes and SHA-256. It publishes no release and merges
no branch.

## Physical-device acceptance test

1. Install Build 135 over 134 without uninstalling or clearing data. Start
   narration; background the app. Press shade Pause while audio is audible,
   confirm silence, then Play. Repeat from the lock screen.
2. Keep listening for at least the interval that previously caused failure.
   Include several automatic chapter transitions, chapter navigation while
   seeking/loading, screen locking, and returning to the app. Repeat rapid
   Pause/Play; a deliberate Pause must stay silent through loading/transitions.
3. If controls fail, leave narration playing and press external Pause once.
   Wait 15 seconds before opening diagnostics. Capture that command and the
   “Last session bridge error” field before using in-app Pause. Then confirm
   whether in-app Pause still stops narration.

The lasting Pixel failure is resolved only when that real-device test passes.
