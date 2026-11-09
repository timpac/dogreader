"""Read-only export of ONE immutable narration source matched by MP3 SHA-256.

Uses the owner's existing gcloud sign-in, never exports credentials, and never
dispatches tasks, synthesizes audio, changes IAM or modifies storage objects.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


class StorageReader:
    def __init__(self, token):
        self.token = token
        self.deadline = time.monotonic() + 180

    def get_bytes(self, url, limit=4 * 1024 * 1024):
        if not url.startswith('https://storage.googleapis.com/storage/v1/b/'):
            raise ValueError('Only the Google Storage JSON API is supported')
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Read-only export exceeded its three-minute network deadline')
        request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + self.token})
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        with urllib.request.build_opener(NoRedirect).open(request, timeout=min(30, remaining)) as response:
            data = response.read(limit + 1)
        if len(data) > limit:
            raise ValueError('Oversized storage response')
        return data

    def get_json(self, url):
        data = self.get_bytes(url)
        return json.loads(data)


def export_source(reader, bucket, audio_sha256, max_pages=10, checkpoint_proofs=False,
                  audio_size=None, progress=None, save=None, resume_report=None):
    progress = progress or (lambda message: None)
    save = save or (lambda report: None)
    if not re.fullmatch('[0-9a-f]{64}', audio_sha256):
        raise ValueError('Expected the exact original MP3 SHA-256')
    base = 'https://storage.googleapis.com/storage/v1/b/' + urllib.parse.quote(bucket, safe='') + '/o'
    matches = []
    legacy = []
    legacy_read_bytes = 0
    page = None
    for page_index in range(max_pages):
        progress(f'Checking recording metadata, page {page_index + 1}...')
        query = dict(prefix='audio/', maxResults=1000,
                     fields='nextPageToken,items(name,generation,size,metadata)')
        if page:
            query['pageToken'] = page
        listing = reader.get_json(base + '?' + urllib.parse.urlencode(query))
        matches.extend(item for item in listing.get('items', [])
                       if item.get('metadata', {}).get('sha256') == audio_sha256)
        legacy.extend(item for item in listing.get('items', [])
                      if audio_size is not None and int(item.get('size', -1)) == audio_size
                      and not item.get('metadata', {}).get('sha256'))
        page = listing.get('nextPageToken')
        if not page:
            break
    if page:
        raise ValueError('Bounded metadata scan exceeded 10000 objects; no export created')
    if not matches and audio_size is not None:
        progress('Verifying the exact-size legacy recording...')
        if len(legacy) != 1 or not 0 < audio_size <= 128 * 1024 * 1024:
            raise ValueError('Legacy lookup requires one exact-size candidate within 128 MiB')
        item = legacy[0]
        if not item.get('generation'):
            raise ValueError('Missing immutable legacy recording generation')
        url = base + '/' + urllib.parse.quote(item['name'], safe='') + '?' + urllib.parse.urlencode(
            dict(alt='media', generation=item['generation']))
        content = reader.get_bytes(url, limit=audio_size)
        if len(content) != audio_size or hashlib.sha256(content).hexdigest() != audio_sha256:
            raise ValueError('Legacy recording byte digest mismatch')
        legacy_read_bytes = len(content)
        matches.append(item)
    if len(matches) != 1:
        raise ValueError('Expected one recording with matching stored digest; legacy audio '
                         'without digest metadata needs a separately verified read')
    recording = matches[0]
    match = re.fullmatch(r'audio/([0-9a-f]{32})\.mp3', recording.get('name', ''))
    if match is None or not recording.get('generation'):
        raise ValueError('Invalid immutable recording identity')
    identity = match.group(1)
    progress('Recording matched. Reading the original narration text...')
    job_url = base + '/' + urllib.parse.quote('jobs/' + identity + '.json', safe='')
    metadata = reader.get_json(job_url + '?fields=name,generation,size')
    if not metadata.get('generation'):
        raise ValueError('Missing immutable source generation')
    job = reader.get_json(job_url + '?' + urllib.parse.urlencode(
        dict(alt='media', generation=metadata['generation'])))
    if not isinstance(job.get('text'), str) or not 1 <= len(job['text']) <= 250000:
        raise ValueError('Missing or oversized exact narration source text')
    # The result contains book content and recording identity, not credentials.
    safe_job = {key: job[key] for key in
                ('text', 'title', 'engine', 'voice', 'model_version', 'created') if key in job}
    if isinstance(job.get('settings'), dict):
        allowed = ('encoding', 'splitter', 'speed', 'sample_rate', 'bitrate', 'runtime',
                   'frontend', 'encoder', 'trim', 'language', 'phonemizer')
        safe_job['settings'] = {key: job['settings'][key] for key in allowed
                                if key in job['settings'] and isinstance(
                                    job['settings'][key], (str, int, float, bool, type(None)))}
    report = dict(schema='dogreader-source-export-v1', bucket=bucket, job_id=identity,
                audio=dict(name=recording['name'], generation=str(recording['generation']),
                           size=int(recording['size']), sha256=audio_sha256,
                           chunks=recording.get('metadata', {}).get('chunks'),
                           digest_verified_by='pinned-object-bytes' if legacy_read_bytes else 'stored-metadata'),
                source_generation=str(metadata['generation']), job=safe_job)
    cached = {}
    if (isinstance(resume_report, dict) and resume_report.get('bucket') == bucket and
            resume_report.get('job_id') == identity and
            resume_report.get('source_generation') == report['source_generation'] and
            resume_report.get('audio', {}).get('generation') == report['audio']['generation'] and
            resume_report.get('audio', {}).get('sha256') == audio_sha256):
        cached = {item['name']: {key: item[key] for key in
                      ('name', 'generation', 'size', 'audio_sha256', 'frames_sha256', 'frame_bytes', 'text_sha256')
                      if key in item} for item in resume_report.get('checkpoints', [])
                  if isinstance(item, dict) and isinstance(item.get('name'), str)}
    if checkpoint_proofs or cached:
        report.update(checkpoints=list(cached.values()), checkpoint_proofs_complete=False)
    save(report)
    progress('Source text saved. No credentials are included.')
    if checkpoint_proofs:
        # The standalone CLI hashes frames with the production framing rules.
        query = urllib.parse.urlencode(dict(prefix=f'chunks/{identity}/v1/', maxResults=1000,
            fields='nextPageToken,items(name,generation,size,metadata)'))
        checkpoints = reader.get_json(base + '?' + query)
        if checkpoints.get('nextPageToken'):
            raise ValueError('Checkpoint metadata scan exceeded its bound')
        total_bytes = legacy_read_bytes
        proofs = []
        items = sorted(checkpoints.get('items', []), key=lambda x: x['name'])
        for index, item in enumerate(items):
            if not re.fullmatch(f'chunks/{identity}/v1/[0-9]{{4}}\\.mp3', item['name']):
                continue
            size = int(item['size'])
            total_bytes += size
            if not 0 < size <= 2 * 1024 * 1024 or total_bytes > 128 * 1024 * 1024:
                raise ValueError('Checkpoint audio proof exceeds bounded reads')
            metadata = item.get('metadata', {})
            previous = cached.get(item['name'], {})
            if (previous.get('generation') == str(item['generation']) and
                    previous.get('size') == size and
                    previous.get('audio_sha256') == metadata.get('audio_sha256') and
                    previous.get('text_sha256') == metadata.get('text_sha256') and
                    re.fullmatch('[0-9a-f]{64}', str(previous.get('frames_sha256', ''))) and
                    isinstance(previous.get('frame_bytes'), int) and previous['frame_bytes'] > 0):
                proofs.append(previous)
                report['checkpoints'] = list(cached.values())
                save(report)
                progress(f'Checkpoint {index + 1}/{len(items)}: reusing verified digest.')
                continue
            progress(f'Verifying checkpoint {index + 1}/{len(items)}...')
            url = base + '/' + urllib.parse.quote(item['name'], safe='') + '?' + urllib.parse.urlencode(
                dict(alt='media', generation=item['generation']))
            content = reader.get_bytes(url, limit=2 * 1024 * 1024)
            digest = hashlib.sha256(content).hexdigest()
            if len(content) != size or digest != metadata.get('audio_sha256'):
                raise ValueError('Checkpoint byte identity mismatch')
            frame_bytes = mp3_frames(content)
            proofs.append(dict(name=item['name'], generation=str(item['generation']), size=size,
                audio_sha256=digest, frames_sha256=hashlib.sha256(frame_bytes).hexdigest(),
                frame_bytes=len(frame_bytes), text_sha256=metadata.get('text_sha256')))
            cached[item['name']] = proofs[-1]
            report['checkpoints'] = list(cached.values())
            save(report)
        report['checkpoints'] = proofs
        count = str(recording.get('metadata', {}).get('chunks', ''))
        report['checkpoint_proofs_complete'] = count.isdigit() and len(proofs) == int(count)
        save(report)
    return report


def save_export(path, report):
    """Keep the useful source and completed proofs even if later reads time out."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                prefix=path.name + '.', suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(report, stream, ensure_ascii=False, indent=2)
        temporary.chmod(0o600)
        temporary.replace(path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def mp3_frames(content):
    """Remove tags without decoding/re-encoding for immutable frame identity."""
    stream, frames = io.BytesIO(content), bytearray()
    while stream.tell() < len(content):
        pos = stream.tell()
        header = stream.read(4)
        if header[:3] == b'ID3':
            rest = stream.read(6)
            if len(header) != 4 or len(rest) != 6 or header[3] not in (2, 3, 4) or any(x & 128 for x in rest[2:]):
                raise ValueError('Malformed checkpoint ID3 tag')
            length = sum(x << (7 * (3 - i)) for i, x in enumerate(rest[2:]))
            end = pos + 10 + length + (10 if header[3] == 4 and rest[1] & 16 else 0)
        else:
            h = int.from_bytes(header, 'big')
            version, layer, rate, sample = (h >> 19) & 3, (h >> 17) & 3, (h >> 12) & 15, (h >> 10) & 3
            if len(header) != 4 or h >> 21 != 0x7ff or version == 1 or layer != 1 or rate in (0, 15) or sample == 3:
                raise ValueError('Malformed checkpoint MP3 frame')
            hz = [44100, 48000, 32000][sample] // {3: 1, 2: 2, 0: 4}[version]
            rates = ([0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                     if version == 3 else [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
            end = pos + (144000 if version == 3 else 72000) * rates[rate] // hz + ((h >> 9) & 1)
            if end <= len(content):
                frames.extend(content[pos:end])
        if end > len(content) or end <= pos:
            raise ValueError('Truncated checkpoint audio')
        stream.seek(end)
    if not frames:
        raise ValueError('Empty checkpoint audio')
    return bytes(frames)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--audio-sha256', required=True)
    parser.add_argument('--audio-size-bytes', type=int,
                        help='For legacy recordings, verify one exact-size object by reading its pinned bytes')
    parser.add_argument('--output', type=Path, default=Path('dogreader-alignment-source.json'))
    parser.add_argument('--checkpoint-proofs', action='store_true',
                        help='Read this job’s bounded checkpoints and export frame digests, not audio')
    parser.add_argument('--resume', action='store_true',
                        help='Resume a matching export, reusing generation-verified checkpoint digests')
    args = parser.parse_args(argv)
    previous = None
    if args.output.exists() and not args.resume:
        raise ValueError('Refusing to overwrite an existing export')
    if args.output.exists():
        previous = json.loads(args.output.read_text())
        if (previous.get('schema') != 'dogreader-source-export-v1' or
                previous.get('bucket') != args.bucket or
                previous.get('audio', {}).get('sha256') != args.audio_sha256):
            raise ValueError('Existing export belongs to another recording; choose a new output path')
    def progress(message):
        print('[source export] ' + message, file=sys.stderr, flush=True)
    progress('Getting your existing gcloud sign-in. Approve Cloud Shell authorization if prompted...')
    try:
        token = subprocess.check_output(['gcloud', 'auth', 'print-access-token'],
                                        text=True, timeout=90).strip()
    except subprocess.TimeoutExpired:
        raise TimeoutError('gcloud sign-in did not finish in 90 seconds; authorize Cloud Shell and retry') from None
    progress('Authentication ready.')
    try:
        report = export_source(StorageReader(token), args.bucket, args.audio_sha256,
            checkpoint_proofs=args.checkpoint_proofs, audio_size=args.audio_size_bytes,
            progress=progress, save=lambda result: save_export(args.output, result), resume_report=previous)
    except TimeoutError:
        if not args.output.exists():
            raise
        report = json.loads(args.output.read_text())
        if not isinstance(report.get('job', {}).get('text'), str):
            raise
        progress('Time limit reached. Source text and completed proofs are saved; '
                 'you can send this JSON now. Use --resume for any remaining checkpoint proofs.')
    print(f'Created {args.output.name}: one job, {len(report["job"]["text"])} source characters. '
          'No credentials exported and no cloud data changed.', flush=True)


if __name__ == '__main__':
    main()
