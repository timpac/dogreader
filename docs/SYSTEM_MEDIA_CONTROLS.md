# Notification shade and lock-screen control repair

This change is based on build 124 source, commit
`6aadd2a12d17a4842d9d5b7015dbc24a24e56640`, rather than the older default branch.
The installed APK version and exact device symptom still need confirmation.
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

First confirm the installed build using the app's visible build number and the
package version. Record phone model, Android version, and whether the problem is
missing controls, ignored commands, or stale state. Do not uninstall the app or
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
