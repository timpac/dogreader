"""Materialize only pinned frontend source/header inputs. No FONNX hooks or ORT binary."""
from pathlib import Path
import argparse
import hashlib
import io
import json
import re
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
FONNX_SHA = '41eca06a51d05078d7fa9bcfcdf7782d1ee17ed0fd018db381573d444bfec170'
ORT_REV = '33ca9628233dc8f002435e868d4c2e9f82766ca1'  # v1.28.2
receipts = {}

def download(url, expected=None):
    data = urllib.request.urlopen(url, timeout=90).read()
    digest = hashlib.sha256(data).hexdigest()
    if expected and digest != expected:
        raise ValueError('Checksum mismatch: ' + url)
    receipts[url] = {'bytes': len(data), 'sha256': digest}
    return data

def prepare():
    archive = tarfile.open(fileobj=io.BytesIO(download(
        'https://pub.dev/api/archives/fonnx-1.2.0.tar.gz', FONNX_SHA)))
    dest = ROOT / 'lib/third_party/fonnx_misaki'
    dest.mkdir(parents=True, exist_ok=True)
    names = ['misaki.dart', 'misaki_en.dart', 'spacy_en.dart', 'spacy_hash.dart',
             'num2words_en.dart', 'misaki_fallback.dart']
    for name in names:
        source = archive.extractfile('lib/models/kokoro/misaki/' + name).read().decode()
        source = source.replace('package:fonnx/models/kokoro/misaki/', '')
        (dest/name).write_text('// Vendored from hash-pinned FONNX 1.2.0; imports made relative.\n' + source)
    for name in ['diacritic.dart', 'replacement_map.dart']:
        source = archive.extractfile('lib/third_party/diacritic/' + name).read().decode()
        source = source.replace('package:fonnx/third_party/diacritic/', '')
        (dest/name).write_text(source)
    notices = [
        'Experimental frontend only. No FONNX native runtime/hook or Kokoro engine is used.',
        'FONNX 1.2.0 root MIT; Apache-2.0-derived Misaki; spaCy MIT; diacritic BSD-3-Clause.',
        archive.extractfile('LICENSE').read().decode(),
        archive.extractfile('lib/third_party/diacritic/LICENSE').read().decode(),
        archive.extractfile('lib/third_party/diacritic/ORIGINAL_LICENSE').read().decode(),
    ]
    # Misaki's exact published sdist has the upstream Apache license.
    misaki = tarfile.open(fileobj=io.BytesIO(download(
        'https://files.pythonhosted.org/packages/1a/c7/fb01370a76585b46595a01b52f18e65c8ba6d7a313a05e5d9fff0a8e1c69/misaki-0.9.4.tar.gz',
        '3960fa3e6de179a90ee8e628446a4a4f6b8c730b6e3410999cf396189f4d9c40')))
    notices.append(misaki.extractfile('misaki-0.9.4/LICENSE').read().decode())
    notices.append('English fallback ONNX export: PeterReid/graphemes_to_phonemes_en_us at '
                   'a5631b285d18d59483c32c0c3379cb9fac924f4b; publisher declares Apache-2.0. '
                   'No detailed training-data provenance or standalone LICENSE was supplied upstream.')
    # Model release wheel: use its exact license/source notices, not another spaCy version.
    import zipfile
    wheel = zipfile.ZipFile(io.BytesIO(download(
        'https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl',
        '1932429db727d4bff3deed6b34cfc05df17794f4a52eeb26cf8928f7c1a0fb85')))
    for n in ['LICENSE', 'LICENSES_SOURCES']:
        notices.append(wheel.read('en_core_web_sm/en_core_web_sm-3.8.0/'+n).decode())
    headers = ROOT / 'native/ort_headers'
    headers.mkdir(exist_ok=True)
    base = 'https://raw.githubusercontent.com/microsoft/onnxruntime/'+ORT_REV+'/'
    for n in ['onnxruntime_c_api.h', 'onnxruntime_error_code.h', 'onnxruntime_ep_c_api.h', 'onnxruntime_float16.h']:
        data = download(base+'include/onnxruntime/core/session/'+n)
        (headers/n).write_bytes(data)
    assert '#define ORT_API_VERSION 28' in (headers/'onnxruntime_c_api.h').read_text()
    notices.append(download(base+'LICENSE').decode())
    # Notice texts are bundled in the probe and exposed via Flutter's license page.
    (ROOT/'frontend-notices.txt').write_text('\n\n'.join(notices))
    (ROOT/'frontend-vendor-receipts.json').write_text(json.dumps(receipts, indent=2)+'\n')

def test_data():
    spec = json.loads((ROOT/'english-frontend-manifest.json').read_text())
    dest = ROOT/'research/test-data'
    dest.mkdir(exist_ok=True)
    for name, item in spec['files'].items():
        p = dest/name
        if p.exists() and len(p.read_bytes()) == item['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest() == item['sha256']:
            continue
        data = download(item['url'], item['sha256'])
        assert len(data) == item['bytes']
        p.write_bytes(data)
    data = download('https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/main/tokens.txt',
                    '6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425')
    (dest/'tokens.txt').write_bytes(data)

if __name__ == '__main__':
    args = argparse.ArgumentParser()
    args.add_argument('--test-data', action='store_true')
    if args.parse_args().test_data:
        test_data()
    else:
        prepare()
