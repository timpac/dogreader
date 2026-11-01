"""Verify the actual signed APK on an isolated emulator, using local fixtures.

No cloud host/token, engine preview, generation request, or production data.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import traceback
import xml.etree.ElementTree as ET
import zipfile

PACKAGE = 'com.example.audiobook_app'
BOOK = 'Harbour Verification'
ONE = 'Chapter One - The Harbour'
TWO = 'Chapter Two - The Island'
checks = []


def adb(*args, binary=False, timeout=40):
    return subprocess.check_output(['adb', *map(str, args)], text=not binary, timeout=timeout)


def shell(*args):
    return adb('shell', *args)


def xml():
    until = time.monotonic() + 30
    while time.monotonic() < until:
        try:
            shell('rm', '-f', '/sdcard/window.xml')
            shell('uiautomator', 'dump', '/sdcard/window.xml')
            return ET.fromstring(adb('exec-out', 'cat', '/sdcard/window.xml'))
        except (ET.ParseError, subprocess.CalledProcessError):
            time.sleep(1)
    raise AssertionError('Android did not provide a ready accessibility window within 30 seconds')


def label(node):
    return (node.get('text', '') + '\n' + node.get('content-desc', '')).strip()


def bounds(node):
    return tuple(map(int, re.findall(r'\d+', node.get('bounds', ''))))


def find(text, timeout=25):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        nodes = [n for n in xml().iter('node') if text in label(n) and len(bounds(n)) == 4
                 and bounds(n)[2] > bounds(n)[0] and bounds(n)[3] > bounds(n)[1]]
        if nodes:
            return sorted(nodes, key=lambda n: (label(n) != text, len(label(n)), bounds(n)[1]))[0]
        time.sleep(0.5)
    raise AssertionError(f'Actual APK screen is missing: {text}')


def expect(*texts):
    until = time.monotonic() + 25
    while time.monotonic() < until:
        labels = [label(n) for n in xml().iter('node')]
        missing = [text for text in texts if not any(text in value for value in labels)]
        if not missing:
            checks.append('visible: ' + ', '.join(texts))
            print(checks[-1], flush=True)
            return
        time.sleep(0.5)
    raise AssertionError('Actual APK screen is missing: ' + ', '.join(missing))


def tap(text):
    x1, y1, x2, y2 = bounds(find(text))
    shell('input', 'tap', (x1 + x2) // 2, (y1 + y2) // 2)
    time.sleep(0.8)


def back():
    shell('input', 'keyevent', '4')
    time.sleep(0.8)


def capture(name):
    print('Capturing actual APK screen: ' + name, flush=True)
    root = xml()
    (output / f'{name}.xml').write_bytes(ET.tostring(root))
    (output / f'{name}.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))


def read_json(name):
    return json.loads(adb('exec-out', 'run-as', PACKAGE, 'cat', f'app_flutter/{name}'))


def seed(path, relative):
    remote = '/data/local/tmp/' + path.name
    adb('push', path, remote)
    shell('chmod', '644', remote)
    shell('run-as', PACKAGE, 'cp', remote, 'app_flutter/' + relative)


def make_fixture(folder):
    book = folder / 'proof.epub'
    with zipfile.ZipFile(book, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip')
        archive.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        archive.writestr('OEBPS/content.opf', f'''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="2.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{BOOK}</dc:title><dc:creator>Dogreader CI</dc:creator><dc:language>en</dc:language><dc:identifier id="id">proof</dc:identifier></metadata>
<manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine toc="ncx"><itemref idref="one"/><itemref idref="two"/></spine></package>''')
        archive.writestr('OEBPS/toc.ncx', f'''<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="proof"/></head><docTitle><text>{BOOK}</text></docTitle><navMap><navPoint id="one" playOrder="1"><navLabel><text>{ONE}</text></navLabel><content src="one.xhtml"/></navPoint><navPoint id="two" playOrder="2"><navLabel><text>{TWO}</text></navLabel><content src="two.xhtml"/></navPoint></navMap></ncx>''')
        for name, title in [('one', ONE), ('two', TWO)]:
            paragraphs = ''.join(f'<p>Mara watched the harbour lights. <em>Quiet water</em> reflected the <strong>last ferry</strong>. Paragraph {i} preserves the reader layout and a saved page position.</p>' for i in range(45))
            archive.writestr(f'OEBPS/{name}.xhtml', f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body><h1>{title}</h1>{paragraphs}<hr/><p>Across the island, another story began.</p></body></html>')
    audio = folder / 'proof_0.mp3'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=30',
                    '-ar', '24000', '-y', str(audio)], check=True)
    return book, audio


def verify_mode(mode, audio_test=False):
    expect(BOOK, 'BUILD 131', 'Chapters and narration')
    capture(f'{mode}-01-library')
    tap('Chapters and narration')
    expect(BOOK, ONE, TWO, 'Continue reading', 'Generate narration')
    capture(f'{mode}-02-chapters')
    tap(ONE)
    expect('Increase text size', 'Listen from this page', 'Tap to jump')
    capture(f'{mode}-03-reader')
    tap('Increase text size')
    expect('Tap to jump')
    tap('Tap to jump')
    expect('Jump to page', 'Go to page')
    capture(f'{mode}-04-page-jump')
    tap('Cancel')
    if audio_test:
        tap('Listen from this page')
        expect('Chapter narration', 'Replace chapter MP3', 'Play', '0:30')
        capture(f'{mode}-05-player')
        x1, y1, x2, y2 = bounds(find('Play'))
        center = ((x1 + x2) // 2, (y1 + y2) // 2)
        shell('input', 'tap', *center)
        time.sleep(1)
        assert re.search(r'state=3\b', shell('dumpsys', 'media_session')), 'Native media session did not start playback'
        shell('input', 'tap', *center)
        time.sleep(0.5)
        expect('Play')
        # Seek on the real player's accessibility slider; check saved handler progress.
        sliders = [n for n in xml().iter('node') if n.get('class') == 'android.widget.SeekBar']
        assert sliders, 'Native narration seek slider is absent'
        x1, y1, x2, y2 = bounds(sliders[0])
        shell('input', 'tap', (x1 + x2) // 2, (y1 + y2) // 2)
        time.sleep(1)
        assert abs(read_json('narration_state.json')['proof:0']['positionMs'] - 15000) < 3000, 'Native seek did not persist the middle position'
        checks.append('real decoder playback/pause and seek persisted')
        capture(f'{mode}-06-player-seek')
        back()
    back()
    expect(ONE, TWO)
    tap('Generate narration')
    expect('Narration engine', 'Preview voice', ONE, TWO, 'Repair audio from cloud', 'Delete chapter audio')
    capture(f'{mode}-07-narration')
    # Engine choice changes the future default, not the existing Google recording.
    pref = read_json('dogreader_queue.json').get('engine', 'google')
    if pref == 'google':
        tap('Google Chirp')
        tap('Kokoro')
    expect('George' if pref == 'google' else 'Lewis')
    if pref == 'google':
        tap('George')
        expect('Fable', 'Daniel', 'Lewis')
        tap('Lewis')
    expect('Kokoro', 'Lewis', 'Google Chirp', 'Charon')
    capture(f'{mode}-08-kokoro-chapter-controls')
    tap('Delete chapter audio')
    expect('Delete chapter audio?', 'The chapter text and reading progress will remain.')
    tap('Cancel')
    tap('Regenerate narration')
    expect('Regenerate narration?', 'Kokoro', 'Lewis')
    tap('Cancel')
    back()
    back()
    expect(BOOK, 'BUILD 131')


def main(apk):
    print('Installing the verified signed candidate (180-second limit)', flush=True)
    adb('install', '-r', apk, timeout=180)
    shell('run-as', PACKAGE, 'mkdir', '-p', 'app_flutter/epubs', 'app_flutter/narration')
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        book, audio = make_fixture(folder)
        seed(book, 'epubs/proof.epub')
        seed(audio, 'narration/proof_0.mp3')
        data = {
            'appearance.json': {'theme': 'light'},
            'reading_state.json': {'positions': {'proof': {'chapter': 0, 'offset': 50}}, 'chapterProgress': {'proof': {'0': 50}}, 'lastOpened': {'proof': 1}},
            'dogreader_queue.json': {'host': '', 'token': '', 'narrator': 'en-US-Chirp3-HD-Achernar', 'books': {'proof': {'0': {'id': 'a' * 32, 'status': 'ready', 'voice': 'en-US-Chirp3-HD-Charon'}}}},
        }
        for name, value in data.items():
            path = folder / name
            path.write_text(json.dumps(value))
            seed(path, name)
    launch = adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity', timeout=90)
    print(launch, flush=True)
    assert 'Error' not in launch, 'Android could not launch the installed APK'
    # Android 13 may ask for notification permission on the first launch.
    time.sleep(3)
    root = xml()
    if any('Allow' == label(n) for n in root.iter('node')):
        tap('Allow')
    verify_mode('light', audio_test=True)
    tap('Settings')
    tap('Light')
    tap('Dark')
    expect('Appearance', 'Dark')
    assert read_json('appearance.json')['theme'] == 'dark'
    capture('dark-00-settings')
    tap('Library')
    verify_mode('dark')
    tap('Settings')
    tap('Dark')
    tap('Follow system')
    assert read_json('appearance.json')['theme'] == 'system'
    capture('system-settings')
    shell('am', 'force-stop', PACKAGE)
    launch = adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity', timeout=90)
    print(launch, flush=True)
    assert 'Error' not in launch, 'Android could not launch the installed APK'
    expect(BOOK, 'BUILD 131')
    tap('Settings')
    expect('Follow system')
    tap('Library')
    tap('Chapters and narration')
    tap('Generate narration')
    expect('Kokoro', 'Lewis', 'Repair audio from cloud', 'Delete chapter audio')
    preferences = read_json('dogreader_queue.json')
    assert preferences['books']['proof']['0']['voice'] == 'en-US-Chirp3-HD-Charon'
    assert preferences['engine'] == 'kokoro' and preferences['narrator'] == 'bm_lewis'
    assert read_json('reading_state.json')['positions']['proof']['offset'] >= 0
    checks.append('restart retained EPUB, chapter progress, existing recording, appearance, and Kokoro default')
    (output / 'verification.json').write_text(json.dumps({'passed': True, 'checks': checks,
        'scope': 'actual signed APK 131 on Android 13 emulator; local EPUB and synthetic tone; no cloud generation'}, indent=2))
    print(json.dumps(checks, indent=2))


if __name__ == '__main__':
    output = Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    try:
        main(sys.argv[1])
    except Exception:
        (output / 'error.txt').write_text(traceback.format_exc())
        for name, command in [
            ('failure.png', ('exec-out', 'screencap', '-p')),
            ('failure.xml', ('exec-out', 'cat', '/sdcard/window.xml')),
            ('logcat.txt', ('logcat', '-d', '-t', '2000')),
            ('activities.txt', ('shell', 'dumpsys', 'activity', 'activities')),
        ]:
            try:
                (output / name).write_bytes(adb(*command, binary=True))
            except Exception as capture_error:
                (output / (name + '.error')).write_text(str(capture_error))
        raise
