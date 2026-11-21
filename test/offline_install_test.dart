import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/kokoro/worker.dart';

void main() {
  test('existing archive 3 installer verifies and streams a bzip2 tar into private storage', () async {
    final root = await Directory.systemTemp.createTemp('dogreader3-install-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = ReceivePort();
    final data = utf8.encode('tiny model fixture; no actual model');
    final archive = Archive()..addFile(ArchiveFile('fixture/model.onnx', data.length, data));
    final packed = BZip2Encoder().encode(TarEncoder().encode(archive));
    server.listen((request) async {
      request.response.contentLength = packed.length;
      request.response.add(packed);
      await request.response.close();
    });
    final manifest = {
      'url': 'http://127.0.0.1:${server.port}/model', 'directory': 'fixture',
      'archiveBytes': packed.length, 'archiveSha256': sha256.convert(packed).toString(),
      'files': {'model.onnx': {'bytes': data.length, 'sha256': sha256.convert(data).toString()}},
    };
    try {
      await install({'manifest': jsonEncode(manifest), 'root': root.path}, port.sendPort);
      expect(await File('${root.path}/fixture/model.onnx').readAsBytes(), data);
      expect(await File('${root.path}/fixture/READY').readAsString(), manifest['archiveSha256']);
      expect(await File('${root.path}/model.part').exists(), isFalse);
      final bad = {...manifest, 'archiveSha256': 'bad'};
      await expectLater(install({'manifest': jsonEncode(bad), 'root': root.path}, port.sendPort), throwsStateError);
      expect(await File('${root.path}/fixture/model.onnx').readAsBytes(), data);
    } finally {
      port.close(); await server.close(force: true); await root.delete(recursive: true);
    }
  });
}
