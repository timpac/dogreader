"""Versioned recording configuration; no SDK, credentials or inference at import."""
import hashlib
import json
import re

GOOGLE = 'google'
KOKORO = 'kokoro'
KOKORO_MODEL = 'kokoro-82m-v1.0-onnx-f32-assets-224414194-227558528'
KOKORO_VOICES = {'bm_george': 'George', 'bm_fable': 'Fable',
                 'bm_daniel': 'Daniel', 'bm_lewis': 'Lewis'}
# Includes the frontend, splitter and encoder, not just the network weights.
KOKORO_SETTINGS = dict(speed=1.0, language='en-gb', sample_rate=24000,
                       bitrate='64k', splitter='lossless-1200-v1',
                       runtime='kokoro-onnx-0.6.1', trim=False,
                       encoder='ffmpeg-5.1.9-libmp3lame-3.100')
GOOGLE_SETTINGS = dict(encoding='MP3', splitter='google-3800-v1')


class NarrationConfiguration(ValueError):
    pass


def configuration(data, default_voice='en-US-Chirp3-HD-Achernar'):
    engine = data.get('engine', GOOGLE)
    if engine not in (GOOGLE, KOKORO):
        raise NarrationConfiguration('Unsupported narration engine')
    if engine == KOKORO:
        voice = data.get('voice', 'bm_george')
        if not isinstance(voice, str) or voice not in KOKORO_VOICES:
            raise NarrationConfiguration('Unsupported Kokoro voice')
        model, settings = KOKORO_MODEL, dict(KOKORO_SETTINGS)
    else:
        voice = data.get('voice', default_voice)
        if not isinstance(voice, str) or voice not in {
                'en-US-Chirp3-HD-Achernar', 'en-US-Chirp3-HD-Charon',
                'en-US-Chirp3-HD-Kore', 'en-US-Chirp3-HD-Puck'}:
            raise NarrationConfiguration('Unsupported Google narrator')
        # Google does not expose an immutable revision for managed Chirp voices.
        model, settings = 'google-chirp3-hd-managed', dict(GOOGLE_SETTINGS)
    if data.get('model_version', model) != model or data.get('settings', settings) != settings:
        raise NarrationConfiguration('Unsupported model version or generation settings')
    return dict(engine=engine, voice=voice, model_version=model, settings=settings)


def recording_id(text, config):
    identity = json.dumps(config, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return hashlib.sha256((identity + '\n' + text).encode()).hexdigest()[:32]


def legacy_id(text, voice):
    return hashlib.sha256((voice + '\n' + text).encode()).hexdigest()[:32]


def split_kokoro(text, limit=1200):
    """Lossless slices: prefer paragraphs, then sentences, then word boundaries.

    No strip, punctuation removal, Unicode normalization, or discarded dialogue.
    Kokoro's frontend further splits these at <=510 phonemes without truncation.
    At most 209 text chunks for 250,000 characters (unless preferred breaks shorten
    chunks); the half-window minimum keeps even pathological input below 418.
    """
    chunks = []
    start = 0
    boundary = re.compile(r'\n\s*\n|[.!?…。！？][\u201d\u2019"\x27)]*\s+|\s+')
    while start < len(text):
        end = min(start + limit, len(text))
        if end < len(text):
            candidates = list(boundary.finditer(text, start + limit // 2, end))
            paragraphs = [m for m in candidates if '\n' in m.group()]
            sentences = [m for m in candidates if m.group()[0] in '.!?…。！？']
            preferred = paragraphs or sentences or candidates
            if preferred:
                end = preferred[-1].end()
        chunks.append(text[start:end])
        start = end
    return chunks


def stored_configuration(job):
    # Validate explicit configurations rather than quietly changing a failed job.
    return configuration(job)
