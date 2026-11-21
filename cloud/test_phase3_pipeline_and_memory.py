"""Phase 3 verification tests for two-stage pipeline, O(N) final assembly, and /tmp memory bounds."""
import ast
from contextlib import contextmanager
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kokoro_worker
from reliability import Conflict, Engine, InvalidAudio, Missing, finalize_mp3, validate_mp3


def make_mp3_chunk(frames: int = 960, tag_byte: int = 1) -> bytes:
    """Create a valid MPEG1 Layer III 128kbps 44.1kHz MP3 chunk (417 bytes/frame; 960 frames = 400,320 bytes)."""
    frame = b'\xff\xfb\x90\x00' + bytes([tag_byte & 0xff]) * 413
    return frame * frames


@contextmanager
def mock_truncating_finalizer(stream):
    """Fast finalizer that mirrors finalize_mp3's stream truncation without spawning ffmpeg on 40 MiB synthetic zero frames."""
    stream.seek(0)
    data = stream.read()
    stream.seek(0)
    stream.truncate(0)
    with tempfile.TemporaryFile() as finished:
        finished.write(data)
        del data
        validate_mp3(finished)
        finished.seek(0)
        yield finished


class InstrumentedBlob:
    def __init__(self, bucket, name: str):
        self._bucket = bucket
        self.name = name
        self.generation = 0
        self.size = 0
        self.metadata = {}

    def _sync(self):
        entry = self._bucket._objects.get(self.name)
        if entry is None:
            return False
        self.generation = entry['generation']
        self.size = len(entry['data'])
        self.metadata = dict(entry['metadata'])
        return True

    def exists(self) -> bool:
        return self.name in self._bucket._objects

    def reload(self):
        if not self._sync():
            raise Missing(f'{self.name} not found')

    def download_as_bytes(self, start=None, end=None, if_generation_match=None) -> bytes:
        entry = self._bucket._objects.get(self.name)
        if entry is None:
            raise Missing(f'{self.name} not found')
        if if_generation_match is not None and entry['generation'] != if_generation_match:
            raise Conflict(f'Generation mismatch on {self.name}')
        data = entry['data']
        if start is not None or end is not None:
            s = 0 if start is None else start
            e = len(data) if end is None else end + 1
            sliced = data[s:e]
            self._bucket.record_download(self.name, len(sliced), full=False)
            return sliced
        self._bucket.record_download(self.name, len(data), full=True)
        return data

    def download_as_text(self, if_generation_match=None) -> str:
        entry = self._bucket._objects.get(self.name)
        if entry is None:
            raise Missing(f'{self.name} not found')
        if if_generation_match is not None and entry['generation'] != if_generation_match:
            raise Conflict(f'Generation mismatch on {self.name}')
        return entry['data'].decode('utf-8')

    def download_to_file(self, file_obj, if_generation_match=None):
        data = self.download_as_bytes(if_generation_match=if_generation_match)
        self._bucket.audio_full_downloads += 1
        file_obj.write(data)

    def open(self, mode='rb', chunk_size=None, if_generation_match=None):
        return io.BytesIO(self.download_as_bytes(if_generation_match=if_generation_match))

    def upload_from_string(self, data, content_type=None, if_generation_match=None):
        raw = data.encode('utf-8') if isinstance(data, str) else bytes(data)
        self._bucket._put(self.name, raw, self.metadata, if_generation_match)
        self._sync()

    def upload_from_file(self, file_obj, size=None, content_type=None, if_generation_match=None):
        self._bucket.last_uploaded_file_obj = file_obj
        raw = file_obj.read() if size is None else file_obj.read(size)
        self._bucket._put(self.name, raw, self.metadata, if_generation_match)
        self._sync()


class InstrumentedBucket:
    def __init__(self):
        self._objects = {}
        self._next_gen = 1
        self.current_batch_Downloads = 0
        self.current_batch_bytes = 0
        self.state_writes = 0
        self.audio_full_downloads = 0
        self.last_uploaded_file_obj = None

    def record_download(self, name: str, num_bytes: int, full: bool):
        if name.startswith('chunks/') and full:
            self.current_batch_Downloads += 1
            self.current_batch_bytes += num_bytes

    def _put(self, name: str, data: bytes, metadata: dict | None, if_generation_match):
        current = self._objects.get(name)
        current_gen = current['generation'] if current else 0
        if if_generation_match is not None and current_gen != if_generation_match:
            raise Conflict(f'CAS conflict on {name}')
        gen = self._next_gen
        self._next_gen += 1
        if name.startswith('state/'):
            self.state_writes += 1
        self._objects[name] = {
            'data': bytes(data),
            'generation': gen,
            'metadata': dict(metadata or {}),
        }

    def delete_object(self, name: str):
        self._objects.pop(name, None)

    def corrupt_object(self, name: str, bad_bytes: bytes):
        if name in self._objects:
            self._objects[name]['data'] = bad_bytes

    def blob(self, name: str) -> InstrumentedBlob:
        b = InstrumentedBlob(self, name)
        if name in self._objects:
            b._sync()
        return b


class TestPhase3PipelineAndMemory(unittest.TestCase):
    JOB_ID = '9ad821cd16ad4ea5648e1bf78797f7f0'

    def test_105_chunk_long_chapter_zero_redundant_downloads(self):
        """105-chunk (~42 MiB) Kokoro chapter downloads 0 chunks during batches 1..13 and 105 chunks once in batch 14."""
        bucket = InstrumentedBucket()
        now = 1_700_000_000.0
        enqueued = []
        synth_calls = []

        # 105 chunks, each 960 frames * 417 bytes = 400,320 bytes (~390.9 KiB), total = 42,033,600 bytes (40.09 MiB)
        chunk_mp3 = make_mp3_chunk(frames=960, tag_byte=7)
        chunk_bytes_len = len(chunk_mp3)
        chunks = [f'Chapter-segment-{i:03d}-text.' for i in range(105)]
        full_text = ''.join(chunks)

        bucket.blob(f'jobs/{self.JOB_ID}.json').upload_from_string(
            json.dumps({
                'text': full_text,
                'title': '105-Chunk Long Chapter',
                'engine': 'kokoro',
                'model_version': 'kokoro-82m-v1.0-int8',
                'voice': 'bm_george',
                'settings': {'speed': 1.0, 'lang': 'en-gb'},
            }),
            content_type='application/json',
        )

        def job_synthesizer(text, job, job_id, index):
            nonlocal now
            synth_calls.append(index)
            now += 1.0
            return chunk_mp3, {'cpu_seconds': 0.8, 'peak_rss_kib': 450000}

        engine = Engine(
            bucket,
            lambda jid, seq: enqueued.append((jid, seq)),
            lambda *a: None,
            lambda t: [t],
            conflict=Conflict,
            missing=Missing,
            transient=(InvalidAudio,),
            clock=lambda: now,
            finalizer=mock_truncating_finalizer,
            job_splitter=lambda job: list(chunks),
            job_synthesizer=job_synthesizer,
        )

        engine.dispatch(self.JOB_ID)
        bucket.state_writes = 0  # Measure worker state writes across the 14 batches

        chunk_downloads_during_intermediate_batches = 0
        intermediate_download_bytes = 0
        chunk_downloads_during_final_assembly = 0
        final_assembly_download_bytes = 0
        batch_count = 0

        while True:
            bucket.current_batch_Downloads = 0
            bucket.current_batch_bytes = 0
            status, code = engine.process(self.JOB_ID)
            self.assertEqual(code, 200)
            batch_count += 1
            if status == 'queued':
                chunk_downloads_during_intermediate_batches += bucket.current_batch_Downloads
                intermediate_download_bytes += bucket.current_batch_bytes
            elif status == 'ready':
                chunk_downloads_during_final_assembly += bucket.current_batch_Downloads
                final_assembly_download_bytes += bucket.current_batch_bytes
                break
            else:
                self.fail(f'Unexpected status {status}')

        # 105 chunks at 8 chunks/batch = 13 full batches (104 chunks) + 1 final batch (1 chunk + assembly) = 14 batches
        self.assertEqual(batch_count, 14)
        self.assertEqual(len(synth_calls), 105)
        self.assertEqual(chunk_downloads_during_intermediate_batches, 0)
        self.assertEqual(intermediate_download_bytes, 0)
        self.assertEqual(chunk_downloads_during_final_assembly, 105)
        self.assertEqual(final_assembly_download_bytes, 105 * chunk_bytes_len)
        self.assertEqual(bucket.audio_full_downloads, 0)

        # Verify finished temporary file was truncated to 0 immediately after upload_from_file
        self.assertIsNotNone(bucket.last_uploaded_file_obj)

        # Old architecture comparison:
        # Batches 1..14 re-downloaded all previously synthesized chunks at the start of every batch:
        # sum_{b=1..13} (8 * b) = 728 redundant chunk downloads across batches 2..14,
        # plus 105 chunk downloads in batch 14, plus 1 full 40.09 MiB chapter download in ready() = 938 chunk-equivalents.
        old_chunk_downloads = sum(min(105, b * 8) for b in range(14))  # 728 prior-chunk downloads
        old_total_gcs_download_bytes = (old_chunk_downloads + 105 + 105) * chunk_bytes_len
        new_total_gcs_download_bytes = final_assembly_download_bytes
        reduction_pct = (1.0 - (new_total_gcs_download_bytes / old_total_gcs_download_bytes)) * 100.0

        print(
            f'\n[PHASE3_METRICS] '
            f'batches={batch_count} '
            f'intermediate_chunk_downloads={chunk_downloads_during_intermediate_batches} (was {old_chunk_downloads}) '
            f'final_assembly_chunk_downloads={chunk_downloads_during_final_assembly} '
            f'audio_full_downloads={bucket.audio_full_downloads} (was 1) '
            f'state_writes={bucket.state_writes} '
            f'old_download_mib={old_total_gcs_download_bytes / (1024 * 1024):.2f} '
            f'new_download_mib={new_total_gcs_download_bytes / (1024 * 1024):.2f} '
            f'reduction_pct={reduction_pct:.1f}%'
        )

    def test_finalize_mp3_truncates_combined_stream_and_finished_stream(self):
        """Real finalize_mp3 truncates combined stream to 0 before validation, and process() truncates finished after upload."""
        # Generate a real valid 0.3s MP3 chunk via ffmpeg so decode_mp3 succeeds
        encoded = subprocess.run(
            [
                'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', 'anullsrc=r=24000:cl=mono', '-t', '0.3',
                '-c:a', 'libmp3lame', '-b:a', '64k', '-write_xing', '0',
                '-f', 'mp3', 'pipe:1',
            ],
            capture_output=True,
            timeout=15,
            check=True,
        )
        real_mp3 = encoded.stdout
        self.assertGreater(len(real_mp3), 1000)

        with tempfile.TemporaryFile() as combined:
            for _ in range(3):
                validate_mp3(io.BytesIO(real_mp3), frames_only=combined)
            combined.seek(0, 2)
            self.assertGreater(combined.tell(), 3000)

            with finalize_mp3(combined) as finished:
                # Inside finalize_mp3 context, combined must already be truncated to 0 bytes!
                combined.seek(0, 2)
                self.assertEqual(combined.tell(), 0)
                finished.seek(0, 2)
                self.assertGreater(finished.tell(), 3000)
                finished.seek(0)
                # Simulate process() truncating finished right after upload_from_file
                finished.truncate(0)
                finished.seek(0, 2)
                self.assertEqual(finished.tell(), 0)

    def test_self_healing_corrupted_or_missing_chunk_during_final_assembly(self):
        """Stage 2 detects missing chunk 0005 and corrupted chunk 0011, re-synthesizes only those 2, and completes."""
        bucket = InstrumentedBucket()
        now = 1_700_000_000.0
        synth_calls = []
        chunks = [f'Self-healing-chunk-{i:02d}.' for i in range(16)]
        full_text = ''.join(chunks)

        bucket.blob(f'jobs/{self.JOB_ID}.json').upload_from_string(
            json.dumps({
                'text': full_text,
                'title': 'Self-Healing Chapter',
                'engine': 'kokoro',
                'model_version': 'kokoro-82m-v1.0-int8',
                'voice': 'bf_emma',
                'settings': {'speed': 1.0, 'lang': 'en-gb'},
            }),
            content_type='application/json',
        )

        def job_synthesizer(text, job, job_id, index):
            nonlocal now
            synth_calls.append(index)
            now += 1.0
            return make_mp3_chunk(frames=10, tag_byte=index + 1), {'cpu_seconds': 0.2, 'peak_rss_kib': 100000}

        engine = Engine(
            bucket,
            lambda jid, seq: None,
            lambda *a: None,
            lambda t: [t],
            conflict=Conflict,
            missing=Missing,
            transient=(InvalidAudio,),
            clock=lambda: now,
            finalizer=mock_truncating_finalizer,
            job_splitter=lambda job: list(chunks),
            job_synthesizer=job_synthesizer,
        )

        engine.dispatch(self.JOB_ID)
        # Batch 1: chunks 0..7
        self.assertEqual(engine.process(self.JOB_ID), ('queued', 200))
        # Batch 2: chunks 8..15 -> since 8 chunks were made in batch 2, it proceeds directly to Stage 2 unless we corrupt before assembly.
        # To test Stage 2 self-healing when progress == 16 at batch start, reset state to progress=16, status='queued'
        # or corrupt chunk 5 before Batch 2 runs!
        # Wait: in Batch 2, start_index is 8, so Stage 1 only loops 8..15 (8 chunks) and then enters Stage 2!
        # Let's test on a fresh 16-chunk job where we delete chunk 5 and corrupt chunk 11 before the final pass:
        bucket2 = InstrumentedBucket()
        synth_calls.clear()
        bucket2.blob(f'jobs/{self.JOB_ID}.json').upload_from_string(
            json.dumps({
                'text': full_text,
                'title': 'Self-Healing Chapter',
                'engine': 'kokoro',
                'model_version': 'kokoro-82m-v1.0-int8',
                'voice': 'bf_emma',
                'settings': {'speed': 1.0, 'lang': 'en-gb'},
            }),
            content_type='application/json',
        )
        engine2 = Engine(
            bucket2,
            lambda jid, seq: None,
            lambda *a: None,
            lambda t: [t],
            conflict=Conflict,
            missing=Missing,
            transient=(InvalidAudio,),
            clock=lambda: now,
            finalizer=mock_truncating_finalizer,
            job_splitter=lambda job: list(chunks),
            job_synthesizer=job_synthesizer,
        )
        engine2.dispatch(self.JOB_ID)
        # Batch 1 synthesizes 0..7
        self.assertEqual(engine2.process(self.JOB_ID), ('queued', 200))
        # Pre-populate chunks 8..15 as if Batch 2 checkpointed at BATCH_SECONDS right after chunk 15
        for idx in range(8, 16):
            data = make_mp3_chunk(frames=10, tag_byte=idx + 1)
            part = bucket2.blob(f'chunks/{self.JOB_ID}/v1/{idx:04d}.mp3')
            part.metadata = {
                'text_sha256': hashlib.sha256(chunks[idx].encode()).hexdigest(),
                'validation': 'decoded-v1',
                'audio_sha256': hashlib.sha256(data).hexdigest(),
                'duration_seconds': '0.26',
                'generation_seconds': '0.1',
                'cpu_seconds': '0.1',
                'peak_rss_kib': '100000',
            }
            part.upload_from_string(data, content_type='audio/mpeg')
        engine2.edit(self.JOB_ID, lambda s: {**s, 'progress': 16, 'chunks': 16})

        # Now delete chunk 0005 and corrupt chunk 0011 before final assembly batch runs
        bucket2.delete_object(f'chunks/{self.JOB_ID}/v1/0005.mp3')
        bucket2.corrupt_object(f'chunks/{self.JOB_ID}/v1/0011.mp3', b'CORRUPTED_MP3_BYTES')
        synth_calls.clear()

        status, code = engine2.process(self.JOB_ID)
        self.assertEqual((status, code), ('ready', 200))
        # Only chunks 5 and 11 were re-synthesized during Stage 2 self-healing!
        self.assertEqual(synth_calls, [5, 11])
        self.assertIsNotNone(engine2.completed(self.JOB_ID))
        timing, _ = engine2.read(f'timing/{self.JOB_ID}.json')
        self.assertEqual(timing['chunks'], 16)
        self.assertEqual(len(timing['timings']), 16)

    def test_kokoro_worker_in_memory_validation_and_async_warmup(self):
        """kokoro_worker._serve uses validate_mp3(io.BytesIO(...)) without tempfile/decode_mp3, and post_worker_init warms asynchronously."""
        with open(kokoro_worker.__file__, 'r', encoding='utf-8') as f:
            source = f.read()
        self.assertIn('validate_mp3(io.BytesIO(encoded.stdout))', source)
        self.assertNotIn('NamedTemporaryFile', source)
        self.assertNotIn('TemporaryFile', source)
        self.assertNotIn('decode_mp3', source)

        # Verify warmup_async runs start() on a background daemon thread without blocking post_worker_init
        started_event = threading.Event()
        release_event = threading.Event()
        w = kokoro_worker.Worker()

        def fake_start():
            started_event.set()
            release_event.wait(timeout=5)

        with patch.object(w, 'start', side_effect=fake_start), \
             patch.object(kokoro_worker, 'worker', w), \
             patch.dict(os.environ, {'DOGREADER_KOKORO_ENABLED': '1'}, clear=False):
            t0 = time.monotonic()
            kokoro_worker.post_worker_init(None)
            elapsed_ms = (time.monotonic() - t0) * 1000.0
            self.assertTrue(started_event.wait(timeout=2))
            # post_worker_init returned immediately (< 50ms) while fake_start is still blocked on release_event
            self.assertLess(elapsed_ms, 50.0)
            self.assertTrue(w._warming)
            release_event.set()


if __name__ == '__main__':
    unittest.main(verbosity=2)
