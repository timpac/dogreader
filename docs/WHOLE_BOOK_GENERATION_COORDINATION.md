# Task 3: whole-book generation coordination

Status: **integration handoff complete; whole-book execution is not integrated
or delivered**. Independent planning, cost calculation and progress projection
are implemented and mock-tested. Shared TTS, queue and backend changes remain
subject to separate approval, as the user explicitly instructed. Stop at this
handoff; do not merge, deploy, build an APK or generate paid narration.

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

## Verified companion branches and exact dependencies

Read-only GitHub review on 2026-11-11 verified these open draft PRs and inspected
their changed-file lists and relevant source. These are snapshots, not assumptions
that the branches have been merged or validated together.

| Task | PR, branch and reviewed SHA | Task 3 integration requirement |
| --- | --- | --- |
| Read/audio synchronization | [#22](https://github.com/timpac/dogreader/pull/22), `feature/audio-to-text-sync`, `a97ed9cc08e735a4dfc7b1f0721f0b0492fb048e` | `NarrationQueueScreen` and `ChapterNarrationScreen` require `SavePosition onSave`. Pass the existing library/chapter callback through all new whole-book routes, including article entry points. Preserve `jobId`, `<MP3>.alignment.json`, GET-only map fetching and replacement/deletion invalidation. |
| Task 1 dictionary | [#23](https://github.com/timpac/dogreader/pull/23), `feature/narration-dictionary`, `cddf1e01370c518b13cf9ab0a08f8e538e200596` | Freeze `narrationDictionary.effective(book.id).toJson()` once when planning. Use `NarrationDictionaryConfig.fromJson(snapshot).transform(chapter)` and retain its exact `text` and `offsets`. Reuse the frozen snapshot for admission, retries and restart; never use later dictionary edits. Preserve `narration_dictionary` and `narration_offsets` through download/regeneration. |
| Task 2 articles and summaries | [#24](https://github.com/timpac/dogreader/pull/24), `feature/article-import-summary`, `46048e5dee8733ba4053434b945e7f51d60135df` | Verified actual branch/PR in GitHub. `openArticle` currently constructs `NarrationQueueScreen(book: book)`; integration with #22 must add `onSave: (chapter, offset) => saveProgress(book.id, chapter, offset)`. Articles and summaries are separate single-chapter library IDs; apply each ID's dictionary scope and never reuse the original's audio/maps for its summary. |
| Sync backend | [dogreader-cloud#7](https://github.com/timpac/dogreader-cloud/pull/7), `feature/audio-text-alignment`, `04fa757dfef195658c20742d4325a0f16f0fd288` | Coordinate `main.py` integration while retaining timing/readiness/storage behavior. Whole-book scheduling adds no alignment inference and never turns an unreviewed map into an accepted one. |

All three client candidates modify `lib/main.dart`; #22/#23 also modify
`reader_content.dart`, and #23 modifies `narration_options.dart` and introduces
dictionary/preview modules. #22 modifies `narration_files.dart`, the audio handler
and dependencies; #24 modifies dependencies and Android Share entry points.
Manual integration must preserve these unrelated hunks. Task 3 changes none of
those shared files and has not copied, merged or cherry-picked any companion work.

### Dictionary, alignment and recording binding

- `WholeBookChapter.text` means **exact frozen spoken text**, after dictionary
  replacement and artifact silence. Eligibility and cost use its Unicode scalar
  count, matching Python `len`, rather than the original reader's UTF-16 length.
  Entirely silent, expanded-over-limit and shortened-under-limit chapters stay
  explicit exclusions. Do not normalize, truncate or silently split EPUB chapters.
- Recording ID remains the backend's canonical hash of configuration and exact
  submitted text, with its existing Google legacy lookup. Do not put local book
  IDs, dictionary revision numbers or chapter indexes into the shared TTS hash.
  Identical spoken text/configuration should still reuse identical audio.
- Bind each local recording to its original-text UTF-8 digest, spoken-text UTF-8
  digest, backend job ID, frozen dictionary and UTF-16 edit map. This provenance
  is needed even if two different source versions yield the same spoken text.
  Retain the old recording's map while replacement is pending or fails.
- #23's `narrationFraction` is approximate, monotonic forward interpolation.
  It is **not** an inverse word map. #22 currently requires exact reader-text
  digest and complete lexical coverage; transformed spoken text can fail that
  validator. Accurate synchronization remains unavailable until a separately
  reviewed adapter validates spoken text/audio and translates word spans to
  original spans, including one-to-many pronunciations and intentional silence.
  Do not weaken digest, review, duration, surrogate or coverage checks.
- Article `ReaderChapter` objects do not currently carry parser-derived
  `narrationSeparators`. Preserve actual reader text/ranges and coordinate that
  metadata with Tasks 1/2; whole-book planning must not invent separator ranges.
- Task 2's proposed `/dogreader/article-summaries/estimate` and
  `/dogreader/article-summaries` routes, existing-token auth and Vertex AI
  configuration are separate approvals. Narration must consume saved original
  or summary text; it must never initiate a summary request, enable Vertex AI,
  reuse a summary request ID as a TTS job ID, or combine the two price estimates.

No other branch was modified. Findings are recorded here for the integration
owner; no messages or comments were sent to other people or PRs.

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

## Smallest proposed backend extension — approval required

These are design requirements for review, **not implemented API contracts**.
Use one small book-manifest/admission module in the existing service and bucket.
Keep `Engine.process`, splitter, chunk paths, synthesis, leases, retry budgets,
job IDs, MP3 paths and download/timing endpoints intact. No second generation
engine, database, service, provider SDK, or Cloud Tasks queue is proposed.

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

### Proposed resource boundary

Names below are a review proposal, not routes the client may assume exist.

| Proposed route | Required behavior |
| --- | --- |
| `POST /dogreader/book-plans` | Create/reuse a non-generating draft using a stable client request ID, book identity and pinned backend-confirmed engine/voice/model/settings. No paid synthesis. |
| `PUT /dogreader/book-plans/<id>/chapters/<index>` | Idempotently stage one exact transformed chapter plus title and source/spoken provenance hashes. Enforce existing per-chapter and request limits. Resolve existing canonical/legacy jobs without creating or retrying generation. Reusing an index with different content conflicts. |
| `GET /dogreader/book-plans/<id>` | Return revision, ordered manifest, resolved recording IDs/status, exclusions and a bound cost quote; no synthesis-budget reset. Quote identifies exact content/configuration/retry set and expiry. Existing Engine status recovery can reconcile admitted jobs only. |
| `POST /dogreader/book-plans/<id>/actions` | `activate`, `pause`, `resume`, `retry_failed` or `cancel_remaining`, with stable operation ID, expected manifest revision and accepted quote/limits when paid work is possible. Persist action result before dispatch so ambiguous responses cannot repeat an activation or retry-budget reset. |

All public routes must reuse `authorized()`/`auth_error()` and
`X-Dogreader-Token`. Do not add provider credentials or queue administration to
the APK. Follow the existing HTTPS host/token boundary and disable redirects for
authenticated downloads. Existing endpoints remain backward compatible.

The existing `main.py` chapter-creation path needs a narrowly extracted shared
helper that preserves validation, configuration, legacy lookup and conditional
job creation. Book admission calls that helper without invoking the existing
POST behavior that automatically resets an error job. Status/reconciliation
never performs an explicit retry. Record retry operation ownership before calling
`Engine.retry`; serialize ambiguous retry recovery so the same operation cannot
reset a newly failed attempt's budget again.

### Admission, concurrency and cancellation semantics

- Default to **one outstanding admitted chapter per book**. Proposed initial
  configurable range: **1–2**, server-clamped; the operator can lower the ceiling
  to one. Count both queued and generating jobs against the limit. Raising a
  limit requires explicit user action; it must not silently override a pause.
- An existing matching chapter job counts toward admission and uses its original
  ID. A job referenced by two plans still has one generation/checkpoint identity;
  completing or stopping one plan cannot delete or cancel another plan's job.
- Cross-book/per-chapter aggregate dispatch remains bounded by the existing
  Cloud Tasks queue configuration. Inspect and approve that setting separately;
  a per-book limit is not a global limit. Do not change queue settings, Run
  concurrency or IAM as part of this client handoff.
- Persist a conditional GCS admission intent before creating/dispatching a
  chapter. Fill slots in reading order; actual completion order can differ at
  concurrency two. Ready/skipped chapters require no new dispatch. A failed
  chapter remains failed and releases its book slot; continue to later eligible
  chapters, and wait for explicit Retry Failed to reset any failure budget.
- After the existing `/internal/process/<job_id>` processing returns, reconcile
  referencing active plans and fill free slots. Make that hook best-effort and
  preserve the worker's original response/retry semantics. Extend the existing
  `recover.py` sweep to repair interrupted admissions and advance manifests.
  A durable active-plan index/references avoids scanning all historical books
  on every completion. No new generation task type is needed.
- The existing recovery runner must be enabled and verified under separate
  operational approval. Completion hooks alone cannot guarantee continuation
  after a crash between publishing the last MP3 and admitting the next chapter.
  Without a working runner, that gap requires a later reconciliation request;
  do not claim reliable app-closed continuation until this is verified.
- **Pause Queue** means stop admitting future chapter jobs. Queued or generating
  chapters already admitted can finish. **Cancel Remaining** means permanently
  exclude unadmitted chapters in this plan. An admission already committed at
  the cancellation boundary may continue and must be reported explicitly.
  Neither operation stops an in-flight paid TTS call, promises a refund, deletes
  audio/checkpoints, purges the shared Cloud Tasks queue or changes other plans.
  Resume is for paused plans; restarting cancelled chapters requires a new
  explicit plan/confirmation. Controls remain unavailable on today's backend.

### Partial progress and download handoff

The server retains staged exact speech text, manifest revision/actions,
admission intents, chapter IDs and states in additive private `book-plans/`
objects. Existing `jobs/`, `state/`, `chunks/`, `audio/` and `verified/` data remain
the generation source of truth. A process restart resumes the same identities
and saved chunks, not current dictionary transformations or fresh paid POSTs.

The client must durably save plan ID/revision, the frozen chapter inputs and
per-recording provenance before activation. Use an additive book-level field or
sidecar only after the shared storage owner approves its schema. Restore all
active plans on application startup/resume, not only when their queue screen is
opened. One serialized, atomic writer must merge existing `dogreader_queue.json`
and `narration_state.json` entries, retaining unrelated fields and books.

Download completed chapters serially while the app is running and network/storage
permit. A failed or interrupted `.part` download remains pending, separate from
generation failure. Re-download through the existing audio endpoint; range resume
is not currently offered. Validate Content-Length and complete audio before
replacement, retain old MP3/map/position on failure, and defer replacement of the
active player source. Preserve `jobId`, `narration_dictionary`, `narration_offsets`
and valid #22 sidecars together. Reset position only for an explicit recording
change, not re-fetching the same recording. Replacement/deletion invalidation and
timing-map caching remain owned by the agreed shared download integration.

### Cost controls, impact and approval decisions

Before activation show total/eligible chapter counts, frozen narrator, original
versus spoken character counts, reusable completed chapter titles/count, existing
active jobs, explicit failures/exclusions and gross TTS estimate with verified
rate/currency. Compute new work from unique recording IDs, not merely chapter
count; two chapters containing identical speech should not double the quote.
The isolated planner's chapter-summed estimate is conservative until that server
deduplication. Credits are not a budget or a guaranteed discount.

Bind activation/retry to an accepted character ceiling and, when a verified rate
is available, accepted gross dollar ceiling. Changed content/configuration or an
expired quote requires a new review. Unknown pricing must say unknown and require
an explicit character-budget confirmation, subject to the operator's policy;
never display it as zero/free. Provider retry costs and ancillary cloud charges
are outside the baseline estimate; preserve existing synthesis/failure budgets.
Exact-once provider billing is not guaranteed during the existing response-to-
checkpoint crash window, even though activation and job identity are deduplicated.

Estimated implementation impact: a new small coordinator module and mock tests;
narrow changes to chapter creation, internal worker completion and the existing
recovery runner; no change to chunking/synthesis or audio-session lifecycle.
Additional storage/operations scale with chapter count: staged speech/provenance,
manifest/index conditional writes, readiness lookups and recovery reads. Retaining
both staged and admitted job text temporarily duplicates that chapter text.
There is no paid TTS in staging/estimation, and coordination creates no additional
paid synthesis for a valid reused recording. Dollar impact for storage, Run,
Tasks and recovery depends on existing configuration and verified rates; no
fixed operational price is claimed. Retention/cleanup is a separate decision;
no existing text, checkpoints or completed audio may be deleted by cancellation.

Outstanding approvals/decisions for the integration owner:

1. Approve the additive book routes, shared chapter helper, completion hook and
   runner extension on a separate backend feature branch; verify recovery-runner
   operation and select the per-book/queue-wide ceilings. None is implemented here.
2. Assign shared `main.dart`, download and storage ownership across #22/#23/#24;
   approve additive book/provenance fields and required callback propagation.
3. Resolve spoken-to-reader word spans/intentional silence with #22/#23, or keep
   accurate synchronization explicitly unavailable for transformed recordings.
4. Supply verified TTS rates and decide unknown-price/maximum-budget policy and
   staged-text retention. Summary API/auth/Vertex approval stays separate.

Recommended integration order: agree shared callback/storage/provenance contracts;
validate #22/#23 mapping behavior and #24 article routing with synthetic inputs;
approve and implement backend book admission; then wire whole-book UI/startup
download reconciliation. These are dependencies, not permission to merge branches.

Submitting every chapter immediately through today's chapter API would let
Cloud Tasks continue after app closure, but cannot enforce a configurable
book concurrency limit or reliable book cancellation. Throttling submissions on
the phone would leave later chapters unsubmitted after app closure. Neither
approach satisfies the complete request without the coordinated backend work.

## Independent planning/progress code and verification

`lib/whole_book_preflight.dart` is a pure, non-mutating planning component. It
does not submit, persist, retry, download or change any shared interface. It
requires backend-resolved expected recording IDs and authoritative server status
to classify completed/active recordings. Unknown identity or metadata is never
treated as proof of reuse. Configuration is snapshotted and compared with stable
JSON key ordering. Unicode counts match Python scalar counts. Input text is the
frozen transformed speech text, not a second dictionary implementation.

`lib/whole_book_progress.dart` projects cloud status and identity-validated local
downloads into pending, queued, generating, ready, downloaded, failed and
ineligible counts. Completed is ready plus downloaded, without double counting;
failed downloads remain ready with a separate error count. Offline validated
audio remains completed, and stale recording IDs/narrators cannot inflate
completion. Projection is immutable and reconstructible from retained inputs;
it does not itself implement persistence, networking, UI or cancellation.

`tool/check_whole_book_preflight.dart` exercises reading order, reuse, active and
explicit-retry classification, changed text/voice/model/settings, missing
metadata, cost exclusion, Unicode, limits/no truncation, immutable snapshots,
duplicate chapter rejection, invalid rates, mixed cloud/download states,
deterministic restart reconstruction, offline/stale audio and transformed-text
eligibility. The Flutter test wrapper includes
these checks in the normal suite once Flutter is available.

Actual local results:

- Dart 3.13.7: **38 checks passed**, no network or synthesis calls in the test.
- Targeted Dart analysis of planning/progress and harness: **no issues found**.
- Files formatted. Formatter warned that the project's Flutter lint include
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
