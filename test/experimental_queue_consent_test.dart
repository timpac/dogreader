import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/app_identity.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/narration_dictionary.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_player.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'experimental queue requires fresh consent and never retries paid work automatically',
    (tester) async {
      if (!dogreaderExperimental) return;
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('experimental-consent-'),
      ))!;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      late DogreaderAudioHandler handler;
      late HttpServer server;
      var posts = 0;
      var missing = false;
      await tester.runAsync(() async {
        await narrationDictionary.load();
        handler = DogreaderAudioHandler(
          player: FakePlayer(),
          documentsDirectory: () async => root,
        );
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.method == 'POST') {
            posts++;
            await utf8.decoder.bind(request).join();
          }
          request.response.headers.contentType = ContentType.json;
          if (missing && request.method == 'GET') {
            request.response.statusCode = 404;
            request.response.write(jsonEncode({'error': 'Unknown job'}));
          } else {
            request.response.write(
              jsonEncode({'id': 'approved', 'status': 'generating'}),
            );
          }
          await request.response.close();
        });
      });
      audioHandler = handler;
      const book = ImportedBook(
        'Book',
        'Author',
        [
          ReaderChapter('One', 'One unchanged chapter.', []),
          ReaderChapter('Two', 'Two unchanged chapters.', []),
        ],
        'experimental',
        null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NarrationQueueScreen(book: book, onSave: (_, _) async {}),
        ),
      );
      final dynamic queue = tester.state(find.byType(NarrationQueueScreen));
      await tester.runAsync(() async => queue.load());
      await tester.pumpAndSettle();
      queue.host = 'http://127.0.0.1:${server.port}';
      queue.token = 'fake';
      queue.jobs[0] = <String, dynamic>{'status': 'waiting'};
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () async => queue.checkJobs(),
          _RealHttp(),
        ),
      );
      expect(posts, 0);
      expect(queue.jobs[0]['status'], 'error');
      expect(find.text('Entire book'), findsNothing);
      queue.selectEntireBook();
      expect(queue.selected, isEmpty);
      queue.selected.addAll([0, 1]);
      await queue.generate();
      expect(posts, 0);
      queue.selected.clear();
      queue.selected.add(0);
      final cancelled = queue.generate() as Future<void>;
      await tester.pumpAndSettle();
      expect(find.text('Allow paid cloud request?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await cancelled;
      expect(posts, 0);
      final approved = HttpOverrides.runWithHttpOverrides(
        () => queue.generate() as Future<void>,
        _RealHttp(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve one request'));
      var completed = false;
      approved.then((_) => completed = true);
      for (var i = 0; i < 100 && !completed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(completed, isTrue);
      await approved;
      await tester.pumpAndSettle();
      expect(posts, 1);
      missing = true;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () async => queue.checkJobs(),
          _RealHttp(),
        ),
      );
      expect(posts, 1);
      await tester.pumpWidget(const SizedBox());
      var disposed = false;
      final disposing = handler.dispose().then((_) => disposed = true);
      for (var i = 0; i < 100 && !disposed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(disposed, isTrue);
      await disposing;
      await tester.runAsync(() async {
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    },
  );
}
