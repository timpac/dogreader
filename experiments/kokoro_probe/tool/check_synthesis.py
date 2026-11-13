"""Run accepted frontend phonemes through the pinned FP32 Sherpa engine.

Host acceptance evidence, not Android performance or pronunciation approval.
No network/model download. Reuses one engine for this small corpus.
"""
import argparse
import hashlib
import json
from pathlib import Path
import wave

import numpy as np
import sherpa_onnx


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('corpus_results', type=Path)
    parser.add_argument('model_dir', type=Path)
    parser.add_argument('output_dir', type=Path)
    args = parser.parse_args()
    inputs = json.loads(args.corpus_results.read_text())
    assert inputs['allPassed'] and inputs['corpusCases'] == 16
    graph = args.model_dir / 'model.onnx'
    model_sha = digest(graph)
    assert model_sha == 'b40f62b166ac8164b0627ef48a0b358eda0985e272fb03ef5252e7206305da11'
    assert digest(args.model_dir / 'tokens.txt') == '6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425'
    assert digest(args.model_dir / 'voices.bin') == '1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29'
    tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(
            kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
                model=str(graph), voices=str(args.model_dir / 'voices.bin'),
                tokens=str(args.model_dir / 'tokens.txt'), lang='en-us'),
            provider='cpu', num_threads=2), max_num_sentences=1))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for case in inputs['results']:
        assert case['pass']
        if case['outcome'] == 'visible_error':
            assert 'phonemeChunks' not in case
            results.append({'id': case['id'], 'locale': case['locale'],
                            'outcome': 'expected_error_before_synthesis', 'pass': True})
            continue
        assert case['coverageChecked']
        chunks = case['phonemeChunks']
        assert chunks and all(0 < len(chunk) <= 400 for chunk in chunks)
        config = sherpa_onnx.GenerationConfig()
        config.sid = 21 if case['locale'] == 'en-GB' else 3
        config.speed = 1.0
        wav = args.output_dir / f"{case['id']}-{case['locale']}.wav"
        frames = []
        with wave.open(str(wav), 'wb') as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(24000)
            for chunk in chunks:
                # Same pre-phonemized API/input used by Dart generateWithConfig.
                config.phoneme_codepoints = [[ord(phone) for phone in chunk]]
                audio = tts.generate('', config)
                samples = np.asarray(audio.samples, dtype=np.float64)
                assert audio.sample_rate == 24000 and samples.size > 0
                assert np.isfinite(samples).all()
                # Match the unchanged Dart PCM conversion, including ties away from zero.
                scaled = np.clip(samples, -1, 1) * 32767
                pcm = (np.sign(scaled) * np.floor(np.abs(scaled) + 0.5)).astype('<i2')
                output.writeframes(pcm.tobytes())
                frames.append(int(samples.size))
        with wave.open(str(wav), 'rb') as output:
            assert output.getnframes() == sum(frames)
            assert (output.getframerate(), output.getnchannels(), output.getsampwidth()) == (24000, 1, 2)
            pcm = np.frombuffer(output.readframes(output.getnframes()), dtype='<i2').astype(np.float64) / 32767
            pcm_peak = float(np.max(np.abs(pcm)))
            pcm_rms = float(np.sqrt(np.mean(pcm * pcm)))
            assert pcm_peak > 1e-5 and pcm_rms > 1e-7, 'Silent output'
        result = {'id': case['id'], 'locale': case['locale'], 'pass': True,
                  'outcome': 'all_chunks_synthesized', 'chunks': len(chunks),
                  'normalizedText': case['normalizedText'], 'phonemeChunks': chunks,
                  'sourceCoverageChecked': case['coverageChecked'],
                  'suppliedPhonemeCodepoints': sum(map(len, chunks)),
                  'framesPerChunk': frames, 'audioFrames': sum(frames),
                  'audioSeconds': sum(frames) / 24000, 'sampleRate': 24000,
                  'channels': 1, 'pcmBits': 16, 'pcmPeak': pcm_peak,
                  'pcmRms': pcm_rms, 'wavSha256': digest(wav)}
        results.append(result)
        print(f"PASS {case['id']} {case['locale']}: {len(chunks)} chunks, {sum(frames)} finite frames", flush=True)
    assert len(results) == 17 and sum(r['outcome'] == 'all_chunks_synthesized' for r in results) == 15
    report = {'platform': 'Linux x86_64 host, NOT Android/Pixel',
              'runtime': 'sherpa_onnx 2.0.1 CPU / ORT 1.28.2', 'model': 'FP32',
              'modelSha256': model_sha, 'threads': 2, 'speed': 1.0,
              'frontendInputSha256': digest(args.corpus_results), 'allPassed': True,
              'corpusCases': 16, 'localeRuns': 17, 'synthesizedRuns': 15,
              'expectedErrors': 2, 'results': results,
              'note': 'Every accepted phoneme chunk produced finite nonempty audio. Source coverage was checked by the frontend. '
                      'This does not prove pronunciation correctness or that listeners hear every intended word. '
                      'No Android speed, RAM, heat or battery result is claimed.'}
    (args.output_dir / 'synthesis-results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
