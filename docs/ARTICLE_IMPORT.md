# Article import integration handoff

Branch: `feature/article-import-summary`, descended from accepted Build 135
`cdf4227dc6a966b20e24f61179ac953b22689024`. [Draft PR #24](https://github.com/timpac/dogreader/pull/24)
records the current head and checks. No other feature branch or backend repository
is modified. Build 135's audio-session lifecycle, signing/package identity,
EPUB storage, library ordering and saved-position formats remain intact.

## Ready client functionality

Pasted URLs and Android Share prefill enter the same `ArticleLibrary.enqueue`
pipeline. Sharing alone never fetches or generates paid work. The serial worker
deduplicates normalized URLs, and final canonical identity deduplicates aliases.
An extraction/save failure reports an error without stopping subsequent imports.
Saved originals and summaries restore from local storage. Unfinished import jobs
are in memory and must be resubmitted after process termination.

Extraction uses the existing HTML parser locally: main paragraphs/headings,
optional author/date, title and source URL. It removes common navigation, ads,
cookie notices and unrelated containers. It does not execute JavaScript,
authenticate, use browser cookies or unlock paywalls. Unsupported layouts,
gates, non-HTML/encoding errors, network failures and size/time limits are reported.
Limits: five redirects, 2 MiB HTML, 30 seconds, 250,000 readable-text UTF-16 units.

Original/summary narration uses the established library, job API and queue.
Each is a separate one-chapter `ImportedBook`; no whole-book planner is added.

## Exact text, identity and storage contract

Whitespace is resolved once during HTML extraction. The saved readable text,
not raw HTML or a later extraction, is the source of all subsequent coordinates.
Blocks are immutable; their joiner is exactly two newlines. `text` and
`chapter.text` are identical, including Unicode, empty blocks and spacing.
`blockOffsets` are half-open UTF-16 ranges, matching Dart reader offsets;
hashes use UTF-8 bytes. Summary responses are saved without trimming or
paragraph rewriting and never replace the original.

New article JSON adds `textSha256`, `textLengthUtf16` and, for summaries,
`originalContentHash`. Version-1 files without these fields still restore
without rewriting. Integrity mismatches are rejected; a damaged article does
not hide the remaining library. Saving an existing ID cannot overwrite its text
or metadata. Existing EPUBs/positions/queue formats are not migrated.

Original IDs are `article_` plus SHA-256 of canonical/normalized source URL.
Summary IDs include original ID, depth and output digest. Local data lives at
`<documents>/articles/<id>.json`; audio remains
`<documents>/narration/<bookId>_0.mp3`. Progress and queue keys use the separate
book IDs, so original and summary cannot reuse each other's positions/audio.
Summary caching checks source identity; old summaries remain readable offline.

The existing TTS recording ID remains the first 32 hex characters of SHA-256
over canonical engine/voice/model/settings JSON, one newline, and exact submitted
TTS text, with existing legacy reuse. Summary request IDs are separate full
SHA-256 values over prompt version, summary model, depth and readable source text.

## Interfaces for the other tasks

- Both `NarrationQueueScreen` and `ChapterNarrationScreen` now require
  `SavePosition onSave`, matching synchronization PR #22. Every local route
  supplies/forwards it. Library routes use
  `(chapter, offset) => saveProgress(book.id, chapter, offset)`; reader routes
  forward `widget.onSave`. Merely listening does not update reader positions.
  The callback is carried for #22's explicit reader navigation action.
- Pronunciation dictionary Task 1: `feature/narration-dictionary`, reviewed
  commit `93aaa69`. Its agent/integrator must retain required callbacks and
  freeze `narration_dictionary` plus `narration_offsets` per new recording.
  Apply pronunciation/silence only to submitted TTS text, never stored article
  text or summarizer input. Per-book rules see distinct original/summary IDs.
  Articles directly construct `ReaderChapter`; Task 1 must accept/default
  `narrationSeparators` and agree how article separators acquire UTF-16 metadata.
  No dictionary implementation or persisted dictionary schema is copied here.
- Entire-audiobook Task 3: independent whole-book preflight planner; branch/owner
  unreported. It must pass `onSave` when opening narration routes, treat each
  article version as one chapter, and keep summary charges separate from TTS
  estimates. This branch does not change its planner or queue contract.
- Synchronization client #22 / backend #7 remain separate, unmerged work. Keep
  exact text/audio digests, reviewed maps and `<MP3>.alignment.json` invalidation.
  When dictionary text differs, compose the recording's frozen spoken-to-reader
  UTF-16 map; never weaken alignment validation or reuse original maps for summaries.
- Remaining overlap is `lib/main.dart` imports/settings/library/narration hunks,
  Task 1's reader metadata, and eventual backend `main.py` registration. These
  branches have not been merged or tested together. This branch refreshes its
  README from canonical baseline documentation without changing default history.

## Disabled summary feature

Production client requests are gated by the compile-time flag
`DOGREADER_ENABLE_ARTICLE_SUMMARIES`, default **false**. The API client checks
before reading settings or creating HTTP requests; UI generation is unavailable.
Saved summaries still read/narrate offline. No alternate provider, model, paid
fallback or runtime settings toggle exists. Tests opt in only with mocked HTTP.
Do not enable the client flag until authenticated backend acceptance and explicit
rollout approval. No APK is built here.

## Backend proposal and verified provider contract

Only `backend_proposal/` in this app branch contains server code. It must be
reviewed/copied/registered on a separately coordinated companion branch; nothing
is installed in the live service. Reuse existing Flask auth, ADC, bucket and
Google dependencies; no new service or Cloud Tasks queue.

Authenticated with existing `X-Dogreader-Token`:

| POST route | Input | Output |
| --- | --- | --- |
| `/dogreader/article-summaries/estimate` | `text`, `depth` | approximate input tokens, output cap, nullable `estimatedCostUsd`; no provider call |
| `/dogreader/article-summaries` | `text`, `depth`, client-supplied UTF-8 SHA-256 `contentHash` | `status`, `id`, exact `summary`, token `usage` and nullable `costUsd` |

Depths: brief/standard/detailed, output caps 512/1024/2048 tokens.
Input: 200–250,000 characters. Output: normal STOP, 100–50,000 characters and
no longer than source. Errors: invalid input 400; auth 401; disabled/provider
failure 503; processing/previously interrupted identity 409; invalid output 422.
A durable GCS conditional claim under `article-summaries/<id>.json` prevents
duplicate paid work. Stuck/failed claims require operator review; no automatic
paid retry, expiry, continuation or new-provider fallback.

Documentation checked **2026-11-11**, without inference requests:

- The old `gemini-2.5-flash-lite` target is retired as of October 20, 2026;
  it is now rejected. [Google model lifecycle](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/2-5-flash-lite).
- Proposed candidate: exact GA ID `gemini-3.1-flash-lite`. Its documentation
  supports GenerateContent, system instructions and `MINIMAL` thinking level;
  listed locations are `global`, `us`, `eu`. The proposal requires an explicit
  `DOGREADER_SUMMARY_REGION` in that set, rather than inheriting `us-central1`
  from TTS. No region/model substitution occurs.
  [Model and availability](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-1-flash-lite).
- ADC REST uses `https://aiplatform.googleapis.com/v1/projects/PROJECT/locations/global/publishers/google/models/gemini-3.1-flash-lite:generateContent`
  (location host for approved multi-region). Payload uses `systemInstruction`,
  `contents`, `generationConfig.maxOutputTokens`, and
  `thinkingConfig.thinkingLevel: MINIMAL`, not the retired model's
  `thinkingBudget: 0`. Thought parts are excluded from readable output but counted
  in known usage; text parts are concatenated without inserted characters.
  No tools/browsing/grounding are enabled.
  [API contract](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference).
  Project access, endpoint behavior, factual quality and latency still need
  separately approved backend acceptance; documentation/mocks are not live proof.

Before deployment, the backend owner must:

1. Integrate/register the proposal with existing `authorized`, `auth_error`,
   bucket, project and region interfaces. Run real companion auth/API regressions,
   including #7 timing/readiness behavior; preserve all existing TTS routes/jobs.
2. Verify enabled Vertex AI API, model availability and billing in the approved
   project. Minimum inference permission: `aiplatform.endpoints.predict`;
   `roles/aiplatform.user` is a broader alternative, not a required admin grant.
   Existing runtime ADC is used; no provider key in APK.
   [Inference IAM](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/access-control).
   GCS needs `storage.objects.get`, `storage.objects.create` and
   `storage.objects.delete` for generation-conditional content replacement,
   scoped to the existing summary prefix where practical; no listing is used.
   [Storage permissions](https://cloud.google.com/storage/docs/access-control/iam-permissions).
3. Explicitly configure server `DOGREADER_SUMMARIES_ENABLED=1`,
   `DOGREADER_SUMMARY_MODEL=gemini-3.1-flash-lite` and
   `DOGREADER_SUMMARY_REGION=global|us|eu`. Both feature flags remain off otherwise.
4. Review timeout headroom: provider connection/read limits are 8/75 seconds;
   client overall deadline is 100 seconds. Allow at least 120 seconds in Cloud Run
   and process/worker configuration, then measure ADC, storage and cold-start
   overhead. Requests read timeouts are not hard wall-clock deadlines; a client
   timeout may leave a processing claim, which must be checked rather than rerun.
5. Set verified `DOGREADER_SUMMARY_INPUT_USD_PER_MILLION` and
   `DOGREADER_SUMMARY_OUTPUT_USD_PER_MILLION` or show unknown cost. Current published
   standard global text rates for the candidate are $0.25 input / $1.50 output
   per million tokens; non-global rates $0.275 / $1.65.
   With 5,000 billable input tokens, illustrative costs at 512/1024/2048 billable
   output tokens are $0.002018 / $0.002786 / $0.004322. Include reasoning in output
   billing. Character-based estimates are approximate, not spend guarantees;
   hosting/storage/taxes are extra. No rates are silently hardcoded at runtime.
   [Google pricing](https://cloud.google.com/model-garden/pricing).
6. Review private bucket retention/access and stuck-claim operations; obtain
   explicit authorization for any IAM/API/billing changes, paid quality test,
   deployment, and later client flag enablement. None is performed here.

## Focused validation

Tests cover Share/paste pipeline deduplication, extraction errors, sequential
imports, exact Unicode/UTF-16 preservation, legacy restore, immutable saved
versions, disabled UI/API with zero HTTP clients, mocked summary usage and
caching, and reader position/reflow. Backend proposal tests use only memory
stores/fake generation. This integration pass passed 20 focused Flutter cases
(19 initial cases plus the added Share/paste entry case), 14 backend proposal
tests, and clean static analysis. Earlier broad regression
evidence is retained; no emulator, APK, production backend, IAM or paid API work
is part of this integration pass.
