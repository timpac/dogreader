# Build-135 dictionary and article integration

This draft integrates application code, without an APK, deployment or paid API
request. The base is canonical `dogreader-oct22-update` at
`c3cc7bd2e9dadfc1c38019baf16a0a2c28fad4f4`, retaining build 135
`cdf4227dc6a966b20e24f61179ac953b22689024`.

## Sources and decisions

| Source | Included behavior |
| --- | --- |
| Dictionary #23, `90971cb90eae7bafcf870992f092d99a2d2c5d55` | Scoped rules, previews, frozen queue snapshots and recording-specific UTF-16 edit maps. |
| Articles #24, `3495b56864cf12091eaa097130793cfd181804c8` | Local URL/Android Share import, immutable offline text, existing reader/narration routes and disabled summary client/proposal. |
| Planning #25, `bad6908495c94f5247841993d4b6f56e44a85dcb` | Pure preflight/progress helpers and their harness only; no application route imports these helpers. |
| Synchronization #22, `a97ed9cc08e735a4dfc7b1f0721f0b0492fb048e` | Reviewed, deferred. No source from this PR is ported. Its callback signature is already supplied by #24. |

Integration order was dictionary, article adapters/callbacks, then isolated
planning helpers. There is one narration queue and one existing audio handler.
The original feature PRs remain unchanged.

## Shared Android boundaries

Articles construct `ReaderChapter` directly. Their saved blocks retain exact
two-newline joins, headings, Unicode, IDs and UTF-8 hashes. Only conservative
whole-block ornament ranges are added using `isDecorativeNarrationSeparator`.
These ranges use half-open UTF-16 offsets and do not alter persisted text.
Original articles and cached summaries retain separate dictionary, progress and
audio scopes. Summarization receives readable source text before speech rules.

The shared queue freezes `narration_dictionary` when work is explicitly queued;
reloads and missing-job retries use the saved matching version and rules.
Legacy jobs without a dictionary keep untransformed text. `narration_offsets`
belong to the installed recording, not current preferences. Audio and metadata
replacement retains #23's handled-failure rollback; failed regeneration leaves
old audio and its map usable. This is not a journal across abrupt termination.
Existing imported MP3s retain baseline seeking; importing replacement audio
clears stale dictionary metadata. Reading callbacks are forwarded through every
article, chapter, queue and player route; listening alone never infers reader
progress.

Build 135's audio handler, session configuration, package identity, signing
configuration, release workflow, storage paths and dependency versions are
unchanged. Android changes are #24's text/plain Share intent and platform
channel on the existing `AudioServiceActivity`, retaining superclass lifecycle
calls. `crypto` was already locked transitively; #24 declares that same version
as a direct dependency for text integrity. No new package version is introduced.

## Synchronization boundary

Existing reader-to-audio seeking remains build 135's approximate duration
fraction, translated through the actual recording's frozen UTF-16 edit map.
No word-level or reverse synchronization is claimed.

#22 requires reviewed word timing with exact reader-text/audio digests. A map
for changed speech cannot satisfy that reader-text contract. Reverse navigation
is unnecessary for the dictionary/article integration, so its loader, routes,
parser changes and sidecar mutations are deferred together. Existing sidecars
are untouched. Future integration must validate exact spoken text and audio,
bind original/spoken UTF-8 digests and job identity to the frozen edit map, and
compose timing into reader UTF-16 spans, including intentional silence and
one-to-many/many-to-one replacements. Keep #22's fail-closed checks and
transactional sidecar invalidation; never bypass them to enable a route.

## Backend work and approval boundaries

Dictionary transformation and article narration use the existing chapter-job
API. They need no new server routes. Actual production engine pronunciation and
Pixel Share/background playback acceptance remain separate from mock tests.

AI summary generation remains disabled by
`DOGREADER_ENABLE_ARTICLE_SUMMARIES=false`; cached summaries remain usable.
`backend_proposal/` is proposal code in this app repository, not a backend
installation. Before enabling it, separately coordinate these changes in the
existing Flask service:

1. Register authenticated POST `/dogreader/article-summaries/estimate`
   (`text`, `depth`) and `/dogreader/article-summaries`
   (`text`, `depth`, UTF-8 SHA-256 `contentHash`). Reuse `X-Dogreader-Token`, ADC,
   bucket and existing authorization helpers. Retain durable conditional GCS
   claims under `article-summaries/`, with operator handling for interrupted
   attempts rather than automatic paid retries.
2. Verify the proposal's `gemini-3.1-flash-lite` candidate and GenerateContent v1
   `thinkingConfig.thinkingLevel: MINIMAL` against the approved project. The
   proposal rejects its retired `gemini-2.5-flash-lite` target. Require explicit
   `global|us|eu` location, never inherit the TTS region. Documentation/mock
   compatibility in #24 does not establish live access, quality or latency.
3. Verify Vertex API/model access and minimum runtime permissions:
   `aiplatform.endpoints.predict` plus existing summary-prefix
   `storage.objects.get/create/delete`. No provider key in the APK, new service,
   Tasks queue or administrator grant is required by this proposal.
4. Only under separate rollout authorization set
   `DOGREADER_SUMMARIES_ENABLED=1`,
   `DOGREADER_SUMMARY_MODEL=gemini-3.1-flash-lite` and
   `DOGREADER_SUMMARY_REGION=global|us|eu`. Verify pricing variables
   `DOGREADER_SUMMARY_INPUT_USD_PER_MILLION` and
   `DOGREADER_SUMMARY_OUTPUT_USD_PER_MILLION`, or leave costs unknown. Allow at
   least 120 seconds server/process headroom for 8/75-second provider limits
   and the client's 100-second deadline, then measure overhead.
5. Run companion authentication/API, claim/recovery and #7 timing/readiness
   regressions, and separately authorized live quality/cost checks before
   deployment and eventual client-flag enablement. See
   [the complete article contract](ARTICLE_IMPORT.md).

Whole-book generation remains partial and inactive. The pure helpers require
already-frozen speech and externally verified recording identities/pricing;
they neither obtain these values nor submit, persist or download work. They
cannot be wired directly to current queue flags as proof of reusable audio.
Remaining work includes authoritative plan/identity/price lookup, confirmation
UI, durable manifests and restart recovery, idempotent admission around existing
chapter jobs, worker/recovery reconciliation, concurrency policy, downloads,
progress UI and pause/resume/retry/cancel semantics. The proposed book-plan,
staging and action endpoints are unapproved design work, not deployed or
finalized interfaces. Preserve independent chapter audio and mappings; do not
introduce a second narrator. See [the planning handoff](WHOLE_BOOK_GENERATION_COORDINATION.md).

Merging, APK release, cloud/IAM/API/billing changes, deployment, paid acceptance
and summary enablement require separate authorization. This integration does
none of them.

## Verification

Flutter 3.47.9 / Dart 3.13.7 with enforced locked dependencies:

- 90 distinct focused Flutter tests passed across affected batches, including
  the four combined article/dictionary/queue cases and the planner harness
  (38 internal checks). Only affected failures were rerun.
- Repository-wide Flutter analysis and final shared-harness analysis are clean.
- 14 backend-proposal unit tests passed with memory storage and fake generation.
- `git diff --check` passed. Protected-file comparisons confirm the build-135
  audio handler, seek helper, signing/build configuration, resources, assets and
  release workflow are unchanged. Android changes are limited to Share intake.

Initial integration-test failures were confined to test fixtures/callback types
and initializing the application's final handler twice in one test isolate.
Separate isolate wrappers now share the same regression body without changing
the production handler. No unresolved playback or data-compatibility failure
was observed in these focused checks.

 Focused regressions cover real saved-article adapters, Unicode/UTF-16 and
scope identity, frozen queue reload, recording rollback/seek metadata,
disabled-summary network guards, planner identity and build-135 media-session
behavior. No emulator, APK or live inference test is part of these checks.
