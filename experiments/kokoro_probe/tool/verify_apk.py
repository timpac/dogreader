"""Check native ELF alignment and absence of model/GPL frontend binaries."""
import re
import subprocess
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

with zipfile.ZipFile(sys.argv[1]) as apk, tempfile.TemporaryDirectory() as temp:
    libs = [n for n in apk.namelist() if n.endswith('.so')]
    assert libs and any('sherpa-onnx' in n for n in libs), libs
    assert not any(n.endswith('.onnx') or Path(n).name == 'voices.bin' or 'espeak' in n.lower() or 'phonemize' in n.lower()
                   for n in apk.namelist()), 'Unexpected model or GPL frontend'
    # Flutter's target-platform flag targets its engine/Dart AOT code. Federated
    # FFI dependencies may still package unused libraries for other ABIs.
    assert 'lib/arm64-v8a/libflutter.so' in libs
    assert 'lib/arm64-v8a/libapp.so' in libs
    assert not any(n.endswith(('/libflutter.so', '/libapp.so')) and
                   not n.startswith('lib/arm64-v8a/') for n in libs)
    arm64 = [n for n in libs if n.startswith('lib/arm64-v8a/')]
    for name in arm64:
        info = apk.getinfo(name)
        if info.compress_type == zipfile.ZIP_STORED:
            with open(sys.argv[1], 'rb') as raw:
                raw.seek(info.header_offset + 26)
                filename_length, extra_length = struct.unpack('<HH', raw.read(4))
            assert (info.header_offset + 30 + filename_length + extra_length) % 16384 == 0, name
        target = Path(temp) / Path(name).name
        target.write_bytes(apk.read(name))
        headers = subprocess.check_output(['readelf', '-lW', str(target)], text=True)
        loads = [line.split()[-1] for line in headers.splitlines() if re.match(r'\s*LOAD\s', line)]
        assert loads and all(int(value, 16) >= 16384 for value in loads), (name, loads)
    print(f'Checked {len(arm64)} ARM64 ELF files: 16 KB alignment, no model files/eSpeak libraries; '
          f'{len(libs)-len(arm64)} unused dependency libraries for other ABIs')
