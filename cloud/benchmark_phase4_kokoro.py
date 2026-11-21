"""Phase 4 Kokoro ONNX CPU utilization and thread scaling benchmark."""
import json
import os
import subprocess
import sys
import time

CHUNKS = [
    (
        "The sunshine of a fair tight-fitting morning in May streamed through the tall windows of the "
        "breakfast room at Blandings Castle, illuminating the silver coffee-pot, the Rackstraw portrait "
        "of the fourth Earl, and the thoughtfully furrowed brow of Clarence, ninth Earl of Emsworth. "
        "Outside on the trim velvet lawn, Beach the butler moved with the slow, majestic deliberation "
        "of a galleon under gentle sail, bearing a salver upon which rested a telegram of ominous aspect. "
        "Lord Emsworth adjusted his pince-nez, dropped them into his kedgeree, rescued them with a mild "
        "exclamation of annoyance, and endeavoured to recall whether his sister Constance had promised "
        "to leave for London on the eleven-fifteen or the two-forty."
    ),
    (
        "Bertie Wooster leaned back against the cushions of the two-seater and surveyed the shimmering "
        "expanse of the Hampshire countryside with the quiet satisfaction of a man who had narrowly "
        "escaped being dragooned into stealing a silver cow-creamer before luncheon. Beside him, Jeeves "
        "preserved that delicately poised expression of respectful reserve which had so often steadied "
        "the Wooster nerve in moments of domestic crisis. 'The contingency, sir,' observed Jeeves, "
        "steering neatly past a meditative Sussex spaniel in the lane, 'is one that frequently arises "
        "when relatives of a forceful temperament assemble at a country seat without adequate diversion.'"
    ),
    (
        "Down by the ornamental lake, Psmith paused to flick an invisible speck of dust from the lapel "
        "of his irreproachable morning coat and regarded Comrade Jackson through a monocle of crystalline "
        "serenity. 'We are confronted, Comrade Wallop,' he murmured, 'with one of those intriguing "
        "problems of rural diplomacy which call for the utmost suavity and tact. If the Empress of "
        "Blandings is to enjoy the uninterrupted tranquility essential to a champion Berkshire sow in "
        "the weeks preceding the Shrewsbury Agricultural Show, we must act with both precision and "
        "dispatch before the hour of the dressing gong.'"
    ),
]
WARMUP_TEXT = "Good morning, Jeeves. The weather appears remarkably pleasant today."
VOICE = "bm_george"


CHILD_CODE = r"""
import json, os, sys, time
sys.path.insert(0, '/home/antigravity/dogreader/cloud')
import kokoro_worker

chunks = json.loads(sys.argv[1])
warmup = sys.argv[2]
voice = sys.argv[3]

w = kokoro_worker.Worker()
t_load_start = time.monotonic()
w.start()
load_wall_s = time.monotonic() - t_load_start

# Warmup inference so ONNX Runtime arena allocations stabilize
w.synthesize(warmup, voice)

total_wall_s = 0.0
total_cpu_s = 0.0
total_audio_s = 0.0
total_mp3_bytes = 0
peak_rss_kib = 0
per_chunk = []

for idx, text in enumerate(chunks):
    t0 = time.monotonic()
    mp3_bytes, metrics = w.synthesize(text, voice)
    wall_s = time.monotonic() - t0
    cpu_s = float(metrics['cpu_seconds'])
    audio_s = float(metrics['sample_seconds'])
    rss_kib = int(metrics['peak_rss_kib'])
    total_wall_s += wall_s
    total_cpu_s += cpu_s
    total_audio_s += audio_s
    total_mp3_bytes += len(mp3_bytes)
    peak_rss_kib = max(peak_rss_kib, rss_kib)
    per_chunk.append({
        'chunk': idx,
        'chars': len(text),
        'wall_s': round(wall_s, 3),
        'cpu_s': round(cpu_s, 3),
        'audio_s': round(audio_s, 3),
        'mp3_bytes': len(mp3_bytes),
    })

w.close()
total_chars = sum(len(c) for c in chunks)
print('BENCHMARK_JSON=' + json.dumps({
    'threads': int(os.environ.get('DOGREADER_KOKORO_THREADS', '0')),
    'omp_threads': int(os.environ.get('OMP_NUM_THREADS', '0')),
    'total_chars': total_chars,
    'load_wall_s': round(load_wall_s, 3),
    'total_wall_s': round(total_wall_s, 3),
    'total_cpu_s': round(total_cpu_s, 3),
    'cpu_utilization_cores': round(total_cpu_s / total_wall_s, 2),
    'total_audio_s': round(total_audio_s, 2),
    'realtime_factor': round(total_audio_s / total_wall_s, 2),
    'chars_per_sec': round(total_chars / total_wall_s, 1),
    'peak_rss_kib': peak_rss_kib,
    'peak_rss_mib': round(peak_rss_kib / 1024.0, 1),
    'total_mp3_bytes': total_mp3_bytes,
    'per_chunk': per_chunk,
}))
"""


def run_config(threads: int) -> dict:
    env = dict(os.environ)
    env['DOGREADER_KOKORO_DIR'] = os.environ.get(
        'DOGREADER_KOKORO_DIR',
        '/home/antigravity/dogreader-cloud-deployed/opt/kokoro',
    )
    env['DOGREADER_KOKORO_THREADS'] = str(threads)
    env['OMP_NUM_THREADS'] = str(threads)
    proc = subprocess.run(
        [sys.executable, '-c', CHILD_CODE, json.dumps(CHUNKS), WARMUP_TEXT, VOICE],
        env=env,
        capture_output=True,
        text=True,
        timeout=300,
        check=True,
    )
    for line in proc.stdout.splitlines():
        if line.startswith('BENCHMARK_JSON='):
            return json.loads(line.split('=', 1)[1])
    raise RuntimeError(f'Missing BENCHMARK_JSON in output: {proc.stdout}\n{proc.stderr}')


def main():
    results = []
    for threads in (1, 2):
        res = run_config(threads)
        results.append(res)
        print(json.dumps(res, indent=2), flush=True)

    r1, r2 = results[0], results[1]
    speedup = r1['total_wall_s'] / r2['total_wall_s']
    print('\n=== PHASE 4 KOKORO CPU BENCHMARK SUMMARY ===')
    print(f"Total benchmark text: {r1['total_chars']} chars across {len(CHUNKS)} chunks (voice={VOICE})")
    print(f"{'Metric':<32} | {'1 Thread (Before)':<20} | {'2 Threads (After)':<20}")
    print('-' * 78)
    print(f"{'Model Load Wall Time (s)':<32} | {r1['load_wall_s']:<20.3f} | {r2['load_wall_s']:<20.3f}")
    print(f"{'Synthesis Wall Time (s)':<32} | {r1['total_wall_s']:<20.3f} | {r2['total_wall_s']:<20.3f}")
    print(f"{'Process CPU Time (s)':<32} | {r1['total_cpu_s']:<20.3f} | {r2['total_cpu_s']:<20.3f}")
    print(f"{'Effective CPU Cores Used':<32} | {r1['cpu_utilization_cores']:<20.2f} | {r2['cpu_utilization_cores']:<20.2f}")
    print(f"{'Generated Audio Duration (s)':<32} | {r1['total_audio_s']:<20.2f} | {r2['total_audio_s']:<20.2f}")
    print(f"{'Real-Time Factor (audio/wall)':<32} | {str(r1['realtime_factor']) + 'x':<20} | {str(r2['realtime_factor']) + 'x':<20}")
    print(f"{'Throughput (chars/sec)':<32} | {r1['chars_per_sec']:<20.1f} | {r2['chars_per_sec']:<20.1f}")
    print(f"{'Peak RSS (MiB)':<32} | {r1['peak_rss_mib']:<20.1f} | {r2['peak_rss_mib']:<20.1f}")
    print(f"Wall-time speedup (2 threads vs 1 thread): {speedup:.2f}x")


if __name__ == '__main__':
    main()
