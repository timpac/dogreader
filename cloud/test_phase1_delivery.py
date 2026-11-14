"""Phase 1 unit tests for Dogreader audio delivery endpoint (/dogreader/audio/<job_id>)."""
import hashlib
import io
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ['DOGREADER_TOKEN'] = 'PHASE1_UNIT_TOKEN'
import main as cloud_main


class FakeBlob:
    def __init__(self, payload: bytes, sha256: str = '', generation: int = 123456789, signed_url: str | None = None):
        self._payload = payload
        self.size = len(payload)
        self.generation = generation
        self.metadata = {'sha256': sha256} if sha256 else {}
        self._signed_url = signed_url
        self.signed_url_calls = []
        self.open_calls = []

    def generate_signed_url(self, **kwargs):
        self.signed_url_calls.append(kwargs)
        if self._signed_url:
            return self._signed_url
        raise RuntimeError('No local private key')

    def open(self, mode='rb', chunk_size=None, if_generation_match=None):
        self.open_calls.append({
            'mode': mode,
            'chunk_size': chunk_size,
            'if_generation_match': if_generation_match,
        })
        return io.BytesIO(self._payload)


class FakeEngine:
    def __init__(self, blob):
        self._blob = blob

    def completed(self, job_id):
        return self._blob


class TestPhase1AudioDelivery(unittest.TestCase):
    JOB_ID = '9ad821cd16ad4ea5648e1bf78797f7f0'
    HEADERS = {'X-Dogreader-Token': 'PHASE1_UNIT_TOKEN'}

    def setUp(self):
        cloud_main.API_TOKEN = 'PHASE1_UNIT_TOKEN'
        self.client = cloud_main.app.test_client()

    def test_auth_required_401_without_token(self):
        resp_missing = self.client.get(f'/dogreader/audio/{self.JOB_ID}')
        self.assertEqual(resp_missing.status_code, 401)

        resp_wrong = self.client.get(
            f'/dogreader/audio/{self.JOB_ID}',
            headers={'X-Dogreader-Token': 'WRONG_TOKEN'},
        )
        self.assertEqual(resp_wrong.status_code, 401)

    def test_302_redirect_to_signed_gcs_url_without_tmp_buffering(self):
        size_45mb = 45 * 1024 * 1024
        expected_sha = 'a874f6dc14b211fa89f0854a2dc2667d8e8a8a9c5a992ff274b54bf1e7d7b897'
        signed = 'https://storage.googleapis.com/pg-wodehouse-dogreader-audio/audio/test.mp3?X-Goog-Algorithm=GOOG4-RSA-SHA256'
        blob = FakeBlob(b'', sha256=expected_sha, generation=998877, signed_url=signed)
        blob.size = size_45mb

        tmp_before = set(os.listdir(tempfile.gettempdir()))
        with patch.object(cloud_main, 'engine', return_value=FakeEngine(blob)), \
             patch.dict(os.environ, {'DOGREADER_DISABLE_SIGNED_URLS': '0'}, clear=False):
            resp = self.client.get(f'/dogreader/audio/{self.JOB_ID}', headers=self.HEADERS)
        tmp_after = set(os.listdir(tempfile.gettempdir()))

        self.assertEqual(resp.status_code, 302)
        self.assertEqual(resp.headers.get('Location'), signed)
        self.assertEqual(resp.headers.get('X-Dogreader-Audio-Bytes'), str(size_45mb))
        self.assertEqual(resp.headers.get('X-Dogreader-Audio-Sha256'), expected_sha)
        self.assertEqual(resp.headers.get('X-Dogreader-Audio-Generation'), '998877')
        self.assertEqual(resp.data, b'')
        self.assertEqual(len(blob.open_calls), 0)
        self.assertEqual(tmp_after - tmp_before, set())

    def test_bounded_206_partial_content_slices_for_45mib_recording(self):
        # Simulated 45 MiB recording
        size_45mb = 45 * 1024 * 1024
        pattern = (b'DOGREADER_45MB_BLOCK_' * 3200)[:65536]
        payload = (pattern * ((size_45mb // len(pattern)) + 1))[:size_45mb]
        expected_sha = hashlib.sha256(payload).hexdigest()
        blob = FakeBlob(payload, sha256=expected_sha, generation=554433, signed_url=None)

        tmp_before = set(os.listdir(tempfile.gettempdir()))
        assembled = bytearray()
        slice_sizes = []
        content_ranges = []

        with patch.object(cloud_main, 'engine', return_value=FakeEngine(blob)), \
             patch.dict(os.environ, {'DOGREADER_DISABLE_SIGNED_URLS': '1'}, clear=False):
            # Initial request without Range header when signed URLs are disabled:
            # must return 206 bounded to <= 16 MiB (never >32 MiB 200 OK).
            resp1 = self.client.get(f'/dogreader/audio/{self.JOB_ID}', headers=self.HEADERS)
            self.assertEqual(resp1.status_code, 206)
            data1 = resp1.data
            self.assertLessEqual(len(data1), 16 * 1024 * 1024)
            self.assertEqual(len(data1), 16 * 1024 * 1024)
            self.assertEqual(
                resp1.headers.get('Content-Range'),
                f'bytes 0-{16 * 1024 * 1024 - 1}/{size_45mb}',
            )
            self.assertEqual(resp1.headers.get('X-Dogreader-Audio-Sha256'), expected_sha)
            assembled.extend(data1)
            slice_sizes.append(len(data1))
            content_ranges.append(resp1.headers.get('Content-Range'))

            # Subsequent Range requests until complete
            offset = len(assembled)
            while offset < size_45mb:
                headers = {**self.HEADERS, 'Range': f'bytes={offset}-'}
                resp = self.client.get(f'/dogreader/audio/{self.JOB_ID}', headers=headers)
                self.assertEqual(resp.status_code, 206)
                chunk = resp.data
                self.assertGreater(len(chunk), 0)
                self.assertLessEqual(len(chunk), 16 * 1024 * 1024)
                expected_end = min(offset + 16 * 1024 * 1024 - 1, size_45mb - 1)
                self.assertEqual(
                    resp.headers.get('Content-Range'),
                    f'bytes {offset}-{expected_end}/{size_45mb}',
                )
                assembled.extend(chunk)
                slice_sizes.append(len(chunk))
                content_ranges.append(resp.headers.get('Content-Range'))
                offset = len(assembled)

        tmp_after = set(os.listdir(tempfile.gettempdir()))
        self.assertEqual(tmp_after - tmp_before, set())
        self.assertEqual(slice_sizes, [16 * 1024 * 1024, 16 * 1024 * 1024, 13 * 1024 * 1024])
        self.assertEqual(len(assembled), size_45mb)
        self.assertEqual(hashlib.sha256(assembled).hexdigest(), expected_sha)

    def test_416_range_not_satisfiable_on_out_of_bounds_ranges(self):
        payload = b'x' * 10240
        blob = FakeBlob(payload, sha256=hashlib.sha256(payload).hexdigest(), generation=111)
        with patch.object(cloud_main, 'engine', return_value=FakeEngine(blob)):
            for bad_range in ['bytes=10240-', 'bytes=99999-', 'bytes=500-100', 'items=0-5']:
                resp = self.client.get(
                    f'/dogreader/audio/{self.JOB_ID}',
                    headers={**self.HEADERS, 'Range': bad_range},
                )
                self.assertEqual(resp.status_code, 416, msg=f'Failed for {bad_range}')
                self.assertEqual(resp.headers.get('Content-Range'), 'bytes */10240')


if __name__ == '__main__':
    unittest.main(verbosity=2)
