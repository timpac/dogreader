"""One persistent CPU model process per Gunicorn worker; no network at runtime."""
import multiprocessing
import os
from pathlib import Path
import threading
import time

from narration import KOKORO_VOICES


class KokoroUnavailable(RuntimeError):
    pass


class KokoroBusy(KokoroUnavailable):
    pass


def _serve(connection):
    # Imports and the model live only in this process. spawn avoids inheriting
    # Gunicorn threads or an initialized ONNX runtime through fork.
    try:
        import numpy as np
        import onnxruntime as ort
        from kokoro_onnx import Kokoro
        import resource
        import subprocess
        from reliability import InvalidAudio, validate_mp3, decode_mp3
        import tempfile
        folder = Path(os.environ.get('DOGREADER_KOKORO_DIR', '/opt/kokoro'))
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        session = ort.InferenceSession(str(folder / 'kokoro-v1.0.onnx'),
                                       sess_options=options, providers=['CPUExecutionProvider'])
        model = Kokoro.from_session(session, str(folder / 'voices-v1.0.bin'))
        if not set(KOKORO_VOICES).issubset(model.get_voices()):
            raise RuntimeError('Pinned voice pack is missing required British voices')
        connection.send(('loaded', None))
        while True:
            text, voice = connection.recv()
            started = time.process_time()
            if text.strip():
                samples, hz = model.create(text, voice=voice, lang='en-gb', speed=1.0, trim=False)
            else:
                samples, hz = np.zeros(2400, dtype=np.float32), 24000
            if hz != 24000 or not len(samples) or not np.isfinite(samples).all():
                raise InvalidAudio('Kokoro produced invalid samples')
            if len(samples) > 24000 * 180:
                raise InvalidAudio('Kokoro chunk exceeded 180 seconds')
            # No Xing header per chunk: the existing finalizer writes one for
            # the complete chapter. The frame timeline also powers text seeking.
            encoded = subprocess.run([
                'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
                '-f', 'f32le', '-ar', str(hz), '-ac', '1', '-i', 'pipe:0',
                '-c:a', 'libmp3lame', '-b:a', '64k', '-write_xing', '0',
                '-f', 'mp3', 'pipe:1'], input=np.asarray(samples, dtype='<f4').tobytes(),
                capture_output=True, timeout=20, check=True)
            with tempfile.TemporaryFile() as stream:
                stream.write(encoded.stdout)
                validate_mp3(stream)
                decode_mp3(stream)
            connection.send(('audio', (encoded.stdout, dict(
                cpu_seconds=time.process_time() - started,
                peak_rss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                sample_seconds=len(samples) / hz))))
    except EOFError:
        pass
    except Exception as exc:
        # Provider errors can contain input text. Only return a safe class name.
        import traceback
        frames = [(Path(f.filename).name, f.lineno, f.name) for f in traceback.extract_tb(exc.__traceback__)]
        print('Kokoro worker failure: ' + repr((type(exc).__name__, getattr(exc, 'errno', None), frames)), flush=True)
        connection.send(('error', type(exc).__name__))
    finally:
        connection.close()


class Worker:
    def __init__(self):
        self.lock = threading.Lock()
        self.process = None
        self.connection = None

    def close(self):
        if self.connection:
            self.connection.close()
        if self.process:
            self.process.terminate()
            self.process.join(timeout=5)
        self.process = self.connection = None

    def start(self):
        if self.process and self.process.is_alive():
            return
        self.close()
        context = multiprocessing.get_context('spawn')
        self.connection, child = context.Pipe()
        self.process = context.Process(target=_serve, args=(child,), daemon=True)
        self.process.start()
        child.close()
        try:
            if not self.connection.poll(90):
                raise KokoroUnavailable('Kokoro model loading exceeded 90 seconds')
            state, _ = self.connection.recv()
            if state != 'loaded':
                raise KokoroUnavailable('Kokoro model or voice pack could not be loaded')
        except Exception:
            self.close()
            raise

    def synthesize(self, text, voice):
        if not self.lock.acquire(blocking=False):
            raise KokoroBusy('Kokoro CPU worker is busy; saved chunks will resume')
        try:
            self.start()
            self.connection.send((text, voice))
            if not self.connection.poll(120):
                self.close()
                raise KokoroUnavailable('Kokoro chunk exceeded 120 seconds')
            state, result = self.connection.recv()
            if state != 'audio':
                self.close()
                raise KokoroUnavailable('Kokoro inference failed; check pinned runtime assets')
            return result
        except (EOFError, BrokenPipeError, OSError) as exc:
            self.close()
            raise KokoroUnavailable('Kokoro CPU worker stopped; saved chunks will resume') from exc
        finally:
            self.lock.release()


worker = Worker()


def post_worker_init(server_worker):
    if os.environ.get('DOGREADER_KOKORO_ENABLED') == '1':
        worker.start()


def worker_exit(server, server_worker):
    worker.close()
