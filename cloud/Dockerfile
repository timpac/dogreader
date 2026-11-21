FROM python:3.12.14-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg=7:5.1.9-0+deb12u1 libmp3lame0=3.100-6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt requirements-kokoro.txt ./
RUN pip install --no-cache-dir -r requirements-kokoro.txt

COPY fetch_kokoro.py ./
RUN python fetch_kokoro.py /opt/kokoro

COPY main.py reliability.py recover.py narration.py kokoro_worker.py gunicorn_conf.py ./
COPY notices /app/notices

ENV PORT=8080 DOGREADER_KOKORO_ENABLED=1 OMP_NUM_THREADS=2 DOGREADER_KOKORO_THREADS=2

CMD ["/bin/sh", "-c", "exec gunicorn --config gunicorn_conf.py --bind :${PORT} --workers 1 --threads 4 --timeout 600 main:app"]
