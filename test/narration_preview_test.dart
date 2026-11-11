import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/narration_options.dart';
import 'package:audiobook_app/narration_preview.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  final payloads = <Map<String, dynamic>>[];
  var returnedEngine = 'kokoro';
  var returnedVoice = 'bm_lewis';
  var audioSize = 1200;
  var current = true;
  var cancelOnSubmit = false;
  var downloads = 0;
  setUp(() async {
    payloads.clear();
    returnedEngine = 'kokoro';
    returnedVoice = 'bm_lewis';
    audioSize = 1200;
    current = true;
    cancelOnSubmit = false;
    downloads = 0;
    root = await Directory.systemTemp.createTemp('dictionary-preview-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('X-Dogreader-Token'), 'test-token');
      if (request.method == 'POST') {
        payloads.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        if (cancelOnSubmit) current = false;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'sample',
            'status': 'ready',
            'engine': returnedEngine,
            'voice': returnedVoice,
          }),
        );
      } else {
        downloads++;
        expect(request.uri.path, '/dogreader/audio/sample');
        request.response.contentLength = audioSize;
        request.response.add(List.filled(audioSize, 1));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });
  Future<File?> preview({String sample = 'SISS er oh'}) =>
      HttpOverrides.runWithHttpOverrides(
        () => generateNarrationPreview(
          host: 'http://127.0.0.1:${server.port}',
          token: 'test-token',
          preference: const NarrationPreference('kokoro', 'bm_lewis'),
          sample: sample,
          isCurrent: () => current,
        ),
        _RealHttp(),
      );

  test('short preview uses selected engine, voice and transformed text in temporary storage', () async {
    final file = await preview();
    expect(file!.path, '${root.path}/preview_sample.mp3');
    expect(await file.length(), 1200);
    expect(payloads.single['text'], 'SISS er oh');
    expect(payloads.single['engine'], 'kokoro');
    expect(payloads.single['voice'], 'bm_lewis');
    expect(downloads, 1);
    await preview(sample: List.filled(500, 'x').join());
    expect((payloads.last['text'] as String).length, 300);
    expect(
      await File('${root.path}/preview_sample.mp3.part').exists(),
      isFalse,
    );
  });

  test(
    'unsupported engine/voice is reported without playing another engine',
    () async {
      returnedEngine = 'google';
      returnedVoice = 'other';
      await expectLater(preview(), throwsStateError);
      expect(downloads, 0);
    },
  );

  test('cancelled preview and silent sample do not download audio', () async {
    cancelOnSubmit = true;
    expect(await preview(), isNull);
    expect(downloads, 0);
    expect(await preview(sample: '   '), isNull);
    expect(payloads.length, 1);
  });

  test(
    'incomplete preview fails cleanly without replacing existing sample',
    () async {
      final old = File('${root.path}/preview_sample.mp3');
      await old.writeAsBytes(List.filled(1200, 9));
      audioSize = 10;
      await expectLater(preview(), throwsStateError);
      expect(await old.readAsBytes(), List.filled(1200, 9));
      expect(await File('${old.path}.part').exists(), isFalse);
    },
  );
}
