# Build 144: reliable download states and recovery

Base: default branch at build 143, `73d5b6b9b19bec6a74b07321572b1fa3daab4600`.
This carries forward the combined build-142 media controls and build-143 delivery
implementation. No backend, Android/native, playback-handler, dependency, signing,
dictionary, article-import or separate development branch changes are required.

The client previously announced Downloading before audio response headers and
recorded an unfinished recording's expected HTTP 404 as Failed. Build 144 checks
status first for pending jobs, retaining the existing backend's recovery of
published audio. A missing legacy status record still permits a quiet audio GET
fallback. Pending audio 404 remains pending; real status/download failures keep
bounded persisted backoff. Known Ready recordings and manual Retry Download use
only audio GET, without resubmitting narration or triggering generation retries.

Generating/Queued shows actual completed/total chunks when already exposed by
the API. Finished narration moves through Waiting to download, Downloading only
after valid audio headers, and Downloaded after atomic publication. Friendly
Failed messages replace raw exception names. Existing app-owned reconciliation
continues outside the queue, at startup/resume and chapter entry; interrupted
transfers retry safely from the same ID. No new background-service architecture
or backend progress changes are introduced.

Build-143 false 404 failures and interrupted Downloading states normalize on
restore. Opening the queue preserves any active transfer. Existing staged-file
transactions, length checks, duplicate suppression, persistent cooldown and
reading/listening-position preservation remain in force. Diagnostics reuse the
bounded asynchronous media journal and existing Share diagnostics: opaque job
IDs, state transitions, chunk counts, HTTP codes and automatic/manual attempts,
with no credentials, titles, URLs or chapter text.

Local verification: clean Flutter analysis and 37 focused tests covering delivery,
file transactions, persistent diagnostics, pronunciation dictionaries and article
narration/import queues. New cases cover repeated generation polls without false
Downloading/Failed, held response headers, legacy 404 fallback, status outage and
restart, real interrupted downloads, active queue reattachment, safe retry modes
and diagnostic redaction. All HTTP/storage tests use local fixtures; no paid TTS.
The canonical Actions release adds its required full regression and original-key
APK/package/version/hash checks before publishing the single build-144 release.

Physical Pixel checks remain outstanding: interrupt a finished download, reopen
with connectivity, verify automatic playback readiness and saved positions, then
check lock-screen/headset controls. A killed process resumes on reopening; no
new Android work scheduler is added. Long-duration media-control acceptance is
separate from these automated delivery checks.
