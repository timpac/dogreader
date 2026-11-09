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

Current client validation is clean analysis and all **88 Flutter regressions**
passing. The companion backend now passes **130 tests** without skips. No APK or
container build was needed for source investigation.

The supplied Section 4 MP3 is 12,113.424 seconds (about 3 hours 22 minutes). Its
opening matches a passage within EPUB chapter 6, but the supplied EPUB and original
server text have lexical and structural differences. A generation-pinned,
MP3-digest-matched source export now supplies the exact 201,718-character original
narration text. All 55 chunks / 34,771 source words have been aligned locally
within the approved four-batch budget, with no paid cloud/TTS calls. Saved outputs
were converted into one complete **unreviewed** candidate, including an exact
source paragraph at 30 minutes. The actual Dart parser agrees with six independently
computed full-recording targets; it rejects the saved unreviewed candidate.

These are structural and compatibility checks, not proof of acoustic accuracy or
phone acceptance. A private listening preview now has five 20-second clips around
30, 60, 120, 180 minutes and the end. Chromium checks verified decoding, visible
paragraphs, continuing playback and highlight expiry. Human listening review,
phone text/version identity and immutable checkpoint frame verification remain
before activation. The backend's ALIGNMENT_PILOT_RESULTS.md records the measured
runtime, costs and limits. No production map, backend rollout or APK release has
occurred; build 135 remains unchanged.

This EPUB also exposed empty XHTML `<title/>` elements, which HTML parsing
treated as an unclosed title and swallowed the chapter body. A minimal parser
correction expands that metadata tag before the existing parsing logic. It adds
no text and changes no offsets in already-readable chapters. Extraction now
produces chapter text, and a regression covers the empty-title variants and
preserved styling.

The read-only Cloud Shell utility is mirrored at
`tool/export_alignment_source.py` in this public app repository so the owner
can download it without GitHub authentication. It is byte-for-byte identical to
the backend helper; keep both copies synchronized when updating the export
protocol. It exports only a digest-matched job and optional bounded checkpoint
proofs, never credentials, and performs no cloud writes or inference.
