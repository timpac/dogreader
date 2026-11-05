# Build 134: playback ownership and native Pause boundary

Baseline: published Build 133, `69016ca19c86be1dafa53b65a7624094ebc73c61`.
Work is isolated on `fix/134-media-ownership`; the older default branch and
other development/release branches are not modified.

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
