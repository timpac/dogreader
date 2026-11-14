"""Durable narration workflow using the existing bucket and Cloud Tasks queue.

No cloud SDK imports: dependencies are injected so crashes and races can be tested
without credentials or paid synthesis. All mutable job state uses GCS generations.
"""
import hashlib
from contextlib import contextmanager
import io
import json
import logging
import subprocess
import tempfile
import time
import uuid

LOG = logging.getLogger(__name__)
LEASE_SECONDS = 300
DISPATCH_SECONDS = 900
MAX_DISPATCH_SECONDS = 6 * 60 * 60
MAX_FAILURES = 12
MAX_SYNTHESIS_RUNS = 128
MAX_CHUNK_BYTES = 2 * 1024 * 1024
MAX_AUDIO_BYTES = 128 * 1024 * 1024
BATCH_CHUNKS = 8
BATCH_SECONDS = 240


class Conflict(Exception):
    pass


class Missing(Exception):
    pass


class LeaseLost(Exception):
    pass


class InvalidAudio(ValueError):
    pass


class AudioLimit(InvalidAudio):
    pass


class SynthesisLimit(Exception):
    pass


def mp3_seconds(content):
    """Encoded frame timeline used by the copy/remux assembly (including padding)."""
    _, duration = validate_mp3_with_duration(io.BytesIO(content))
    return duration


def event(name, job_id, **fields):
    LOG.info(json.dumps(dict(severity='INFO', event=name, job_id=job_id, **fields), sort_keys=True))


def validate_mp3_with_duration(stream, frames_only=None, max_bytes=None):
    """Check every MPEG Layer III frame and return (size_bytes, duration_seconds) in one pass.

    This checks framing and truncation, not linguistic accuracy or audibility.
    Never scans ahead past corrupt bytes or accepts an empty/tag-only response.
    """
    stream.seek(0, 2)
    size = stream.tell()
    if size > (MAX_AUDIO_BYTES if max_bytes is None else max_bytes):
        raise AudioLimit('Audio exceeds the 128 MiB safety limit')
    if not size:
        raise InvalidAudio('Audio is empty')
    stream.seek(0)
    frames = 0
    duration = 0.0
    while stream.tell() < size:
        pos = stream.tell()
        header = stream.read(4)
        if header[:3] == b'ID3':
            rest = stream.read(6)
            if len(rest) != 6 or header[3] not in (2, 3, 4) or any(x & 128 for x in rest[2:]):
                raise InvalidAudio('Invalid ID3 tag')
            length = sum(x << (7 * (3 - i)) for i, x in enumerate(rest[2:]))
            end = pos + 10 + length + (10 if header[3] == 4 and rest[1] & 16 else 0)
        elif header[:3] == b'TAG' and size - pos == 128:
            end = size
        else:
            if len(header) != 4:
                raise InvalidAudio('Truncated MP3 header')
            h = int.from_bytes(header, 'big')
            version, layer = (h >> 19) & 3, (h >> 17) & 3
            rate, sample = (h >> 12) & 15, (h >> 10) & 3
            if h >> 21 != 0x7ff or version == 1 or layer != 1 or rate in (0, 15) or sample == 3:
                raise InvalidAudio('Invalid MP3 frame')
            rates = ([0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                     if version == 3 else [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
            sample_rate = [44100, 48000, 32000][sample] // {3: 1, 2: 2, 0: 4}[version]
            length = (144000 if version == 3 else 72000) * rates[rate] // sample_rate + ((h >> 9) & 1)
            end = pos + length
            frames += 1
            duration += (1152 if version == 3 else 576) / sample_rate
            if end <= size and frames_only is not None:
                stream.seek(pos)
                frames_only.write(stream.read(length))
        if end > size or end <= pos:
            raise InvalidAudio('Truncated MP3 frame or tag')
        stream.seek(end)
    if not frames:
        raise InvalidAudio('Audio contains no MP3 frames')
    stream.seek(0)
    return size, duration


def validate_mp3(stream, frames_only=None, max_bytes=None):
    """Check every MPEG Layer III frame, including concatenated TTS ID3 tags."""
    size, _ = validate_mp3_with_duration(stream, frames_only=frames_only, max_bytes=max_bytes)
    return size


def decode_mp3(stream, timeout=10):
    stream.seek(0)
    with tempfile.TemporaryFile() as errors:
        try:
            decoded = subprocess.run([
                'ffmpeg', '-nostdin', '-hide_banner', '-v', 'error', '-xerror',
                '-err_detect', 'explode', '-f', 'mp3', '-i', 'pipe:0',
                '-map', '0:a:0', '-f', 'null', '-'], stdin=stream,
                stdout=subprocess.DEVNULL, stderr=errors, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as exc:
            raise InvalidAudio('MP3 decoding exceeded its time limit') from exc
        if decoded.returncode:
            raise InvalidAudio('MP3 failed decoding validation')
    stream.seek(0)


@contextmanager
def finalize_mp3(stream):
    """Remux without re-encoding, then require successful full audio decoding.

    Assembly strips per-chunk ID3 tags first. A single Xing header in this final
    seekable file supplies chapter duration rather than the first chunk duration.
    """
    with tempfile.NamedTemporaryFile(suffix='.mp3') as finished, tempfile.TemporaryFile() as errors:
        stream.seek(0)
        try:
            remux = subprocess.run([
                'ffmpeg', '-nostdin', '-hide_banner', '-v', 'error', '-y',
                '-f', 'mp3', '-i', 'pipe:0', '-map', '0:a:0', '-c:a', 'copy',
                '-write_xing', '1', finished.name], stdin=stream,
                stdout=subprocess.DEVNULL, stderr=errors, timeout=120, check=False)
            # Release tmpfs pages held by the raw frame stream before validation/upload.
            try:
                stream.seek(0)
                stream.truncate(0)
            except Exception:
                pass
            if remux.returncode:
                raise InvalidAudio('MP3 assembly failed')
            validate_mp3(finished)
            decode_mp3(finished, timeout=120)
        except subprocess.TimeoutExpired as exc:
            raise InvalidAudio('MP3 validation exceeded its time limit') from exc
        finished.seek(0)
        yield finished


class Engine:
    def __init__(self, bucket, enqueue, synthesize, split_text, *,
                 conflict=Conflict, missing=Missing, transient=(), clock=time.time,
                 finalizer=finalize_mp3, task_exists=None, job_splitter=None, job_synthesizer=None):
        self.bucket = bucket
        self.enqueue = enqueue
        self.synthesize = synthesize
        self.split_text = split_text
        self.conflict = conflict
        self.missing = missing
        self.transient = transient
        self.clock = clock
        self.finalizer = finalizer
        self.task_exists = task_exists
        self.job_splitter = job_splitter
        self.job_synthesizer = job_synthesizer

    def chunks_for(self, job):
        return self.job_splitter(job) if self.job_splitter else self.split_text(job['text'])

    def read(self, path):
        for _ in range(8):
            blob = self.bucket.blob(path)
            try:
                blob.reload()
                value = json.loads(blob.download_as_text(if_generation_match=blob.generation))
                return value, blob.generation
            except self.missing:
                return None, 0
            except self.conflict:
                continue
        raise Conflict('Object changed repeatedly; retry the request')

    def edit(self, job_id, change):
        path = f'state/{job_id}.json'
        for _ in range(12):
            state, generation = self.read(path)
            if state is None:
                state = self.initial_state(job_id)
            updated = change(dict(state))
            if updated is None:
                return state
            try:
                self.bucket.blob(path).upload_from_string(
                    json.dumps(updated), content_type='application/json', if_generation_match=generation)
                return updated
            except self.conflict:
                continue
        raise Conflict('Job changed repeatedly; retry the request')

    def initial_state(self, job_id):
        if not self.bucket.blob(f'jobs/{job_id}.json').exists():
            raise self.missing('Job not found')
        # Old markers are respected for at most the old worker's 1800s timeout.
        marker = self.bucket.blob(f'running/{job_id}.txt')
        until = 0
        try:
            until = int(marker.download_as_text()) + 1800
        except (self.missing, ValueError):
            pass
        failed = (self.bucket.blob(f'errors/{job_id}.txt').exists() and
                  not self.bucket.blob(f'retry-claims/{job_id}.txt').exists())
        state = dict(status='error' if failed else 'queued', failures=0,
                     recoveries=0, sequence=0, last_dispatch=0, progress=0)
        if failed:
            state['error'] = 'Previous narration failed. Retry to resume generation.'
        if until > self.clock():
            state.update(status='generating', owner='legacy', lease_until=until)
        return state

    def ready(self, job_id, *, require_timing=True):
        blob = self.bucket.blob(f'audio/{job_id}.mp3')
        try:
            blob.reload()
            generation = blob.generation
            metadata = blob.metadata or {}
            if not blob.size or (blob.size > MAX_AUDIO_BYTES and metadata.get('schema') == '1'):
                return None
            proof, _ = self.read(f'verified/{job_id}.json')
            if not proof or str(proof.get('generation')) != str(generation) or proof.get('size') != blob.size:
                # Validate legacy files once without modifying or regenerating them.
                # New uploads carry completion metadata written atomically with bytes.
                if metadata.get('schema') == '1':
                    job, _ = self.read(f'jobs/{job_id}.json')
                    if (metadata.get('job_id') != job_id or
                            not str(metadata.get('chunks', '')).isdigit() or
                            int(metadata['chunks']) < 1 or
                            (job and metadata.get('chunks') != str(len(self.chunks_for(job))))):
                        return None
                legacy_large = blob.size > MAX_AUDIO_BYTES
                reader = (blob.open('rb', chunk_size=256 * 1024, if_generation_match=generation)
                          if legacy_large else tempfile.TemporaryFile())
                with reader as stream:
                    if not legacy_large:
                        blob.download_to_file(stream, if_generation_match=generation)
                    size = validate_mp3(stream, max_bytes=blob.size)
                    if metadata.get('schema') == '1':
                        digest = hashlib.sha256()
                        while block := stream.read(64 * 1024):
                            digest.update(block)
                        if digest.hexdigest() != metadata.get('sha256'):
                            return None
                self.bucket.blob(f'verified/{job_id}.json').upload_from_string(
                    json.dumps(dict(generation=str(generation), size=size,
                                    validation='complete' if metadata.get('schema') == '1' else 'legacy-frames')),
                    content_type='application/json')
                event('audio_verified', job_id, generation=str(generation), bytes=size,
                      legacy=metadata.get('schema') != '1')
            job, _ = self.read(f'jobs/{job_id}.json')
            if require_timing and job and job.get('engine') == 'kokoro':
                report, _ = self.read(f'timing/{job_id}.json')
                if (not report or report.get('audio_sha256') != metadata.get('sha256') or
                        report.get('characters') != len(job['text'])):
                    return None
            # Prove the pinned object is readable, including on cache hits.
            blob.download_as_bytes(start=0, end=3, if_generation_match=generation)
            return blob
        except (self.missing, self.conflict, InvalidAudio):
            return None

    def completed(self, job_id):
        """Reconcile verified published bytes without dispatch or synthesis.

        Timing metadata may be repaired separately; losing it must never cause
        successfully published narration to be synthesized again.
        """
        blob = self.ready(job_id, require_timing=False)
        if blob is None:
            return None
        # Audio can outlive its job record. It remains directly downloadable.
        if self.bucket.blob(f'jobs/{job_id}.json').exists():
            repaired = []
            def finish(state):
                if state['status'] == 'ready' and not state.get('owner'):
                    return None
                repaired.append(True)
                state.update(status='ready', owner=None, lease_until=0,
                             pending=False, error=None)
                return state
            try:
                self.edit(job_id, finish)
                if repaired:
                    event('job_ready_reconciled', job_id, generation=str(blob.generation))
            except Exception as exc:
                event('ready_state_repair_failed', job_id, error_type=type(exc).__name__)
        return blob

    def dispatch(self, job_id):
        now = self.clock()
        observations = {}

        def reserve(state):
            # Repair states produced by the earlier dispatch-only budget. Do not
            # revive real generation failures or reset their paid-work budgets.
            revived = (state['status'] == 'error' and
                    state.get('error') == 'Recovery limit reached. Retry to resume saved chunks.' and
                    state.get('failures', 0) < MAX_FAILURES)
            if revived:
                state.update(status='queued')
                state.pop('error', None)
            if state['status'] == 'error':
                return None
            if state['status'] == 'ready':
                if self.ready(job_id):
                    return state if revived else None
                state.update(status='error', error='Completed audio is missing or invalid. Retry to rebuild from saved chunks.')
                return state
            if state.get('lease_until', 0) > now:
                return state if revived else None
            if (state['sequence'] and not state.get('pending') and
                    now < state.get('next_dispatch', state['last_dispatch'] + DISPATCH_SECONDS)):
                return state if revived else None
            if not state.get('pending'):
                sequence = state['sequence']
                if sequence and sequence not in observations:
                    observations[sequence] = (self.task_exists(job_id, sequence)
                                              if self.task_exists else None)
                present = observations.get(sequence)
                if present is True:
                    # Paused/backlogged tasks are healthy waiting work. Expiring
                    # a worker lease is not evidence that its task disappeared.
                    state.update(status='queued', owner=None, lease_until=0,
                                 next_dispatch=now + DISPATCH_SECONDS)
                    return state
                delay = DISPATCH_SECONDS
                if sequence and present is None:
                    # No read permission (or older caller): bound duplicate
                    # delivery creation without putting an age limit on the job.
                    delay = min(MAX_DISPATCH_SECONDS,
                                state.get('dispatch_delay', DISPATCH_SECONDS) * 2)
                state['sequence'] += 1
                if sequence:
                    state['recoveries'] += 1
                state.update(dispatch_delay=delay, next_dispatch=now + delay)
            state.update(status='queued', pending=True, lease_until=0)
            return state

        state = self.edit(job_id, reserve)
        if state.get('pending') and state['status'] == 'queued':
            sequence = state['sequence']
            self.enqueue(job_id, sequence)

            def accepted(current):
                if current['sequence'] != sequence or not current.get('pending'):
                    return None
                current.update(pending=False, last_dispatch=now)
                return current

            state = self.edit(job_id, accepted)
            event('job_dispatched', job_id, sequence=sequence)
        return state

    def retry(self, job_id):
        def reset(state):
            if state['status'] not in ('error', 'ready'):
                return None
            state.update(status='queued', failures=0, recoveries=0, runs=0, last_dispatch=0,
                         synthesis_runs=0, next_dispatch=0, dispatch_delay=DISPATCH_SECONDS,
                         pending=False, lease_until=0)
            state.pop('error', None)
            return state
        self.edit(job_id, reset)
        return self.dispatch(job_id)

    def owned(self, job_id, token, **fields):
        def update(state):
            if state.get('owner') != token or state.get('lease_until', 0) <= self.clock():
                raise LeaseLost('Worker lease expired or was replaced')
            state.update(fields)
            return state
        state = self.edit(job_id, update)
        if fields.get('lease_until', 0) and state['lease_until'] <= self.clock():
            raise LeaseLost('Lease renewal did not complete before expiry')
        return state

    def checkpoint(self, job_id, token, completed, total, *, rewind=False):
        """Persist batch progress under lease, enqueue the continuation task, and return 200."""
        sequences = []

        def prepare(state):
            now = self.clock()
            if state.get('owner') != token or state.get('lease_until', 0) <= now:
                raise LeaseLost('Worker lease expired or was replaced')
            next_sequence = state.get('sequence', 0) + 1
            sequences.append(next_sequence)
            progress = completed if rewind else max(state.get('progress', 0), completed)
            state.update(
                status='queued',
                owner=None,
                lease_until=0,
                pending=True,
                sequence=next_sequence,
                progress=progress,
                chunks=total,
                dispatch_delay=DISPATCH_SECONDS,
                next_dispatch=now + DISPATCH_SECONDS,
            )
            return state

        self.edit(job_id, prepare)
        sequence = sequences[-1]
        try:
            self.enqueue(job_id, sequence)
        except Exception as exc:
            event('checkpoint_enqueue_failed', job_id, sequence=sequence,
                  error_type=type(exc).__name__)
            return 'queued', 503
        dispatched_at = self.clock()

        def accepted(current):
            if current.get('sequence') != sequence or not current.get('pending'):
                return None
            current.update(pending=False, last_dispatch=dispatched_at)
            return current

        self.edit(job_id, accepted)
        event('batch_checkpoint', job_id, completed=completed, total=total, sequence=sequence)
        return 'queued', 200

    def _synthesize_chunk(self, job_id, owner, state, job, index, text, total_chunks, part, expected, reserved):
        """Synthesize, validate once in memory, and upload a single chunk under lease."""
        if not reserved[0]:
            synthesis_runs = state.get('synthesis_runs', 0)
            if synthesis_runs >= (max(MAX_SYNTHESIS_RUNS, total_chunks + MAX_FAILURES)
                                  if job.get('engine') == 'kokoro' else MAX_SYNTHESIS_RUNS):
                raise SynthesisLimit('Automatic synthesis attempt limit reached')
            state = self.owned(job_id, owner, synthesis_runs=synthesis_runs + 1,
                               lease_until=self.clock() + LEASE_SECONDS)
            reserved[0] = True
        elif state.get('lease_until', 0) - self.clock() < LEASE_SECONDS * 2 // 3:
            state = self.owned(job_id, owner, lease_until=self.clock() + LEASE_SECONDS)

        started = time.monotonic()
        generated = (self.job_synthesizer(text, job, job_id, index)
                     if self.job_synthesizer else
                     self.synthesize(text, job['voice'], job_id, index))
        metrics = {}
        if isinstance(generated, tuple):
            content, metrics = generated
        else:
            content = generated
        metrics = dict(metrics)
        metrics['generation_seconds'] = time.monotonic() - started
        if not content or len(content) > MAX_CHUNK_BYTES:
            raise InvalidAudio('TTS returned empty or oversized audio')
        _, duration = validate_mp3_with_duration(io.BytesIO(content), max_bytes=MAX_CHUNK_BYTES)
        metrics['duration_seconds'] = duration
        if state.get('lease_until', 0) - self.clock() < LEASE_SECONDS * 2 // 3:
            state = self.owned(job_id, owner, lease_until=self.clock() + LEASE_SECONDS)
        part.metadata = dict(text_sha256=expected, validation='decoded-v1',
                             audio_sha256=hashlib.sha256(content).hexdigest(),
                             **{key: str(value) for key, value in metrics.items()})
        # A stale worker cannot overwrite a newer worker's checkpoint.
        part.upload_from_string(content, content_type='audio/mpeg',
                                if_generation_match=part.generation or 0)
        state = self.owned(job_id, owner, progress=index + 1, chunks=total_chunks,
                           lease_until=self.clock() + LEASE_SECONDS,
                           dispatch_delay=DISPATCH_SECONDS,
                           next_dispatch=self.clock() + DISPATCH_SECONDS)
        return content, state

    def process(self, job_id):
        if self.completed(job_id):
            return 'ready', 200
        owner = uuid.uuid4().hex
        now = self.clock()

        def acquire(state):
            if state['status'] == 'error' or state.get('lease_until', 0) > now:
                return None
            state.update(status='generating', owner=owner, lease_until=now + LEASE_SECONDS,
                         last_dispatch=now, pending=False, runs=state.get('runs', 0) + 1,
                         dispatch_delay=DISPATCH_SECONDS, next_dispatch=now + DISPATCH_SECONDS)
            return state

        state = self.edit(job_id, acquire)
        if state['status'] == 'error':
            return 'error', 200
        if state.get('owner') != owner:
            return 'generating', 503  # never acknowledge the only surviving delivery
        event('worker_started', job_id, owner=owner, failures=state['failures'])
        try:
            job, _ = self.read(f'jobs/{job_id}.json')
            chunks = self.chunks_for(job)
            if not chunks:
                raise ValueError('Chapter contains no narratable text')
            total_chunks = len(chunks)
            made = 0
            reserved = [False]

            # Stage 1: Resume directly from durable progress without downloading prior chunks.
            start_index = max(0, min(int(state.get('progress', 0)), total_chunks))
            for index in range(start_index, total_chunks):
                if state.get('lease_until', 0) - self.clock() < LEASE_SECONDS * 2 // 3:
                    state = self.owned(job_id, owner, lease_until=self.clock() + LEASE_SECONDS)
                text = chunks[index]
                path = f'chunks/{job_id}/v1/{index:04d}.mp3'
                part = self.bucket.blob(path)
                expected = hashlib.sha256(text.encode()).hexdigest()
                cached_valid = False
                try:
                    part.reload()
                    meta = part.metadata or {}
                    if (part.size and part.size <= MAX_CHUNK_BYTES and
                            meta.get('text_sha256') == expected and
                            meta.get('validation') == 'decoded-v1' and
                            meta.get('audio_sha256')):
                        cached_valid = True
                except self.missing:
                    pass
                if cached_valid:
                    if index == total_chunks - 1 and state.get('progress', 0) < total_chunks:
                        state = self.owned(job_id, owner, progress=total_chunks, chunks=total_chunks,
                                           lease_until=self.clock() + LEASE_SECONDS,
                                           dispatch_delay=DISPATCH_SECONDS,
                                           next_dispatch=self.clock() + DISPATCH_SECONDS)
                    continue
                if made >= BATCH_CHUNKS or self.clock() - now >= BATCH_SECONDS:
                    return self.checkpoint(job_id, owner, index, total_chunks)
                _, state = self._synthesize_chunk(
                    job_id, owner, state, job, index, text, total_chunks, part, expected, reserved)
                made += 1

            if self.clock() - now >= BATCH_SECONDS:
                return self.checkpoint(job_id, owner, total_chunks, total_chunks)

            # Stage 2: Single final-assembly pass once all chunks are complete.
            total_bytes = 0
            digest = hashlib.sha256()
            timings = []
            text_offset = 0
            audio_offset = 0.0
            generation_seconds = 0.0
            cpu_seconds = 0.0
            peak_rss_kib = 0
            with tempfile.TemporaryFile() as combined:
                for index, text in enumerate(chunks):
                    if state.get('lease_until', 0) - self.clock() < LEASE_SECONDS * 2 // 3:
                        state = self.owned(job_id, owner, lease_until=self.clock() + LEASE_SECONDS)
                    path = f'chunks/{job_id}/v1/{index:04d}.mp3'
                    part = self.bucket.blob(path)
                    expected = hashlib.sha256(text.encode()).hexdigest()
                    content = None
                    duration = None
                    try:
                        part.reload()
                        meta = part.metadata or {}
                        if (part.size and part.size <= MAX_CHUNK_BYTES and
                                meta.get('text_sha256') == expected and
                                meta.get('validation') == 'decoded-v1'):
                            content = part.download_as_bytes(if_generation_match=part.generation)
                            if hashlib.sha256(content).hexdigest() != meta.get('audio_sha256'):
                                raise InvalidAudio('Checkpoint digest does not match its audio')
                            _, duration = validate_mp3_with_duration(
                                io.BytesIO(content), frames_only=combined, max_bytes=MAX_CHUNK_BYTES)
                    except self.missing:
                        content = None
                    except InvalidAudio:
                        content = None
                    if content is None:
                        # Self-healing recovery if an earlier chunk was deleted or corrupted.
                        if made >= BATCH_CHUNKS or self.clock() - now >= BATCH_SECONDS:
                            return self.checkpoint(job_id, owner, index, total_chunks, rewind=True)
                        content, state = self._synthesize_chunk(
                            job_id, owner, state, job, index, text, total_chunks, part, expected, reserved)
                        made += 1
                        _, duration = validate_mp3_with_duration(
                            io.BytesIO(content), frames_only=combined, max_bytes=MAX_CHUNK_BYTES)
                    if job.get('engine') == 'kokoro':
                        timings.append(dict(text_start=text_offset, text_end=text_offset + len(text),
                                            audio_start=audio_offset, audio_end=audio_offset + duration))
                        text_offset += len(text)
                        audio_offset += duration
                        generation_seconds += float((part.metadata or {}).get('generation_seconds', 0))
                        cpu_seconds += float((part.metadata or {}).get('cpu_seconds', 0))
                        peak_rss_kib = max(peak_rss_kib, int((part.metadata or {}).get('peak_rss_kib', 0)))
                    total_bytes += len(content)
                    del content
                    if total_bytes > MAX_AUDIO_BYTES:
                        raise AudioLimit('Chapter audio exceeds the 128 MiB safety limit')

                state = self.owned(job_id, owner, lease_until=self.clock() + LEASE_SECONDS)
                with self.finalizer(combined) as finished:
                    size = validate_mp3(finished)
                    while block := finished.read(64 * 1024):
                        digest.update(block)
                    finished.seek(0)
                    state = self.owned(job_id, owner, lease_until=self.clock() + LEASE_SECONDS)
                    audio_sha256 = digest.hexdigest()
                    if job.get('engine') == 'kokoro':
                        if text_offset != len(job['text']):
                            raise InvalidAudio('Text coverage validation failed')
                        report = dict(audio_sha256=audio_sha256, engine='kokoro', model_version=job['model_version'],
                                      voice=job['voice'], settings=job['settings'],
                                      audio_seconds=audio_offset, generation_seconds=generation_seconds,
                                      cpu_seconds=cpu_seconds, peak_rss_kib=peak_rss_kib,
                                      characters=text_offset, chunks=total_chunks, timings=timings)
                        self.bucket.blob(f'timing/{job_id}.json').upload_from_string(
                            json.dumps(report), content_type='application/json')
                        event('kokoro_measurements', job_id, **{k: v for k, v in report.items() if k != 'timings'})
                    result = self.bucket.blob(f'audio/{job_id}.mp3')
                    try:
                        result.reload()
                        generation = result.generation
                    except self.missing:
                        generation = 0
                    # Concurrent valid publication wins; CAS rejects later changes.
                    if not self.ready(job_id):
                        result.metadata = dict(schema='1', job_id=job_id, chunks=str(total_chunks),
                                               sha256=audio_sha256)
                        result.upload_from_file(finished, size=size, content_type='audio/mpeg',
                                                if_generation_match=generation)
                        try:
                            finished.seek(0)
                            finished.truncate(0)
                        except Exception:
                            pass
                        # Persist proof immediately for the validated upload so ready() does not
                        # re-download the entire chapter MP3 back into /tmp.
                        if result.generation:
                            self.bucket.blob(f'verified/{job_id}.json').upload_from_string(
                                json.dumps(dict(generation=str(result.generation), size=size,
                                                validation='complete')),
                                content_type='application/json')
                            event('audio_verified', job_id, generation=str(result.generation),
                                  bytes=size, legacy=False)
            if not self.ready(job_id):
                raise InvalidAudio('Uploaded chapter could not be verified')
            self.owned(job_id, owner, status='ready', progress=total_chunks, chunks=total_chunks,
                       lease_until=0, owner=None, error=None)
            event('job_ready', job_id, chunks=total_chunks, bytes=size)
            return 'ready', 200
        except LeaseLost:
            event('worker_fenced', job_id, owner=owner)
            return 'queued', 503
        except Exception as exc:
            failures = state['failures'] + 1
            retryable = (not isinstance(exc, AudioLimit) and
                         isinstance(exc, self.transient + (self.conflict, Conflict)))
            terminal = not retryable or failures >= MAX_FAILURES
            reason = {
                'PermissionDenied': 'Service account cannot access a required service. Check existing permissions.',
                'Unauthenticated': 'Cloud service authentication failed. Check runtime credentials.',
                'InvalidArgument': 'TTS rejected the chapter text or voice configuration.',
                'NotFound': 'A required job or cloud object was not found.',
                'InvalidAudio': 'TTS audio is empty, malformed or exceeds the audio size limit.',
                'AudioLimit': 'Chapter audio exceeds the 128 MiB safety limit. Choose a shorter chapter.',
                'KokoroUnavailable': 'Kokoro CPU worker failed; saved chunks will resume. No engine or voice was changed.',
                'NarrationConfiguration': 'Requested narration engine, model or voice is unavailable. No fallback was used.',
                'SynthesisLimit': 'Automatic synthesis attempt limit reached. Retry to resume saved chunks.',
            }.get(type(exc).__name__, 'Check service configuration and chapter audio limits.')
            message = ('Temporary service failure; retry budget exhausted. Retry to resume saved chunks.'
                       if retryable and terminal else 'Temporary service failure; saved chunks will be resumed.'
                       if retryable else f'Narration failed ({type(exc).__name__}). {reason}')
            try:
                self.owned(job_id, owner, status='error' if terminal else 'queued',
                           failures=failures, error=message, lease_until=0, owner=None)
            except LeaseLost:
                return 'queued', 503
            # Provider exception strings may echo chapter text; log safe context.
            LOG.error(json.dumps(dict(severity='ERROR', event='worker_failed', job_id=job_id,
                                      error_type=type(exc).__name__, failures=failures,
                                      progress=locals().get('index', 0), retryable=retryable)))
            return ('error', 200) if terminal else ('queued', 503)

