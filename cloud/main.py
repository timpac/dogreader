"""Dogreader cloud narration bridge. Private jobs, Cloud Tasks, GCS, Google TTS."""
import datetime
import hashlib
import hmac
import json
import os
import re
import random
import tempfile
import logging
import time
from flask import Flask, jsonify, request, Response
from google.cloud import storage, tasks_v2, texttospeech
from google.api_core.exceptions import (ServiceUnavailable, DeadlineExceeded, TooManyRequests,
    InternalServerError, BadGateway, GatewayTimeout, PreconditionFailed, NotFound, AlreadyExists)
from google.api_core.exceptions import PermissionDenied
from google.api_core.retry import Retry
from reliability import Engine, InvalidAudio, event, validate_mp3, decode_mp3, MAX_AUDIO_BYTES
from narration import (configuration, stored_configuration, recording_id, legacy_id,
    split_kokoro, KOKORO, KOKORO_VOICES, NarrationConfiguration)
from kokoro_worker import worker as kokoro, KokoroUnavailable
import google.auth
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format='%(message)s')
logging.getLogger('reliability').setLevel(logging.INFO)
PROJECT = os.environ.get('GOOGLE_CLOUD_PROJECT', 'pg-wodehouse')
REGION = os.environ.get('DOGREADER_REGION', 'us-central1')
BUCKET = os.environ.get('DOGREADER_BUCKET', 'pg-wodehouse-dogreader-audio')
QUEUE = os.environ.get('DOGREADER_QUEUE', 'dogreader-narration')
WORKER_SA = os.environ.get('DOGREADER_WORKER_SA', f'dogreader-worker@{PROJECT}.iam.gserviceaccount.com')
SIGNER_SA = os.environ.get('DOGREADER_SIGNER_SA', '')
SIGNED_URL_SECONDS = int(os.environ.get('DOGREADER_SIGNED_URL_SECONDS', '900'))
# Cloud Run enforces a 32 MiB HTTP/1.1 buffered response cap; bound fallback slices to 16 MiB.
DIRECT_SLICE_BYTES = 16 * 1024 * 1024
VOICE = os.environ.get('DOGREADER_VOICE', 'en-US-Chirp3-HD-Achernar')
AVAILABLE_VOICES = {
    'en-US-Chirp3-HD-Achernar',
    'en-US-Chirp3-HD-Charon',
    'en-US-Chirp3-HD-Kore',
    'en-US-Chirp3-HD-Puck',
}
BASE_URL = os.environ.get('DOGREADER_URL', '').rstrip('/')
API_TOKEN = os.environ.get('DOGREADER_TOKEN', '')
store = None
TRANSIENT = (ServiceUnavailable, DeadlineExceeded, TooManyRequests,
             InternalServerError, BadGateway, GatewayTimeout)
# 250k supplementary characters can occupy 3 MB as JSON surrogate escapes.
app.config['MAX_CONTENT_LENGTH'] = 4 * 1024 * 1024


def split_text(text, max_bytes=3800):
    """Retains original Dogreader audiobook factory's splitting algorithm."""
    paragraphs = re.split(r'\n\s*\n', text)
    chunks = []
    buffer = ''
    for paragraph in paragraphs:
        sentences = re.split(r'(?<=[.!?])\s+', paragraph.strip())
        for sentence in sentences:
            if not sentence:
                continue
            while len(sentence.encode('utf-8')) > max_bytes:
                part = sentence[:max_bytes // 4]
                while len(part.encode('utf-8')) > max_bytes:
                    part = part[:-1]
                if buffer:
                    chunks.append(buffer)
                    buffer = ''
                chunks.append(part)
                sentence = sentence[len(part):]
            candidate = (buffer + ' ' + sentence).strip()
            if len(candidate.encode('utf-8')) > max_bytes and buffer:
                chunks.append(buffer)
                buffer = sentence
            else:
                buffer = candidate
    if buffer:
        chunks.append(buffer)
    return chunks


def bucket():
    global store
    if store is None:
        store = storage.Client()
    return store.bucket(BUCKET)


def authorized():
    given = request.headers.get('X-Dogreader-Token', '')
    return bool(API_TOKEN and hmac.compare_digest(given, API_TOKEN))


def auth_error():
    return jsonify(error='Invalid Dogreader access token'), 401


def task_authorized():
    header = request.headers.get('Authorization', '')
    if not header.startswith('Bearer ') or not BASE_URL:
        return False
    try:
        claims = id_token.verify_oauth2_token(header[7:], google_requests.Request(), audience=BASE_URL)
        return claims.get('email') == WORKER_SA and claims.get('email_verified') is True
    except Exception:
        return False


@app.get('/health')
def health():
    return jsonify(ok=True, service='dogreader')


@app.get('/dogreader/ping')
def ping():
    if not authorized():
        return auth_error()
    return jsonify(ok=True, voice=VOICE)


def enqueue(job_id, sequence):
    if not BASE_URL:
        raise ValueError('DOGREADER_URL is not configured')
    with tasks_v2.CloudTasksClient() as tasks:
        parent = tasks.queue_path(PROJECT, REGION, QUEUE)
        # A persisted sequence makes concurrent/ambiguous enqueue attempts idempotent.
        name = f'{parent}/tasks/{job_id}-{sequence}'
        try:
            tasks.create_task(request={
                'parent': parent,
                'task': {
                    'name': name,
                    'dispatch_deadline': {'seconds': 600},
                    'http_request': {
                        'http_method': tasks_v2.HttpMethod.POST,
                        'url': BASE_URL + '/internal/process/' + job_id,
                        'oidc_token': {'service_account_email': WORKER_SA, 'audience': BASE_URL},
                        'headers': {'Content-Type': 'application/json'},
                        'body': b'{}',
                    },
                },
            }, retry=Retry(deadline=10), timeout=10)
        except AlreadyExists:
            pass  # The same dispatch was already accepted, possibly before a timeout.


def task_exists(job_id, sequence):
    """Optional BASIC lookup; never require a new IAM grant for recovery."""
    with tasks_v2.CloudTasksClient() as tasks:
        parent = tasks.queue_path(PROJECT, REGION, QUEUE)
        try:
            tasks.get_task(request={'name': f'{parent}/tasks/{job_id}-{sequence}'},
                           retry=Retry(deadline=5), timeout=5)
        except NotFound:
            return False
        except PermissionDenied:
            # Enqueuer-only identities still recover through bounded backoff.
            event('task_lookup_unavailable', job_id, reason='permission_denied')
            return None
    return True


def synthesize_with_retry(client, synthesis_input, voice, audio_config, job_id='', index=0):
    for attempt in range(3):
        try:
            response = client.synthesize_speech(
                input=synthesis_input, voice=voice, audio_config=audio_config,
                retry=None, timeout=60)  # disable the SDK's independent retry loop
            if not response.audio_content or len(response.audio_content) > 2 * 1024 * 1024:
                raise InvalidAudio('TTS returned empty or oversized audio')
            with tempfile.TemporaryFile() as stream:
                stream.write(response.audio_content)
                validate_mp3(stream)
                decode_mp3(stream)
            return response
        except TRANSIENT + (InvalidAudio,) as exc:
            if attempt == 2:
                raise
            delay = random.uniform(1, min(30, 2 ** (attempt + 2)))
            event('tts_retry', job_id, chunk=index, attempt=attempt + 1,
                  error_type=type(exc).__name__, delay_seconds=round(delay, 2))
            time.sleep(delay)


def synthesize(text, voice_name, job_id, index):
    with texttospeech.TextToSpeechClient() as client:
        return synthesize_with_retry(
            client,
            texttospeech.SynthesisInput(text=text),
            texttospeech.VoiceSelectionParams(language_code=voice_name[:5], name=voice_name),
            texttospeech.AudioConfig(audio_encoding=texttospeech.AudioEncoding.MP3),
            job_id, index).audio_content


def split_job(job):
    config = stored_configuration(job)
    return split_kokoro(job['text']) if config['engine'] == KOKORO else split_text(job['text'])


def synthesize_job(text, job, job_id, index):
    config = stored_configuration(job)
    if config['engine'] == KOKORO:
        if os.environ.get('DOGREADER_KOKORO_ENABLED') != '1':
            raise NarrationConfiguration('Kokoro is not enabled on this server')
        return kokoro.synthesize(text, config['voice'])
    return synthesize(text, config['voice'], job_id, index)


def engine():
    return Engine(bucket(), enqueue, synthesize, split_text,
                  conflict=PreconditionFailed, missing=NotFound,
                  transient=TRANSIENT + (InvalidAudio, KokoroUnavailable), task_exists=task_exists,
                  job_splitter=split_job, job_synthesizer=synthesize_job)


def valid_id(job_id):
    return re.fullmatch(r'[0-9a-f]{32}', job_id) is not None


def job_response(job_id, state):
    # Preserve the Android app's existing status vocabulary; extra fields are optional.
    fields = {key: state[key] for key in ('error', 'progress', 'chunks', 'failures') if state.get(key) is not None}
    job, _ = engine().read(f'jobs/{job_id}.json')
    metadata = stored_configuration(job) if job else {}
    return jsonify(id=job_id, status=state['status'], **metadata, **fields)


@app.errorhandler(Exception)
def service_error(exc):
    from werkzeug.exceptions import HTTPException
    if isinstance(exc, HTTPException):
        return jsonify(error=exc.description), exc.code
    if isinstance(exc, NotFound):
        return jsonify(error='Job not found'), 404
    event('request_failed', (request.view_args or {}).get('job_id', ''),
          error_type=type(exc).__name__, endpoint=request.endpoint)
    return jsonify(error='Narration service temporarily unavailable. Retry the request.'), 503


@app.post('/dogreader/jobs')
def submit():
    if not authorized():
        return auth_error()
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify(error='Expected a JSON object'), 400
    chapter = data.get('text')
    title = data.get('title', 'Chapter')
    if not isinstance(chapter, str) or not 100 <= len(chapter) <= 250000:
        return jsonify(error='Chapter must contain 100–250,000 characters'), 400
    if not split_text(chapter):
        return jsonify(error='Chapter contains no narratable text'), 400
    if not isinstance(title, str):
        title = 'Chapter'
    try:
        config = configuration(data, VOICE)
    except NarrationConfiguration as exc:
        return jsonify(error=str(exc)), 400
    if config['engine'] == KOKORO and os.environ.get('DOGREADER_KOKORO_ENABLED') != '1':
        return jsonify(error='Kokoro is not enabled on this server'), 503
    job_id = recording_id(chapter, config)
    workflow = engine()
    # Reuse an existing legacy Google recording/job byte-for-byte. All new jobs
    # use the complete identity, even when submitted by an old Android client.
    if config['engine'] == 'google':
        old_id = legacy_id(chapter, config['voice'])
        if bucket().blob(f'jobs/{old_id}.json').exists() or workflow.ready(old_id):
            job_id = old_id
    if workflow.completed(job_id):
        return job_response(job_id, {'status': 'ready'}), 200
    payload = dict(text=chapter, title=title[:150], created=int(time.time()), **config)
    created = False
    try:
        bucket().blob(f'jobs/{job_id}.json').upload_from_string(
            json.dumps(payload), content_type='application/json', if_generation_match=0)
        created = True
    except PreconditionFailed:
        pass
    # Current Android retries a failed chapter by submitting its text again.
    # Treat that explicit action like /retry; polling never resets budgets.
    existing = workflow.edit(job_id, lambda current: None)
    state = (workflow.retry(job_id) if existing['status'] in ('error', 'ready')
             else workflow.dispatch(job_id))
    event('job_submitted', job_id, created=created, characters=len(chapter), status=state['status'])
    return job_response(job_id, state), 202 if created else 200


@app.get('/dogreader/jobs/<job_id>')
def status(job_id):
    if not authorized():
        return auth_error()
    if not valid_id(job_id):
        return jsonify(error='Invalid job id'), 400
    workflow = engine()
    if workflow.completed(job_id):
        return job_response(job_id, {'status': 'ready'})
    state = workflow.dispatch(job_id)  # recover missing dispatches and expired leases
    return job_response(job_id, state)


def signed_audio_url(blob, job_id):
    """Generate a short-lived V4 signed GCS URL so large MP3s bypass the Cloud Run 32 MiB proxy limit."""
    if os.environ.get('DOGREADER_DISABLE_SIGNED_URLS') == '1':
        return None
    params = dict(
        version='v4',
        expiration=datetime.timedelta(seconds=SIGNED_URL_SECONDS),
        method='GET',
        generation=blob.generation,
        response_disposition=f'attachment; filename="{job_id}.mp3"',
        response_type='audio/mpeg',
    )
    try:
        return blob.generate_signed_url(**params)
    except Exception:
        pass
    try:
        credentials, _ = google.auth.default(scopes=['https://www.googleapis.com/auth/cloud-platform'])
        if not credentials.valid or not credentials.token:
            credentials.refresh(google_requests.Request())
        signer = SIGNER_SA or getattr(credentials, 'service_account_email', None) or WORKER_SA
        if signer and signer != 'default' and credentials.token:
            return blob.generate_signed_url(
                service_account_email=signer,
                access_token=credentials.token,
                **params)
    except Exception as exc:
        event('signed_url_unavailable', job_id, error_type=type(exc).__name__)
    return None


def parse_byte_range(header, total_size):
    """Parse an HTTP Range header and bound the slice to DIRECT_SLICE_BYTES."""
    if not header:
        return None
    match = re.fullmatch(r'bytes=(\d+)-(\d*)', header.strip())
    if not match:
        return 'invalid'
    start = int(match.group(1))
    end = int(match.group(2)) if match.group(2) else total_size - 1
    if start >= total_size or start > end:
        return 'invalid'
    end = min(end, start + DIRECT_SLICE_BYTES - 1, total_size - 1)
    return start, end


@app.get('/dogreader/audio/<job_id>')
def audio(job_id):
    if not authorized():
        return auth_error()
    if not valid_id(job_id):
        return jsonify(error='Invalid job id'), 400
    blob = engine().completed(job_id)
    if blob is None:
        return jsonify(error='Audio not ready'), 404
    metadata = blob.metadata or {}
    sha256 = metadata.get('sha256', '')
    common_headers = {
        'Cache-Control': 'private, no-store',
        'Accept-Ranges': 'bytes',
        'X-Dogreader-Audio-Bytes': str(blob.size),
        'X-Dogreader-Audio-Generation': str(blob.generation),
    }
    if sha256:
        common_headers['X-Dogreader-Audio-Sha256'] = sha256

    range_header = request.headers.get('Range')
    if not range_header and request.args.get('direct') != '0':
        signed = signed_audio_url(blob, job_id)
        if signed:
            event('audio_download_redirect', job_id, bytes=blob.size,
                  generation=str(blob.generation))
            return Response('', status=302, headers={
                **common_headers,
                'Location': signed,
            })

    parsed_range = parse_byte_range(range_header, blob.size)
    if parsed_range == 'invalid':
        return Response('', status=416, headers={
            **common_headers,
            'Content-Range': f'bytes */{blob.size}',
        })
    if parsed_range is not None:
        start, end = parsed_range
        status = 206
    elif blob.size > DIRECT_SLICE_BYTES:
        # Never emit a non-chunked HTTP/1.1 response >32 MiB through Cloud Run.
        start, end = 0, DIRECT_SLICE_BYTES - 1
        status = 206
    else:
        start, end = 0, blob.size - 1
        status = 200

    length = end - start + 1
    stream = blob.open('rb', chunk_size=4 * 1024 * 1024, if_generation_match=blob.generation)
    prefix = b''
    try:
        if start > 0:
            stream.seek(start)
        prefix = stream.read(min(64 * 1024, length))
    except Exception:
        stream.close()
        raise

    def body():
        sent = 0
        try:
            if prefix:
                sent += len(prefix)
                yield prefix
            while sent < length:
                block = stream.read(min(64 * 1024, length - sent))
                if not block:
                    break
                sent += len(block)
                yield block
            event('audio_download_complete', job_id, bytes=sent,
                  start=start, end=end, total=blob.size,
                  generation=str(blob.generation))
        except GeneratorExit:
            event('audio_download_disconnected', job_id, bytes=sent, start=start)
            raise
        except Exception as exc:
            event('audio_download_failed', job_id, bytes=sent, start=start,
                  error_type=type(exc).__name__)
            raise
        finally:
            stream.close()

    event('audio_download_started', job_id, bytes=length, start=start, end=end,
          total=blob.size, generation=str(blob.generation))
    headers = {
        **common_headers,
        'Content-Disposition': f'attachment; filename="{job_id}.mp3"',
        'Content-Length': str(length),
    }
    if status == 206:
        headers['Content-Range'] = f'bytes {start}-{end}/{blob.size}'
    response = Response(body(), status=status, mimetype='audio/mpeg', headers=headers)
    response.call_on_close(stream.close)
    return response


@app.get('/dogreader/jobs/<job_id>/timing')
def timing(job_id):
    if not authorized():
        return auth_error()
    if not valid_id(job_id):
        return jsonify(error='Invalid job id'), 400
    if not engine().ready(job_id):
        return jsonify(error='Audio not ready'), 404
    report, _ = engine().read(f'timing/{job_id}.json')
    if not report:
        return jsonify(error='This recording has no generated timing map'), 404
    return jsonify(report)


@app.get('/dogreader/voices')
def voices():
    if not authorized():
        return auth_error()
    return jsonify(engines=[
        dict(id='google', name='Google Chirp', available=True,
             voices=[dict(id=v, name=v.rsplit('-', 1)[-1]) for v in sorted(AVAILABLE_VOICES)]),
        dict(id='kokoro', name='Kokoro', available=os.environ.get('DOGREADER_KOKORO_ENABLED') == '1',
             voices=[dict(id=v, name=n) for v, n in KOKORO_VOICES.items()])])


@app.post('/internal/process/<job_id>')
def process(job_id):
    if not task_authorized():
        return jsonify(error='Forbidden'), 403
    if not valid_id(job_id):
        return jsonify(error='Invalid job id'), 400
    try:
        state, code = engine().process(job_id)
    except NotFound:
        event('worker_missing_job', job_id)
        return jsonify(status='error', error='Job not found'), 200
    return jsonify(status=state), code


@app.post('/dogreader/jobs/<job_id>/retry')
def retry_job(job_id):
    if not authorized():
        return auth_error()
    if not valid_id(job_id):
        return jsonify(error='Invalid job id'), 400
    workflow = engine()
    if not bucket().blob(f'jobs/{job_id}.json').exists():
        return jsonify(error='Job not found'), 404
    if workflow.completed(job_id):
        return job_response(job_id, {'status': 'ready'})
    state = workflow.retry(job_id)
    return job_response(job_id, state), 202 if state['status'] == 'queued' else 200

