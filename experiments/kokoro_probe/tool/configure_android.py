"""Apply only prototype-specific Android settings to a pinned Flutter template."""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
app = root / 'android/app'
gradle = app / 'build.gradle.kts'
text = gradle.read_text()
assert 'applicationId = "com.dogreader.kokoro_probe"' in text
assert 'minSdk = flutter.minSdkVersion' in text
text = text.replace('minSdk = flutter.minSdkVersion', 'minSdk = 26')
# Flutter's release template uses the debug signing config. CI restores the
# original repository key before building; the separate package cannot update Dogreader.
assert 'signingConfigs.getByName("debug")' in text
gradle.write_text(text)
manifest = app / 'src/main/AndroidManifest.xml'
text = manifest.read_text().replace('android:label="kokoro_probe"', 'android:label="Kokoro Offline Probe"')
text = text.replace('<application', '<uses-permission android:name="android.permission.INTERNET"/>\n    <application', 1)
text = text.replace('android:label=', 'android:allowBackup="false" android:label=', 1)
manifest.write_text(text)
destination = app / 'src/main/kotlin/com/dogreader/kokoro_probe/MainActivity.kt'
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'native/MainActivity.kt', destination)
