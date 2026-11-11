# Article import and summaries

Feature branch: `feature/article-import-summary`, starting at the requested Build
135 commit `cdf4227dc6a966b20e24f61179ac953b22689024`.

## Status and coordination

The Android/Flutter client implements URL import, Share receipt, extraction,
offline persistence, summary-depth selection, usage review, summary caching, and
reader/narration entry points. AI generation requires the coordinated backend
extension described below. It is not available on the existing server merely by
installing the client.

Before edits, likely conflicts were reported in the task conversation:

| File/interface | Task 2 changes | Coordination boundary |
| --- | --- | --- |
| `lib/main.dart` library state/loading/import buttons | Small integration hunks calling new article modules | Merge with other tasks' library/reader UI changes manually |
| `ImportedBook`, `ReaderChapter`, reading callbacks | Reused unchanged | No schema or callback change required |
| `lib/reader_content.dart` | No changes | Existing reader styling/parsing remains owned by reader work |
| Android manifest and `MainActivity.kt` | SEND text/plain filter and separate `dogreader/article_share` channel | Keep AudioServiceActivity inheritance, super calls and media lifecycle |
| Narration queue, TTS handlers, audio filenames, job API | No interface changes | Existing text submission handles both article versions |
| Cloud settings file | Read host/token only | Never write settings or change its schema |
| Backend `main.py` | Proposed registration patch only, not applied | Backend owner must review the additive endpoints on a separate companion branch |

Tasks 1 and 3 branches/owners were requested but were unavailable during this
implementation. No shared TTS, queue, or backend contract was independently
changed. Use a separate `feature/article-import-summary` branch in
`timpac/dogreader-cloud` for coordinated backend work. Do not merge or deploy it
as part of another task implicitly.

## Using the client

Choose **Import a web article** in the library, paste a public HTTP(S) URL, and
choose **Read original** or **AI summary**. Chrome's Android Share menu also
offers Dogreader and pre-fills the URL. Sharing does not silently fetch a page or
start paid work: tap **Import article**. Cold and warm intents use the same path.

Imports run sequentially; additional URLs can be submitted while one is running.
The existing queue is specific to narration, so it remains unchanged. Article
import ordering uses a separate lightweight in-memory worker. Saved content
survives restart; unfinished import jobs must be submitted again after process
termination.

Tap a saved article for its author, source URL, publication date (when supplied),
reading and narration controls. The original is retained when a summary is
requested or fails. The three slider positions select Brief, Standard or
Detailed. **Review AI usage** obtains an estimate without invoking the AI
provider. **Generate** submits the selected depth. Saved summaries can be read
and narrated offline without another summary request. Narration retains its
existing cloud settings and charging behavior.

## Extraction and local data

Extraction runs locally with the already-installed HTML parser. It scores main
article containers and preserves text paragraphs, list items and heading ranges;
it discards navigation, sidebars, scripts, forms, ads, cookie/consent elements,
related links and common clutter. It does not execute JavaScript, send browser
cookies, authenticate, or attempt to unlock paywalls. This is a bounded heuristic,
not a universal website extractor. Some public pages need browser rendering or
use unsupported layouts; Dogreader reports that limitation rather than saving
the whole page as an article.

HTTP errors, access gates, non-HTML responses, invalid TLS, unsupported encodings,
timeouts, excessive redirects, oversized pages and insufficient article text have
clear failure messages. Fetches allow at most five redirects, 2 MiB of decompressed
HTML and 30 seconds. The reader/narration text limit is 250,000 characters.
Public HTTP(S) URLs only; private/local destinations are rejected at validation
and DNS checks. No article-site request receives the Dogreader cloud token.

`<documents>/articles/*.json` stores versioned metadata and text blocks with atomic
temporary-file replacement. EPUBs and existing persisted formats are untouched.
IDs use canonical/normalized URL hashes. Known tracking parameters/fragments are
removed; meaningful query parameters are retained. Repeated canonical URLs reuse
the original. Summary IDs include original identity, depth and output digest,
keeping audio and progress distinct from the original. Originals are immutable;
there is no implicit article refresh that could invalidate saved narration.

## Backend integration proposal — not activated

`backend_proposal/article_summaries.py`, its tests, and `register.patch` are a
reviewable extension for the **existing** Cloud Run service, not a new service.
The shared backend entry point has not been modified. After coordination:

1. Copy the module and tests into the companion feature branch and review/apply
   `register.patch` against the current `main.py`.
2. Run the companion API regression suite, including auth for both routes. The
   module takes the existing `authorized`, `auth_error`, bucket, project and region.
3. Review the configured model, pricing, Vertex AI availability, Cloud Run timeout
   and Vertex AI permissions for the existing runtime service account. Enabling an
   API, changing IAM/billing or deploying requires separate explicit approval.
4. Only after that approval, deploy a new revision of the existing service. Keep
   summaries disabled until configuration and permissions are verified.

Proposed authenticated routes:

| Route | Request | Response |
| --- | --- | --- |
| `POST /dogreader/article-summaries/estimate` | `text`, `depth` | Approximate token counts, output cap, nullable `estimatedCostUsd` |
| `POST /dogreader/article-summaries` | `text`, `depth`, SHA-256 `contentHash` | `summary`, durable `id`, `usage` with nullable `costUsd` |

The inspected backend has Google TTS/Kokoro but no general text-generation
provider. The proposal uses Vertex AI through its existing Google authentication
dependencies and Cloud Run service identity. There is no provider key in the APK,
new key file, or additional backend service. No dependency changes are needed for
the proposal; the existing backend includes google-auth and its requests transport.

Configuration, all server-side:

- `DOGREADER_SUMMARIES_ENABLED=1` (otherwise disabled).
- `DOGREADER_SUMMARY_MODEL=gemini-2.5-flash-lite` (restricted allowlist).
- Optional `DOGREADER_SUMMARY_REGION`; defaults to the service region.
- Optional `DOGREADER_SUMMARY_INPUT_USD_PER_MILLION` and
  `DOGREADER_SUMMARY_OUTPUT_USD_PER_MILLION`, using operator-verified current
  regional/provider rates. No price is invented when these are absent.

Estimates use an explicitly approximate characters/3 input count plus the selected
output-token cap. They exclude hosting/storage/taxes and are not guaranteed bills.
Known usage uses provider token counts and configured prices. Only text is sent
to the model; no browsing, retrieval, tools, or outside context are enabled. The
prompt preserves central argument, qualifications, attribution and uncertainty,
and rejects instructions embedded in source text. Output must finish normally;
blocked, truncated, short or oversized output is not saved as a ready summary.
Factual quality still needs a small approved model evaluation; prompts and mocks
cannot prove accuracy.

GCS conditional creation claims each content/depth/model/prompt identity once.
Concurrent requests reuse ready output or report processing. A timeout or
interrupted paid request is **never automatically regenerated**, including after
a server restart. Failed or stuck claims require operator review; there is no
expiry that silently risks another charge. This intentionally trades automatic
recovery for charge deduplication. Claims/results live under the existing bucket's
`article-summaries/` prefix and contain private article-derived text; review the
existing bucket's access and retention when enabling the feature.

## Validation and remaining gates

Use the feature tests with `flutter test --no-pub test/article_import_test.dart
test/article_summary_test.dart` and the backend proposal's stdlib tests with
`python -m unittest discover -s backend_proposal -v`. Tests use small fictional
articles and mocked provider/HTTP responses, with no paid AI requests.

Two downloaded small public pages were successfully extracted locally: HTTPBin's
Moby-Dick HTML fixture (3,566 characters) and PEP 20 (1,375 characters). The helper
`tools/article_extract_smoke.dart` can repeat extraction on downloaded HTML.
A one-article network smoke check also used the actual `ArticleFetcher` for PEP
20, then saved and reloaded its exact text/identity. Only the temporary test
adapter selected the managed environment's proxy; production fetch code was used
unchanged.

Recorded checks: Flutter 3.47.7 / Dart 3.13.5 locked dependency resolution and
clean static analysis; all 93 tests in the full Flutter suite passed. After the
final idle-UI Share frame fix, its additional focused navigation test passed.
All 11 backend proposal tests passed, Python compilation succeeded, and the
registration patch applies cleanly to the inspected backend source. No live
provider or backend endpoint was invoked.

Real Pixel/Chrome Share delivery, native compilation, actual provider summary
quality/usage, and real cloud narration of imported versions remain acceptance
gates. No APK build/publication, backend deployment, paid model request, IAM
change, or expensive end-to-end test is authorized by this implementation.
