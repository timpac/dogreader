# Media-control reference audit

Audit date: 2026-11-11. Base: `eca7c65412c1c174557224b1522b7dbabfa559c7`.
Repair is isolated on `fix/audio-controls-142`, with no changes to other branches.
The device journal supports a native listener ownership defect across service
recreation with a surviving Flutter engine. The native baseline reproduces listener loss; the repaired service recreation,
source/position retention, media-key and 11-minute locked-pause checks pass.
System UI button activation through accessibility is pending. Physical touch
acceptance remains separate.

## Build 136 evidence

Export: 129,617 bytes; one Dart handler/process (PID 11273), no reported dropped
entries or I/O failures. Device reports API 37. All times below are UTC.

| Time | Evidence |
| --- | --- |
| 09:29:05–09:29:08 | External-origin Pause #30 completes and Play #31 reaches Dart. |
| 10:02:26.304–26.349 | Last external-origin Pause #33 reaches Dart and acknowledges native Pause/Stop. |
| 14:24:33.751 | External-origin Stop #35 reaches Dart; session publishes terminal idle. Its origin label does not identify which physical control caused it. |
| 16:55:55.306 | Old activity destroyed. |
| 16:55:55.415 | Activity resumes, before the old session is destroyed. |
| 16:55:55.730 | Native session token 20234485 destroyed. |
| 17:26:38.757 | Observer sees replacement token 142048267; new service start time, same PID. The snapshot does not timestamp service creation precisely. |
| 19:51:55 onward | Original Dart handler resumes via in-app commands, publishes state to the replacement session, and preserves source/position. No subsequent external play/pause receipt appears. |

There is no new Dart process/handler creation, bridgeError or playbackError in
the export. The activity reattachment before session destruction matches the
plugin's explicit engine-retention condition. This supports the listener-loss
path below. Build 136 did not record native command ingress or failed physical
taps, so the exact first failed touch cannot be timestamped from this export.
A later 20:32 foreground demotion follows a long Pause; retaining foreground on
Pause is not a guarantee that Android will retain the service indefinitely.

## Repair

Keep audio_service 0.18.19 and just_audio. The listener now follows its owning
Flutter engine: service destruction does not clear it if the engine survives;
that engine's plugin detach clears it. No handler recreation, retry loop, second
session or notification manager is added. Source, seek, focus, saved-position,
preview, chapter-transition and reader behavior are retained.

The exact previously locked package is retained under `third_party/audio_service`
with original license and provenance. Only its two native lifecycle/bridge files
change, plus an independent bounded native transport journal. Dart package source
and APIs are unchanged. Native receipt is logged before the listener-null guard;
bridge dispatch and Dart receipt are separate events. Build 136's bounded export
is selectively ported without its historical workflows or obsolete app baseline.

Verification uses the real Android service lifecycle with an attached activity:
explicit Stop followed by releasing the plugin's last service binding allows
Android to destroy the service while the engine survives; rebinding creates a
new session. Reflection changes the binding only in the isolated test harness,
not the production app. The baseline restores exactly upstream's two listener
ownership statements. It must receive native Play with listener=false and no
Dart receipt. The repaired probe must deliver it to the original handler, resume
the retained source near its saved position, and pause real native audio output.
Additional checks cover actual System UI button actions, media-key routing, rapid cycles
and an 11-minute paused/locked interval. Physical Bluetooth and prolonged API 37
Pixel acceptance remain separate from Android 13 emulator evidence.

## Verification evidence

| Check | Result / Actions run |
| --- | --- |
| Analysis and full Flutter regression suite | Passed in [43111278083](https://github.com/timpac/dogreader/actions/runs/43111278083). |
| Upstream listener lifetime | Reproduced native Play reception with listener=false and no Dart delivery in the same run. |
| Repaired recreation and long pause | All five stages passed in [43113144187](https://github.com/timpac/dogreader/actions/runs/43113144187), including the original handler/source/position, media-key Play/Pause and resume after 11 minutes locked. That run subsequently failed its separate UI touch case. |
| System UI controls | Pending. Tests activate visible real buttons through Android accessibility and require Dart receipt and native output changes. Coordinate-injection attempts exposed emulator clipping/launcher issues. Physical touch acceptance remains separate. |
| Diagnostic persistence | Local JVM rotation, restart, bounds and I/O checks passed. |
| Physical Pixel / Bluetooth | Outstanding; emulator media keys do not establish Bluetooth hardware acceptance. |

Later runs compare runtime files against the passing source before reusing
results. The full Flutter suite and timed pause are not repeated for changes to
the UI test driver or emulator display setup.

## References inspected

- [Official audio_service example](https://github.com/ryanheise/audio_service/blob/da405ddd07840d5861a09ab252cce6f40cc95a0b/audio_service/example/lib/main.dart).
- [Native AudioService](https://github.com/ryanheise/audio_service/blob/da405ddd07840d5861a09ab252cce6f40cc95a0b/audio_service/android/src/main/java/com/ryanheise/audioservice/AudioService.java)
  and [Flutter bridge](https://github.com/ryanheise/audio_service/blob/da405ddd07840d5861a09ab252cce6f40cc95a0b/audio_service/android/src/main/java/com/ryanheise/audioservice/AudioServicePlugin.java).
  The inspected upstream version is 0.18.19, also locked by Dogreader.
- [Google Media3 background playback, notification lifecycle and resumption](https://developer.android.com/media/media3/session/background-playback).
- Build 136 (`6ff767385bd6bfbc59eccd7ec842d74305ef0736`): diagnostic
  implementation and `docs/MEDIA_DIAGNOSTICS.md`. The subsequently supplied device export is analyzed above.

## Comparison

| Area | Dogreader / audio_service | Reference implication |
| --- | --- | --- |
| Session ownership | One `AudioService.init`, one handler-owned just_audio player; `MainActivity` extends `AudioServiceActivity`. The plugin creates the native session in service `onCreate` and releases it in `onDestroy`. | Matches the single service-owned session pattern. No evidence warrants another session or notification manager. |
| Notification | Plugin `buildNotification()` attaches the service session token with `MediaStyle.setMediaSession`. | Attachment already uses the active service's session. Investigate session/token changes before changing notification code. |
| Commands | Session callbacks forward through the plugin's static `ServiceListener` and MethodChannel to handler play/pause/click. In-app commands call the same handler directly. | Native reception and Dart reception are distinct boundaries; working in-app Pause does not prove the external bridge is intact. |
| Lifecycle | `androidStopForegroundOnPause: false`. Deliberate Pause releases the decoder while retaining source and a nonterminal session state. Only explicit Stop publishes session idle. | Preserve build 135's terminal-idle correction. The example's direct decoder-idle mapping is unsuitable for Dogreader's decoder-release-on-Pause behavior. Media3 normally leaves foreground after prolonged inactivity and explicitly supports restoration. |
| Restoration | `_recording` and `_resumePosition` are in-memory. Positions are saved in `narration_state.json`; the playback screen's `restore()` loads a source. Startup does not restore the handler source. | Process recreation loses the handler source until a screen reloads it. Persistence must include a recoverable active item and restore it through the same handler; saved position alone is insufficient. |
| Android 13+ | Plugin publishes session state/actions, converts rewind/forward/stop to custom actions on API 33+, and attaches the same session token. | System UI derives controls from session data. A separate notification implementation would not correct an absent command listener. |

## Native ownership path

The upstream native source has this possible sequence:

1. `AudioService.onDestroy()` invokes `listener.onDestroy()` and then clears the
   static `listener`.
2. That callback calls `AudioServicePlugin.disposeFlutterEngine()`. It returns
   without destroying the engine if an activity still exists.
3. In that case the static `audioHandlerInterface` can survive while the
   service's listener is null. A recreated service retrieves the cached engine;
   engine attachment need not run again. The configure path for an existing
   interface does not call `AudioService.init(audioHandlerInterface)` again.
4. A native play/pause callback checks `listener == null` and returns without
   invoking Dart.

The supplied journal now corroborates service/session turnover with a surviving
handler and the activity reattachment timing. The native baseline/candidate test
is required to establish the missing-listener mechanism independently.

Further tracing confirms that both `onAttachedToEngine` and the native configure
method install the listener only when creating a new `audioHandlerInterface`.
Neither `AudioService.onCreate()` nor the plugin's media-browser `onConnected()`
reinstalls it for a surviving interface. The listener-null guard executes before
the Dart dispatch, so this failure would not produce a Dart `commandReceived`
event. It is separate from a command reaching Dart but waiting in `_operations`.

For the supplied journal, use the last `commandReceived` with external origin
and its matching `commandResult` as the last known Dart delivery; a `dispatched`
result alone does not establish audible playback. Correlate the following
`session_destroyed`, `session_observed` token changes, `service_observed` start
times, `bridgeError`, and process identity. A new process indicates a different
recovery path from a surviving engine. A gap in events without destruction or
turnover evidence cannot establish listener loss. Export drop/I/O counters and
rotation limits must accompany the conclusion.

## Diagnostic coverage and verification gaps

Build 136 adds persistent Dart command events and a native **controller observer**,
not interception of native command callbacks. Its own documentation explicitly
states that it does not establish native media-button ingress. A native playback
state event is not a received command. The audited base did not include those
persistent diagnostics; importing the entire build 136 branch would also remove
newer dictionary/article work and restore historical workflows.

The evidence review compared process IDs, session tokens, session destruction,
bridge errors, focus, loading, and in-app commands around the last successful
external command and subsequent reported failure. Absence of a Dart event alone cannot distinguish an Android routing
failure from a lost Flutter callback.

Any native ingress instrumentation must record at the existing session callback
before its listener-null guard, then record bridge dispatch and Dart receipt
separately. It must not replace the callback with a competing controller/session
or route commands around the maintained library. Record process/service/session
identity and listener presence without logging titles, paths or credentials.

Existing `session_lifecycle_test.dart` and `session_bridge_test.dart` cover retained
session state and the Dart MethodChannel contract using fakes. They do not execute
the native service destruction path. The canonical release workflow runs Flutter
analysis/tests and builds the signed APK. For this isolated repair, the branch
version additionally requires native Android verification before the APK job.
Runtime verification runs through GitHub Actions; local checks cover source provenance, Python syntax and workflow structure.

Required acceptance remains: shade and lock-screen touches, real Bluetooth
controls, locked background playback, repeated transport cycles, an extended
pause, and service/process recreation with source/position restoration. Native
and Dart event counts plus actual output must agree. Short mocked tests cannot
establish sustained Pixel acceptance.

## Release constraints discovered

`v137` already exists at the audited application SHA and contains
`Dogreader-137.apk` (171,476,299 bytes). Releases through `v141-dog-reader-2.0`
also exist. The release workflow requires the next globally unused number,
currently **142**, and verifies original signing identity and package. The user
has approved v142 if still unused at publication, requires isolated development
without merging either active branch, and requires verification before release.
Preserve existing assets/tags and recheck availability before any build dispatch.
The isolated manual release workflow has been dispatched; publication is gated
on native verification. Its branch-only delivery override will be removed from
the final PR after delivery, preserving the canonical release workflow.
