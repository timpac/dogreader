# Audio-to-text synchronization

The new **Read from here** action opens the existing reader at the word/paragraph
mapped to the active narration position and highlights that paragraph for three
seconds. It reads the shared handler's actual source and position; it does not
pause, seek, reload or stop audio. Automatic chapter advancement is supported.
Coming from the reader returns to that same reader route and saves reading
progress using its existing callback.

## Accurate timing is required

This client consumes `dogreader-alignment-v1` word maps. It does not present the
old chapter-percentage estimate or Kokoro chunk timing as accurate paragraph
synchronization. Without a valid map it says synchronization is unavailable;
listening and **Listen from this page** continue to work.

The current Google Chirp generation path retains MP3s without word timestamps.
Google's [generic SSML timepoints](https://cloud.google.com/text-to-speech/docs/ssml#ssml_timepoints)
need `<mark>`, which is absent from the current
[Chirp 3 HD supported SSML tags](https://cloud.google.com/text-to-speech/docs/chirp3-hd).
An APK alone cannot align existing recordings. The separate backend change and
an approved, measured alignment rollout are necessary for real books.

## Cache and compatibility

Maps are optional sidecars at `<existing MP3 path>.alignment.json`. Their exact
UTF-8 text SHA-256 and MP3 SHA-256 must match before use. Timestamps are integer
milliseconds; text offsets are UTF-16 code units, matching the reader. The client
rejects unreviewed maps, malformed/non-monotonic intervals, missing text coverage,
coarse timing, split surrogate pairs and mismatched duration.

Downloads attempt a bounded GET of the existing authenticated timing endpoint.
Opening the player also warms the cache; a cached map works without connectivity.
Old downloads can use their retained queue job identity without migrating old
state files. Newly downloaded state adds `jobId`; imported MP3s explicitly clear
it. Replacement/deletion invalidates sidecars. Timing requests never submit TTS
or alignment jobs. Tokens are sent only to the configured HTTPS host with
redirect following disabled.

Reader pagination publishes the destination page before the remainder of the
chapter finishes. Existing saved offsets, publisher styles and scene spacing are
retained. Highlight decoration is excluded from page measurement.

## Current validation and remaining gate

Automated tests use fabricated timestamps, fake playback and local bytes. They
exercise 30-minute positions, offline cache validation, chapter advancement,
playing/paused route changes, highlight expiry, early long-chapter display and
the existing seek/session regressions. They do not establish acoustic accuracy
or 30-minute Pixel background-playback acceptance.

Validation on this candidate: Flutter 3.47.7 analysis passed with no issues and
all 87 Flutter tests passed. The companion backend's full 122-test suite passed
without skips. No APK or container build was run for this preparation.

The approved real-recording pilot is pending an existing chapter MP3 plus its
exact submitted text and recording identity. The environment has repository
access but no recordings or GCP identity. The backend provides a bounded offline
pilot adapter; no actual model alignment or production deployment has occurred.
Complete that pilot and report measured accuracy/runtime/cost before a production
alignment rollout or a claim that real books meet the synchronization objective.
Build 135 remains the known-good release; no replacement APK is implied here.
