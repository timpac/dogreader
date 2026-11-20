# Original DogReader: build 153 progress audit and build 156 repair

## Provenance and scope

The verified **compiled source of original DogReader 153** is
`47bd9a985a1bccadef07f6f2d961433a4898949c`, not the largest numbered branch.
[Actions run 43649191605](https://github.com/timpac/dogreader/actions/runs/43649191605)
explicitly checked out that SHA, passed analysis/tests, built versionCode 153,
and verified `com.example.audiobook_app` and the original certificate. Its
`Dogreader 153` draft release identifies the same source and APK SHA-256
`0fee109a9be692b05e2e24a934f551d2296e3159bcbf85abb5bfb699aa7d31a6`.
There is no published Git tag `v153`; draft release metadata and build logs
establish the source independently.

The source is contained in `fix/145-backend-and-delivery-repair` (exact tip)
and `fix/153-backend-and-delivery-repair`. The latter tip `f997cd0` only adjusts
the release workflow to compile `47bd9a9`. The default branch remains
`dogreader-oct22-update`, tip `30e92ca`. Build 153 contains its application plus
large-audio delivery fixes and a checked-in cloud source snapshot. None of the
cloud source is changed or deployed by this repair.

This task branch, `fix/156-progress-persistence`, starts at **47bd9a9** as
explicitly requested by the owner, overriding the older default-baseline
instructions in AGENTS.md. All branches, tags, draft/published releases, open
PRs and Actions history were inspected before branching. The next unused number
is **156** under the existing repository-wide reservation rule: 154 and 155
are retained DogReader 3.0 draft APKs, not newer original applications.

Relevant unmerged work: PR #22 (`feature/audio-to-text-sync`) implements optional
validated audio/text alignment; it is not required to remember a section and
is not imported. PR #31 (`fix/audio-controls-142`) has useful service-recreation
history; its native listener fix is already present in this baseline through
the build-143 integration (the remaining divergent commits are diagnostics,
verification/delivery history). No other newer original-client fix exists on
the build-153 branch. DogReader 2.0 and 3.0 branches are excluded. Existing
baseline features remain intact; no RSS or Kokoro branch is merged.

## Confirmed implementation defects

These are code findings reproduced with regression tests. The user's actual
phone data was not available, so no claim is made to have inspected Brass Man's
on-device files or reproduced its full driving session.

| Before repair: file/function | Finding and consequence |
| --- | --- |
| `main.dart`, `_LibraryScreenState.saveProgress`, `openBook`, `openChapters` | Library-owned maps were loaded from `reading_state.json`. Only reading called `saveProgress`. |
| `main.dart`, `ChapterNarrationScreen.onSave` | Callback was carried but unused. Listening deliberately did not alter reader offsets, but had no separate book-level activity link. |
| `dogreader_audio_handler.dart`, `_savePosition` | Saved only `narration_state.json[book:section].positionMs`. Correct audio resume could coexist with an overview permanently showing an older reading section. |
| `dogreader_audio_handler.dart`, `_advanceToNextChapter` | `_savePosition(Duration.zero)` ran while `_recording` still referred to the finished section. It erased that section's resume timestamp; the new section had no immediate activity checkpoint. Final EOF also lacked a completion save. |
| `main.dart`, `ChapterListScreen` | Took a fixed `saved` snapshot. No subscription refreshed the visible Continue Reading row; bars used text highwater alone. |
| `dogreader_audio_handler.dart`, position listener and focus interruption | Saving depended on an event falling within an exact second divisible by five; focus loss silenced audio without an explicit checkpoint. |
| `main.dart`, reader pagination/dispose; player `restore` | Routine reader checkpoints could look like new activity. Restoring a discovered MP3 redundantly wrote a previously read timestamp, permitting a stale overwrite. The player route retained its original chapter label after background advancement. |

## Storage and complete event path

No database or shared preferences store book progress. Existing JSON files in
the application documents directory remain the persistence layers:

* `reading_state.json`: `positions` is the last **actual text cursor** per book;
  `chapterProgress` is maximum text offset per section; `lastOpened` orders the
  library. New additive `readingActivity` stores section and activity order.
* `narration_state.json`: existing `book:section` records retain `path`,
  `positionMs`, recording identity, dictionary and offset maps. Additive
  `furthestPositionMs`, `durationMs`, `visited`, and `completed` describe listening
  highwater/completion. `_bookProgress[book]` stores the last listening section
  and activity order **in the same atomic commit as its timestamp**.
* `dogreader_queue.json`: cloud jobs/preferences/delivery status, not playback
  progress. `narration/` contains unchanged MP3 files and download recovery
  journals. Appearance/dictionary/article files do not own EPUB/audio progress.
* In memory: `BookProgress` holds a read model and serialized event queue. The
  audio handler retains confirmed native position, source/intent revisions and
  transport queues. Reader state holds pagination anchors and a session token.

Audio event -> handler captures the actual recording/confirmed timestamp ->
`BookProgress.saveAudio` -> `updateNarrationJson` serial read/modify/flushed-temp
write/atomic rename -> notifier -> library and chapter overview refresh.
Restart loads both files and derives the same destination. Download/import
metadata writes retain the existing shared serialization helper, so cloud
recording fields and positions cannot overwrite one another's snapshots.

## Defined behavior and repairs

* **Continue reading** opens the last active reading/listening **section**.
  It restores a real saved reader offset only when the text cursor is in that
  section; otherwise it opens its start. No audio timestamp is guessed into a
  text offset. **Continue listening** separately opens the saved listening
  section and restores its audio timestamp without auto-playing.
* Opening/reading an earlier section intentionally changes last reading
  activity. It does not overwrite audio resume or furthest progress. Merely
  preparing an earlier audio section (including paused position events or a
  redundant Pause) does not claim new listening activity. Playing/seeking does.
* Furthest reached is separate from last active and shown when they differ.
  Section bars use the greater of text highwater and listening highwater
  fraction; a completion check is consistent with that persisted state. The
  ratio represents consumption, not word-level alignment. New/unknown audio
  duration does not fabricate a fraction.
* EOF commits the completed section at its duration, including the final
  section or an unavailable next MP3. Automatic transition commits the new
  section immediately after successful preparation and before starting audio.
* Checkpoints occur on Play, Pause, Stop, verified seek, outgoing source change,
  focus interruption, navigation, app lifecycle and task removal. A position
  delta of five seconds supplements these events without relying on exact
  modulo seconds. Shutdown callbacks are not required for committed progress.
  Unexpected process death can still lose the most recent uncommitted interval;
  five seconds is a Dart-event checkpoint target, not a measured Android limit.
* Captured events are serialized; timestamps are ordered after loading prior
  clocks, including clock rollback. Per-reader session tokens prevent old route
  checkpoints from replacing a newer text cursor. Historical highwater remains
  preserved. Reflow/dispose/lifecycle checkpoints do not reclaim last activity.
* Writes merge the latest JSON, preserve unknown fields, flush before rename,
  and publish in-memory changes only after success. Corrupt files are retained,
  healthy progress remains readable, and a failed save does not poison later
  operations. Audio save failures are exposed in existing diagnostics without
  disabling transport.
* The player route follows actual handler chapter metadata after automatic
  transitions, while initial loading continues to honor the selected section.

Compatibility is additive; neither MP3 bytes nor saved text/audio cursors are
mass-migrated. Legacy files cannot reveal actual recency because they had no
audio activity record. Until a new reading/listening event exists, only the
**overview fallback** includes a later section with a positive saved audio
timestamp. This never changes either stored resume. Earlier completion erased
by old code cannot be reconstructed. Legacy bars gain audio fractions when a
real duration is subsequently observed.

## Android audit and verification boundary

The retained `audio_service` handler owns the player, focus listeners and
progress writes outside screen lifetime. `main` injects the same coordinator
into the library and handler. The existing Android mediaPlayback foreground
service, wake-lock permissions, notification channel, native listener ownership
patch and original MediaSession remain unchanged. Notification/lock-screen/
Bluetooth commands route through the same Play/Pause/seek methods; becoming
noisy routes through Pause. Focus interruption now checkpoints before silencing.
Foreground/lifecycle checkpoint observation is registered once on the handler,
independently of the reader. Task removal checkpoints without stopping playback.
Force-stop/process death has no assumed final callback.

Flutter fake-player tests demonstrate event handling and persistence, **not**
Android scheduling, native Bluetooth delivery, Doze, OEM restrictions, lock-screen
touch reliability or extended physical playback. No emulator or physical device
was used for this repair. Sustained device acceptance remains outstanding.

## Automated verification

The initial full Flutter run passed **177 tests**. Final affected regressions
and static analysis are rerun after review; the delivery workflow gates APK
compilation on clean analysis and the full suite for the exact committed SHA.

| Required scenario | Regression coverage |
| --- | --- |
| Listen 7 -> 8, return to overview | `progress_handler_test`, `progress_overview_test`: old completion, immediate next activity, live row/bar/check update and correct Continue Reading destination |
| Pause 8, restart | `progress_handler_test`: exact millisecond disk record, new coordinator and new player load |
| Background section boundaries | Handler test without any Flutter reading/player screen; existing repeated-continuous-playback/session tests |
| Audio -> reading | Independent text/audio resume tests and real route-switch widget test |
| Reading -> audio | `progress_mode_switch_test`: actual Listen from this page route and seek, preserved reading anchor |
| Earlier section | Separate last active/furthest/listening cursor, prepared-but-unplayed audio and redundant external Pause |
| Rapid navigation | Multiple queued handler loads; queued reading/audio updates; late older-reader checkpoint |
| Overlapping/interrupted writes | Stalled directory resolution, concurrent metadata writes, corrupt-file failure/retry and unknown-field preservation |
| Termination/restoration | New instances read already committed files without any shutdown call; OS kill timing remains a device check |
| Final section | Explicit EOF completion survives Stop/reload; reader forward gesture completes the last page |
| Existing progress | Legacy two-file fixtures, no inferred timestamp migration, healthy reading despite damaged audio metadata |
| New imports | New-book progress initialization remains empty until use; existing EPUB parsing/navigation tests retained |

`book_progress_test.dart`, `progress_handler_test.dart`,
`progress_overview_test.dart`, and `progress_mode_switch_test.dart` contain the
new cases. Two existing continuous-playback assertions now wait for actual
playback as well as metadata publication, allowing the transition checkpoint
to commit. Their media-session and playback assertions are retained.

## Physical Android acceptance checklist

Install the new APK **over the existing original application**. Do not uninstall,
clear storage, regenerate narration or delete downloaded audio.

1. Brass Man: note separate text/audio resumes; play Section 7 through 8. Lock
   the phone before transition, listen at least 30 minutes, and pause through
   the lock screen. Unlock: verify Continue Reading/Listening says Section 8,
   the previous section is complete and resume is near the paused timestamp.
2. Repeat with notification buttons and Bluetooth car/headset media keys,
   including disconnect/reconnect and 10+ minutes paused before resuming.
3. Switch apps; trigger a real call/navigation prompt or other audio-focus
   interruption. Verify Pause/resume, position and continued single-session
   notification behavior without opening the reading screen.
4. Swipe the task away while playing. Verify supported background behavior,
   transition/pause saving and reopening. Separately terminate the process
   without a shutdown callback, then force-stop and relaunch; playback need not
   auto-start after force-stop. Compare with the latest committed timestamp.
5. Read earlier sections, switch to Listen from this page, then return. Verify
   text anchor, explicit seek, independent listening resume and furthest label.
   Rapidly open/back between sections, rotate/reflow, and confirm no regression.
6. Complete the final section and reopen after restart. Test an unavailable
   next MP3, seeking backward after completion, and intentional replay.
7. Confirm existing downloaded files play offline, seeking/speed/continuous
   playback work, existing cloud downloads/generation still work, and a newly
   imported EPUB starts with no fabricated progress. Exercise overnight/Doze
   and OEM battery restrictions separately. Save diagnostics for any failure.

## Delivery and changelog

The only build route remains the manual `release-apk.yml`. A narrowly scoped
task-branch exception verifies both build-153 ancestry and the exact repair
branch/source. Push/PR/tag events do not compile APKs. Signing, package identity,
download verification and existing-release overwrite protection are retained.
Publication explicitly pins the numbered tag and source to avoid temporary
draft-tag delivery. No default branch merge or other-app release is performed.

Build 156 changelog: synchronize overview with listening; preserve independent
reading/audio resumes; persist section transitions and final completion; add
event-driven/background checkpoints; prevent stale reader/metadata writes;
refresh progress indicators and player chapter labels; retain legacy data and
downloaded audio; add automated regressions and a physical-device checklist.
