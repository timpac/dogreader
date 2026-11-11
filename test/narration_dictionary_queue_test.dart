import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/narration_dictionary.dart';
import 'package:audiobook_app/reader_content.dart' show parseReaderChapter;
import 'package:flutter/material.dart';
// Uses the platform mock already present in path_provider's locked dependencies.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_player.dart';

class _RealHttp extends HttpOverrides {}

class _TestPaths extends PathProviderPlatform {
  final String path;
  _TestPaths(this.path);
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  testWidgets(
    'new jobs freeze transformations; audio replacement carries its own seek map',
    (tester) async {
      late Directory root;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('dictionary-queue-');
      });
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(root.path);
      addTearDown(() => PathProviderPlatform.instance = oldPaths);
      late FakePlayer player;
      late DogreaderAudioHandler handler;
      await tester.runAsync(() async {
        player = FakePlayer();
        handler = DogreaderAudioHandler(
          player: player,
          documentsDirectory: () async => root,
        );
      });
      audioHandler = handler;
      final chapter = parseReaderChapter(
        'One',
        '<p>Cicero spoke.</p><p>***</p><p>End.</p>',
      );
      final book = ImportedBook('Book', 'Author', [chapter], 'book', null);
      final audio = File('${root.path}/narration/book_0.mp3');
      final stateFile = File('${root.path}/narration_state.json');
      const oldState = '{"book:0":{"positionMs":17000}}';
      await tester.runAsync(() async {
        await audio.parent.create();
        await audio.writeAsBytes(List.filled(1200, 7));
        await stateFile.writeAsString(oldState);
        await narrationDictionary.load();
      });
      await tester.pumpWidget(
        MaterialApp(home: NarrationQueueScreen(book: book)),
      );
      final dynamic queue = tester.state(find.byType(NarrationQueueScreen));
      await tester.runAsync(() async {
        await queue.load();
      });
      await tester.pumpAndSettle();
      expect(queue.jobs[0]['status'], 'ready');
      await tester.runAsync(
        () => narrationDictionary.setRules(null, [
          const NarrationRule('Cicero', 'SEE'),
        ]),
      );
      queue.setState(() {});
      await tester.pump();
      expect(queue.dictionaryChanged(0), isTrue);
      expect(find.textContaining('Dictionary changed'), findsOneWidget);
      await tester.runAsync(() async {
        expect(await audio.readAsBytes(), List.filled(1200, 7));
        expect(await stateFile.readAsString(), oldState);
      });
      // Explicit new generation freezes rules. Merely editing them above did not
      // enqueue anything or disturb a ready recording.
      queue.jobs[0] = <String, dynamic>{
        'status': 'waiting',
        'engine': 'kokoro',
        'voice': 'bm_lewis',
        'narration_dictionary': narrationDictionary.effective('book').toJson(),
      };
      final payload = queue.chapterPayload(0) as Map<String, dynamic>;
      expect(payload['text'], 'SEE spoke.\n　\n　End.');
      expect(payload['engine'], 'kokoro');
      await tester.runAsync(
        () => narrationDictionary.setRules(null, [
          const NarrationRule('Cicero', 'KIK er oh'),
        ]),
      );
      expect(queue.chapterPayload(0), payload);
      await tester.runAsync(() async {
        await queue.save();
      });
      late HttpServer server;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          expect(request.uri.path, '/dogreader/audio/new');
          request.response.contentLength = 1300;
          request.response.add(List.filled(1300, 9));
          await request.response.close();
        });
        queue.host = 'http://127.0.0.1:${server.port}';
        queue.token = 'test';
        await HttpOverrides.runWithHttpOverrides(() async {
          await queue.downloadAudio(0, 'new');
        }, _RealHttp());
        expect(await audio.readAsBytes(), List.filled(1300, 9));
        final saved = jsonDecode(await stateFile.readAsString()) as Map;
        expect(
          saved['book:0']['narration_offsets'],
          queue.jobs[0]['narration_offsets'],
        );
        expect(
          saved['book:0']['narration_dictionary'],
          queue.jobs[0]['narration_dictionary'],
        );
        await server.close(force: true);
      });
      // Reading seeks with the recording's frozen map, despite newer dictionary
      // settings. No replacement of the audio handler or chapter routing.
      final originalFraction =
          chapter.text.indexOf('End.') / chapter.text.length;
      final expectedFraction =
          (payload['text'] as String).indexOf('End.') /
          (payload['text'] as String).length;
      await tester.pumpWidget(
        MaterialApp(
          home: ChapterNarrationScreen(
            book: book,
            chapterIndex: 0,
            initialTextFraction: originalFraction,
          ),
        ),
      );
      final dynamic narration = tester.state(
        find.byType(ChapterNarrationScreen),
      );
      var restored = false;
      final restore = (narration.restore() as Future<void>).then(
        (_) => restored = true,
      );
      for (var i = 0; i < 50 && !restored; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(restored, isTrue);
      await restore;
      await tester.pumpAndSettle();
      expect(
        player.position.inMilliseconds,
        (100000 * expectedFraction).round(),
      );
      expect(handler.mediaItem.value?.id, 'book:0');
      expect(player.playing, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      var disposed = false;
      final disposing = handler.dispose().then((_) => disposed = true);
      for (var i = 0; i < 50 && !disposed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(disposed, isTrue);
      await disposing;
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
