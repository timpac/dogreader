"""Compare APK identities/manifests without installing or changing either app."""
import argparse
import re
import subprocess


def declarations(tree):
    stack, authorities, permissions = [], set(), set()
    if 'android:sharedUserId' in tree:
        raise ValueError('Shared Android UID is forbidden')
    for line in tree.splitlines():
        element = re.match(r'(\s*)E: ([\w-]+)', line)
        if element:
            indent = len(element[1])
            while stack and stack[-1][0] >= indent:
                stack.pop()
            stack.append((indent, element[2]))
        attribute = re.search(r'A: android:(name|authorities)\([^)]*\)="([^"]+)"', line)
        if not attribute or not stack:
            continue
        kind, value = attribute.groups()
        if stack[-1][1] == 'provider' and kind == 'authorities':
            authorities.update(value.split(';'))
        if stack[-1][1] == 'permission' and kind == 'name':
            permissions.add(value)
    return authorities, permissions


def verify(original_badging, experimental_badging, original_tree, experimental_tree, number):
    if "package: name='com.example.audiobook_app' versionCode='135'" not in original_badging:
        raise ValueError('Original APK is not build 135')
    expected = f"package: name='com.example.audiobook_app.experimental' versionCode='{number}'"
    if expected not in experimental_badging:
        raise ValueError('Experimental package/version mismatch')
    for expected in ["application-label:'Dog Reader 2.0'", 'ic_launcher_experimental',
                     "launchable-activity: name='com.example.audiobook_app.MainActivity'"]:
        if expected not in experimental_badging:
            raise ValueError('Experimental launcher identity mismatch: ' + expected)
    original = declarations(original_tree)
    experimental = declarations(experimental_tree)
    if original[0] & experimental[0]:
        raise ValueError('Provider authorities would conflict during installation')
    if original[1] & experimental[1]:
        raise ValueError('Declared permissions would conflict during installation')
    return 'Distinct package, launcher, provider authorities and declared permissions; no shared UID. Android private storage is package-isolated. Physical installation not exercised.'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('aapt')
    parser.add_argument('original')
    parser.add_argument('experimental')
    parser.add_argument('number')
    args = parser.parse_args()
    def dump(path, kind):
        command = [args.aapt, 'dump', kind, path]
        if kind == 'xmltree':
            command.append('AndroidManifest.xml')
        return subprocess.check_output(command, text=True)
    print(verify(dump(args.original, 'badging'), dump(args.experimental, 'badging'),
                 dump(args.original, 'xmltree'), dump(args.experimental, 'xmltree'), args.number))


if __name__ == '__main__':
    main()
