"""Run real Android instrumentation only on an isolated CI emulator."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

PACKAGE = 'com.example.audiobook_app.test'
TEST_PACKAGE = PACKAGE + '.runner'
STAGES = {
    'own-session-pause', 'own-session-play', 'background-session-pause', 'background-session-play',
    'background-rewind', 'background-forward', 'lock-session-pause', 'lock-session-play',
    'app-stop', 'app-restart', 'restart-background-pause', 'restart-background-play',
    'focus-automatic-resume', 'focus-pause-stays-paused',
    'rapid-commands-final-pause', 'foreground-final-pause',
}


def adb(*args, timeout=30):
    return subprocess.run(['adb', *args], text=True, capture_output=True,
                          timeout=timeout, check=True).stdout


def check_identity(apk, package):
    sdk = Path(os.environ.get('ANDROID_HOME', os.environ.get('ANDROID_SDK_ROOT', '')))
    tools = sorted((sdk / 'build-tools').glob('*/aapt'))
    if not tools:
        raise AssertionError('Android aapt is required to verify the test APK identity.')
    output = subprocess.run([str(tools[-1]), 'dump', 'badging', str(apk)],
                            capture_output=True, text=True, check=True, timeout=30).stdout
    if f"package: name='{package}' " not in output:
        raise AssertionError('Refusing an APK outside the isolated test packages.')


def run(apk, instrumentation_apk):
    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise AssertionError('This check is restricted to an emulator, not a user phone.')
    check_identity(apk, PACKAGE)
    check_identity(instrumentation_apk, TEST_PACKAGE)
    adb('install', '-r', '-t', str(apk))
    adb('install', '-r', '-t', str(instrumentation_apk))
    adb('shell', 'am', 'force-stop', PACKAGE)
    adb('shell', 'pm', 'clear', PACKAGE)
    # Instrumentation owns launch and the complete session. Starting a separate
    # instrumentation for each dump would restart the app and invalidate it.
    output = adb('shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
                 'com.example.audiobook_app.MediaControlDeliveryTest',
                 TEST_PACKAGE + '/androidx.test.runner.AndroidJUnitRunner',
                 timeout=360)
    print(output, flush=True)
    stages = set()
    for line in output.splitlines():
        if 'MEDIA_CONTROL_RESULT ' in line:
            value = json.loads(line.split('MEDIA_CONTROL_RESULT ', 1)[1])
            stages.add(value['stage'])
    if not re.search(r'OK \(1 test\)', output) or stages != STAGES:
        raise AssertionError('Native instrumentation did not pass all stages: ' +
                             json.dumps(sorted(stages)) + '\n' + output[-16000:])
    return sorted(stages)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--instrumentation-apk', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = {'package': PACKAGE, 'success': False}
    try:
        report['stages'] = run(args.apk, args.instrumentation_apk)
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
