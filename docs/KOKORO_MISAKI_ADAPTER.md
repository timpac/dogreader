# Experimental Kokoro: frontend-only Misaki adapter

13 November 2026. PR #38, based on PR #37 at `8ab5840d1dd882a3b782316ace72d3e60f7eebcd` and working build 146.

## Result

**The English fallback can share Sherpa's existing ORT 1.28.2. No runtime migration or second ORT is needed.** The probe now offers a Misaki frontend, defaults to FP32, and retains the build-146 lexicon frontend for reference.

All 16 frontend corpus cases passed: 17 executions including both date locales, comprising 15 accepted inputs and two expected explicit errors. Probe analysis, the seven existing safeguards, host native compilation and Android ARM64 native compilation also passed. See [tracked results](KOKORO_MISAKI_ADAPTER_RESULTS.json) and [the successful workflow](https://github.com/timpac/dogreader/actions/runs/43355950797).

**Release target: experimental build 147**, published through GitHub Actions as [v147-kokoro-offline](https://github.com/timpac/dogreader/releases/tag/v147-kokoro-offline) after APK verification. No PR is merged and production/cloud files remain unchanged. Android loading/inference, end-to-end device WAV generation, listening quality and new device resource costs remain unverified by host checks.

## Native compatibility proof

The adapter is more than a Dart wrapper:

1. `native/g2p_bridge.cc` compiles against Microsoft's official **API-28** header, pinned to ORT v1.28.2 commit `33ca9628233dc8f002435e868d4c2e9f82766ca1`. It obtains the official function table using `OrtGetApiBase()->GetApi(28)`. It does not import API-31 bindings or guess table offsets.
2. Android opens exactly `libonnxruntime.so`, already supplied by pinned Sherpa 2.0.1. The bridge does not link, download or bundle another ORT. It rejects a different Android runtime path and owns a separate BART **session** in the shared runtime.
3. A native host test ran the actual 3.10 MB fallback alongside active Sherpa FP32 synthesis. BART produced phonemes for Xylophonia and Quvenzhane; FP32 produced 41,375 finite samples at 24 kHz for “The morning train reached the coast.” The process map contained exactly one ORT library, version 1.28.2. [The measured proof](../experiments/kokoro_probe/research/shared-runtime-host-proof.json) records exact hashes. This is not a phone performance or listening benchmark.
4. CI independently ran real BART inference through the repository's Dart adapter and checked one loaded ORT 1.28.2. Android API-26 ARM64 cross-compilation passed: AArch64, 16 KB ELF load alignment, and no ORT/FONNX/shared-C++ runtime dependency. The bridge uses static C++. Android loading and APK ZIP alignment still require device/build checks.

FONNX 1.2.0's whole-package API-31/bundling conflict remains true. This adapter does not install that package, import its native hook/binding/finalizer, or use its staged Kokoro synthesis engine.

## Reused components and licenses

`tool/prepare_frontend.py` materializes an explicit subset from the [FONNX 1.2.0 archive](https://pub.dev/api/archives/fonnx-1.2.0.tar.gz), SHA-256 `41eca06a51d05078d7fa9bcfcdf7782d1ee17ed0fd018db381573d444bfec170`:

- Misaki English lexicon/morphology and number wording;
- spaCy tokenizer/POS implementation and hash helper;
- fallback vocabulary;
- the maintained diacritic helper for Latin transliteration.

The pronunciation system is reused. Only import paths and provenance comments change in copied sources. Generated upstream sources/headers are ignored in Git and reproducible with the preparation script. There is **no new Dart package dependency or lockfile change**. The small C ABI bridge replaces FONNX's runtime-dependent adapter. Preparation/download of source happens during development/build, never inference.

Preparation preserves full notices in bundled `frontend-notices.txt`, registered with the existing Flutter license page: FONNX MIT, Misaki-derived code/data Apache-2.0, spaCy 3.8.0 MIT with source notices, diacritic BSD-3-Clause, and ORT MIT. See the [exact license audit](KOKORO_FONNX_COMPATIBILITY.md#exact-assets-and-licenses). The pinned PeterReid fallback declares Apache-2.0 but still lacks a standalone LICENSE and detailed training-data provenance; independent production clearance remains unresolved.

The optional frontend download is **22,217,792 bytes (22.22 MB)** including US/GB dictionaries, tokenizer/config, POS weights and BART graph/vocabulary. All eight files passed size/hash verification against [the manifest](../experiments/kokoro_probe/english-frontend-manifest.json). No model/data binary enters Git or the APK. Installation verifies staging before READY; generation rechecks files. Only explicit Download actions use the network.

## Normalization and omission protection

The frontend retains original UTF-16 provenance while handling book quotes/apostrophes, dash pauses, ellipses, nonbreaking spaces, ligatures, common Latin accents, combining accents and soft hyphens. Horizontal whitespace is canonicalized; line wraps become spaces; paragraphs are phonemized separately and force chunk boundaries.

The small normalization layer uses FONNX's number-wording functions for integers, decimals, percentages, ordinals, common currencies, clock times, named dates and slash dates. US voices use month/day/year; the British voice uses day/month/year. Dates/times are validated. Titles, time abbreviations and common metric units have explicit expansions. `St.` defaults to **Saint**, not contextual Street disambiguation. Not all written forms are supported.

Before synthesis the adapter verifies:

- complete lexical source coverage, including normalization/substitution mappings;
- nonempty speech phonemes for every lexical token, with no unresolved marker;
- membership of every phoneme in the unchanged model inventory;
- chunks of at most 400 codepoints, below the model's 510-content-token limit;
- supported fallback input and natural decoder termination without unknown output.

BART's initial BOS framing is accepted; UNK/PAD, later BOS, excessive word length and decoding exhaustion fail explicitly. EOS is never forced to conceal truncation. Unsupported non-English content/symbols/expressions cause visible errors. Punctuation-only text causes a no-speech error. Preparation finishes before a new WAV opens, preserving the previous successful recording on frontend failure.

Frozen dictionary snapshots support text substitutions before G2P and explicitly scoped decorative suppression. These are tested adapter APIs, not production dictionary integration. Paired emphasis retains its words; multiplication retains its meaning. There is no blanket symbol stripping.

Measurement JSON exposes normalized text, edit reasons, source/token/phoneme spans, chunks, fallback use, locale and ORT version. Coverage is not proof of correct pronunciation.

## Preserved FP32 synthesis and audio

FP32 remains `model.onnx`, SHA-256 `b40f62b166ac8164b0627ef48a0b358eda0985e272fb03ef5252e7206305da11`. Model/voice manifests, runtime/dependency versions, speed 1.0, CPU selector, PCM conversion, WAV encoding, playback/export and 24 kHz mono output remain unchanged. No gain, filter, resampler or quantization substitution was added.

The new input path uses Sherpa's existing `generateWithConfig` with validated phoneme codepoints, bypassing incomplete native lexicon lookup. Reference mode uses its original text path. BART closes before Kokoro loads. `frontendMs` includes verification/loading/preparation once per session, separate from TTS model loading and generation/WAV writes; repeated runs reuse prepared phonemes.

The owner-reported RTF 1.48 / roughly 806 MB build-146 baseline is historical, not a measurement of this adapter. New Android RAM, speed, battery and heat costs are unknown. File size is not a RAM estimate; parsed dictionaries/POS state and diagnostics add memory. No speedup is claimed.

## Targeted results

Tested code commit: `ec6c9b5271598b7d1b1edbef0f7f90f5c6b8f69f`. Subsequent documentation does not change that code.

| Corpus coverage | Observed frontend outcome |
| --- | --- |
| Austen and Carroll paragraphs | Accepted with lexical coverage |
| Curly quotes, contractions, inflections | Accepted |
| Names and unfamiliar vocabulary | Accepted; best effort, not pronunciation approval |
| Numbers, money, percentages, units | Accepted with spoken expansions |
| Named date/time and slash dates | Accepted; both locale expectations passed |
| Abbreviations, paragraphs, dialogue | Accepted |
| EPUB Unicode typography | Accepted with normalization mappings |
| Dictionary substitution and decorative suppression | Accepted |
| Inline emphasis and multiplication | Words/meaning retained |
| Punctuation-only | Expected visible no-speech error |
| Non-English inside English prose | Expected visible unsupported-input error |

Additional guards passed for invalid dates, malformed currency, emoji, unknown inventory, overlong/non-English fallback input and closed sessions. Seven existing probe tests passed, covering PCM rounding/clipping/nonfinite values, WAV fields, sample-preserving joins, legacy validation/chunking and the 1,000-word fixture. Probe analysis found no issues; the lockfile stayed unchanged.

The managed environment disconnected after the initial native proof. Remaining checks ran in GitHub Actions without Gradle/APK compilation. Early targeted failures identified missing transitive official headers, initial BOS framing, validation of the vowel `ɐ` and whitespace passed to fallback. The successful run covers the corrected code. No broad production suite ran.

Full token/normalization diagnostics and source receipts are retained for 14 days in the workflow's `kokoro-frontend-checks` artifact. The committed summary preserves outcomes and exact source/run links.

## FP32 synthesis acceptance before the APK build

The corpus was rerun locally with the actual native API-28 fallback. Its 15 accepted executions (the ambiguous date is checked twice) were then passed to Sherpa 2.0.1 using `GenerationConfig.phoneme_codepoints`, the same native phoneme-input facility used by the probe. The exact FP32 graph, voices and token inventory hashes were verified first. This closes the earlier gap between frontend-only acceptance and actual engine acceptance.

**All 23 phoneme chunks produced finite, nonempty, non-silent audio**, totaling 74.58 seconds on the Linux host. Each WAV's frame count, 24 kHz rate, mono channel count and PCM16 encoding were read back and checked. The two expected error cases made no synthesis call. [Detailed results](KOKORO_MISAKI_SYNTHESIS_RESULTS.json) retain normalized text, supplied phonemes, frame counts, PCM level checks and WAV hashes; `tool/check_synthesis.py` reproduces the check with an already-installed FP32 model, without downloading or modifying it.

Source-to-phoneme coverage and accepted phonemes are automated evidence against silent frontend omission. They do not prove pronunciation correctness or that a listener hears every intended word. This is not an Android speed, memory, battery or heat measurement. Audio acceptance did not require changing the frontend, Sherpa runtime, FP32 graph or audio conversion pipeline.

## Pixel instructions for experimental build 147

Open the release page and tap **Dogreader-147-Kokoro-Offline-Probe.apk** under **Assets** after the workflow publishes it. Build 146 remains an unchanged reference release. The update has the same probe package and signing certificate; it installs separately from production Dogreader.

1. Install the future probe update in place. Do not uninstall or clear storage. Existing models and separate production Dogreader remain intact.
2. Select **FP32**, **Misaki English**, **af_heart**, **2 threads**, **1 run**. Retain the existing FP32 download; download **English frontend** once (22.2 MB).
3. Enable airplane mode with Wi-Fi off. Paste a normal novel paragraph or an Austen/Carroll [corpus fixture](../experiments/kokoro_probe/research/english-corpus.json).
4. Generate, then use **Play FP32**, **Save FP32 WAV** and **Save FP32 measurements**. Inspect `frontendDiagnostics` for transformations/fallbacks/coverage and runtime **1.28.2**.
5. Try contractions, names, numbers and dialogue. Listen for pronunciation, rhythm, joins and retained FP32 quality. Name pronunciation requires review.
6. Try punctuation-only input and a sentence containing `你好`. Expect a visible error, no new successful WAV, and the previous recording still playable.
7. For reference, select **Build 146 lexicon** with its supported short passage. Keep text/voice/speed/thread count identical for timing comparisons; export each recording before replacing that model variant's latest result.

Production integration still needs Android linker/packaging verification, sustained listening, measured resource costs, broader English normalization/pronunciation review, fallback provenance review and real pronunciation-dictionary/source-mapping integration. None is represented as complete here.
