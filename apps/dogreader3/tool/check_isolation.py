"""Fast identity, storage and copied-pipeline contracts. No APK or models."""
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
repo = root.parents[1]
base = '30e92ca871bad697b19637488b085a8ecd03f1a3'
probe = '57042ff146f8363b6bcc555e2b713e1a4228ec8b'
subprocess.run(['git', 'diff', '--exit-code', base, '--', 'lib', 'android',
                'pubspec.yaml', 'pubspec.lock', 'third_party', 'test'], cwd=repo, check=True)
gradle = (root/'android/app/build.gradle.kts').read_text()
assert 'applicationId = "com.dogreader.v3"' in gradle
assert 'manifestPlaceholders["dogreaderAppLabel"] = "Dogreader 3.0"' in gradle
manifest = ET.parse(root/'android/app/src/main/AndroidManifest.xml').getroot()
android = '{http://schemas.android.com/apk/res/android}'
assert manifest.get(android+'sharedUserId') is None
app = manifest.find('application')
assert app.get(android+'allowBackup') == 'false'
assert app.find('provider').get(android+'authorities') == '${applicationId}.media_diagnostics'
services = {s.get(android+'name'): s for s in app.findall('service')}
assert services['com.ryanheise.audioservice.AudioService'].get(android+'foregroundServiceType') == 'mediaPlayback'
generation = services['.GenerationService']
assert generation.get(android+'process') == ':kokoro_generation'
assert generation.get(android+'exported') == 'false'
assert set(generation.get(android+'foregroundServiceType').split('|')) == {'mediaProcessing', 'dataSync'}
service = (root/'native/GenerationService.kt').read_text()
assert 'FlutterEngine(applicationContext, null, false)' in service
assert 'PARTIAL_WAKE_LOCK' in service and 'onTimeout' in service
for name in ['narration_delivery.dart', 'narration_preview.dart', 'narration_options.dart',
             'reader_content.dart', 'narration_dictionary.dart', 'narration_files.dart']:
    assert (root/'lib'/name).read_bytes() == (repo/'lib'/name).read_bytes(), name
for name in ['audio.dart', 'english_frontend.dart', 'english_normalization.dart', 'native_g2p.dart']:
    expected = subprocess.check_output(['git', 'show', f'{probe}:experiments/kokoro_probe/lib/{name}'], cwd=repo)
    assert (root/'lib/kokoro'/name).read_bytes() == expected, name
for name in ['fp32-model-manifest.json', 'english-frontend-manifest.json', 'native/g2p_bridge.cc']:
    expected = subprocess.check_output(['git', 'show', f'{probe}:experiments/kokoro_probe/{name}'], cwd=repo)
    assert (root/name).read_bytes() == expected, name

def versions(path):
    text = path.read_text()
    return {m[1]: re.search(r'^    version: "([^"]+)"', m[2], re.M)[1]
            for m in re.finditer(r'^  (\w+):\n(.*?)(?=^  \w+:\n|^sdks:|\Z)', text, re.M|re.S)
            if re.search(r'^    version: "([^"]+)"', m[2], re.M)}

original, current = versions(repo/'pubspec.lock'), versions(root/'pubspec.lock')
assert {k: (v, current[k]) for k,v in original.items() if k in current and current[k] != v} == {}, 'Existing dependency upgrade'
assert current['archive'] == '3.6.1'
assert current.get('sherpa_onnx', '2.0.1') == '2.0.1'
assert not any(p.suffix in ['.onnx', '.bz2'] or p.name == 'voices.bin' for p in root.rglob('*') if p.is_file()), 'Model binary in app source'
print('Distinct identity, private storage boundary, production isolation, unchanged cloud/reader/FP32/Misaki and dependency versions verified.')
