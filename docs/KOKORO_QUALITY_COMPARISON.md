# Kokoro INT8 / FP32 quality comparison

## Finding and scope

Quantization is a plausible cause of the reported muffling/hiss, **not yet a
confirmed cause**. The probe's WAV conversion has no identified rate, channel,
endianness or resampling defect. This change adds an optional matching FP32 model
so the owner can compare the same passage and settings without changing the audio
pipeline. No denoiser, EQ, gain adjustment, smoothing or other audio processing
has been added to mask the symptom.

This focused branch is based on PR #35 (`dc29054`); the canonical development tip
is still `30e92ca`. Production Dogreader, cloud narration, media controls, RSS,
reading progress and other PRs are untouched. The APK updates **Kokoro Offline
Probe** in place with the same package and signing identity, preserving its INT8
download and existing files. Neither model is bundled in the APK or committed to Git.

**Owner-reported Pixel 8 Pro build-145 baseline:** 1,000 words, 276 seconds audio,
402 seconds generation, RTF 1.46, two CPU threads, approximately 658 MB peak sampled
memory, no severe thermal pressure. The hiss persists across two voices and both
Bluetooth and phone speakers. These are owner observations; no raw recording or
benchmark JSON from that test was supplied for independent analysis.

## Audio-path audit

- Sherpa returns one mono waveform. The worker requires **24,000 Hz**, nonempty,
  finite samples. No sample-rate conversion occurs in Dart. The WAV declares one
  channel, PCM format 1, 16 bits/sample, 2 bytes/frame and 48,000 bytes/second.
- Float samples use build 145's exact conversion:
  `round(clamp(sample, -1, 1) * 32767)`, signed little-endian PCM16. Negative full
  scale is -32767 rather than -32768; that conventional symmetric mapping is not
  a rate/pitch error. The maximum unclipped rounding error is `0.5 / 32767`.
  RIFF and data lengths are finalized after writing all frames.
- Chunks are appended directly to a single WAV, without extra headers, padding,
  crossfades, normalization or intentional pauses. Native synthesis may itself
  include silence. Hard joins can cause local clicks; they do not by themselves
  explain a continuous hiss within speech. The splitter and voice/speed settings
  are unchanged so this comparison does not confound precision with chunking.
- Playback uses the existing experimental `MediaPlayer` with a local WAV file.
  No app-level effects or resampling are configured. Android/Bluetooth may convert
  sample rates downstream; exporting and playing the same WAV in another player
  helps distinguish a generated artifact from playback/route processing.
- New JSON fields record raw peak/RMS/mean amplitude, samples outside full scale,
  samples at full scale, exact frames, and each chunk's first/last PCM value and
  join step. The PCM formula is unchanged; extracting it into a small pure Dart
  helper permits targeted byte/header tests. Measurement adds some conversion
  overhead equally to both variants, so build 146 timings are best compared with
  each other rather than treated as an exact repeat of build 145.

One upstream issue concerns quantized STFT convolutions producing NaNs. Build
145's graph hash already matches the **fixed** graph documented in
[Sherpa PR #4087](https://github.com/k2-fsa/sherpa-onnx/pull/4087); inspection confirms
both STFT nodes remain ordinary Conv nodes. The reported hiss cannot simply be
attributed to that older bug. Finite output also does not prove clean output.

## Compatible higher-precision model

Use Sherpa's existing **FP32 Kokoro v1.0** package:
[download archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2),
[model documentation](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html).
It derives from [official Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M).
Its package LICENSE is byte-identical to the INT8 Apache-2.0 license. Existing
Sherpa/ONNX Runtime and voice/dictionary licensing requirements remain unchanged;
the installer continues to exclude unused eSpeak data.

**Verified archive SHA-256:**
`60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4`.

**Verified FP32 graph SHA-256:**
`b40f62b166ac8164b0627ef48a0b358eda0985e272fb03ef5252e7206305da11`.

[`fp32-model-manifest.json`](../experiments/kokoro_probe/fp32-model-manifest.json)
pins the archive and every installed file. The graph's 443 initializers are FLOAT;
the INT8 graph contains quantized integer initializers. Both graphs expose the
same `tokens`, `style`, `speed` inputs and `audio` plus shape outputs. Native Sherpa
2.0.1 CPU inference succeeded with each graph on the host. Voices, tokens, US/UK
lexicons, README and LICENSE are byte-identical between the packages. The existing
runtime, dependencies, frontend, speaker IDs and speed 1.0 are reused.

FP32 was chosen over the
[Hugging Face FP16 export](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/tree/main/onnx)
because this FP32 package already has Sherpa's required metadata/voice format and
works without conversion. FP16 CPU operator support and a different export would
introduce extra compatibility work. No new exporter or inference runtime is needed.

## Storage and performance

| Resource | Existing INT8 | Optional FP32 |
| --- | ---: | ---: |
| Verified archive download | 132,353,410 bytes | 349,886,476 bytes |
| Verified graph | 114,202,993 bytes | 325,560,556 bytes |
| Verified installed selected files | 154,740,248 bytes | 366,097,811 bytes |
| Free-space allowance during install | 800 MB | 1.5 GB |

Both installed packages together occupy **520,838,059 bytes** (decimal 520.84 MB),
plus APK and WAV files. Duplicate support files are intentionally retained to
avoid restructuring the working INT8 installation. Archive + temporary tar + new
selected FP32 files require about 1.12 GB transient space; the 1.5 GB allowance is
a conservative installation budget. Download failures leave the other variant intact.

**Measured on a Linux x86_64 managed host, not Android:** one 13-word sentence,
Heart, speed 1.0, two threads, one fresh process per model, identical runtime and
support files. This is a compatibility/audio-path smoke test, not a robust speed
benchmark or a listening evaluation.

| Host observation | INT8 | FP32 |
| --- | ---: | ---: |
| Model load | 2.476 s | 2.117 s |
| Generation | 4.758 s | 2.022 s |
| Audio duration | 3.318 s | 3.348 s |
| RTF | 1.434 | 0.604 |
| Process maximum RSS | 421,444 KiB | 618,152 KiB |
| Raw peak amplitude | 0.3764 | 0.4438 |
| Raw RMS amplitude | 0.06268 | 0.06493 |
| Clipped / full-scale samples | 0 / 0 | 0 / 0 |

Both WAVs read back as exact mono PCM16 at 24 kHz; maximum float-to-PCM roundtrip
error was below half a PCM16 step. These samples do not show clipping. That does
not establish that the owner's longer recording was unclipped, or that either
sample lacks hiss. The outputs are not sample-aligned/duration-identical, so a
simple waveform subtraction would not diagnose quantization noise reliably.

**Android FP32 RAM, generation time, energy, temperature and quality improvement
remain unmeasured.** The FP32 graph adds 211.36 MB of weights on disk; a weights-only
budget would add roughly that amount to the reported 658 MB Pixel baseline, but
native allocations and optimized graphs may differ. Budget approximately 1–1.5 GB
as a planning allowance, not a measured requirement or guaranteed ceiling.
Higher precision is not necessarily slower on CPU: quantized kernels and dynamic
quantization overhead matter, as the short host example illustrates. Battery use
may rise or fall with CPU time and memory traffic; do not scale the host RTF to the
Pixel or invent an energy figure. Use the phone's measured counters and thermal
status, with the same screen/volume/room conditions and cooling between trials.

## Exact Pixel 8 Pro comparison

1. Open the numbered experimental GitHub Release and tap its APK under **Assets**.
   Install as an update to **Kokoro Offline Probe**. Do not uninstall it, clear its
   data, or change the production Dogreader installation. Build 145's INT8 cache
   is recognized automatically.
2. On Wi-Fi, select **FP32 · optional comparison** and tap **Download FP32 model**.
   Have 1.5 GB free; wait for verification/decompression to finish. INT8 remains
   installed in its original directory. Then enable airplane mode and turn Wi-Fi off.
3. Tap **Load short comparison passage** (49 words). Select **af_heart**, **2
   threads**, **1 run**. Speed remains fixed at 1.0. Keep these settings and the
   text unchanged throughout the pair; keep the screen open during generation.
4. Select **INT8** and **Generate INT8 offline audio**. Then select **FP32** and
   generate again. Switching the model does not replace the text or voice. Each
   operation loads only one model; two engines are not intentionally resident.
5. Confirm **Comparison controls match**. This checks exact text, voice, threads,
   speed/runtime and the chunk list. A mismatch message means regenerate the pair
   with matching controls. Different output durations alone are not a mismatch.
6. Use the separate **Play INT8 / Play FP32** buttons at the same hardware volume,
   on the same route. Listen for sustained high-frequency buzz, muffling, sibilants,
   silence/noise between words, and local chunk clicks. Do not play during synthesis.
   Reverse the listening order to reduce expectation bias. Repeat with Michael
   only if useful, keeping each pair's voice fixed.
7. Tap **Save INT8 WAV**, **Save FP32 WAV** and each variant's **Save measurements**.
   Export names include `int8` or `fp32`, session timestamp and run. JSON records
   variant, graph/archive hashes, text/settings/chunk hashes, audio statistics,
   generation/load times, PSS, CPU/battery samples and thermal status. Buttons retain
   the latest recording per variant for this app session; export before closing.
   Old files are not deleted, but the UI does not restore recording history on restart.
8. Listen to the exported originals in another player if both have the same hiss.
   If the hiss is in both exported WAVs, playback route alone is less likely. If
   FP32 improves consistently, quantization becomes a stronger explanation; repeat
   a short pair before committing to its larger download. If both sound similar,
   investigate shared model/vocoder/export/frontend effects next rather than adding
   a filter or assuming a precision upgrade fixes it.
9. For performance, let the phone cool, stay unplugged at fixed brightness and
   room/case conditions, and run each variant separately. The existing **3 runs**
   option distinguishes the first engine-cold run from later engine-warm runs.
   Use one thread count initially. Only after the short comparison is worthwhile,
   use **Load 1,000 words** with both variants. Record RTF, audio length, sampled peak
   PSS, charge/energy deltas and thermal status. A single short run or battery-percent
   reading is insufficient for energy/endurance conclusions. Battery temperature
   is not CPU temperature; PSS sampled each second can miss a true peak.
   For independent memory comparisons, export first and force-stop/reopen the
   probe between model sessions: native allocators/file caches can retain memory
   after an engine is freed. Do not compare an INT8 fresh-process peak with an
   FP32-after-INT8 peak as though process history were identical.

## Unresolved

- The exact origin of the owner's hiss and any FP32 listening improvement.
- FP32 behavior, speed, RAM and energy on the actual Pixel; no new phone benchmark
  is claimed here. Both models are graph-compatible on the host, but phone acceptance
  remains part of this experiment.
- Long-form clipping and chunk-join behavior: new measurements expose these without
  changing the signal. No alignment/crossfade/DSP experiment is mixed into this one.
- Existing lexicon/normalization restrictions and current-session-only output history
  remain. This is still an experimental probe, not production narration integration.
