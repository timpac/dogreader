# Notification shade and lock-screen control repair

This change is based on build 124 source, commit
`6aadd2a12d17a4842d9d5b7015dbc24a24e56640`, rather than the older default branch.
The user has confirmed build 124: notification and lock-screen controls flash
on touch but do not affect playback. The same symptom occurred around build
119. In-app controls still work; the failure is confined to notification and
lock-screen controls. Phone: Pixel 8 Pro. Android 17 Beta 3 was reported with uncertainty; the exact OS version remains unconfirmed.
Build 119 already added a player-state listener; adding that listener again is
not the repair here.

## Reproduced failures

A test-only commit, `5e1dd88e59358a492978b55763aa32a88db889c3`, reproduced eight
failures against the build-124 handler in
[CI](https://github.com/timpac/dogreader/actions/runs/41114208778):

- Stop could publish idle while retaining playing=true without a native update.
- Final completion and a missing next recording retained a Pause action at EOF.
- Delayed duration and speed changes did not reach system metadata immediately.
- Asynchronous decoder errors left the session advertising ready/playing.
- Continuous playback held its advancement guard until the next play Future
  completed, preventing another completion event from advancing again.
- Pause during next-chapter preparation was overwritten by automatic playback.

The repair explicitly synchronizes stop/completion state, rewinds before replay,
checks user intent before automatically starting the next chapter, and releases
the advancement guard before awaiting a long-lived play operation. It preserves
the existing player, continuous playback, progress files, chapter IDs, app ID,
recordings, Android activity/service/receiver, and cloud API. No signing identity,
runtime permissions, or cloud settings are changed.

Stopping intentionally dismisses the active session. A later Play must rebuild a
valid playing state. Pausing keeps a resumable state. When a next source finishes
preparing after Pause/Stop, metadata must match that source and automatic
playback must remain suppressed.

## Automated checks

The new PR-only `System media control regression tests` workflow uses Flutter
3.47.7 (matching the existing APK workflow), pinned action commits and the locked
dependencies. It runs full static analysis and all Flutter regression tests.
It has contents:read only, no signing/cloud secrets, no OIDC permission, and no
APK publication or deployment steps.

Tests use the injected fake player and temporary state files. Its play Future
can remain pending until pause/end, matching just_audio semantics rather than
returning immediately. Tests cover native-event omissions, media-key toggle,
completion/replay, safe seeks, late metadata, errors, multiple chapter advances,
and Pause/Stop during preparation. These tests do not emulate Android's native
MediaSession, notification rendering, or PendingIntent delivery.

## Required device verification before calling the reported issue fixed

Build 124 and ignored system-control touches are confirmed. Record phone model
and Android version. In-app controls are confirmed working. Do not uninstall the app or
clear its storage: that risks local books and recordings. Use an update signed
with the existing key and a higher version code when an APK is prepared.

On the matching candidate APK, test both notification shade and lock screen:

1. Start an existing local chapter and check title, duration and Play/Pause state.
2. Pause/resume repeatedly and rewind/forward near zero and the chapter end.
3. Navigate away from the narration screen, lock for at least a minute, then
   repeat the controls. Verify pause remains paused after another app opens.
4. Stop, reopen the chapter and play again. Check that the session returns.
5. Finish the last chapter and a chapter whose next recording is missing; Play
   must replay from zero. Check media-button/headset toggle as well.
6. Let at least three downloaded chapters advance with the screen closed. Pause
   and Stop during a transition; neither may be overridden by autoplay.
7. Verify a late duration update, speed change, imported replacement recording,
   and a corrupt local-file error. A failed local file must not trigger paid
   regeneration merely to test these controls.

Android 13+ chooses notification slots from MediaSession state. The locked
audio_service version already maps rewind/fast-forward to custom actions for
those versions; this patch does not replace them with chapter-navigation buttons.
Check the actual phone and an Android 13+ emulator/device before treating a
source-level result as native command-dispatch validation.

## Native delivery regression harness

`Android native media controls` builds two synthetic probe APKs: the original
build-124 handler and the candidate handler. Both use the real audio_service,
just_audio, Android activity/service/receiver, and production service configuration.
The test entrypoint records command counters and observed playback state while
playing a bounded, locally generated WAV tone. It makes no cloud request and
reads no existing recording.

Native instrumentation connects explicitly to DogReader's own media session,
checks its transport, then physically taps Play, Pause, Rewind and Fast Forward
in Android System UI using accessibility bounds. It reads the current window
directly rather than requiring an idle UI dump while the seek bar is updating.
It repeats Play/Pause with the lock screen visible and after Stop/restart. A tap
passes only if the handler receives the command and the real player changes
state or position. Tests use an isolated `.test` package, an ephemeral signing
key, and an emulator; the script refuses a physical phone or another APK package.

The instrumentation runs the whole case in one session: starting a separate
instrumentation for each query would restart the target app. The separate helper
APK has test-only AndroidX dependencies; the shipped runtime dependencies and
signing configuration are unchanged. Twelve stages must report receipt and
observed player/session response, including the locked-screen checks.

The baseline result is reported separately and may fail; the candidate check is
required. A baseline pass means the reported phone symptom was not reproduced
on that emulator and must not be presented as a proven fix. The harness does
not exercise every production screen or OEM power-management policy. No APK is
uploaded, published, or installed on the user's phone by this job.

An early native attempt did not establish the reported touch failure: a global
media-key command was not observed by the baseline handler, while the candidate
accepted direct commands but the CLI accessibility dump failed before a touch
could be tested. The instrumentation replaces both ambiguous mechanisms. An
earlier runner also exhausted disk space before starting the emulator; runner
disk preparation is now explicit.

## Diagnosing a remaining failure

Command entry points emit `dogreader_media_command` with command name, chapter
identifier, playing flag and processing state. Decoder errors emit
`dogreader_media_error` with error type/code. No recording path, title, chapter
text, token, or provider exception message is included.

For a locally connected test phone, `adb logcat -v time -s flutter` captures
these markers, and `adb shell dumpsys media_session` shows the Android session.
Review dumps locally: they can contain private book titles. Do not publish a
complete log or dump without redaction.

If a physical button press produces no command marker, investigate native
session registration/delivery and device lifecycle. If a marker arrives but
state is wrong, correlate the operation with the player/session state. A lack of
markers alone is not proof of a particular Android cause.

## Rollback

Keep the draft PR unmerged until verification. Revert its changes to restore
the build-124 handler; no data migration or cloud rollback is needed. Android
usually prevents installing a lower version code over a higher one: use a new
build number with the old source and existing signing key instead of uninstalling
or clearing app storage. No APK has been installed or published by this workflow.

## Native result for PR #13

[Run 41138199459](https://github.com/timpac/dogreader/actions/runs/41138199459)
passed all twelve candidate stages on stock Android 13. The baseline passed
initial shade/lock controls, but its Pause control was absent after Stop/restart.
This does not reproduce the reported flashing/unresponsive touch on the Pixel
8 Pro, reportedly Android 17 Beta 3 (unconfirmed). Device validation remains open.
