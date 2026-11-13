# FONNX Misaki compatibility gate

13 November 2026. Working baseline: experimental build 146, `7ea52004bbfa193ba0b5eaad6ba25788798bd876`, Sherpa-ONNX 2.0.1. Follow-up to [frontend options](KOKORO_ENGLISH_FRONTEND_OPTIONS.md), on the same research PR #37.

## Decision

**Do not add the published FONNX package to this probe as a drop-in frontend. Stop before implementation or an APK build.** Its current native binding cannot use the existing ORT library, and its build hook bundles another runtime. A supported external-runtime mode was not found in the inspected package/hook. Making them share one runtime requires a maintained adapter/fork or a runtime migration and regression qualification.

This does **not** mean Misaki phonemes or the fallback ONNX graph inherently require a new synthesis runtime. The conflict is in FONNX's binding and packaging. A frontend-only adapter could preserve Sherpa and the exact FP32 graph, but it is a separate integration task, not one dependency addition. No frontend has been implemented or declared ready. The 16-case acceptance corpus has **not** been executed against a new frontend.

No app source, dependency manifest/lockfile, model manifest, workflow, production file or audio path changed. No APK/release, merge, cloud action or new Android benchmark occurred. Build 146 remains the working device build, including its existing ordinary-prose limitations.

## Compatibility evidence

The evidence below comes from published source archives, actual Sherpa native libraries, a small Linux C API availability check and a graph-format check. It is not an Android loader/build test.

| Component | Inspected result | Consequence |
| --- | --- | --- |
| `sherpa_onnx_android_arm64` 2.0.1 | Its `libonnxruntime.so` contains version `1.28.2`. ELF SONAME is `libonnxruntime.so`; `libsherpa-onnx-c-api.so` has a `DT_NEEDED` entry for that name. | Sherpa already ships and loads ORT. Dart's Sherpa API does not expose arbitrary ORT sessions for the BART graph. |
| FONNX **1.2.0**, immutable pub.dev archive | Generated `ORT_API_VERSION = 31`. `createOrtSession` calls `GetApi(31)` and throws if it returns null. Android ARM64 pins select ORT **1.31.1**, bundled as `libonnxruntime.so`, plus `libfonnx_ort_session_finalizer.so`. | FONNX's normal build supplies a second ORT artifact. It cannot simply point its current binding at Sherpa's ORT. |
| Host availability check | Actual ORT **1.28.2** from the Sherpa 2.0.1 Linux wheel: `GetApi(27)` and `GetApi(28)` succeed; `GetApi(31)` returns null with the runtime's unsupported-version diagnostic. No session or inference was run. | Direct reuse fails at API negotiation, before model loading. Host result corroborates the Android binary version; it is not execution of the Android binary. |
| FONNX diagnostic override | `fonnxOrtDylibPathOverride` changes library lookup only. It still requests API 31. Its comment explicitly reserves it for diagnostic hosts. | It neither fixes the API mismatch nor disables the native build hook. |
| FONNX/Kiln native assets | `hook/build.dart` invokes Kiln on native builds. Kiln 1.0.0 publishes each `delivery: bundle` file as `DynamicLoadingBundled`. Native build choices cover prebuilt/source, not a consumer-supplied shared ORT mode. FONNX session finalization also references its native helper. | Importing the neural fallback reaches the native binding. Discarding ORT with a packaging `pickFirst` is not a validated sharing solution. |
| Android/toolchain | FONNX ARM64 artifacts declare minimum API 24; the probe uses 26. FONNX requires Dart >=3.10; the probe requires >=3.13.5. | These version floors are compatible. The blocker is runtime ownership/API, not the Android minimum. |
| Neural fallback format | Verified 3,101,005-byte ONNX export: IR 8, opset 17, inputs `input_ids`, `decoder_input_ids`, output `logits`, 342 nodes. ONNX 1.19.1 checker passed. | No format-level need for ORT 1.31 is established. Actual fallback execution through ORT 1.28 and Android remains untested. |

Both package paths supply the same runtime filename. The exact APK packaging/loader outcome (collision, duplicate copies or symbol/load-order interaction) was deliberately not tested by building an APK. There is no evidence that installing the two unmodified packages safely shares one runtime. Selecting FONNX's newer library for Sherpa would itself change the validated native runtime, even if older C APIs remain available.

### Older releases checked

Hash-verified source inspection found:

| FONNX version | Required ORT API | Misaki sources present | Packaging |
| --- | --- | --- | --- |
| 0.1.0 | 27 | Yes | Native hook bundles ORT 1.27.0 and its finalizer. |
| 0.2.2, 1.0.0, 1.1.0 | 31 | Yes | Native build hook present. |
| 1.2.0 | 31 | Yes | Native hook bundles ORT 1.31.1 and its finalizer. |

Thus an older API-compatible binding exists; claiming every FONNX version requires API 31 would be wrong. Version 0.1.0 still does not solve duplicate runtime ownership without modifying its hook/binding and qualifying that fork. No downgrade was installed. Intermediate releases were not exhaustively audited.

## Exact assets and licenses

[Machine-readable evidence](../experiments/kokoro_probe/research/fonnx-compatibility-evidence.json) records the inspected package hashes, native hashes/dynamic entries, six downloaded asset hashes/URLs, and dependency license receipts. No model binary is committed.

The proposed US frontend download comprises **15,715,342 bytes (15.72 MB / 14.99 MiB)**. This is measured file size, not estimated RAM. All six files were downloaded once and their exact byte counts and SHA-256 values matched FONNX's pins. They were not installed in the Android app. The GB dictionaries are optional alternatives and were not downloaded for this follow-up.

All downloads below are pinned to the publisher repository commit `4322a6e7ef82e0e483ad795466f60e370701cba0`:

| File | Bytes | License and source |
| --- | ---: | --- |
| [US gold dictionary](https://huggingface.co/telosnex/fonnx/resolve/4322a6e7ef82e0e483ad795466f60e370701cba0/kokoro_misaki_us_gold.json) | 3,000,469 | Apache-2.0; unchanged Misaki 0.9.4 dictionary, per FONNX's per-file card. |
| [US silver dictionary](https://huggingface.co/telosnex/fonnx/resolve/4322a6e7ef82e0e483ad795466f60e370701cba0/kokoro_misaki_us_silver.json) | 3,099,517 | Apache-2.0; same source. |
| [spaCy tokenizer/config](https://huggingface.co/telosnex/fonnx/resolve/4322a6e7ef82e0e483ad795466f60e370701cba0/kokoro_spacy_en_core_web_sm.json) | 231,990 | MIT; export of `en_core_web_sm` **3.8.0**. |
| [spaCy tagger weights](https://huggingface.co/telosnex/fonnx/resolve/4322a6e7ef82e0e483ad795466f60e370701cba0/kokoro_spacy_en_core_web_sm_tagger.bin) | 6,282,056 | MIT; same source. |
| [English BART fallback ONNX](https://huggingface.co/telosnex/fonnx/resolve/4322a6e7ef82e0e483ad795466f60e370701cba0/kokoro_g2p_fallback_en_us.onnx) | 3,101,005 | Apache-2.0 **declared** by upstream and exporter; qualifications below. |
| [Fallback vocabulary/config](https://huggingface.co/telosnex/fonnx/resolve/4322a6e7ef82e0e483ad795466f60e370701cba0/kokoro_g2p_fallback_en_us.json) | 305 | Same source/license; 64-position limit. |

License verification used the actual license texts/immutable metadata, rather than applying FONNX's MIT license to every model:

- **FONNX 1.2.0:** root MIT, copyright Telosnex. Its `misaki_en.dart` explicitly identifies an Apache-2.0 port of Misaki 0.9.4; retain that attribution and upstream Apache terms for derived code/data. The spaCy port identifies MIT upstream. The English number helper explicitly states it does not use num2words source; Python num2words and spaCy are not app runtime dependencies of this Dart path.
- **Misaki 0.9.4:** full Apache-2.0 text verified in its [PyPI source archive](https://files.pythonhosted.org/packages/1a/c7/fb01370a76585b46595a01b52f18e65c8ba6d7a313a05e5d9fff0a8e1c69/misaki-0.9.4.tar.gz), SHA-256 `3960fa3e6de179a90ee8e628446a4a4f6b8c730b6e3410999cf396189f4d9c40`.
- **spaCy model 3.8.0:** full MIT `LICENSE` and `LICENSES_SOURCES` verified inside the [exact release wheel](https://github.com/explosion/spacy-models/releases/tag/en_core_web_sm-3.8.0), SHA-256 `1932429db727d4bff3deed6b34cfc05df17794f4a52eeb26cf8928f7c1a0fb85`. Preserve source notices, including WordNet 3.0 terms where applicable. Its notices identify OntoNotes as commercially licensed by Explosion; the released model grant is MIT. This is not the Brown-corpus/non-commercial tagger identified in the separate Phonemis option. Do not redistribute original training corpora based on the model's license.
- **PeterReid fallback:** FONNX's export script pins [upstream revision `a5631b285d18d59483c32c0c3379cb9fac924f4b`](https://huggingface.co/PeterReid/graphemes_to_phonemes_en_us/tree/a5631b285d18d59483c32c0c3379cb9fac924f4b). At that revision, the entire README is the `license: apache-2.0` declaration; there is **no standalone LICENSE or detailed training-data account**. FONNX's [per-file card](https://huggingface.co/telosnex/fonnx/blob/4322a6e7ef82e0e483ad795466f60e370701cba0/README.md), export script and config independently identify that source and declared license. This verifies the publisher's grant claim, not an independent provenance clearance. Keep this unresolved for production review; it is not evidence that the weights are necessarily unlicensed.
- **ORT 1.28.2 and 1.31.1:** both upstream `LICENSE` files verified as MIT ([1.28.2](https://github.com/microsoft/onnxruntime/blob/v1.28.2/LICENSE), [1.31.1](https://github.com/microsoft/onnxruntime/blob/v1.31.1/LICENSE)). Preserve the selected binary's applicable third-party notices as well; FONNX ships `THIRD_PARTY_NOTICES_onnxruntime.txt`. **Sherpa 2.0.1** is [Apache-2.0](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/LICENSE). The current FP32 archive's Apache license/model hash are unchanged.

The exact inspected **direct dependency versions** for FONNX 1.2.0 were:

| Dependencies | Verified license |
| --- | --- |
| `archive` 4.0.9, `kiln` 1.0.0 | MIT |
| `args` 2.7.0, `code_assets` 2.2.0, `crypto` 3.0.7, `ffi` 2.1.3, `hooks` 2.2.0, `path` 1.9.1 | BSD-3-Clause |
| `ml_linalg` 13.12.6 | BSD-2-Clause |

Their recursively inspected main-dependency closure totals **27 packages**, documented with exact archive hashes, license-file hashes, versions and dependency edges in the evidence JSON. Transitive exceptions to BSD-3-Clause are `posix` 6.0.2 and `yaml` 3.1.3 (MIT), and `quiver` 3.2.2 (Apache-2.0). These are explicit audited version selections satisfying the declared constraints, **not a newly resolved Flutter lockfile**. Dev/build-author tools such as Python/PyTorch used to create already-published exports, and unrelated FONNX models with other licenses, are not proposed runtime dependencies. No new package was added or upgraded. Recheck any versions a future solver actually selects and include required notices with distribution.

MIT/BSD grants require copyright/license/disclaimer notices; Apache additionally requires its license, applicable NOTICE attribution and notices of modifications. A future vendored port must preserve its component licenses. The audit found no GPL requirement in this proposed FONNX path, but does not remove the fallback provenance limitation above.

## Options before further implementation

Estimates below are **engineering effort estimates**, not measured throughput or delivery promises. They exclude time awaiting upstream responses or device feedback. None has been implemented or proven on Android.

| Option | Work and risks | Estimated effort |
| --- | --- | --- |
| Frontend-only FONNX reuse with existing ORT 1.28 | Reuse the maintained Dart Misaki/spaCy/number/vocabulary code (about 2,310 lines excluding its FFI adapter), retain licenses, and adapt only the BART session to a reviewed ORT-28 binding/bridge. Own assets, resource lifetime, error handling, token/source coverage and the 16 tests. Sherpa has no public generic-session runner to plug into. Keeps the validated synthesis runtime/FP32 model. | 2–4 engineering days for a bounded implementation and host corpus checks, then Android qualification. Recommended architecture if this extra integration is authorized; prefer an upstream external-runtime feature over a permanent private fork. |
| Fork FONNX's native binding/hook to share ORT 1.28 | Regenerate/check API-28-compatible bindings and explicitly map one shared ORT; keep/qualify its finalizer helper and packaging. The API-27 older release shows an ABI-compatible starting point but still needs hook changes and older-source qualification. Merely changing the API constant is insufficient evidence. | 2–4 engineering days including packaging/lifetime checks and corpus work, then device checks. Similar maintenance burden; avoids replacing synthesis but changes FONNX infrastructure. |
| Unify on ORT 1.31.1 | Deliberately supply one runtime to both consumers. Validate Sherpa's native ABI/provider requirements and operator coverage; rebuild/relink Sherpa if necessary, rather than assuming it is always required. Recheck 16 KB packaging, FP32 waveform/quality, memory and performance. The backward-compatible ORT C API makes this plausible, but not automatically qualified. | 3–5 engineering days for migration and basic regression qualification, then device listening/measurement. Highest risk to the established baseline. |
| Two independent ORT copies | Native library names/SONAME/linkage/load isolation must be engineered and audited, with extra APK/RAM cost. | Not recommended for this narrow probe; deliberately not pursued. |

No option promises faster narration. Additional POS/G2P work may add overhead; the extra 15.72 MB of assets is not a RAM or battery estimate. FP32 remains the required quality baseline.

## Tests and remaining limitations

**Completed:** immutable package/archive hash checks; actual Sherpa Android ELF/version inspection; Linux API 27/28/31 negotiation (no inference); all six frontend asset size/hash checks; fallback ONNX format/checker validation; exact direct and recursive selected dependency license-text inspection; corpus JSON structure/16 unique IDs. Production/app/dependency/workflow diffs are empty against build 146.

**Not completed:** FONNX on Android, fallback inference on the current ORT, frontend acceptance/pronunciation for any of the 16 cases, audio comparison, thread profiling, RAM, battery or heat measurements. The runtime integration gate is why acceptance testing stopped; the corpus's `not_executed` status is intentional. Successful graph checking is not successful G2P or pronunciation evidence.

Even after an adapter, do not pass FONNX's full Kokoro engine through to synthesis: its staged/quantized pipeline would change the baseline. Use only its frontend, validate every phone against the existing inventory, then Sherpa's `generateWithConfig` phoneme/token input with the **same FP32 graph**. FONNX's full engine uses `unk: ''`; that behavior must not be copied into Dogreader. Accented/OOV characters, 64-position fallback limits, locale-specific dates, EPUB normalization, explicit decorative suppression, and dictionary source-span coverage still require the corpus/error-path work and listening checks. No result here establishes that all 16 cases will pass unchanged.

### Reproducing the small runtime check

Use the existing research libraries rather than installing FONNX in the Flutter app. On a host matching the **host** ORT binary architecture, this standard-library Python check creates no session and runs no model:

```python
import ctypes
lib = ctypes.CDLL('/path/to/host/sherpa_onnx/lib/libonnxruntime.so')
GetApi = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_uint32)
GetVersion = ctypes.CFUNCTYPE(ctypes.c_char_p)
class OrtApiBase(ctypes.Structure):
    _fields_ = [('get_api', GetApi), ('get_version', GetVersion)]
lib.OrtGetApiBase.restype = ctypes.POINTER(OrtApiBase)
base = lib.OrtGetApiBase().contents
print(base.get_version().decode())
print({n: bool(base.get_api(n)) for n in (27, 28, 31)})
```

Expected measured output for the inspected host wheel: `1.28.2`, `{27: True, 28: True, 31: False}`, plus ORT's API-31 rejection diagnostic. Inspect Android libraries without executing them using `readelf -d`; the evidence JSON records their SHA-256 and exact SONAME/NEEDED entries. No Flutter dependency resolution, model export, inference benchmark or APK build is required to reproduce this blocker.
