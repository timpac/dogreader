"""Phase 5 unit and acceptance tests for independent recovery sweeps, status caching, and safe diagnostics."""
from contextlib import contextmanager
import hashlib
import io
import json
import logging
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ['DOGREADER_TOKEN'] = 'PHASE5_TEST_TOKEN'
import main as cloud_main
import recover
import reliability
from reliability import Conflict, Engine, InvalidAudio, Missing, validate_mp3


def make_mp3_chunk(frames: int = 10, tag_byte: int = 1) -> bytes:
    frame = b'\xff\xfb\x90\x00' + bytes([tag_byte & 0xff]) * 413
    return frame * frames


@contextmanager
def passthrough_finalizer(stream):
    stream.seek(0)
    yield stream


class FakeBlob:
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
        self._bucket.reads[self.name] = self._bucket.reads.get(self.name, 0) + 1
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
        self._sync()

    def upload_from_file(self, file_obj, size=None, content_type=None, if_generation_match=None):
        raw = file_obj.read() if size is None else file_obj.read(size)
        self._bucket._put(self.name, raw, self.metadata, if_generation_match)
        self._sync()


class FakeBucket:
    def __init__(self):
        self._objects = {}
        self._next_gen = 1
        self.reads = {}

    def _put(self, name: str, data: bytes, metadata: dict | None, if_generation_match):
        current = self._objects.get(name)
        current_gen = current['generation'] if current else 0
        if if_generation_match is not None and current_gen != if_generation_match:
            raise Conflict(f'CAS conflict on {name}')
        gen = self._next_gen
        self._next_gen += 1
        self._objects[name] = {
            'data': bytes(data),
            'generation': gen,
            'metadata': dict(metadata or {}),
        }

    def blob(self, name: str) -> FakeBlob:
        b = FakeBlob(self, name)
        if name in self._objects:
            b._sync()
        return b

    def list_blobs(self, prefix='', start_offset='', max_results=None):
        names = sorted(
            n for n in self._objects
            if n.startswith(prefix) and (not start_offset or n >= start_offset)
        )
        if max_results is not None:
            names = names[:max_results]
        return [self.blob(n) for n in names]


class TestPhase5Operations(unittest.TestCase):
    HEADERS = {'X-Dogreader-Token': 'PHASE5_TEST_TOKEN'}

    def setUp(self):
        cloud_main.API_TOKEN = 'PHASE5_TEST_TOKEN'
        self.client = cloud_main.app.test_client()

    def test_independent_abandoned_job_recovery_via_sweep_and_endpoint(self):
        """POST /internal/recover skips terminal jobs and recovers an abandoned job to completion with zero phone polls."""
        bucket = FakeBucket()
        now = 2000.0
        enqueued = []

        job_ready = '11111111111111111111111111111111'
        job_error = '22222222222222222222222222222222'
        job_abandoned = '33333333333333333333333333333333'

        chunks = [f'Abandoned-chapter-chunk-{i:02d}.' for i in range(10)]
        full_text = ''.join(chunks)

        for jid in (job_ready, job_error, job_abandoned):
            bucket.blob(f'jobs/{jid}.json').upload_from_string(
                json.dumps({
                    'text': full_text,
                    'title': f'Job {jid[:6]}',
                    'engine': 'kokoro',
                    'model_version': 'kokoro-82m-v1.0-int8',
                    'voice': 'bm_george',
                    'settings': {'speed': 1.0, 'lang': 'en-gb'},
                }),
                content_type='application/json',
            )

        # 1. Completed terminal job (status='ready', owner=None)
        bucket.blob(f'state/{job_ready}.json').upload_from_string(
            json.dumps({
                'status': 'ready',
                'owner': None,
                'lease_until': 0,
                'sequence': 1,
                'progress': 10,
                'chunks': 10,
                'failures': 0,
                'recoveries': 0,
            }),
            content_type='application/json',
        )

        # 2. Terminal failed job (status='error', failures=12)
        bucket.blob(f'state/{job_error}.json').upload_from_string(
            json.dumps({
                'status': 'error',
                'owner': None,
                'lease_until': 0,
                'sequence': 1,
                'progress': 4,
                'chunks': 10,
                'failures': 12,
                'recoveries': 0,
                'error': 'Temporary service failure; retry budget exhausted.',
            }),
            content_type='application/json',
        )

        # 3. Abandoned job (status='generating', owner='dead-worker', lease_until=100, sequence=2, progress=8)
        bucket.blob(f'state/{job_abandoned}.json').upload_from_string(
            json.dumps({
                'status': 'generating',
                'owner': 'dead-worker',
                'lease_until': 100,
                'sequence': 2,
                'last_dispatch': 50,
                'next_dispatch': 950,
                'dispatch_delay': 900,
                'pending': False,
                'progress': 8,
                'chunks': 10,
                'failures': 0,
                'recoveries': 0,
            }),
            content_type='application/json',
        )
        # Pre-populate saved chunks 0..7 for the abandoned job
        for idx in range(8):
            data = make_mp3_chunk(frames=10, tag_byte=idx + 1)
            part = bucket.blob(f'chunks/{job_abandoned}/v1/{idx:04d}.mp3')
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

        synth_calls = []

        def job_synthesizer(text, job, job_id, index):
            synth_calls.append((job_id, index))
            return make_mp3_chunk(frames=10, tag_byte=index + 1), {'cpu_seconds': 0.1, 'peak_rss_kib': 100000}

        workflow = Engine(
            bucket,
            lambda jid, seq: enqueued.append((jid, seq)),
            lambda *a: None,
            lambda t: [t],
            conflict=Conflict,
            missing=Missing,
            transient=(InvalidAudio,),
            clock=lambda: now,
            finalizer=passthrough_finalizer,
            task_exists=lambda jid, seq: False,
            job_splitter=lambda job: list(chunks),
            job_synthesizer=job_synthesizer,
        )

        completed_calls = []
        dispatch_calls = []
        orig_completed = workflow.completed
        orig_dispatch = workflow.dispatch

        def tracked_completed(jid):
            completed_calls.append(jid)
            return orig_completed(jid)

        def tracked_dispatch(jid):
            dispatch_calls.append(jid)
            return orig_dispatch(jid)

        workflow.completed = tracked_completed
        workflow.dispatch = tracked_dispatch

        with patch.object(cloud_main, 'engine', return_value=workflow):
            resp = self.client.post(
                '/internal/recover',
                headers=self.HEADERS,
                json={'limit': 50, 'enqueue': True, 'include_terminal': False},
            )
        self.assertEqual(resp.status_code, 200)
        summary = resp.get_json()
        self.assertTrue(summary['ok'])
        self.assertEqual(summary['scanned'], 3)
        self.assertEqual(summary['skipped_terminal'], 2)
        self.assertEqual(summary['recovered'], 1)
        self.assertEqual(summary['failed'], 0)

        # Terminal jobs made 0 completed() or dispatch() calls
        self.assertEqual(completed_calls, [job_abandoned])
        self.assertEqual(dispatch_calls, [job_abandoned])
        self.assertEqual(enqueued, [(job_abandoned, 3)])

        # Process the recovered task {job_abandoned}-3 with zero Android status polling
        workflow.completed = orig_completed
        workflow.dispatch = orig_dispatch
        status, code = workflow.process(job_abandoned)
        self.assertEqual((status, code), ('ready', 200))
        # Only remaining chunks 8 and 9 were synthesized
        self.assertEqual(synth_calls, [(job_abandoned, 8), (job_abandoned, 9)])
        final_state, _ = workflow.read(f'state/{job_abandoned}.json')
        self.assertEqual(final_state['status'], 'ready')
        self.assertEqual(final_state['sequence'], 3)
        self.assertEqual(final_state['recoveries'], 1)

    def test_status_poll_avoids_redundant_job_payload_downloads(self):
        """GET /dogreader/jobs/<job_id> uses config metadata cached in state/{job_id}.json without reading jobs/{job_id}.json."""
        bucket = FakeBucket()
        now = 1_700_000_000.0
        enqueued = []
        chunks = [f'Status-poll-chunk-{i:02d}-with-enough-length.' for i in range(12)]
        full_text = ' '.join(chunks)

        workflow = Engine(
            bucket,
            lambda jid, seq: enqueued.append((jid, seq)),
            lambda *a: None,
            lambda t: list(chunks),
            conflict=Conflict,
            missing=Missing,
            transient=(InvalidAudio,),
            clock=lambda: now,
            finalizer=passthrough_finalizer,
            task_exists=lambda jid, seq: True,
            job_splitter=lambda job: list(chunks),
            job_synthesizer=lambda text, job, jid, idx: (
                make_mp3_chunk(frames=5, tag_byte=idx + 1),
                {'cpu_seconds': 0.1, 'peak_rss_kib': 90000},
            ),
        )

        with patch.object(cloud_main, 'engine', return_value=workflow), \
             patch.object(cloud_main, 'bucket', return_value=bucket), \
             patch.dict(os.environ, {'DOGREADER_KOKORO_ENABLED': '1'}, clear=False):
            submit_resp = self.client.post(
                '/dogreader/jobs',
                headers=self.HEADERS,
                json={
                    'text': full_text,
                    'title': 'Status Caching Test',
                    'engine': 'kokoro',
                    'voice': 'bm_george',
                },
            )
            self.assertEqual(submit_resp.status_code, 202)
            job_id = submit_resp.get_json()['id']

            # Run 1 batch (synthesizes chunks 0..7, checkpoints at 8)
            status, code = workflow.process(job_id)
            self.assertEqual((status, code), ('queued', 200))

            # Clear read counter on jobs/{job_id}.json and poll GET /dogreader/jobs/<job_id>
            bucket.reads.clear()
            poll_resp = self.client.get(f'/dogreader/jobs/{job_id}', headers=self.HEADERS)
            self.assertEqual(poll_resp.status_code, 200)
            poll_data = poll_resp.get_json()
            self.assertEqual(poll_data['id'], job_id)
            self.assertEqual(poll_data['status'], 'queued')
            self.assertEqual(poll_data['engine'], 'kokoro')
            self.assertEqual(poll_data['voice'], 'bm_george')
            self.assertEqual(poll_data['progress'], 8)
            self.assertEqual(poll_data['chunks'], 12)
            # Zero reads of jobs/{job_id}.json during GET /dogreader/jobs/<job_id>!
            self.assertEqual(bucket.reads.get(f'jobs/{job_id}.json', 0), 0)

    def test_failure_diagnostics_include_safe_frames_without_leaking_text(self):
        """Worker failure logs error_type, run, sequence, and safe file:line:func frames without leaking exception text."""
        bucket = FakeBucket()
        now = 1_700_000_000.0
        job_id = '44444444444444444444444444444444'
        secret_text = 'Secret chapter text: Jeeves entered the room'

        bucket.blob(f'jobs/{job_id}.json').upload_from_string(
            json.dumps({
                'text': secret_text * 5,
                'title': 'Secret Chapter',
                'engine': 'kokoro',
                'model_version': 'kokoro-82m-v1.0-int8',
                'voice': 'bm_george',
                'settings': {'speed': 1.0, 'lang': 'en-gb'},
            }),
            content_type='application/json',
        )

        def failing_synthesizer(text, job, jid, idx):
            raise RuntimeError(secret_text)

        workflow = Engine(
            bucket,
            lambda jid, seq: None,
            lambda *a: None,
            lambda t: [t],
            conflict=Conflict,
            missing=Missing,
            transient=(InvalidAudio,),
            clock=lambda: now,
            finalizer=passthrough_finalizer,
            job_splitter=lambda job: [secret_text],
            job_synthesizer=failing_synthesizer,
        )

        workflow.dispatch(job_id)
        with self.assertLogs(reliability.LOG, level=logging.ERROR) as cm:
            status, code = workflow.process(job_id)

        self.assertEqual((status, code), ('error', 200))
        self.assertEqual(len(cm.records), 1)
        raw_log = cm.records[0].getMessage()
        self.assertNotIn('Jeeves entered the room', raw_log)
        parsed = json.loads(raw_log)
        self.assertEqual(parsed['event'], 'worker_failed')
        self.assertEqual(parsed['error_type'], 'RuntimeError')
        self.assertEqual(parsed['run'], 1)
        self.assertEqual(parsed['sequence'], 1)
        self.assertIsInstance(parsed['frames'], list)
        self.assertGreater(len(parsed['frames']), 0)
        self.assertTrue(any('failing_synthesizer' in frame for frame in parsed['frames']))

        state, _ = workflow.read(f'state/{job_id}.json')
        self.assertNotIn('Jeeves entered the room', json.dumps(state))


if __name__ == '__main__':
    unittest.main(verbosity=2)
