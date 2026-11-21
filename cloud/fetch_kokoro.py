"""Build-time only. Pin numeric GitHub asset IDs (reuploads get different IDs)."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import urllib.request

ASSETS = [('kokoro-v1.0.onnx', 224414194, 325532387,
           '7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5'),
          ('voices-v1.0.bin', 227558528, 28214398,
           'bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d')]


def fetch(folder):
    folder.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name, asset_id, size, expected_sha256 in ASSETS:
        url = f'https://api.github.com/repos/thewh1teagle/kokoro-onnx/releases/assets/{asset_id}'
        request = urllib.request.Request(url, headers={'Accept': 'application/octet-stream',
                                                       'User-Agent': 'Dogreader-build'})
        target = folder / name
        with urllib.request.urlopen(request, timeout=180) as response, target.open('wb') as out:
            shutil.copyfileobj(response, out, length=1024 * 1024)
        if target.stat().st_size != size:
            raise ValueError(f'Pinned model asset size mismatch: {name}')
        with target.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != expected_sha256:
            raise ValueError(f'Pinned model asset SHA-256 mismatch: {name}')
        manifest.append(dict(name=name, asset_id=asset_id, bytes=size, sha256=digest))
    (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    fetch(Path(sys.argv[1]))
