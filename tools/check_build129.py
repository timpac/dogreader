"""Prevent another old-baseline release; run before APK compilation."""
import subprocess
from pathlib import Path

BASE = '26fd3ef70978c686a2ac09ca0bf655ac7add600e'


def git(*args):
    return subprocess.check_output(['git', *args])


subprocess.run(['git', 'merge-base', '--is-ancestor', BASE, 'HEAD'], check=True)
paths = git('ls-tree', '-r', '--name-only', BASE).decode().splitlines()
protected = [p for p in paths if p.startswith(('lib/', 'test/', 'android/'))
             and p != 'lib/main.dart']
protected += ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml']
for path in protected:
    assert Path(path).read_bytes() == git('show', f'{BASE}:{path}'), f'Baseline file changed: {path}'


def outside_narration(text):
    text = text.replace("import 'narration_options.dart';\n", '')
    text = text.replace('Listen / Generate narration', 'Listen / Generate audiobook')
    start = text.index('class _NarrationQueueScreenState')
    end = text.index('class ReadingScreen', start)
    return text[:start] + text[end:]


assert outside_narration(Path('lib/main.dart').read_text()) == outside_narration(
    git('show', f'{BASE}:lib/main.dart').decode()), 'Reader/book/theme/audio screen code changed outside the Kokoro port'
print(f'Build 129 is an ancestor; {len(protected)} baseline files and all book/reader/player screen code preserved.')
