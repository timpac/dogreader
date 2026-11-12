"""Restore only upstream 0.18.19's listener lifetime for the CI baseline probe.

Keep identical diagnostics/player/app code so native reception with no Dart
delivery is directly observable. Never use this generated source for a release.
"""
from pathlib import Path

root = Path('third_party/audio_service/android/src/main/java/com/ryanheise/audioservice')
service = root / 'AudioService.java'
source = service.read_text()
needle = '''            // The listener belongs to the Flutter engine, which may survive this
            // service (for example when an Activity reattaches during unbinding).
            // Only detaching its owning engine may clear it.
            listener.onDestroy();'''
assert source.count(needle) == 1
service.write_text(source.replace(needle, '            listener.onDestroy();\n            listener = null;'))
plugin = root / 'AudioServicePlugin.java'
source = plugin.read_text()
needle = '            audioHandlerInterface = null;\n            AudioService.init(null);'
assert source.count(needle) == 1
plugin.write_text(source.replace(needle, '            audioHandlerInterface = null;'))
