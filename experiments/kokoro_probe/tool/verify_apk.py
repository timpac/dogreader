"""Check native ELF alignment and absence of model/GPL frontend binaries."""
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

with zipfile.ZipFile(sys.argv[1]) as apk, tempfile.TemporaryDirectory() as temp:
    libs = [n for n in apk.namelist() if n.endswith('.so')]
    assert libs and any('sherpa-onnx' in n for n in libs), libs
    assert not any(n.endswith('.onnx') or Path(n).name == 'voices.bin' or 'espeak' in n.lower() or 'phonemize' in n.lower()
                   for n in apk.namelist()), 'Unexpected model or GPL frontend'
    for name in libs:
        assert name.startswith('lib/arm64-v8a/'), name
        target = Path(temp) / Path(name).name
        target.write_bytes(apk.read(name))
        headers = subprocess.check_output(['readelf', '-lW', str(target)], text=True)
        loads = [line.split()[-1] for line in headers.splitlines() if re.match(r'\s*LOAD\s', line)]
        assert loads and all(int(value, 16) >= 16384 for value in loads), (name, loads)
    print(f'Checked {len(libs)} ARM64 ELF files: 16 KB alignment, no model files/eSpeak libraries')
