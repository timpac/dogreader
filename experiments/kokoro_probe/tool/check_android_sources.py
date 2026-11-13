"""Compile experimental Kotlin against real Android/Flutter APIs, without an APK.

Compile-only tools/dependencies live in runner temp; app dependencies are unchanged.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
manifest = ET.parse(root/'android/app/src/main/AndroidManifest.xml').getroot()
android = '{http://schemas.android.com/apk/res/android}'
service = next(e for e in manifest.findall('application/service') if e.get(android+'name') == '.GenerationService')
assert service.get(android+'process') == ':kokoro_generation'
assert service.get(android+'exported') == 'false' and service.get(android+'stopWithTask') == 'false'
assert set(service.get(android+'foregroundServiceType').split('|')) == {'mediaProcessing', 'dataSync'}
permissions = {e.get(android+'name') for e in manifest.findall('uses-permission')}
assert all('android.permission.'+p in permissions for p in ['WAKE_LOCK', 'POST_NOTIFICATIONS',
           'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_MEDIA_PROCESSING', 'FOREGROUND_SERVICE_DATA_SYNC'])
flutter = Path(os.environ['FLUTTER_ROOT'])
sdk = Path(os.environ['ANDROID_HOME'])
platforms = sorted((p for p in sdk.glob('platforms/android-*/android.jar') if re.fullmatch(r'android-\d+', p.parent.name)), key=lambda p: int(p.parent.name.split('-')[-1]))
assert platforms and int(platforms[-1].parent.name.split('-')[-1]) >= 35
with tempfile.TemporaryDirectory(prefix='kokoro-kotlin-') as directory:
    temp = Path(directory)

    def fetch(url, filename):
        p = temp / filename
        with urllib.request.urlopen(url, timeout=120) as stream, p.open('wb') as out:
            shutil.copyfileobj(stream, out)
        return p

    candidates = list((flutter / 'bin/cache/artifacts/engine').glob('android*/flutter.jar'))
    if candidates:
        embedding = candidates[0]
    else:
        revision = (flutter / 'bin/cache/engine.stamp').read_text().strip()
        version = '1.0.0-' + revision
        embedding = fetch(f'https://storage.googleapis.com/download.flutter.io/io/flutter/flutter_embedding_release/{version}/flutter_embedding_release-{version}.jar', 'flutter.jar')
    lifecycle = fetch('https://dl.google.com/dl/android/maven2/androidx/lifecycle/lifecycle-common-jvm/2.8.7/lifecycle-common-jvm-2.8.7.jar', 'lifecycle.jar')
    compiler = fetch('https://github.com/JetBrains/kotlin/releases/download/v2.1.0/kotlin-compiler-2.1.0.zip', 'compiler.zip')
    with zipfile.ZipFile(compiler) as archive:
        archive.extractall(temp / 'compiler')
    command = temp / 'compiler/kotlinc/bin/kotlinc'
    command.chmod(0o755)
    subprocess.run([str(command), '-jvm-target', '17', '-classpath',
                    os.pathsep.join(map(str, [platforms[-1], embedding, lifecycle])),
                    *map(str, root.glob('native/*.kt')), '-d', str(temp / 'classes')], check=True)
print('Kotlin compiled against real Android/Flutter APIs; no APK built.')
