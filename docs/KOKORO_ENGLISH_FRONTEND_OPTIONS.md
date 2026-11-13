# Offline Kokoro: English frontend decision gate

Date: 13 November 2026. Baseline: build 146, PR #36, commit `7ea52004bbfa193ba0b5eaad6ba25788798bd876`.

## Outcome

**Research only; no frontend selected or runtime changed, no new APK/release.**
The definition of success (paste ordinary novel prose and narrate it without rewriting) is not yet met. I stopped at the task's explicit instruction to report options before substantial native integration or licensing/compatibility work. This PR preserves findings and a proposed 16-case acceptance corpus; it does not present fixture/schema checks as successful frontend tests.

The existing FP32 model, inference, output pipeline, downloads and app functionality remain unchanged. No production Dogreader, cloud, RSS, media-control or reading-progress files changed.

## Confirmed baseline and failure

Owner-reported Pixel 8 Pro results: FP32, Sherpa-ONNX 2.0.1 CPU, 2 threads, 1,000 words / 75 chunks, 276.56 s audio, 409.52 s generation, RTF 1.48, 1.72 s model load, approximately 806 MB peak sampled memory, 24 kHz mono PCM16. The owner reports FP32 quality is suitable for audiobooks. These are owner measurements, not a new device benchmark.

Inspection of `frontend.dart` confirms two separate blockers: the ASCII-oriented whitelist rejects digits, curly quotes, dashes and accents, and the dictionary-only lookup rejects unknown or missing inflected words. Removing validation would expose the native lexicon path's word-skipping behavior. It would not implement reliable English. The worker calls `tts.generate(text: ...)`, so a complete frontend must instead hand validated Kokoro-compatible phonemes/tokens to Sherpa's existing `generateWithConfig` API.

## Options checked

| Option | Compatibility/license findings | Decision |
| --- | --- | --- |
| Original Python Misaki | Apache-2.0, Kokoro's reference English path; spaCy/tokenizer/POS resources and optional OOV fallback. Python/spaCy are not already available inside this Android Flutter app. | Embedding/porting the complete runtime is substantial work. |
| Misakid 0.1.0 | Apache-2.0 Dart port; caller-supplied backends. Published package includes a pure-Dart small-model spaCy adapter, but its English BART fallback is explicitly experimental and not verified against the PeterReid weights. Its existing eSpeak adapter documentation is macOS-oriented, not a ready Android English fallback. | Lexicon/no-fallback mode does not satisfy unfamiliar vocabulary; do not mistake package-level Android labels for a verified complete English configuration. |
| Malsami 0.0.3 | MIT Dart package inspired by Misaki; its own documentation says there is no neural OOV fallback. | Does not close the key gap. |
| phonemize 1.0.0 | Pure-Dart dictionary/rule-based English IPA implementation. Source includes heuristic syllabification and ultimately can return source spelling; it is not a verified Kokoro Misaki frontend. | No validated quality/inventory parity; not selected as a shortcut. |
| FONNX 1.2.0 Misaki components | MIT package, Apache-derived Misaki, MIT spaCy resources, Apache-labelled PeterReid BART fallback. Has Dart English tokenizer/POS, numbers and neural fallback support. **Published bindings require ORT API 31; Android artifact pins select ORT 1.31.1.** The probe's pinned Android ORT is 1.28.2. | Closest Misaki-style candidate, but not a drop-in use of the existing native runtime. Requires a reviewed runtime isolation/migration or adapter plan and omission tests. |
| Phonemis | MIT C++20 normalizer + lexicon/neural G2P; Android static-library build scripts exist. **Its optional English POS tagger has a non-commercial corpus restriction**, explicitly documented upstream. | Requires a new C/FFI or JNI Android bridge and asset packaging. Omit the restricted tagger for a commercial-compatible path, with weaker contextual pronunciation, or replace it with cleared resources. |
| piper_phonemize 1.5.9 / eSpeak-NG | Maintained Flutter/Android package, native bindings and data available. GPL-3.0-or-later. Handles general English pronunciation/normalization rather than dictionary membership alone. | Shortest-looking complete Android route, but distributing the linked experiment introduces GPL/source obligations. A product licensing decision is needed before adopting it. |

### Evidence and sources

Primary sources inspected:
- [Original Misaki](https://github.com/hexgrad/misaki), including its English fallback contract.
- [Misakid](https://pub.dev/packages/misakid) and its [source repository](https://github.com/ProjectKokage/misakid), especially `PORTING_STATUS.md` and `packages/misakid_bart_en/README.md`. The maintainer's BART provenance caution is their support policy; it is not a finding that the upstream Apache-labelled model is unlicensed.
- [Malsami limitations](https://pub.dev/packages/malsami), [phonemize](https://pub.dev/packages/phonemize).
- [FONNX 1.2.0](https://pub.dev/packages/fonnx/versions/1.2.0): `lib/models/kokoro/misaki/`, `lib/onnx/ort.dart`, `lib/onnx/ort_ffi_bindings.dart`, `native_artifacts/upstream_ort.json`, and `tool/kokoro/artifacts.json`. Use the inspected package contents, not older README runtime-version claims.
- [PeterReid fallback model](https://huggingface.co/PeterReid/graphemes_to_phonemes_en_us) is labelled Apache-2.0. Training-data/provenance detail is sparse; this was not independently resolved.
- [Phonemis source](https://github.com/software-mansion-labs/Phonemis/tree/5ec260e33127de044bda7147f52cea27a7e2e491) and [third-party notices](https://github.com/software-mansion-labs/Phonemis/blob/5ec260e33127de044bda7147f52cea27a7e2e491/THIRD_PARTY_NOTICES.md). Its README explicitly warns about the tagger's commercial restriction. The library's MIT badge does not grant a different license to that data.
- [Flutter piper_phonemize](https://pub.dev/packages/piper_phonemize/versions/1.5.9), including GPL-3.0-or-later license. Separate download or dynamic linking does not automatically eliminate distribution obligations.

The four small Dart source archives were downloaded and checked against pub.dev archive hashes before source inspection; no new dependency was added:
- Misakid 0.1.0: `264602d415826626e7b2fc8d1cd34680cfd618e0796b7d8c930227b743f9c83e`
- Malsami 0.0.3: `cba7deba23c2b1b6a5dfcb68309f9f1e55575dd4989158ec1f6767eaadede150`
- phonemize 1.0.0: `793ceb10952d82919002f8599bd6e72781c983cec421c2155283325e7eba93ef`
- FONNX 1.2.0: `41eca06a51d05078d7fa9bcfcdf7782d1ee17ed0fd018db381573d444bfec170`

**Recommended next decision:** evaluate the FONNX Misaki components if retaining permissive licensing and closest reference-English behavior is the priority, with a bounded, explicit ORT coexistence/adapter investigation. Keep the working Sherpa FP32 model unchanged. If avoiding a second ORT binding is more important, a Phonemis frontend-only native adapter is the alternative, subject to the tagger decision. Choose eSpeak only with explicit acceptance of GPL distribution obligations for the standalone experiment. None of these routes has been integrated or tested in this probe.

Do not adopt an entire alternative TTS pipeline merely to obtain its phonemizer: that would confound the validated FP32 baseline and exceed this task's scope.

## Acceptance corpus and no-omission contract

See [english-corpus.json](../experiments/kokoro_probe/research/english-corpus.json). It covers public-domain Austen and Carroll prose; curly quotes/contractions; inflections; unfamiliar names; numbers/currency; dates/times; abbreviations; dialogue/paragraphs; Unicode EPUB typography; future dictionary substitutions and explicit decorative suppression; and safe no-speech/unsupported-input failure.

Each lexical source span needs spoken-text/phoneme coverage, or an explicit suppression reason from a frozen pronunciation-dictionary snapshot. Maintain original UTF-16 -> normalized spoken -> phoneme mappings. Expanding a date is valid; removing its digits without a spoken mapping is not. Reject unresolved words, unmappable phonemes, empty results or failed fallback visibly before successful audio installation. Do not use `unk=''` as permission to discard input. Validate every phoneme against the existing model's inventory and split on linguistic boundaries below its 510-content-token limit.

Text substitutions precede G2P and remain text, not an IPA dictionary. Suppression of decorative characters must be explicit and scoped, not a general punctuation deletion rule. Do not modify the reader's original text. Ambiguous dates need a declared locale policy. Unknown names can receive best-effort G2P, but successful generation is not evidence that their pronunciation is correct.

**Testing status:** corpus structure/category/unique-ID checks ran in the connector orchestration. Corpus acceptance, pronunciation, native compatibility and device tests did not run. The execution environment disconnected during the investigation; the research was preserved through GitHub. Earlier build-146 tests are historical baseline evidence only. No source-level or Android acceptance pass is claimed for a new frontend.

## Performance findings and next experiments

No new Android profile was possible and no 2× improvement is established. Frontend functionality is the first gate, as requested.

1. **Threads 1, 2, 4:** the existing UI already offers all three. Only the owner-supplied 2-thread FP32 result is established here. Once the frontend is fixed, use the identical text, voice, speed, phoneme/chunk policy, brightness, charging state, room/case and initial thermal conditions. Start with one modest passage per thread count; repeat only if results are close or unstable. Export timing, audio length, RTF, PSS, CPU/battery samples and thermal status. Do not infer speedup from audio shortening.
2. **Processing overhead:** the worker currently combines inference, PCM conversion/statistics and WAV writes in generation time. Add separate phase timers before optimizing allocations or synchronous writes. The given output is 6,637,440 samples / 13,274,880 PCM bytes (calculated). This identifies a bounded processing workload, not its measured cost. Reusing a loaded model helps startup, but model loading is already separately timed and only 1.72 s; eliminating it cannot halve 409.52 s generation.
3. **ORT settings:** [Sherpa 2.0.1 session code](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/sherpa-onnx/csrc/session.cc) sets intra- and inter-op thread counts and supports provider config entries including `GraphOptimizationLevel` and profiling. The current CPU configuration does not disable graph optimizations. [ORT's published builds enable them by default](https://onnxruntime.ai/docs/performance/tune-performance/troubleshooting.html); sequential execution and CPU memory reuse are also defaults. There is no evidence of an unenabled optimization switch that will double speed. Verify actual options and operator profiles on Android before changing them.
4. **NNAPI/GPU:** the source has Android/API-dependent NNAPI registration and CPU fallback. Provider availability in the actual prebuilt libraries and on the phone still needs verification; a provider string is not proof of hardware execution. The inspected FP32 graph includes LSTM, Loop/If, sequence operations, ConvTranspose and dynamic shapes. [NNAPI's operator coverage](https://onnxruntime.ai/docs/execution-providers/NNAPI-ExecutionProvider.html) and [ORT mobile guidance](https://onnxruntime.ai/docs/tutorials/mobile/) make partition/copy overhead a real evaluation concern, not proof that acceleration is impossible. No GPU/NNAPI rewrite is justified yet. QNN/Snapdragon-specific claims do not establish Tensor G3 benefit.

A 2× target would require roughly **204.76 s** for the same 276.56 s audio (calculated RTF about 0.74). This is a goal, not an estimate or result. Preserve the exact FP32 graph, speed 1.0 and full text. Correct pronunciation and quality acceptance come before throughput comparisons.

## Device instructions and remaining gate

There is no replacement APK. Keep build 146 and its verified FP32 download. It still has the known dictionary/validation restriction; this PR does not make arbitrary prose work.

Before implementing a new frontend, select the permissive-runtime-adapter, permissive-native, or GPL route above. The subsequent device test should run the corpus with mapping/phoneme diagnostics, listen to names/homographs/numbers/dialogue, verify airplane-mode operation, and only then compare 1/2/4-thread performance. Production integration remains blocked on that frontend decision, corpus acceptance and listening evidence, Android resource/runtime qualification, sustained memory/thermal/battery measurements, and source/normalization mapping compatibility. No PR is merged and no new numbered release is reserved.
