"""Tap real Android System UI controls on an isolated CI emulator.

Requires the synthetic probe APK, never the user's installed application.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

PACKAGE = 'com.example.audiobook_app.test'
ACTIVITY = PACKAGE + '/com.example.audiobook_app.MainActivity'


def adb(*args):
    result = subprocess.run(['adb', *args], text=True, capture_output=True,
                            timeout=30, check=True)
    return result.stdout


def snapshot():
    value = json.loads(adb('shell', 'run-as', PACKAGE, 'cat',
                          'app_flutter/media-control-probe.json'))
    if value.get('fatal'):
        raise AssertionError('Probe error: ' + value['fatal'])
    return value


def wait_for(predicate, timeout=25):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = snapshot()
            if predicate(last):
                return last
        except (subprocess.SubprocessError, ValueError):
            pass
        time.sleep(.25)
    raise AssertionError('Timed out; last probe state: ' + json.dumps(last))


def hierarchy():
    adb('shell', 'uiautomator', 'dump', '--compressed', '/sdcard/media-probe-ui.xml')
    return adb('shell', 'cat', '/sdcard/media-probe-ui.xml')


def tap(label):
    deadline = time.monotonic() + 15
    last = ''
    while time.monotonic() < deadline:
        last = hierarchy()
        tree = ET.fromstring(last)
        for node in tree.iter('node'):
            description = node.get('content-desc', '') or node.get('text', '')
            if label.casefold() != description.casefold():
                continue
            coords = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
            if len(coords) == 4 and coords[2] > coords[0] and coords[3] > coords[1]:
                adb('shell', 'input', 'tap', str((coords[0] + coords[2]) // 2),
                    str((coords[1] + coords[3]) // 2))
                return
        time.sleep(.25)
    raise AssertionError('System UI control absent: ' + label + '; hierarchy: ' + last)


def command(label, method, playing=None, direction=0):
    before = snapshot()
    count = before['commands'].get(method, 0)
    tap(label)
    after = wait_for(lambda state: state['commands'].get(method, 0) > count and
                     (playing is None or state['playing'] == playing) and
                     (playing is None or state['sessionPlaying'] == playing))
    if direction:
        # Compare with position at callback entry, excluding UI dump/tap delay.
        delta = after['positionMs'] - after['commandPositionsMs'][method]
        if direction * delta < 10000:
            raise AssertionError(f'{label} delivered but position did not move: {delta}')
    print(json.dumps({'control': label, 'received': method,
                      'playing': after['playing'], 'positionMs': after['positionMs']}), flush=True)


def run(apk):
    # Refuse any APK/package outside the deliberately separate test namespace.
    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise AssertionError('This test is restricted to an emulator, not a user phone.')
    sdk = Path(os.environ.get('ANDROID_HOME', os.environ.get('ANDROID_SDK_ROOT', '')))
    tools = sorted((sdk / 'build-tools').glob('*/aapt'))
    if not tools:
        raise AssertionError('Android aapt is required to verify the test APK identity.')
    identity = subprocess.run([str(tools[-1]), 'dump', 'badging', str(apk)],
                              capture_output=True, text=True, check=True, timeout=30).stdout
    if f"package: name='{PACKAGE}' " not in identity:
        raise AssertionError('Refusing an APK outside the isolated test package.')
    adb('install', '-r', '-t', str(apk))
    adb('shell', 'am', 'force-stop', PACKAGE)
    adb('shell', 'pm', 'clear', PACKAGE)
    adb('shell', 'am', 'start', '-n', ACTIVITY)
    wait_for(lambda state: state['playing'] and state['sessionPlaying'] and
             (state['durationMs'] or 0) > 200000)

    # A positive control: direct media-key delivery bypasses notification touch.
    before = snapshot()['commands'].get('pause', 0)
    adb('shell', 'cmd', 'media_session', 'dispatch', 'pause')
    wait_for(lambda state: not state['playing'] and
             state['commands'].get('pause', 0) > before)
    adb('shell', 'cmd', 'media_session', 'dispatch', 'play')
    wait_for(lambda state: state['playing'])

    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    adb('shell', 'cmd', 'statusbar', 'expand-notifications')
    command('Pause', 'pause', playing=False)
    command('Play', 'play', playing=True)
    command('Rewind', 'rewind', direction=-1)
    command('Fast forward', 'fastForward', direction=1)

    adb('shell', 'cmd', 'statusbar', 'collapse')
    adb('shell', 'locksettings', 'set-disabled', 'false')
    adb('shell', 'input', 'keyevent', 'KEYCODE_SLEEP')
    time.sleep(1)
    adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    command('Pause', 'pause', playing=False)
    command('Play', 'play', playing=True)

    # Explicit stop/restart with the real cached Flutter engine still alive.
    adb('shell', 'wm', 'dismiss-keyguard')
    adb('shell', 'am', 'start', '-n', ACTIVITY)
    command('In-app Stop', 'stop', playing=False)
    command('In-app Play', 'play', playing=True)
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    adb('shell', 'cmd', 'statusbar', 'expand-notifications')
    command('Pause', 'pause', playing=False)
    command('Play', 'play', playing=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = {'package': PACKAGE, 'success': False}
    try:
        run(args.apk)
        report['success'] = True
    except Exception as error:
        report['error'] = str(error)
        print(json.dumps(report), flush=True)
        try:
            print(adb('shell', 'dumpsys', 'media_session'), flush=True)
            print(adb('logcat', '-d', '-t', '200', '-s', 'flutter', 'AudioService'), flush=True)
        except subprocess.SubprocessError:
            pass
        raise
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
