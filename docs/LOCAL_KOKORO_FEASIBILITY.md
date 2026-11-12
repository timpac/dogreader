# Local Kokoro narration feasibility — 12 November 2026

**Recommendation: proceed with the isolated Pixel experiment; do not yet integrate
into Dogreader.** Free, offline synthesis is technically plausible with an existing
Flutter/Android runtime. General English text processing and sustained phone
performance remain acceptance gates. No cloud deployment or production change.

## Evidence and scope

The task branch starts at the current canonical tip
`30e92ca871bad697b19637488b085a8ecd03f1a3`, not a historical feature branch.
The experiment is `experiments/kokoro_probe`, a separate Flutter project and Android
package `com.dogreader.kokoro_probe`, labelled **Kokoro Offline Probe**. It uses the
existing release signing identity but cannot update the installed Dogreader.
Application `lib/`, Android project, dependencies, tests, cloud calls, playback,
media session, chapter generation and data formats are unchanged.

**Measured/inspected here:** published file metadata; one model archive downloaded
and SHA-256 checked; extracted file sizes; US/UK lexicon coverage. Android inference,
Pixel speed, memory, battery, temperature and listening quality are **not measured**.
APK compilation/static checks are reported separately in the release's `BUILD.txt`.
The prototype must be exercised on the phone before claiming working Android narration.

One short **Linux x86_64 host smoke test**, using the same Sherpa 2.0.1 model,
US lexicon, voice 3 and two threads, produced finite, nonzero 24 kHz audio:
3.318 seconds output, 3.070 seconds model load and 13.406 seconds generation
(RTF 4.04). This validates the selected model/runtime interface only. The managed
host is not a Pixel benchmark, and intelligibility was not assessed by this check.

## Model and runtime choice

[Official Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) is an 82-million-
parameter StyleTTS2/ISTFTNet model. Its Python/PyTorch pipeline is reference material,
not an appropriate Android dependency. v1.0 provides 54 voices across eight language
groups; English has 20 US and eight UK voices. Voice embeddings are separate files,
not voice cloning from a user's recording. Output is 24 kHz mono. Use v1.0 rather
than the older v0.19 checkpoints for this investigation.

[Hugging Face ONNX variants](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/tree/main/onnx)
currently have these measured repository metadata sizes (decimal MB; graph only):

| File | MB | Interpretation |
| --- | ---: | --- |
| `model.onnx` | 325.53 | FP32 reference |
| `model_fp16.onnx` | 163.23 | Smaller weights; CPU operator support/performance must be checked |
| `model_quantized.onnx` | 92.36 | INT8 candidate for a raw ONNX Runtime integration |
| `model_q8f16.onnx` | 86.03 | Mixed precision; not automatically preferable on CPU |
| `model_uint8.onnx` / `model_uint8f16.onnx` | 177.46 / 114.21 | Alternative quantizations |
| `model_q4.onnx` / `model_q4f16.onnx` | 305.22 / 154.59 | Q4 does not imply a fourfold total size reduction |

Voice files, tokens, phonemizer and runtime are additional. The ONNX model expects
phoneme/token IDs, a length-dependent 256-value style vector, and speed; it does
not consume arbitrary prose directly. The context limit is 512 including padding,
or at most 510 content tokens. See the
[export's inference contract](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX#python).
These files are not drop-in replacements for a Sherpa package with model metadata,
`voices.bin`, and `tokens.txt`.

**Preferred runtime:** [Sherpa-ONNX Flutter package 2.0.1](https://pub.dev/packages/sherpa_onnx/versions/2.0.1),
using its Android ARM64 FFI package and native ONNX Runtime CPU backend.
[Pinned Kokoro implementation](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/sherpa-onnx/csrc/offline-tts-kokoro-impl.h)
already handles model invocation, voice selection, chunk synthesis and waveform
delivery. This avoids a custom JNI bridge or Python environment. Established
[Android/Flutter examples](https://github.com/k2-fsa/sherpa-onnx) predate this study.
Only three probe dependencies are added: Sherpa-ONNX 2.0.1, archive 4.0.9 and
crypto 3.0.7, all inside the experiment.

Raw [ONNX Runtime Android](https://onnxruntime.ai/docs/tutorials/mobile/) is the
fallback if frontend customization warrants it, but requires more integration work.
TFLite conversion, PyTorch mobile packaging and WebView/WASM add unnecessary work
for the first feasibility test. CPU is the initial target; no Tensor G3 NPU/GPU
speedup is assumed. ONNX Runtime recommends starting quantized models on CPU;
NNAPI can partition unsupported graphs and make performance worse.

## Selected on-demand package and resource budget

[Download `kokoro-int8-multi-lang-v1_0.tar.bz2`](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2)
from the [Sherpa model release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models).
The mutable release name is protected by an exact hash and per-file hashes in
[`model-manifest.json`](../experiments/kokoro_probe/model-manifest.json).

| Item | Evidence |
| --- | --- |
| Compressed download | **Verified:** 132,353,410 bytes (126.22 MiB) |
| Archive SHA-256 | `72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653` |
| Model graph | **Verified:** 114,202,993 bytes; quantization retains some float operations |
| All voice embeddings | **Verified:** 28,200,960 bytes; package README says 54 voices |
| Selected installed files | **Verified:** 154,740,248 bytes (147.57 MiB), including US/UK lexicons and notices |
| Temporary install space | **Calculated:** roughly 480 MB for archive, temporary tar and selected files; allow **800 MB free** plus APK/OS margin |
| Steady RAM | **Planning estimate only:** budget roughly 0.5–1.5 GB app PSS with INT8, then measure; not a guaranteed minimum or maximum |
| Android support | Runtime Android plugin declares API 21; prototype deliberately requires API 26+, ARM64 only. Physical acceptance, especially 16 KB page mode, remains necessary |
| Pixel 8 Pro | ARM64/Tensor G3 and 12 GB RAM make it a reasonable first target; available app memory, thermals and beta OS behavior still matter |

No API key, paid inference, Google Cloud or network is needed after installation.
The APK contains native runtime libraries but no model. Model installation streams
the download to disk, verifies hashes, unpacks in a worker isolate, and installs
only allowlisted files. A ready marker appears only after verification. A changed
upstream archive fails safely; do not silently accept new bytes. Downloads require
an explicit button press; there are no automatic retries or inference HTTP calls.
Reinstall after an interrupted download; resumable downloads are outside this probe.

The nonquantized Sherpa v1.0 archive is 349,886,476 bytes. INT8 v0.19 is
103,248,205 bytes but uses an older model. Neither is needed for the first experiment.
Do not assume Hugging Face's smaller INT8 export has identical quality or runtime
compatibility to the selected Sherpa graph.

**Speed:** no Pixel RTF is established. At 150–180 spoken words/minute, 1,000 words
would yield about 333–400 seconds of audio and 16–19 MB PCM16 WAV (calculations,
not observations). If RTF were 0.5, generation would take about 3 minutes; at 1,
about 6 minutes; at 2, about 12 minutes. These are scenarios, not performance
predictions. Float32 audio for a whole passage would use twice the PCM16 space;
the prototype writes chunks to disk instead of accumulating the chapter in RAM.

## English frontend and existing dictionary compatibility

The [official Python frontend](https://github.com/hexgrad/misaki) uses Misaki:
English lexicons, linguistic processing and optional eSpeak fallback, with
normalization for numbers and contextual pronunciation. Its Markdown pronunciation
syntax and phoneme inventory are not equivalent to plain text or arbitrary IPA.
The existing cloud pipeline must not be assumed to sound identical locally.

**Version-sensitive finding:** [Sherpa 2.0 removed eSpeak-NG/piper-phonemize](https://github.com/k2-fsa/sherpa-onnx/pull/4055).
`dataDir` is ignored; text uses a lexicon, or callers supply external phonemes or
tokens. The 2.0.1 Kokoro source logs and skips out-of-vocabulary words. Even common
inflections can be missing: our first uncurated 1,000-word draft had 23 distinct
missing words, including `arrived`, `opened`, `questions`, and the name `Clara`.
The supplied passage was adjusted for US lexicon coverage; it is deliberately a
controlled inference fixture. British lexicon coverage differs. No quality result
from this fixture generalizes to an arbitrary EPUB.

The probe preflights every word, rejects unknown words and unsupported phonemes,
and splits below 400 estimated content tokens, leaving padding margin. It rejects
digits, markup, most Unicode punctuation and symbols instead of guessing. It
does not implement full dates, currency, initials, abbreviations, URLs, acronyms,
homographs, possessive/morphological fallback or multilingual text normalization.
Spelled-out English and ordinary contractions present in the lexicon are supported.
Chunk joins/prosody need listening tests. No forced alignment is produced.

Dogreader's existing [`NarrationDictionaryConfig.transform`](../lib/narration_dictionary.dart)
performs literal spoken-text replacements and intentional silence with a frozen
dictionary and UTF-16 original-to-spoken offset map. These replacements can feed
a future local frontend unchanged **as text**; they are not an IPA/ARPAbet lexicon
and should not be loaded as Sherpa phonemes. Preserve global/book precedence,
nonrecursive matching, frozen snapshots, silent-chapter handling and source offsets.
Normalize and phonemize only the transformed spoken copy, with an additional map
if normalization changes offsets. Never rewrite `ReaderChapter.text` or pretend
chunk durations are word timestamps. Local output must have a separate model,
runtime, voice, lexicon/G2P and dictionary identity; cloud MP3 cache IDs cannot
identify these WAVs. All existing behavior is untouched in this experiment.

Before integration, choose a complete offline English frontend: port/package
Misaki-compatible normalization and G2P with validated dependencies, or evaluate a
licensed alternative. Older Sherpa plus eSpeak is technically convenient but
reintroduces GPL obligations; downloading it separately does not automatically
remove obligations for a linked app. Compare US/UK voices on names, irregular
plurals, past tense, homographs (`read`, `lead`, `wind`), dialogue, scene breaks,
numbers/dates, contractions and the existing dictionary's replacement/silence cases.
Zero omitted words is a hard requirement.

## Licensing

Official Kokoro weights/voice package and ONNX export: Apache-2.0. Retain license,
attribution/notices and note conversions/modifications. No paid service or key is
required; Apache permits commercial distribution. Keep upstream training credits
([Koniwa and SIWIS](https://huggingface.co/hexgrad/Kokoro-82M#creative-commons-attribution));
do not infer a separate per-voice permission document that upstream does not publish.

Sherpa 2.0.1 is Apache-2.0; native ONNX Runtime is MIT and carries third-party
notices. Its pinned Android source selects ORT 1.28.2. Unlike 1.x, this runtime
does not bundle eSpeak. The installer also excludes unused eSpeak data present
in the model archive. Flutter/Dart/crypto use BSD licenses and archive uses MIT.
The release includes `LICENSES.txt`, upstream ORT third-party notices and the
resolved prototype lockfile; Flutter dependency notices are also available in-app.
Any future external G2P dependency needs its own license review, including
dictionaries and language models. A permissive acoustic model alone does not
settle the complete product's obligations.

## Pixel 8 Pro test procedure

1. Open the exact numbered **experimental GitHub Release** supplied with this
   report. Under **Assets**, install `Dogreader-<number>-Kokoro-Offline-Probe.apk`.
   It appears as **Kokoro Offline Probe** beside Dogreader. Do not uninstall or
   clear Dogreader. This AOT/release ARM64 build uses the repository's original key.
2. Have at least 800 MB free beyond installation margin. On Wi-Fi, tap **Download
   model** once. Wait for **Model verified**; decompression can take minutes. Then
   enable airplane mode and explicitly disable Wi-Fi. Keep the probe visible.
3. Leave the supplied 1,000 words unchanged. Select **af_heart**, **2 threads**,
   **1 run**, then **Generate offline audio**. Do not play audio during generation.
   A failure is evidence, not a reason to start repeated builds. Record the message.
4. Tap **Play latest WAV**. Listen at the beginning, several middle joins and the
   final sentence, and preferably the entire passage. Check intelligibility,
   missing/repeated words, clipping, long pauses and pronunciation. Tap **Save WAV**
   and **Save measurements** to retain files via Android's document picker.
5. For a repeatable benchmark, use stable brightness (for example 25%), airplane
   mode, the same room temperature and case, battery 40–80%, and an unplugged
   phone. Let it cool to its initial battery temperature and normal thermal status
   between configurations. Note OS/build, page size if known, ambient temperature,
   case, brightness, starting charge, and any concurrent activity.
6. Set **3 runs**, still **2 threads**, and generate once. One engine is loaded:
   run one is engine-cold; runs two/three reuse it. Loading time and frontend time
   are separate fields. The OS file cache is not guaranteed cold, even after
   force-stop. JSON records per-run generation including file writes, audio length,
   first-chunk latency, RTF, hashes and configuration. `RTF = wall seconds / audio
   seconds`; lower is better. First-chunk latency is not streaming playback latency.
7. Only after that succeeds, optionally compare **1** and **4 threads**, same voice,
   passage and three-run procedure. Compare warm-run RTF, not only the first run.
   Do not optimize or try more runtimes before reviewing these basic results.
8. JSON samples process PSS and CPU time about once/second, battery temperature,
   charge counter (µAh), energy counter (nWh), voltage, level, charging state and
   Android thermal status. Peak sampled PSS is a lower bound on the true peak.
   Session CPU time includes all app threads and sampling. Unsupported counters
   appear as null. Battery temperature is **not** SoC/skin temperature; thermal
   statuses 0–6 run from none through shutdown. Stop the experiment if the phone
   reports severe thermal status, discomfort, or an OS warning.
9. For battery, compare start/end energy counters: `mWh = delta nWh / 1e6`.
   If only charge is available, estimate `mWh = delta µAh × mean voltage mV / 1e6`.
   Report the estimate explicitly. Run an equal-duration idle baseline with the
   same screen/settings to account for screen/OS drain. For thermal inspection,
   optional ADB `dumpsys thermalservice` reports available sensors; do not treat
   unavailable sensor readings as zero. A short test or 1% battery gauge change
   cannot establish audiobook battery endurance. Extend sustained testing only
   after the three-run experiment is acceptable.

Suggested gates before authorizing integration: a complete offline passage with
no omissions; acceptable US/UK pronunciation/dictionary behavior; warm RTF at or
below 1 for practical pre-generation (RTF below 0.5 preferred for playback margin);
sampled PSS within a provisional 1.5 GB budget; no sustained severe throttling;
measured energy per audio hour acceptable to the owner. These are proposed product
criteria, not observed results or Android guarantees.

## Build and delivery boundaries

The new reusable `kokoro-prototype.yml` workflow is reached through an explicit
manual dispatch of existing `release-apk.yml` **on this feature branch**, with
the exact full feature-tip SHA, next globally unused build number, and publish
flag. The canonical production job remains restricted to the default branch.
This narrow adapter is necessary because a new workflow existing only on a feature
branch cannot itself be registered for manual dispatch without a default-branch
change. There are no automatic build triggers and no cloud deployment steps.

The workflow generates a standalone Android shell with pinned Flutter 3.47.7,
analyzes only the probe, runs its three frontend tests, builds one ARM64 release
APK, checks package/version/signature and ELF/ZIP 16 KB alignment, and verifies
uploaded bytes after download. It publishes a **prerelease**, never the latest
production release, with APK, `BUILD.txt`, `SHA256SUMS`, lockfile, licenses and this
report. The checked-out source and tag remain on the feature branch. No merge is
authorized. No model is fetched during CI and no emulator/expensive root suite runs.
