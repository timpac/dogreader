"""Targeted real-FP32 tests of the same APK published for Pixel installation.

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

PACKAGE = 'com.dogreader.kokoro_probe'
ACTIVITY = PACKAGE + '/.MainActivity'
SERVICE = PACKAGE + '/.GenerationService'
PRIVATE = f'/data/user/0/{PACKAGE}/files'
OUTPUT = f'/sdcard/Android/data/{PACKAGE}/files'
ROOT = Path(__file__).resolve().parents[1]


def adb(*args, check=True):
    return subprocess.run(['adb', *args], check=check, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=120).stdout.strip()


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


def ui_click(label, attempts=12):
    for _ in range(attempts):
        shell('uiautomator', 'dump', '/sdcard/kokoro-ui.xml', check=False)
        raw = shell('cat', '/sdcard/kokoro-ui.xml', check=False)
        if raw:
            for node in ET.fromstring(raw).iter('node'):
                text = node.get('text', '') + node.get('content-desc', '')
                if label in text and node.get('enabled') == 'true' and node.get('clickable') == 'true':
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
    raise AssertionError('UI control not found: ' + label)


def start_job(short=False):
    shell('input', 'keyevent', 'KEYCODE_WAKEUP')
    shell('wm', 'dismiss-keyguard', check=False)
    shell('am', 'start', '-n', ACTIVITY)
    time.sleep(3)
    previous = state()
    ui_click('Load short comparison passage' if short else 'Load 1,000 words')
    ui_click('Generate FP32 offline audio')
    current = wait_for(lambda: (s if (s := state()) and s.get('active') and
        s.get('jobId') != (previous or {}).get('jobId') and s.get('phase') == 'generating' else None), 180)
    assert current['wakeLockHeld'] and current['pid'] > 0
    assert str(current['pid']) != shell('pidof', PACKAGE)
    return current


def cancel(job, via_ui):
    if via_ui:
        shell('am', 'start', '-n', ACTIVITY)
        time.sleep(2)
        ui_click('Cancel generation')
    else:
        # Dispatch the exact service action used by the notification PendingIntent.
        shell('am', 'startservice', '-n', SERVICE, '-a', PACKAGE + '.CANCEL', '--es', 'jobId', job['jobId'])
    ended = wait_for(lambda: (s if (s := state()) and not s.get('active') else None), 30)
    assert ended['outcome'] == 'cancelled' and ended['wakeLockHeld'] is False, ended
    wait_for(lambda: not shell('pidof', PACKAGE + ':kokoro_generation', check=False), 15)
    assert 'LocalGeneration' not in shell('dumpsys', 'power').split('Wake Locks:')[-1].split('Suspend Blockers:')[0]
    report = read_json(ended['reportPath'])
    assert report and report['completed'] is False and report['outcome'] == 'cancelled'
    partials = shell('find', OUTPUT, '-name', f'*{job["jobId"]}*.part', check=False)
    assert not partials, partials
    return report


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
    uid = re.search(r'userId=(\d+)', shell('dumpsys', 'package', PACKAGE))[1]
    shell('chown', '-R', uid+':'+uid, PRIVATE)
    shell('restorecon', '-R', PRIVATE)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    assert shell('getprop', 'ro.kernel.qemu') == '1', 'Emulator only; never modify a phone'
    adb('root'); adb('wait-for-device')
    assert shell('id', '-u') == '0', 'Use a disposable rooted google_apis image'
    adb('install', '-r', str(args.apk))
    shell('pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
    shell('settings', 'put', 'system', 'screen_off_timeout', '1800000')
    shell('am', 'start', '-n', ACTIVITY); time.sleep(3)
    shell('am', 'force-stop', PACKAGE)  # No job has started; creates the app-private directory.
    models = args.output/'fixtures'; models.mkdir()
    fixture_models(models)
    shell('svc', 'wifi', 'disable'); shell('svc', 'data', 'disable')
    results = []
    try:
        short = start_job(short=True)
        ended = wait_for(lambda: (s if (s := state()) and not s.get('active') else None), 180)
        assert ended['outcome'] == 'completed' and ended['wakeLockHeld'] is False, ended
        wait_for(lambda: not shell('pidof', PACKAGE+':kokoro_generation', check=False), 15)
        success = read_json(ended['reportPath'])
        assert success['completed'] and success['results']
        result = success['results'][-1]
        assert result['modelVariant'] == 'fp32' and result['frontend'].startswith('misaki-')
        assert result['rawPeakAmplitude'] > 1e-5
        good_wav = result['path']
        adb('pull', good_wav, str(args.output/'completion.wav'))
        with wave.open(str(args.output/'completion.wav'), 'rb') as wav:
            assert (wav.getframerate(),wav.getnchannels(),wav.getsampwidth(),wav.getnframes()) == (24000,1,2,result['sampleFrames'])
        (args.output/'completion.json').write_text(json.dumps(success,indent=2)+'\n')
        results.append({'test':'normal_completion','pass':True,'frames':result['sampleFrames']})
        for mode in ['app_switch', 'screen_lock']:
            job = start_job()
            if mode == 'app_switch':
                shell('input', 'keyevent', 'KEYCODE_HOME')
            else:
                shell('input', 'keyevent', 'KEYCODE_SLEEP')
                assert not read_json(PRIVATE+'/generation-state.json').get('active') is False
            before = int(time.time()*1000)
            # No UI polling or resume during the measured interval.
            time.sleep(30)
            after = int(time.time()*1000)
            worker = events(job['jobId'], 'worker')
            service = events(job['jobId'], 'service')
            completed = [e for e in worker if e['event'] == 'chunkInferenceEnd' and before+2000 < e['unixMs'] < after-1000]
            observed = [e for e in service if e['event'] == 'progress' and before+2000 < e['unixMs'] < after-1000 and not e['uiVisible']]
            assert len(completed) >= 2, (mode, completed, state())
            assert observed and all(e['wakeLockHeld'] for e in observed)
            if mode == 'screen_lock':
                assert any(not e['interactive'] for e in observed), observed
            else:
                assert any(e['interactive'] for e in observed), observed
                # The service must also outlive actual UI-process death.
                ui_pid = shell('pidof', PACKAGE)
                assert ui_pid and int(ui_pid) != job['pid']
                shell('kill', '-9', ui_pid)
                killed_at = int(time.time()*1000)
                time.sleep(12)
                assert any(e['event'] == 'chunkInferenceEnd' and e['unixMs'] > killed_at+1000
                           for e in events(job['jobId'], 'worker'))
            foreground = shell('dumpsys', 'activity', 'services', PACKAGE)
            assert 'isForeground=true' in foreground or 'isForeground=true' in foreground.replace(' ', '')
            power = shell('dumpsys', 'power')
            assert 'LocalGeneration' in power
            report = cancel(job, via_ui=mode == 'app_switch')
            assert shell('test', '-f', good_wav, '&&', 'echo', 'exists') == 'exists'
            saved = read_json(PRIVATE+'/generation-recordings.json')
            assert saved['fp32']['path'] == good_wav
            (args.output/(mode+'.json')).write_text(json.dumps(report, indent=2)+'\n')
            (args.output/(mode+'-services.txt')).write_text(foreground)
            (args.output/(mode+'-power.txt')).write_text(power)
            results.append({'test':mode, 'pass':True, 'intervalStartUnixMs':before,
                            'intervalEndUnixMs':after, 'completedDuringInterval':len(completed),
                            'workerPid':job['pid'], 'uiProcessDeathTested':mode=='app_switch',
                            'cancellation':'UI' if mode=='app_switch' else 'notification service action'})
            shell('input', 'keyevent', 'KEYCODE_WAKEUP'); shell('wm', 'dismiss-keyguard', check=False)
        (args.output/'background-tests.json').write_text(json.dumps({
            'platform':'Android emulator; NOT Pixel measurements', 'sdk':shell('getprop','ro.build.version.sdk'),
            'abi':shell('getprop','ro.product.cpu.abi'), 'realFp32Inference':True,
            'allPassed':True, 'tests':results,
            'limitations':'Short controlled intervals on a powered emulator; not prolonged Doze/OEM/battery validation.'}, indent=2)+'\n')
    finally:
        (args.output/'logcat.txt').write_text(adb('logcat','-d','-v','threadtime'))
        # Keep model binaries out of the retained test artifact.
        import shutil
        shutil.rmtree(models)


if __name__ == '__main__':
    main()
