"""One-chapter acceptance of the same independent Dogreader 3.0 APK.

Requires a rooted, disposable google_apis emulator; never run on a user's phone.
Starts inference through the actual foreground UI. No synthetic inference mode.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import time
import urllib.request
import xml.etree.ElementTree as ET
import wave

PACKAGE = 'com.dogreader.v3'
ACTIVITY = PACKAGE + '/com.example.audiobook_app.MainActivity'
SERVICE = PACKAGE + '/com.example.audiobook_app.GenerationService'
PRIVATE = f'/data/user/0/{PACKAGE}/files'
OUTPUT = f'/sdcard/Android/data/{PACKAGE}/files'
ROOT = Path(__file__).resolve().parents[1]


def adb(*args, check=True):
    command = ['adb', '-s', 'emulator-5554', *args]
    result = subprocess.run(command, check=False, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=120)
    if result.returncode:
        print('ADB failure:', command, result.returncode, result.stdout, result.stderr, flush=True)
        if check:
            raise RuntimeError('ADB command failed: '+str(command)+'; '+result.stdout+'; '+result.stderr)
    return result.stdout.strip()


def shell(*args, check=True):
    return adb('shell', *args, check=check)


def read_json(path):
    text = shell('cat', path, check=False)
    return json.loads(text) if text else None


def state():
    return read_json(PRIVATE + '/generation-state.json')


def events(job, kind):
    raw = shell('cat', f'{PRIVATE}/generation-jobs/{job}/{kind}-events.jsonl', check=False)
    result = []
    for line in raw.splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result


def wait_for(predicate, seconds=120):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(1)
    raise AssertionError('Timed out waiting for device condition')


def ui_click(label, attempts=12, exact=False):
    for _ in range(attempts):
        shell('uiautomator', 'dump', '/sdcard/kokoro-ui.xml', check=False)
        raw = shell('cat', '/sdcard/kokoro-ui.xml', check=False)
        if raw:
            tree = ET.fromstring(raw)
            parents = {child: parent for parent in tree.iter() for child in parent}
            for node in tree.iter('node'):
                text = node.get('text', '') + node.get('content-desc', '')
                target = node
                while target is not None and target.get('clickable') != 'true':
                    target = parents.get(target)
                if (text == label if exact else label in text) and node.get('enabled') == 'true' and target is not None:
                    bounds = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
                    if len(bounds) == 4:
                        x1, y1, x2, y2 = bounds
                        shell('input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
                        return
        if _ < attempts//2:
            shell('input', 'swipe', '500', '1600', '500', '650', '350')
        else:
            shell('input', 'swipe', '500', '650', '500', '1600', '350')
        time.sleep(1)
    print('UI control not found:', label, 'hierarchy:', raw, flush=True)
    raise AssertionError('UI control not found: ' + label)


def fixture_models(temp):
    spec = json.loads((ROOT/'fp32-model-manifest.json').read_text())
    archive = temp/'fp32.tar.bz2'
    with urllib.request.urlopen(spec['url'], timeout=120) as src, archive.open('wb') as dst:
        while block := src.read(1024*1024):
            dst.write(block)
    with archive.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == spec['archiveSha256']
    folder = temp/spec['directory']
    folder.mkdir()
    with tarfile.open(archive) as tar:
        for name, item in spec['files'].items():
            data = tar.extractfile(spec['directory']+'/'+name).read()
            assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256']
            (folder/name).write_bytes(data)
    (folder/'READY').write_text(spec['archiveSha256'])
    adb('push', str(folder), PRIVATE + '/')
    front = json.loads((ROOT/'english-frontend-manifest.json').read_text())
    destination = temp/front['directory']
    destination.mkdir()
    for name, item in front['files'].items():
        with urllib.request.urlopen(item['url'], timeout=120) as src:
            data = src.read()
        assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256']
        (destination/name).write_bytes(data)
    (destination/'READY').write_text(front['id'])
    adb('push', str(destination), PRIVATE + '/')
    # Android 15 package dumps may report appId instead of the older userId.
    # The initialized app data directory is already owned by the app UID.
    uid = shell('stat', '-c', '%u', f'/data/user/0/{PACKAGE}')
    assert uid.isdigit() and int(uid) >= 10000, ('Unexpected app data owner', uid)
    shell('chown', '-R', uid+':'+uid, PRIVATE)
    shell('restorecon', '-R', PRIVATE)



def download_release(tag, destination):
    with urllib.request.urlopen('https://api.github.com/repos/timpac/dogreader/releases/tags/'+tag, timeout=60) as src:
        release = json.load(src)
    candidates = [a for a in release['assets'] if a['name'].endswith('.apk')]
    assert len(candidates) == 1 and not release['draft']
    asset = candidates[0]
    digest = hashlib.sha256()
    with urllib.request.urlopen(asset['browser_download_url'], timeout=120) as src, destination.open('wb') as dst:
        while block := src.read(1024*1024):
            digest.update(block); dst.write(block)
    assert destination.stat().st_size == asset['size']
    assert asset['digest'] == 'sha256:'+digest.hexdigest()
    return {'tag':tag, 'sha256':digest.hexdigest(), 'bytes':asset['size']}


def make_epub(path):
    import html, zipfile
    # Same public test passage as build 148, wrapped in an actual EPUB archive.
    passage = '\n\n'.join((ROOT/'test/fixtures/chapter.txt').read_text().split('\n\n')[:4])
    with zipfile.ZipFile(path, 'w') as epub:
        epub.writestr('mimetype','application/epub+zip', compress_type=zipfile.ZIP_STORED)
        epub.writestr('META-INF/container.xml', '\n'.join([
            '<?xml version="1.0"?>',
            '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">',
            '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>']))
        epub.writestr('content.opf', '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">dogreader3-acceptance</dc:identifier><dc:title>Dogreader 3.0 Offline Acceptance</dc:title><dc:creator>Dogreader test fixture</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine toc="ncx"><itemref idref="chapter"/></spine></package>')
        epub.writestr('toc.ncx', '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="dogreader3-acceptance"/></head><docTitle><text>Dogreader 3.0 Offline Acceptance</text></docTitle><navMap><navPoint id="one" playOrder="1"><navLabel><text>Acceptance chapter</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>')
        epub.writestr('chapter.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Acceptance chapter</title></head><body>'+''.join('<p>'+html.escape(p)+'</p>' for p in passage.split('\n\n') if p.strip())+'</body></html>')
    return hashlib.sha256(passage.encode()).hexdigest()


def ui_snapshot():
    shell('uiautomator', 'dump', '/sdcard/kokoro-ui.xml', check=False)
    return shell('cat', '/sdcard/kokoro-ui.xml', check=False)



def media_session_playing(sessions):
    # Android now prints symbolic names (PLAYING(3)); older versions print 3.
    # Inspect our package's session, never a Bluetooth/assistant session.
    match = re.search(r'^\s*package=' + re.escape(PACKAGE) + r'\s*\n(.*?)(?=^\s*package=|\Z)', sessions, re.M|re.S)
    return bool(match and re.search(r'\bstate=(?:3\b|PLAYING\(3\))', match[1]))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    assert shell('getprop','ro.kernel.qemu') == '1', 'Disposable emulator only; never run on a phone'
    for attempt in range(3):
        adb('root', check=False); adb('wait-for-device')
        if shell('id','-u',check=False) == '0': break
        time.sleep(2)
    assert shell('id','-u') == '0', 'Rooted google_apis emulator required; no phone or app changes attempted'
    fixtures = args.output/'fixtures'; fixtures.mkdir()
    try:
        # Install existing immutable apps beside the new one; no cloud calls or user data.
        installs = {}
        for tag, package in [('v135','com.example.audiobook_app'), ('v148-kokoro-offline','com.dogreader.kokoro_probe')]:
            apk = fixtures/(tag+'.apk')
            installs[package] = download_release(tag, apk)
            adb('install','-r',str(apk))
            assert package in shell('pm','list','packages',package)
            sentinel = f'/data/user/0/{package}/dogreader3-isolation-sentinel'
            shell('sh','-c', f'"echo unchanged > {sentinel}"')
        adb('install','-r',str(args.apk))
        shell('pm','grant',PACKAGE,'android.permission.POST_NOTIFICATIONS')
        shell('settings','put','system','screen_off_timeout','1800000')
        shell('input','keyevent','KEYCODE_WAKEUP'); shell('wm','dismiss-keyguard',check=False)
        shell('am','start','-n',ACTIVITY); time.sleep(5)
        shell('am','force-stop',PACKAGE)  # Before any inference; initializes private paths.
        fixture_models(fixtures)
        epub = fixtures/'Dogreader3-acceptance.epub'
        source_hash = make_epub(epub)
        adb('push',str(epub),'/sdcard/Download/Dogreader3-acceptance.epub')
        shell('am','broadcast','-a','android.intent.action.MEDIA_SCANNER_SCAN_FILE','-d','file:///sdcard/Download/Dogreader3-acceptance.epub',check=False)
        shell('svc','wifi','disable'); shell('svc','data','disable')
        shell('am','start','-n',ACTIVITY); time.sleep(3)
        assert not read_json('/data/user/0/'+PACKAGE+'/app_flutter/dogreader_queue.json'), 'No automatic cloud configuration/migration'
        ui_click('Import a book')
        ui_click('Show roots', attempts=3)
        ui_click('Downloads', attempts=4)
        ui_click('Dogreader3-acceptance.epub', attempts=6, exact=True)
        wait_for(lambda: 'Dogreader 3.0 Offline Acceptance' in ui_snapshot(), 60)
        ui_click('Chapters and narration')
        ui_click('Generate narration')
        ui_click('Kokoro Offline')
        ui_click('Generate chapter offline')
        job = wait_for(lambda: s if (s:=state()) and s.get('active') and s.get('phase')=='generating' else None, 180)
        assert job['wakeLockHeld'] and job['chapter']['engine']=='kokoro_offline'
        assert str(job['pid']) != shell('pidof',PACKAGE)
        shell('input','keyevent','KEYCODE_SLEEP')
        before = int(time.time()*1000)
        time.sleep(30)
        after = int(time.time()*1000)
        worker = events(job['jobId'],'worker'); service = events(job['jobId'],'service')
        completions = [e for e in worker if e['event']=='chunkInferenceEnd' and before+2000 < e['unixMs'] < after-1000]
        assert len(completions)>=2, (completions,state())
        observed = [e for e in service if e['event']=='progress' and before+2000 < e['unixMs'] < after-1000]
        assert observed and any(not e['interactive'] and not e['uiVisible'] and e['wakeLockHeld'] for e in observed)
        # Keep the screen off until the full chapter completes; never resume the UI to drive progress.
        ended = wait_for(lambda: s if (s:=state()) and not s.get('active') else None, 480)
        assert ended['outcome']=='completed' and ended['wakeLockHeld'] is False, ended
        wait_for(lambda: not shell('pidof',PACKAGE+':kokoro_generation',check=False),15)
        report = read_json(ended['reportPath']); assert report['completed']
        index = read_json(PRIVATE+'/offline-recordings.json')
        chapter = index[job['chapter']['key']]
        result = chapter['result']
        assert chapter['engine']=='kokoro_offline' and chapter['voice']=='af_heart'
        assert result['modelFileSha256']=='b40f62b166ac8164b0627ef48a0b358eda0985e272fb03ef5252e7206305da11'
        assert result['frontendDiagnostics']['coverageChecked'] and result['rawPeakAmplitude']>1e-5
        assert ended['completedChunks']==result['chunkCount']==ended['totalChunks']
        wav_path = args.output/'chapter.wav'; adb('pull',result['path'],str(wav_path))
        assert hashlib.sha256(wav_path.read_bytes()).hexdigest()==result['wavSha256']
        with wave.open(str(wav_path),'rb') as wav:
            assert (wav.getframerate(),wav.getnchannels(),wav.getsampwidth(),wav.getnframes())==(24000,1,2,result['sampleFrames'])
        # Every synthesized chunk must have a committed checkpoint; exact byte identity is unit-tested.
        chunk_files = shell('ls', f"{PRIVATE}/generation-jobs/{job['jobId']}/chunks/*.json").splitlines()
        assert len(chunk_files)==result['chunkCount']
        uids = {p:shell('stat','-c','%u',f'/data/user/0/{p}') for p in [*installs,PACKAGE]}
        assert len(set(uids.values()))==3
        for package in installs:
            assert shell('cat',f'/data/user/0/{package}/dogreader3-isolation-sentinel')=='unchanged'
        (args.output/'chapter-report.json').write_text(json.dumps(report,indent=2)+'\n')
        (args.output/'generation-checks.json').write_text(json.dumps({
            'platform':'Android emulator; NOT Pixel measurements','package':PACKAGE,
            'coinstalled':uids,'privateSentinelsPreserved':True,
            'epubImportedThroughSystemPicker':True,'completedWhileScreenOff':True,
            'screenOffIntervalStartUnixMs':before,'screenOffIntervalEndUnixMs':after,
            'nativeChunkCompletionsDuringInterval':len(completions),
            'chunkCount':result['chunkCount'],'sampleFrames':result['sampleFrames'],
            'audioSeconds':result['audioSeconds'],'wavSha256':result['wavSha256'],
            'sampleRate':24000,'channels':1,'bits':16,'wakeLockReleased':True,
            'playbackNotYetChecked':True},indent=2)+'\n')
        shell('input','keyevent','KEYCODE_WAKEUP'); shell('wm','dismiss-keyguard',check=False)
        shell('am','start','-n',ACTIVITY); time.sleep(3)
        ui_click('Play completed chapter')
        ui_click('Play', exact=True)
        time.sleep(6)
        sessions = shell('dumpsys','media_session')
        assert media_session_playing(sessions), sessions
        ui_click('Pause', exact=True)  # Persists observed playback position.
        selected = wait_for(lambda: e if (d:=read_json('/data/user/0/'+PACKAGE+'/app_flutter/narration_state.json')) and (e:=d.get(job['chapter']['key'])) and e.get('positionMs',0)>1000 else None, 15)
        assert selected['engine']=='kokoro_offline' and selected['path']==result['path']
        assert selected['positionMs']>1000, selected
        summary = {'platform':'Android 15 x86_64 emulator; NOT Pixel measurements', 'allPassed':True,
            'singleCompiledApk':True,'package':PACKAGE,'coinstalled':uids,'existingReleaseApks':installs,
            'epubImportedThroughSystemPicker':True,'fixturePassageSha256':source_hash,'fixtureWords':391,
            'chapterEngine':chapter['engine'],'modelFileSha256':result['modelFileSha256'],
            'chunkCount':result['chunkCount'],'completedWhileScreenOff':True,
            'measuredScreenOffInterval':{'startUnixMs':before,'endUnixMs':after,'nativeChunkCompletions':len(completions)},
            'wav':{'sha256':result['wavSha256'],'sampleFrames':result['sampleFrames'],'sampleRate':24000,'channels':1,'bits':16},
            'playbackObservedPositionMs':selected['positionMs'],'wakeLockReleased':True,
            'limitations':'Powered emulator, no listening judgement or Pixel battery/heat/endurance result. No paid cloud generation.'}
        (args.output/'MILESTONE.json').write_text(json.dumps(summary,indent=2)+'\n')
        (args.output/'playback-session.txt').write_text(sessions)
        print(json.dumps(summary,indent=2))
    finally:
        (args.output/'logcat.txt').write_text(adb('logcat','-d','-v','threadtime'))
        (args.output/'ui.xml').write_text(ui_snapshot())
        import shutil
        shutil.rmtree(fixtures)


if __name__=='__main__':
    main()
