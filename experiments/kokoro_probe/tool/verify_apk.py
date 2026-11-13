"""Check native ELF alignment and absence of model/GPL frontend binaries."""
import re
import hashlib
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
    supported = ['arm64-v8a', 'x86_64'] if '--background' in sys.argv[2:] else ['arm64-v8a']
    assert not any(n.endswith(('/libflutter.so', '/libapp.so')) and
                   n.split('/')[1] not in supported for n in libs)
    if '--background' in sys.argv[2:]:
        assert 'lib/x86_64/libapp.so' in libs and 'lib/x86_64/libflutter.so' in libs
        assert 'lib/x86_64/libkokoro_g2p.so' in libs
        assert hashlib.sha256(apk.read('lib/x86_64/libonnxruntime.so')).hexdigest() == 'b626c070616d88bd643a6e63dc996d8d478d061176b056d52ce44c961bd355aa'
        assert hashlib.sha256(apk.read('lib/x86_64/libsherpa-onnx-c-api.so')).hexdigest() == 'ac4321f36bdf60249d450bbce81fec6d9269a007d3c4b050bf670995c0a9dbb1'
    arm64 = [n for n in libs if n.startswith('lib/arm64-v8a/')]
    if '--frontend' in sys.argv[2:]:
        # Exactly the original Sherpa runtime, with one new helper and no ORT
        # from FONNX/native assets. Check bytes, not merely a library filename.
        assert [n for n in arm64 if 'onnxruntime' in n.lower()] == ['lib/arm64-v8a/libonnxruntime.so']
        # Android's packaging strips the pub archive's debug symbols. Compare
        # against the already-shipped probe APK, not the unstripped source .so.
        assert hashlib.sha256(apk.read('lib/arm64-v8a/libonnxruntime.so')).hexdigest() == '7a2fb92eb67037837c3f0e428bd732fd0d05ced0546d9e740090c07573d8249a'
        assert hashlib.sha256(apk.read('lib/arm64-v8a/libsherpa-onnx-c-api.so')).hexdigest() == '8523d8044fb7336b945c8662821165f782103e4200a660b0ef097f6a41230e32'
        assert 'lib/arm64-v8a/libkokoro_g2p.so' in arm64
        assert not any('fonnx' in n.lower() for n in libs)
        assert 'assets/flutter_assets/english-frontend-manifest.json' in apk.namelist()
        notices = apk.read('assets/flutter_assets/frontend-notices.txt').decode()
        assert 'Apache License' in notices and 'MIT License' in notices and 'Agilord' in notices
    for name in arm64:
        info = apk.getinfo(name)
        if info.compress_type == zipfile.ZIP_STORED:
            with open(sys.argv[1], 'rb') as raw:
                raw.seek(info.header_offset + 26)
                filename_length, extra_length = struct.unpack('<HH', raw.read(4))
            assert (info.header_offset + 30 + filename_length + extra_length) % 16384 == 0, name
        target = Path(temp) / Path(name).name
        target.write_bytes(apk.read(name))
        if name.endswith('/libkokoro_g2p.so'):
            dynamic = subprocess.check_output(['readelf', '-d', str(target)], text=True)
            assert not re.search(r'NEEDED.*(?:onnxruntime|fonnx|c\+\+_shared)', dynamic)
            symbols = subprocess.check_output(['readelf', '-Ws', str(target)], text=True)
            for symbol in ['create', 'argmax', 'version', 'destroy', 'alloc', 'free']:
                assert f'kokoro_g2p_{symbol}' in symbols
        headers = subprocess.check_output(['readelf', '-lW', str(target)], text=True)
        loads = [line.split()[-1] for line in headers.splitlines() if re.match(r'\s*LOAD\s', line)]
        assert loads and all(int(value, 16) >= 16384 for value in loads), (name, loads)
    print(f'Checked {len(arm64)} ARM64 ELF files: 16 KB alignment, no model files/eSpeak libraries; '
          f'{len(libs)-len(arm64)} unused dependency libraries for other ABIs')
