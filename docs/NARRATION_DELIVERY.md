# Reliable narration delivery

Source base: Android `eca7c65412c1c174557224b1522b7dbabfa559c7` and backend
`3f38d63d6eaa610b5b06222c5d0a1e402cc13bcb`. Changes are isolated from the
ongoing audio-controls, RSS and alignment branches.

## Findings and pipeline

| Stage | Existing gap | Focused change |
| --- | --- | --- |
| Publish `audio/<id>.mp3` | Worker can die before writing Ready; repeated worker delivery returned early without repairing that state | Existing MP3 verification feeds `completed()`, which repairs state without dispatch/synthesis |
| Ready verification | Missing Kokoro timing could hide valid published audio; job records can disappear independently | Downloadable completion validates the published bytes/digest independently of optional timing; timing endpoint retains its original checks |
| Cloud Run `/dogreader/audio/<id>` | An existing file can still fail validation or storage reads; large legacy streams can fail after headers | Preserve generation-pinned reads, bounded staging and Content-Length; add safe start/completion/interruption logs |
| Android discovery | Polling belonged to the queue widget | App-owned reconciliation starts at library startup/resume and chapter entry/change, and persists after queue navigation |
| Android download | No response/body idle deadlines; server Ready was conflated with local availability | Response/connect deadline 20 seconds, stream idle deadline 30 seconds, additive delivery states |
| Local publication | Temporary bytes existed, but a process death during backup/metadata replacement could split the pair | Flush staged bytes; journal old chapter metadata; commit audio/metadata with an atomic marker; recover or roll back before use |
| Playback readiness | Repair reset listening position and metadata writers could race | Serialize atomic narration JSON updates, preserve the same recording's position, and refresh an open chapter after successful delivery |

The historical production HTTP 500 was not reproduced: current source returns
503 for pre-header storage exceptions, and a failed legacy stream is truncated
after headers. No production logs, storage, credentials or service configuration
were inspected. There is no path mismatch in the inspected current source.

## Client behavior

Queue `status` retains its existing vocabulary and paths. New optional `delivery`,
`failureStage`, attempt/cooldown and error fields distinguish server status from
Downloaded. Old queues and already downloaded audio continue to work. Existing
book/article IDs, frozen dictionary snapshots, seek maps and original signing
identity remain in place. There is no reading-state migration.

Reconciliation first probes the audio URL for an existing ID. A stored MP3 can
therefore be found despite a stale server job status. Only a not-yet-completed
job whose audio returns 404 proceeds to the existing job-status/recovery GET.
A known Ready recording never calls that dispatching endpoint after a download
failure. The previous implicit missing-job text resubmission is removed.

**Retry Download** performs only the existing audio GET. It neither submits text
nor invokes the generation retry endpoint. It is available for linked recordings
without local audio, and as repair for downloaded recordings. Repeated taps,
resume and polling share one in-flight download per chapter.

Failures back off for 15, 30, 60, 120 and 240 seconds. At six failures the client
enters a persistent 15-minute cooldown between probes. Reopening preserves that
cooldown; manual Retry Download may bypass it. Successful generation polling
uses the existing 12-second interval. A stalled recording has bounded waits, so
subsequent chapters can continue. Diagnostics retain 80 safe event lines with
job/chapter identity, stage, error type and HTTP code; no tokens, URLs, request
bodies or raw provider exception messages are logged.

Downloads restart from byte zero after interruption. HTTP ranges are deliberately
not introduced: same-directory `.part` staging, declared length checking and
atomic completion make full retries safe. Partial files never become playback
paths. A `.transaction` journal rolls back uncommitted metadata and bytes;
`.transaction.committed` retains a completed replacement after process death.
The same recording preserves its saved listening position; an explicitly
requested different recording starts at zero. Other chapters and reading state
are retained. Existing audio remains available while replacement bytes arrive.

The app checks while foregrounded/resumed, and in-flight transfers can finish
when backgrounded. A killed process resumes reconciliation on the next opening;
this patch does not introduce a second Android background-service architecture.

## Verification and rollout

Offline regression tests use fake storage/tasks/TTS and local HTTP servers.
They cover final-upload crashes, stale Ready state, missing job/timing metadata,
state-write outages, HTTP 503 recovery, post-header stream failure, truncation,
response/body stalls, duplicate triggers, durable cooldown, restart, safe file
publication/rollback, metadata commit failure, listening-position preservation,
and book/article dictionary/seek-map compatibility. No paid synthesis is used.

Android and backend are separate deployables. The patch has not been deployed
and is not yet installed on a Pixel. Use the existing guarded backend deployment
workflow; do not change IAM, queue or resource policy for this repair. Android
must use the existing manual canonical release workflow after reviewed merge,
with the next unused sequential number checked again against releases/drafts,
tags and the ongoing audio-controls build. Preserve all earlier APKs. The final
delivery link must be a verified numbered GitHub Release with its APK under
Assets. No alternate branch workflow, temporary link or local APK build is used.

Phone acceptance after rollout: interrupt a finished chapter's download, reopen
on a working connection, verify automatic Downloaded/playback, retry an existing
recording, and verify both reading and listening positions. These physical tests
remain separate from the offline evidence.

Local validation record (2026-11-11): the full Flutter suite passed 133 tests;
the final focused delivery/file/queue suite passed 22 tests, including the completed-recording/lifecycle/body-stall safeguards and active-staging ownership case. The final service-only
run passed all 11 tests after explicitly retaining playback availability on a
failed repair. Flutter analysis was clean. Backend full regression passed 121
tests; the final seven completion/HTTP failure tests also passed. These counts
overlap; they are separate runs, not a sum of unique tests. All used local/fake
services. CI image validation and physical-phone rollout are separate gates.
