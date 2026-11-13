"""Apply only prototype-specific Android settings to a pinned Flutter template."""
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
# Populate only hash-pinned frontend source and official API-28 headers.
# No FONNX hook, native asset package, or alternate ORT enters the build.
if not (root / 'native/ort_headers/onnxruntime_ep_c_api.h').exists():
    subprocess.run([sys.executable, str(root / 'tool/prepare_frontend.py')], check=True)
app = root / 'android/app'
gradle = app / 'build.gradle.kts'
text = gradle.read_text()
assert 'applicationId = "com.dogreader.kokoro_probe"' in text
assert 'minSdk = flutter.minSdkVersion' in text
text = text.replace('minSdk = flutter.minSdkVersion', 'minSdk = 26')
text = text.replace('    defaultConfig {', '''    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    defaultConfig {
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_static")
            }
        }''', 1)
# Do not rely on the Android plugin's implicit debug-keystore location: explicitly
# bind the restored original key, just as the canonical Dogreader build does.
assert 'signingConfigs.getByName("debug")' in text
assert '    buildTypes {' in text
text = text.replace('    buildTypes {', '''    signingConfigs {
        create("probeOriginal") {
            storeFile = file(System.getProperty("user.home") + "/.android/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    buildTypes {''', 1)
text = text.replace('signingConfigs.getByName("debug")', 'signingConfigs.getByName("probeOriginal")')
gradle.write_text(text)
manifest = app / 'src/main/AndroidManifest.xml'
text = manifest.read_text().replace('android:label="kokoro_probe"', 'android:label="Kokoro Offline Probe"')
text = text.replace('<application', '<uses-permission android:name="android.permission.INTERNET"/>\n    <application', 1)
permissions = ['FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_MEDIA_PROCESSING',
               'FOREGROUND_SERVICE_DATA_SYNC', 'WAKE_LOCK', 'POST_NOTIFICATIONS']
text = text.replace('<application', ''.join(f'<uses-permission android:name="android.permission.{name}"/>\n' for name in permissions) + '<application', 1)
text = text.replace('</application>', '''<service android:name=".GenerationService" android:exported="false"
    android:process=":kokoro_generation" android:stopWithTask="false"
    android:foregroundServiceType="mediaProcessing|dataSync"/>
    </application>''')
text = text.replace('android:label=', 'android:allowBackup="false" android:label=', 1)
manifest.write_text(text)
destination = app / 'src/main/kotlin/com/dogreader/kokoro_probe/MainActivity.kt'
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'native/MainActivity.kt', destination)
for name in ['GenerationService.kt', 'ProbeTelemetry.kt']:
    shutil.copyfile(root / 'native' / name, destination.parent / name)
