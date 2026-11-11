# Narration dictionary

This feature starts from the canonical default branch's build-135 application
source (`cdf4227dc6a966b20e24f61179ac953b22689024`), retaining the later
documentation and manual-only release safeguards. No dependency, backend,
Android/signing, playback-handler or chapter-file-path changes.

## Extraction and transformation

Build 135's EPUB extraction normalizes whitespace and stores UTF-16 style and
reading offsets in `ReaderChapter.text`. It already detects empty structural
scene breaks from `hr`, EPUB semantics and publisher CSS. Text ornaments remain
in that text. New optional `narrationSeparators` ranges identify whole extracted
blocks containing `***`, spaced stars, `⁂`, fleuron/star ornaments or repeated
bullets/middle dots. Additional symbol-only ornaments qualify when EPUB
class/type/role explicitly marks a scene break, separator or ornament. A single
ordinary star, multiplication, inline starred/emphasized prose and prose inside
a semantic separator are preserved. No blanket asterisk deletion occurs.

`NarrationDictionaryConfig.transform` runs only when building the outbound job
text or a preview. It leaves the original text, styles, page starts, saved reading
positions and chapter indexes untouched. Literal rules are case-sensitive and
matched at Unicode letter/number word edges; longer overlapping originals win.
Replacement text is not matched again. Silence rules emit no replacement.
Built-in separator silence is controlled by the global toggle independently of
custom rules. An entirely silent chapter reports an error without submitting a
TTS job or replacing an old recording.

The client previously submitted `chapter.text` directly. The backend's existing
Google splitter normalizes paragraph/sentence whitespace; Kokoro retains source
slices and applies its phonemizer. Neither backend requires a new dictionary
API. The existing job API accepts transformed text and includes that exact text
in recording/cache identity. Backend source was inspected read-only; its current
production engine availability was not probed or changed.

## Alignment and immutable recording settings

Build 135's Listen from this page estimates audio position as the reader's
UTF-16 character fraction multiplied by audio duration. It has no word-level
alignment. Applying replacements directly to reader text would invalidate saved
positions; applying replacements to job text alone would skew that fraction.

Each explicit generation/regeneration freezes the effective dictionary under
`narration_dictionary` in its existing queue entry. Initial submission and
missing-job resubmission use the same snapshot even after edits/restart. Legacy
pending jobs without this field keep their original untransformed text.

Transformation produces a sparse UTF-16 edit map: original start/end, spoken
start/end, source length and spoken length. The map is retained in the queue
and copied under `narration_offsets` to the existing audio-state entry only
when the new recording is successfully downloaded. Reader navigation converts
its original fraction through that recording's map before the existing seek
operation. Deleted spans collapse to one position; replacement spans interpolate
monotonically. This corrects character-length drift, while retaining the existing
approximate timing model. It does not claim acoustic/word synchronization.

Legacy/imported audio without a map uses the original fraction. Importing a new
MP3 clears any old dictionary map. While regeneration is pending or fails, the
old audio's state/map is retained. Editing the dictionary never queues work,
changes audio bytes, unloads a decoder or rewrites reading/audio state. The
existing staged-download/validation/decoder-release replacement remains intact.

## Storage, preview and compatibility

Rules use `narration_dictionary.json` in application documents, following
`ThemePreferences`' serialized temporary-file/rename storage pattern. Book scope
uses the existing persisted book ID, so rules survive reopening the EPUB and
app restart. No database or dependency is added. Missing/corrupt preferences
fall back to an empty dictionary with common separator silence enabled; write
failures are shown in the editor. Per-book rules override the same original
text in global rules, including disabled entries. Deleting a book override
restores its global rule.

Settings and book narration share the editor. A draft can be previewed before
saving; a plain-text sample can preview combined effective rules. The existing
short-job/temporary-audio path and audio handler's preview restoration are reused.
Requests are capped at 300 characters, use the selected engine/voice and reject
mismatched server attribution. Cancelling prevents late results from playing.
No chapter queue entry is created for a preview.

The optional queue/audio-state fields are additive. Existing recordings, voices,
job IDs, audio paths, position fields and old JSON readers remain compatible.
The separate open audio-to-text synchronization PR must compose any future
spoken-text timing map with this original-to-spoken edit map; do not treat
transformed offsets as EPUB offsets or reuse timestamps from another recording.

### Coordination with Read from here (PR #22)

The current [synchronization candidate](https://github.com/timpac/dogreader/pull/22)
validates word maps against the displayed chapter's exact text digest and requires
coverage of every lexical source span. A recording generated from transformed
text has a different text digest when a pronunciation or silence rule changes
its text. Its spoken-text alignment therefore cannot be passed directly to that
validator. It must continue to report synchronization unavailable until the two
coordinate spaces are supported; do not relax digest or review checks to make a
map appear compatible.

A future integration must bind the frozen original-to-spoken edit map to the
exact original text, submitted text and recording/job identity, validate timing
against the spoken text/audio, then translate timed word spans back to original
reader spans. Pronunciations can change one word into several or several into
one. Silence removes source spans entirely, so the current complete lexical
coverage requirement needs an explicit representation for intentional silence.
The fractional interpolation in this PR is only for the existing approximate
reader-to-audio seek; it is not an inverse word map and supplies no timestamps
for silenced text or paragraph-highlight accuracy.

Both candidates touch `lib/main.dart`, `lib/reader_content.dart` and README.
When combining them, preserve the sync candidate's `jobId`, optional sidecar
validation/invalidation and reader-save callbacks alongside this PR's frozen
dictionary/offset fields. Keep each map with its actual MP3 through regeneration,
failure, recovery, deletion and import; never apply current dictionary settings
to an older recording. Neither branch has been merged with the other or tested
as a combined implementation. Compatibility work remains a separate merge gate.

## Verification

Focused tests cover exact reader text/styles, structural and inline punctuation,
rule precedence and literal matching, restart/rapid saves/save failures, frozen
jobs and retries, UTF-16 mapping, editor CRUD/unsaved preview, fake-server short
preview requests, audio replacement metadata and reader seek integration.
Existing EPUB extraction, reader pagination, narration options/download/seek,
preview restoration and media-session lifecycle regressions are also checked.
No full chapter was synthesized, no TTS service was contacted and no APK was
built or released. Actual engine pronunciation and sustained Android playback
still need device/listening acceptance in an authorized future build.

## Final integration handoff

The dictionary is ready as a component for coordinated integration. This is not
approval to merge a combined client: #22/#24 are still separate, unmerged
candidates, and no mixed-branch runtime or device acceptance is claimed.

### Review fixes and compatibility

New snapshots use matching `version: 2`, treating astral letters and combining
marks as word characters without changing UTF-16 coordinate units. Unversioned
snapshots read as version 1 and keep the original matching behavior on retry;
regeneration opts into version 2. Unknown versions are rejected rather than
silently reinterpreted. Preview truncation also respects surrogate pairs.

Audio installation now retains the prior MP3 until its dictionary/offset metadata
has been atomically written through a temporary state file. A handled metadata
write failure rolls back the MP3 replacement; a failed first download is removed.
The optional `replaceNarrationFile.afterReplace` hook is the metadata commit
boundary. This handles reported I/O failures, not a journaled transaction across
both files during abrupt process/device termination. #22 must retain its sidecar
invalidation around this boundary and keep failed replacement metadata unchanged.

### Article import (PR #24)

Reviewed `feature/article-import-summary` at
`46048e5dee8733ba4053434b945e7f51d60135df`. Required integration changes:

1. Keep `ImportedArticle.chapter`'s exact saved block text and two-newline joins.
   Do not run it through the EPUB parser, which applies different whitespace and
   indentation rules. During its existing block loop, classify each whole block
   with exported `isDecorativeNarrationSeparator(block.text)` and append a
   `StyledRange(start, start + block.text.length)` to `narrationSeparators` when
   true. Pass those ranges into `ReaderChapter`; preserve existing heading ranges.
   Only pass `semantic: true` when retained import metadata proves a separator.
   Existing saved articles with no semantic metadata use the conservative common
   ornament whitelist; ambiguous punctuation remains audible or uses an explicit
   user silence rule. The direct-chapter adapter is exercised with synthetic text.
2. Retain #23's shared `NarrationQueueScreen` submission path for both articles
   and summaries: freeze dictionary version/rules, derive `narration_offsets`,
   preserve these fields on save/download/retry. Add article/summary IDs to the
   dictionary selector's book list. Global rules apply to both; an original's
   per-book rule does not silently propagate to its separately identified summary.
3. Summarization consumes immutable readable article text before dictionary
   transformations. A summary has its own immutable text, book ID, reading/audio
   state and maps. Never reuse an original's audio or offsets for a summary.
4. With #22, thread `onSave: (chapter, offset) => saveProgress(book.id, chapter,
   offset)` through the article's queue/player navigation; those parameters are
   required in that branch. Combine library loading for EPUBs/articles without
   rewriting their persisted text. Resolve shared `lib/main.dart`/README edits
   against the canonical branch; preserve its manual-only release workflow.

### Synchronization and eventual whole-book narration

The #22 contract reviewed is `a97ed9cc08e735a4dfc7b1f0721f0b0492fb048e`.
Its spoken-to-reader composition, explicit silent-span coverage, exact original
and spoken text digests, reviewed word timing, and audio/job binding remain the
integration requirements described above. Dart reader/edit offsets are UTF-16;
text digests are over exact UTF-8. Backend code-point/byte indexes must be
converted explicitly. Keep each recording's saved matching version, not the
latest dictionary, and preserve the empty-XHTML-title parser correction from #22.
Do not weaken validation to enable synchronization on transformed text.

The existing Entire book selector already calls the same `generate` loop for
individual chapter jobs; there is no separate dictionary policy per selection.
The focused multi-chapter check verifies one frozen book configuration and
independent chapter-local maps, including scene separators. A future whole-book
planner must freeze dictionary/voice/settings and source identity once before
estimation/approval, then reuse them for every chapter and retry. Estimate the
transformed narration input. Keep original chapter indexes, even for an entirely
silent chapter (currently reported as an error without TTS); an eventual planner
must represent deliberate omission explicitly. If chapters are concatenated,
store original/spoken UTF-16 chapter bases including exact boundary text and an
audio timeline per chapter, while retaining chapter-local maps. Do not use summed
spoken lengths as saved reading offsets or use a chapter fraction as whole-book
audio time. No whole-book planner, concatenation, new queue or backend was added.

### Verification scope

Reused the earlier 53 passing focused tests for unchanged UI, seek and transport
behavior. New/changed checks reproduced the review failures before the fixes,
then verified Unicode boundaries, legacy snapshot retry semantics, preview
truncation, metadata-failure rollback, per-chapter consistency and the article
block adapter. The 27 distinct focused tests across the six affected test files passed,
with clean analysis of changed code. Only affected test files were run for this
review; no full-suite repetition, synthesis, APK build, deployment or merge.
Actual engine pronunciation and sustained physical-device playback remain
acceptance work. Other agents' branches were inspected read-only.
