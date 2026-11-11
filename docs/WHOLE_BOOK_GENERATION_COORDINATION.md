# Task 3: whole-book generation coordination

Status: **preflight only; the whole-book feature is not integrated or delivered**.
The user's last instruction ended at “Do not independently change shared TTS,
queue, or backend interfaces withou”. Shared-interface coordination is pending.

## Baseline and branches

Client branch: `feature/whole-book-generation`, from canonical tip
`c3cc7bd2e9dadfc1c38019baf16a0a2c28fad4f4`. Before these additions, `lib/`,
`android/`, dependencies and tests are identical to requested build 135,
`cdf4227dc6a966b20e24f61179ac953b22689024`. The intervening commits consolidate
documentation and disable historical automatic delivery workflows.

Backend inspected read-only: `timpac/dogreader-cloud`, main
`3f38d63d6eaa610b5b06222c5d0a1e402cc13bcb`. Production deployment, IAM, queue
configuration and current cloud jobs have not been inspected or changed.
Proposed backend branch, after coordination: `feature/whole-book-generation` in
that separate repository. No backend branch or endpoint has been created.

## Overlap report, prepared before changing code

| Files / interface | Potential conflict | Proposed Task 3 boundary |
| --- | --- | --- |
| Client `lib/main.dart`, `NarrationQueueScreen` | Narrator selection, submission, polling, repair, download and queue persistence all share this class. | Keep a small UI integration; agree ownership before moving queue responsibilities. |
| `lib/narration_options.dart` | Narrator lists, saved preference, engine/model/settings attribution. | Consume the selected preference; pin backend-confirmed configuration once per book. Do not duplicate or change voice definitions. |
| `lib/narration_files.dart`, `narration_state.json` | Atomic replacement, repair/deletion and player paths; sync metadata can be lost by replacing a chapter's state object. | Retain chapter filenames and merge existing state fields. Serialize writes and preserve playback position. |
| `dogreader_queue.json` | Multiple screens can race read/modify/write, and `ready` currently combines cloud completion and local download. | Agree additive book metadata and one serialized writer; retain existing chapter records and vocabulary. |
| `lib/dogreader_audio_handler.dart`, Android | Playback lifecycle and current-source ownership. | No Task 3 lifecycle or transport changes. Do not replace the file currently playing during automatic downloads. |
| Backend `main.py` | `/dogreader/jobs`, status/retry/audio routes and recording identity. | Reuse these contracts; coordinate minimal additive book routes and worker-completion integration. |
| Backend `narration.py` | Canonical model/settings and new/legacy recording IDs. | Reuse unchanged, including existing legacy MP3 lookup. |
| Backend `reliability.py`, `recover.py` | Cloud Tasks dispatch, worker leases, checkpoint/retry budgets and recovery sweeps. | Keep the generation engine. Coordinate book admission/recovery hooks; do not introduce a second task queue. |

Open client PR #22, `feature/audio-to-text-sync`, modifies `main.dart`,
`narration_files.dart`, the audio handler, reader parser, dependencies and related
tests. It also has a companion backend alignment PR. Neither is merged into this
task. No branches named for Tasks 1 and 2 were discoverable; their scopes and
owners must be supplied before coordination can be completed. No messages have
been posted to other people or PRs.

## Existing backend behavior to preserve

- Chapter POST validates 100–250,000 Python characters and does not truncate.
  Flask bounds requests at 4 MiB. A whole book must not bypass these safeguards
  or assume that its complete text fits a single request.
- Canonical identity includes text, engine, voice, model and settings. Google
  jobs can reuse an existing legacy ID. Backend `ready` validates completed
  audio and pins the GCS generation. A local file or local `ready` flag alone
  cannot prove that current source/settings match.
- Cloud Tasks uses deterministic job/sequence names. GCS generation conditions,
  renewable worker leases, saved chunks and bounded retry budgets already
  handle duplicate delivery, interruption and crashes.
- **POST of an existing failed chapter resets its retry budget.** Automatic
  resubmission of an ambiguous failed request can therefore restart paid work.
  Poll known IDs; require explicit Retry Failed for terminal failures. Book
  activation needs an idempotency record that survives an ambiguous response.
- GET status repairs missing dispatch and expired leases. MP3 downloads use
  Content-Length and generation-pinned storage. Client replacement uses `.part`
  and retains the previous recording until replacement succeeds.
- There is no book manifest, book pause/cancel or per-book concurrency API.
  Queue-wide Cloud Tasks settings are an operator concern, not an app setting.

## Proposed coordinated implementation

These are design requirements for review, **not implemented API contracts**.

1. Prepare an ordered durable book manifest with one pinned narration
   configuration. Stage chapter text in individually bounded requests without
   dispatching synthesis. Backend preflight resolves canonical/legacy recording
   IDs and validates reusable audio. Return eligible, completed, active, failed
   and rejected chapters and a price estimate before activation.
2. Confirm chapter count, narrator, total/new characters, completed chapter
   titles, price/rate/currency and any rejected chapter reasons. Oversized
   chapters remain explicit failures; never shorten their text. Activation uses
   the durable manifest identity so repeated taps and lost responses reuse it.
3. Add book admission around the existing Engine and Cloud Tasks queue. Persist
   admission before dispatch, default to one active generation job, and bound a
   configurable maximum on the server. Worker completion and the existing
   recovery runner advance/reconcile the manifest independently of the phone.
   Chapter jobs already shared with other books keep their existing identity.
4. Pause stops admission of additional chapters; active work can finish. Cancel
   Remaining cancels unadmitted chapters and retains completed audio. Explicitly
   report already running jobs that will continue. Neither control deletes MP3s
   or resets retry budgets. Retry Failed retains checkpointed chunks and is an
   explicit, durable, idempotent action.
5. Extend client persistence additively and atomically. On startup and resume,
   restore all active books, reconcile status and download ready chapters while
   the app is running. Keep cloud completion separate from local downloaded
   state. Bound network timeouts, retry interrupted downloads, verify response
   length, and retain old recordings/position/sync fields during replacement.
   Automatic download must defer replacement of the currently playing chapter.
6. Show completed/total plus queued, generating, ready, downloaded and failed
   counts, and distinct pending-download errors. Preserve existing player paths
   and playback controls. Do not claim background downloads while Android has
   stopped the app; cloud generation continues and downloads resume on reopening.

Submitting every chapter immediately through today's chapter API would let
Cloud Tasks continue after app closure, but cannot enforce a configurable
book concurrency limit or reliable book cancellation. Throttling submissions on
the phone would leave later chapters unsubmitted after app closure. Neither
approach satisfies the complete request without the coordinated backend work.

## Independent preflight code and verification

`lib/whole_book_preflight.dart` is a pure, non-mutating planning component. It
does not submit, persist, retry, download or change any shared interface. It
requires backend-resolved expected recording IDs and authoritative server status
to classify completed/active recordings. Unknown identity or metadata is never
treated as proof of reuse. Configuration is snapshotted and compared with stable
JSON key ordering. Unicode counts match Python scalar counts.

`tool/check_whole_book_preflight.dart` exercises reading order, reuse, active and
explicit-retry classification, changed text/voice/model/settings, missing
metadata, cost exclusion, Unicode, limits/no truncation, immutable snapshots,
duplicate chapter rejection and invalid rates. The Flutter test wrapper includes
these checks in the normal suite once Flutter is available.

Actual local results:

- Dart 3.13.7: **26 checks passed**, no network or synthesis calls in the test.
- Targeted Dart analysis of the planner and harness: **no issues found**.
- Both files formatted. Formatter warned that the project's Flutter lint include
  is unresolved because Flutter dependencies are not installed.
- Flutter suite and wrapper **not run**. The configured Flutter 3.47.7 archive
  and release-index download returned HTTP 404 in this environment. No APK built.
- Existing client queue, player, Android and backend files are unchanged.

Run the independent checks with `dart tool/check_whole_book_preflight.dart`.
After integration, add fake HTTP/storage tests for repeated activation, lost POST
responses, failed-job polling without automatic retry, restart during submission
and download, two-screen writes, pause/cancel while a worker is active,
concurrency bounds, recovery-runner admission and playback of downloaded samples.
Then run Flutter analysis and the existing regression suite. No full real-book
generation is needed for any of these checks.

## Cost reporting

Development synthesis/cloud-job cost so far: **$0**. SDK downloads are development
tooling, not TTS. No production calls, deployment or APK publication occurred.

The planner accepts an explicitly supplied USD rate per million characters;
there is no hardcoded or purported current tariff. Gross estimated TTS cost is
`new-or-explicitly-retried characters × rate / 1,000,000`. Completed and active
matching jobs are excluded. For illustration only, the test rate of $30/million
gives $15 for 500,000 new characters. This is not a verified current quote.
Checkpoint reuse can reduce retries; provider retries can add charges. Storage,
Cloud Run, Tasks and network costs are additional. Credits are not assumed to
make generation free, and a whole-book total requires the selected EPUB and an
authoritative price/configuration response.
