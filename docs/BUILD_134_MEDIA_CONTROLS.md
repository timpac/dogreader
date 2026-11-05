# Build 134: playback ownership and native Pause boundary

Baseline: published Build 133, `69016ca19c86be1dafa53b65a7624094ebc73c61`.
Work is isolated on `fix/134-media-ownership`; the older default branch and
other development/release branches are not modified.

Final verified playback source: `fe9e1a7d9d7581607b78dcacf6ae8d483536d8c1`.
[Final verification run 42047990148](https://github.com/timpac/dogreader/actions/runs/42047990148)
passed analysis, all 74 Flutter tests and all 17 native Android stages, including
Seek→Pause→Play after engine release. The signed release is gated on identical
playback/test source. Physical Pixel verification remains required.

## Architecture and defects

`main()` initializes one `DogreaderAudioHandler` through `AudioService.init`.
The returned handler is exactly the handler registered with audio_service's
callbacks. Android `MainActivity` extends `AudioServiceActivity`, which provides
the service's cached Flutter engine. The manifest has one media service and
receiver. The narration screen retains `audioHandler.player`; screen disposal
only cancels its subscriptions. It does not replace the narration player.

Before this change, `NarrationQueueScreen.previewVoice` created another
screen-owned player. External controls could not control that player's output.
Build 134 routes samples through the handler's sole player and restores the
previous chapter paused, at its previous listening position. Cloud requests,
generation, file names, saved recording metadata and reading offsets are unchanged.

The handler did not own all playback intent. just_audio 0.10.6, using default
`handleInterruptions:true`, independently paused and resumed the player on focus
changes. In that locked dependency's `pause()`, `if (!playing) return` precedes
clearing `_playInterrupted`. A deliberate Pause while interrupted therefore did
not cancel the plugin's deferred resume. The handler's transport generation
cannot cancel a `play()` called inside the plugin. This is a concrete bypass of
Pause, but must be distinguished from proof of the exact historical Pixel event.

A second boundary defect was that handler `pause()` treated the Dart player's
Pause completion as success, even when no platform command was sent, and caught
native Pause exceptions without silencing output. Build 134 acknowledges native
engine release on every deliberate Pause, preserving a resumable media session
and saved position. Play prepares the retained source on the same Dart player.
This also prevents a retained failed decoder from being reused during recovery.
It adds preparation latency to resume; it does not create a competing player.

Source preparation was concurrent. A slow old `setFilePath` could complete after
a newer load: metadata described chapter B while the engine held chapter A.
Load generations checked publication, but did not serialize the engine mutation.
An old play Future's error also updated the newer chapter's session unconditionally.
Build 134 serializes structural operations, scopes lifetime callbacks to engine
and intent revisions, and keeps Pause/Stop outside the preparation queue so they
can cancel immediately. A cancelled prepare retains matching source metadata
for a later deliberate Play. A completion received while intentionally paused
cannot initiate continuous playback.

The handler now owns speech audio-focus configuration and interruption/noisy
listeners. Temporary focus regain may resume only while the original intent
revision remains current. Pause, Stop and navigation revoke that permission.
The plugin's independent focus activation and interruption handling are disabled.
Background/foreground changes have no automatic-play callback. Listeners belong
to the handler, not a screen.

## Command tracing and suspicious sequences

Android transport callbacks run through audio_service's handler callbacks to the
same play/pause methods used in-app. Build 133 logged entry only. Build 134 logs
receipt, dispatch, native Pause/Stop acknowledgement, cancellation, failure and
play-lifetime settlement separately. It also records intent/source revisions and
in-app/reader/automatic command origins. A dispatched Play is not mislabeled as
a native start acknowledgement: just_audio's play Future ends at Pause/EOF.

The existing reader `seekNarrationFromText` deliberately does load, Pause, Seek,
including Seek(0) when the text fraction is zero. Importing replacement audio
also seeks to zero; EOF replay seeks internally. Recovery prepares a source at
its saved position, and chapter advancement prepares the next source at zero.
The original entry-only history cannot prove which UI route produced #8/#9 or
whether #11 completed. The decoder error likewise lacks enough correlation to
identify it as the cause of the reported touch failure. It is not assumed to be
incidental or conclusive.

## Regression evidence

Run against an untouched Build 133 worktree before applying the fix:

- `playback_ownership_test.dart`: all four tests fail: reordered preparation,
  native Pause failure leaving output playing, unsolicited resume after Pause,
  and an old error poisoning a new session.
- `native_boundary_test.dart`: fails when a model of native output remains active
  although the Dart playing flag is already false. This models the locked
  plugin's early return; it does not claim that drift was observed on the Pixel.

Candidate Flutter coverage includes those cases plus rapid alternating commands,
long playback Futures, delayed native Pause followed by Play, Pause/Play/Stop
while preparing, completion after Pause, focus regain and explicit cancellation,
headset disconnect, recovery, preview cancellation, progress preservation,
media-session actions, multiple automatic chapter transitions, reader behavior,
themes, generation options and recording replacement. Existing continuous-playback
coverage now starts playback before injecting completion: a synthetic completion
on an intentionally paused player must not start a new chapter.

The Android harness uses real audio_service/just_audio, a synthetic local WAV,
an isolated `.test` package and ephemeral signing, and checks external native
MediaSession state/completion, background/foreground and locked-screen handling,
rapid transport commands and real focus loss/regain. It also checks Android's
native music-output activity after Pause rather than accepting Dart flags alone.
It runs a Build-133 baseline separately from the candidate. Physical notification
and lock-screen taps remain device verification; command delivery is already
confirmed on the Pixel. The first emulator attempt could not locate the System UI
Pause control on either baseline or candidate, so no touch pass is claimed.
Report upload hit the repository artifact quota; subsequent jobs retain complete
reports in logs and the job summary independently of that quota. No cloud call, real
book or physical phone is used. Results and release provenance are appended after
verification.

## Physical verification still required

Install the signed update over Build 133 without uninstalling/clearing data.
On the Pixel 8 Pro, record the exact Android version and test both shade and lock
screen: repeated Pause/Play, a phone/navigation interruption, Bluetooth disconnect,
return from background, loading, and several continuous chapter transitions.
Confirm audible silence after Pause and no delayed resumption. Repeat after a
real decoder fault if one occurs naturally; synthetic tests cannot reproduce
every codec/OEM fault. Command completion and Android output activity are stronger
evidence than receipt, but cannot establish the user's phone's audible behavior.

## Initial native proof of the Build-133 defect

[Run 42042177585](https://github.com/timpac/dogreader/actions/runs/42042177585)
completed successfully on Android 13 from
`fb523835170dfe2565d8c8051b36d1249125b533`.

The Build-133 baseline failed with **"Audio output resumed after deliberate
Pause"** during real Android audio-focus regain. This assertion reads
`AudioManager.isMusicActive()` independently of the Dart playing flag. It is a
reproduced native output failure, not merely a command counter, session icon,
or mock assertion. The baseline's plugin resumed without a handler Play command.
The candidate passed all 16 native stages, including remaining paused through
focus regain, native output inactivity, background/locked-session Pause/Play,
seek, in-app Stop/restart, foreground changes and rapid commands. The candidate
snapshot after focus-regain cancellation had player=false, session=false and
processing=idle, while the native session remained resumably paused.

Full Flutter analysis and all **71 tests** passed locally and in that CI run.
The initial System UI selector failure is not counted as a playback failure or
a touch pass. The artifact quota warning is not a test failure: complete native
reports are retained in the successful job's logs and summary.

The signed APK workflow requires a successful native run with identical library,
Android, test, dependency and native-harness contents, checks out its own exact
commit, runs analysis and the complete suite again, and verifies the original
signing certificate, package and version code 134. The release commit changes
only the APK workflow and this report relative to the verified native source.
Release upload is hash-checked before publication and refuses existing assets
or tags belonging to another commit.

This proves and fixes an actual Build-133 Pause bypass on Android. The original
Pixel screenshot does not establish that a focus interruption was its exact
trigger, or that the historical renderer error caused it. Physical Pixel audible
output, notification/lock-screen taps, long background periods and real Bluetooth
or codec faults still require the device checks above.

## Seek cancellation correction before final delivery

Review of locked just_audio Android `AudioPlayer.dispose()` found that its
outstanding `seekResult` is not necessarily completed when ExoPlayer is released.
The initial serialized candidate therefore had a reproducible queue deadlock:
Pause silenced output, but a subsequent Play waited indefinitely for a Seek reply
from a released engine. A dedicated lost-callback regression failed before the
correction. No final installation link was delivered for that candidate.

The operation queue now cancels its Seek waiter only after native release is
acknowledged, restores the inactive player's last confirmed position, and ignores
late replies from the released engine. Navigation also releases a pending Seek;
a five-second native seek deadline safely pauses/releases before returning an
error. The queue never starts a replacement while the prior output is unconfirmed.
Three regression cases cover Pause→Play, navigation plus a late error, and timeout
plus replay. Android verification additionally races native Seek→Pause→Play six
times and requires audio output to stop and then restart, making 17 native stages.

Cancellation of the first signed build arrived after its own release upload had
finished. Its asset had zero downloads. That release was immediately withdrawn,
retained as a private draft titled `Withdrawn pre-seek candidate - do not install`.
The archival Git tag `dogreader-134-withdrawn-a9bbf4a` preserves its source commit.
The original 134 tag was removed only after verifying it belonged to that exact
task-created commit. The final 134 release must contain the corrected source and a new native
verification; that earlier asset must not be installed.

## Final native verification

[Run 42047990148](https://github.com/timpac/dogreader/actions/runs/42047990148)
passed from `fe9e1a7d9d7581607b78dcacf6ae8d483536d8c1`. Analysis and all 74 tests
passed, and the candidate passed all 17 real Android stages. The additional stage
ran six native Seek→Pause→Play sequences, checking audio inactivity after Pause
and active audio after Play. The Build-133 baseline again failed the focus-regain
Pause test. The native reports remain in logs and the job summary despite the
artifact storage quota warning.

The final publication commit changes only this report and the APK workflow's
push trigger relative to that verified source. It re-enables the signed build
only after successful native verification. The original signing identity,
version 134, original application package and uploaded bytes are checked before
the corrected release is published.
