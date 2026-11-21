"""Phase 2 unit and acceptance tests for multi-batch Cloud Tasks continuation without 503 backoff."""
from contextlib import contextmanager
import hashlib
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reliability import Conflict, Engine, InvalidAudio, Missing
from kokoro_worker import KokoroUnavailable


def make_mp3_frame(tag_byte: int = 0) -> bytes:
    """Create a valid 417-byte MPEG1 Layer III 128kbps 44.1kHz MP3 frame."""
    header = b'\xff\xfb\x90\x00'
    payload = bytes([tag_byte & 0xff]) * 413
    return header + payload


@contextmanager
def passthrough_finalizer(stream):
    stream.seek(0)
    yield stream


class InMemoryBlob:
    def __init__(self, bucket, name: str):
        self._bucket = bucket
        self.name = name
        self.generation = 0
        self.size = 0
        self.metadata = {}
        self._data = None

    def _sync_from_store(self):
        entry = self._bucket._objects.get(self.name)
        if entry is None:
            return False
        self.generation = entry['generation']
        self.size = len(entry['data'])
        self.metadata = dict(entry['metadata'])
        self._data = entry['data']
        return True

    def exists(self) -> bool:
        return self.name in self._bucket._objects

    def reload(self):
        if not self._sync_from_store():
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
            return data[s:e]
        return data

    def download_as_text(self, if_generation_match=None) -> str:
        return self.download_as_bytes(if_generation_match=if_generation_match).decode('utf-8')

    def download_to_file(self, file_obj, if_generation_match=None):
        file_obj.write(self.download_as_bytes(if_generation_match=if_generation_match))

    def open(self, mode='rb', chunk_size=None, if_generation_match=None):
        return io.BytesIO(self.download_as_bytes(if_generation_match=if_generation_match))

    def upload_from_string(self, data, content_type=None, if_generation_match=None):
        raw = data.encode('utf-8') if isinstance(data, str) else bytes(data)
        self._bucket._put(self.name, raw, self.metadata, if_generation_match)
        self._sync_from_store()

    def upload_from_file(self, file_obj, size=None, content_type=None, if_generation_match=None):
        raw = file_obj.read() if size is None else file_obj.read(size)
        self._bucket._put(self.name, raw, self.metadata, if_generation_match)
        self._sync_from_store()


class InMemoryBucket:
    def __init__(self):
        self._objects = {}
        self._next_gen = 1

    def _put(self, name: str, data: bytes, metadata: dict | None, if_generation_match):
        current = self._objects.get(name)
        current_gen = current['generation'] if current else 0
        if if_generation_match is not None and current_gen != if_generation_match:
            raise Conflict(f'CAS conflict on {name}: expected {if_generation_match}, got {current_gen}')
        gen = self._next_gen
        self._next_gen += 1
        self._objects[name] = {
            'data': bytes(data),
            'generation': gen,
            'metadata': dict(metadata or {}),
        }

    def blob(self, name: str) -> InMemoryBlob:
        b = InMemoryBlob(self, name)
        if name in self._objects:
            b._sync_from_store()
        return b


class SimulatedCloudTasksQueue:
    """Simulates Cloud Tasks HTTP task dispatch and 5xx exponential backoff."""
    def __init__(self):
        self.created_task_names = set()
        self.pending_tasks = []  # list of (task_name, job_id, sequence, attempt)
        self.history = []  # list of dicts recording each execution
        self.backoff_seconds_total = 0.0
        self.fail_next_enqueue = False

    def enqueue(self, job_id: str, sequence: int):
        if self.fail_next_enqueue:
            self.fail_next_enqueue = False
            raise RuntimeError('Simulated Cloud Tasks transient enqueue error')
        task_name = f'{job_id}-{sequence}'
        if task_name in self.created_task_names:
            return  # Idempotent AlreadyExists behavior
        self.created_task_names.add(task_name)
        self.pending_tasks.append((task_name, job_id, sequence, 1))

    def task_exists(self, job_id: str, sequence: int) -> bool:
        target = f'{job_id}-{sequence}'
        return any(name == target for name, _, _, _ in self.pending_tasks)

    def run_next(self, engine: Engine, clock_advance=None):
        task_name, job_id, sequence, attempt = self.pending_tasks.pop(0)
        state, code = engine.process(job_id)
        backoff = 0.0
        if code >= 500:
            backoff = min(300.0, 10.0 * (2 ** (attempt - 1)))
            self.backoff_seconds_total += backoff
            if clock_advance:
                clock_advance(backoff)
            self.pending_tasks.insert(0, (task_name, job_id, sequence, attempt + 1))
        self.history.append({
            'task_name': task_name,
            'sequence': sequence,
            'attempt': attempt,
            'status': state,
            'http_code': code,
            'backoff_seconds': backoff,
        })
        return state, code


class TestPhase2Continuation(unittest.TestCase):
    JOB_ID = 'a1b2c3d4e5f60123456789abcdef0123'

    def setUp(self):
        self.now = 1_700_000_000.0
        self.bucket = InMemoryBucket()
        self.queue = SimulatedCloudTasksQueue()
        self.synth_calls = []
        self.fail_on_chunk = {}

        # Create a 25-chunk Kokoro job
        self.chunks = [f'Chunk-{i:02d}-narration-text.' for i in range(25)]
        self.full_text = ''.join(self.chunks)
        job_payload = {
            'text': self.full_text,
            'title': 'Phase 2 Multi-Batch Kokoro Chapter',
            'engine': 'kokoro',
            'model_version': 'kokoro-82m-v1.0-int8',
            'voice': 'bf_emma',
            'settings': {'speed': 1.0, 'lang': 'en-gb'},
        }
        self.bucket.blob(f'jobs/{self.JOB_ID}.json').upload_from_string(
            json.dumps(job_payload),
            content_type='application/json',
        )

        def job_splitter(job):
            return list(self.chunks)

        def job_synthesizer(text, job, job_id, index):
            self.synth_calls.append(index)
            if index in self.fail_on_chunk and self.fail_on_chunk[index] > 0:
                self.fail_on_chunk[index] -= 1
                raise KokoroUnavailable('Simulated transient Kokoro worker failure')
            self.now += 1.0
            return make_mp3_frame(index + 1), {'cpu_seconds': 0.5, 'peak_rss_kib': 120000}

        self.engine = Engine(
            self.bucket,
            self.queue.enqueue,
            lambda *a: None,
            lambda t: [t],
            conflict=Conflict,
            missing=Missing,
            transient=(InvalidAudio, KokoroUnavailable),
            clock=lambda: self.now,
            finalizer=passthrough_finalizer,
            task_exists=self.queue.task_exists,
            job_splitter=job_splitter,
            job_synthesizer=job_synthesizer,
        )

    def test_multi_batch_kokoro_continuation_without_503_backoff(self):
        """Phase 2 Acceptance Test: 25-chunk Kokoro job completes across 4 batches with zero 503s and zero phone polls."""
        # Submit / initial dispatch (as /dogreader/jobs does)
        initial_state = self.engine.dispatch(self.JOB_ID)
        self.assertEqual(initial_state['status'], 'queued')
        self.assertEqual(initial_state['sequence'], 1)
        self.assertFalse(initial_state['pending'])
        self.assertEqual(len(self.queue.pending_tasks), 1)
        self.assertEqual(self.queue.pending_tasks[0][0], f'{self.JOB_ID}-1')

        # Batch 1: synthesizes chunks 0..7, checkpoints at index 8, enqueues sequence 2, returns ('queued', 200)
        status1, code1 = self.queue.run_next(self.engine)
        self.assertEqual((status1, code1), ('queued', 200))
        state1, _ = self.engine.read(f'state/{self.JOB_ID}.json')
        self.assertEqual(state1['progress'], 8)
        self.assertEqual(state1['chunks'], 25)
        self.assertEqual(state1['sequence'], 2)
        self.assertFalse(state1['pending'])
        self.assertEqual(self.synth_calls, list(range(0, 8)))
        self.assertEqual(self.queue.pending_tasks[0][0], f'{self.JOB_ID}-2')

        # Batch 2: synthesizes chunks 8..15, checkpoints at index 16, enqueues sequence 3, returns ('queued', 200)
        status2, code2 = self.queue.run_next(self.engine)
        self.assertEqual((status2, code2), ('queued', 200))
        state2, _ = self.engine.read(f'state/{self.JOB_ID}.json')
        self.assertEqual(state2['progress'], 16)
        self.assertEqual(state2['sequence'], 3)
        self.assertFalse(state2['pending'])
        self.assertEqual(self.synth_calls, list(range(0, 16)))
        self.assertEqual(self.queue.pending_tasks[0][0], f'{self.JOB_ID}-3')

        # Batch 3: synthesizes chunks 16..23, checkpoints at index 24, enqueues sequence 4, returns ('queued', 200)
        status3, code3 = self.queue.run_next(self.engine)
        self.assertEqual((status3, code3), ('queued', 200))
        state3, _ = self.engine.read(f'state/{self.JOB_ID}.json')
        self.assertEqual(state3['progress'], 24)
        self.assertEqual(state3['sequence'], 4)
        self.assertFalse(state3['pending'])
        self.assertEqual(self.synth_calls, list(range(0, 24)))
        self.assertEqual(self.queue.pending_tasks[0][0], f'{self.JOB_ID}-4')

        # Batch 4: synthesizes chunk 24, finalizes MP3 + timing map, returns ('ready', 200)
        status4, code4 = self.queue.run_next(self.engine)
        self.assertEqual((status4, code4), ('ready', 200))
        self.assertEqual(len(self.queue.pending_tasks), 0)

        # Verify zero 503 responses and zero backoff seconds
        self.assertEqual(self.queue.backoff_seconds_total, 0.0)
        self.assertTrue(all(h['http_code'] == 200 for h in self.queue.history))
        self.assertEqual([h['sequence'] for h in self.queue.history], [1, 2, 3, 4])

        # Verify every chunk 0..24 was synthesized exactly once
        self.assertEqual(self.synth_calls, list(range(25)))

        # Verify final job state, verified audio blob, and timing report
        final_state, _ = self.engine.read(f'state/{self.JOB_ID}.json')
        self.assertEqual(final_state['status'], 'ready')
        self.assertEqual(final_state['failures'], 0)
        self.assertEqual(final_state['recoveries'], 0)
        self.assertEqual(final_state['progress'], 25)
        self.assertEqual(final_state['chunks'], 25)
        self.assertIsNotNone(self.engine.completed(self.JOB_ID))

        timing, _ = self.engine.read(f'timing/{self.JOB_ID}.json')
        self.assertIsNotNone(timing)
        self.assertEqual(timing['chunks'], 25)
        self.assertEqual(timing['characters'], len(self.full_text))

    def test_genuine_transient_failure_returns_503_and_resumes_saved_chunks(self):
        """Genuine synthesis failure still returns ('queued', 503) so Cloud Tasks backs off and retries."""
        self.engine.dispatch(self.JOB_ID)
        # Fail once on chunk 3 during Batch 1
        self.fail_on_chunk[3] = 1

        status1, code1 = self.queue.run_next(
            self.engine,
            clock_advance=lambda dt: setattr(self, 'now', self.now + dt),
        )
        self.assertEqual((status1, code1), ('queued', 503))
        self.assertEqual(self.queue.backoff_seconds_total, 10.0)
        state_after_fail, _ = self.engine.read(f'state/{self.JOB_ID}.json')
        self.assertEqual(state_after_fail['failures'], 1)
        self.assertEqual(state_after_fail['progress'], 3)
        # Chunks 0, 1, 2 succeeded; chunk 3 failed
        self.assertEqual(self.synth_calls, [0, 1, 2, 3])

        # Cloud Tasks retries task-1 after 10s backoff; chunks 0..2 load from checkpoint without re-synthesis!
        status2, code2 = self.queue.run_next(self.engine)
        self.assertEqual((status2, code2), ('queued', 200))
        # Chunks 3..10 (8 new chunks) were synthesized in this batch
        self.assertEqual(self.synth_calls, [0, 1, 2, 3, 3, 4, 5, 6, 7, 8, 9, 10])

    def test_checkpoint_enqueue_failure_returns_503_and_recovers_cleanly(self):
        """If enqueue() fails during checkpoint(), returns ('queued', 503) with pending=True and recovers without re-synthesis."""
        self.engine.dispatch(self.JOB_ID)
        self.queue.fail_next_enqueue = True

        status1, code1 = self.queue.run_next(
            self.engine,
            clock_advance=lambda dt: setattr(self, 'now', self.now + dt),
        )
        self.assertEqual((status1, code1), ('queued', 503))
        state1, _ = self.engine.read(f'state/{self.JOB_ID}.json')
        self.assertTrue(state1['pending'])
        self.assertEqual(state1['sequence'], 2)
        self.assertEqual(state1['progress'], 8)
        self.assertEqual(self.synth_calls, list(range(0, 8)))

        # Either the Cloud Tasks 503 retry OR a dispatch() call completes without duplicating chunks 0..7
        dispatched = self.engine.dispatch(self.JOB_ID)
        self.assertFalse(dispatched['pending'])
        self.assertEqual(dispatched['sequence'], 2)
        # Pop the retried task-1 (which sees batch 2 work or completes batch 2) and run remaining tasks to completion
        while self.queue.pending_tasks:
            self.queue.run_next(self.engine)
        self.assertEqual(self.synth_calls, list(range(25)))
        self.assertIsNotNone(self.engine.completed(self.JOB_ID))

    def test_concurrent_duplicate_delivery_is_fenced_with_503(self):
        """A concurrent worker delivery while a lease is active is fenced ('generating', 503)."""
        self.engine.dispatch(self.JOB_ID)
        # Simulate an active lease held by another worker
        self.engine.edit(
            self.JOB_ID,
            lambda s: {**s, 'status': 'generating', 'owner': 'active-worker', 'lease_until': self.now + 300},
        )
        status, code = self.engine.process(self.JOB_ID)
        self.assertEqual((status, code), ('generating', 503))
        self.assertEqual(self.synth_calls, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
