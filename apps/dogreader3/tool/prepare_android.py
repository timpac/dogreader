"""Materialize only this app's generation service sources; never edit production."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
destination = root / 'android/app/src/main/kotlin/com/example/audiobook_app'
for name in ['GenerationService.kt', 'ProbeTelemetry.kt']:
    (destination / name).write_bytes((root / 'native' / name).read_bytes())
