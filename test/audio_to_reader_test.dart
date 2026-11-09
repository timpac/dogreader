import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/narration_alignment.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_player.dart';
import 'narration_alignment_test.dart' show alignmentFixture;

void main() {
  late Directory root;
  late FakePlayer player;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('audio-to-reader-');
    player = FakePlayer()..duration = const Duration(milliseconds: 1900000);
    audioHandler = DogreaderAudioHandler(
      player: player,
      documentsDirectory: () async => root,
    );
  });
  tearDownAll(() async {
    await audioHandler.dispose();
    await root.delete(recursive: true);
  });
  testWidgets(
    'Read from here follows the active chapter offline and preserves 30-minute playback',
    (tester) async {
      Future<void> flushIo() async {
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
      }

      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => root.path,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      const text = 'The opening.\nThe narrated paragraph.';
      const bytes = [1, 2, 3, 4];
      final book = ImportedBook(
        'Book',
        'Author',
        [
          const ReaderChapter('One', text, []),
          const ReaderChapter('Two', text, []),
        ],
        'book',
        null,
      );
      await tester.runAsync(() async {
        await Directory('${root.path}/narration').create();
        for (var i = 0; i < 2; i++) {
          final file = File('${root.path}/narration/book_$i.mp3');
          await file.writeAsBytes(bytes);
          await File('${file.path}.alignment.json').writeAsString(
            jsonEncode(
              alignmentFixture(text, bytes, [
                (start: 0, end: 500, word: 'The'),
                (start: 500, end: 1000, word: 'opening'),
                (start: 1800000, end: 1800500, word: 'The'),
                (start: 1800500, end: 1801000, word: 'narrated'),
                (start: 1801000, end: 1802000, word: 'paragraph'),
              ]),
            ),
          );
        }
        await audioHandler.loadChapter(
          path: '${root.path}/narration/book_0.mp3',
          title: 'One',
          author: 'Author',
          bookId: 'book',
          chapterIndex: 0,
          chapterCount: 2,
          startPosition: const Duration(minutes: 30),
        );
        await audioHandler.play();
        await audioHandler.setSpeed(1.5);
      });
      final saved = <(int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ChapterNarrationScreen(
            book: book,
            chapterIndex: 0,
            onSave: (chapter, offset) async {
              saved.add((chapter, offset));
            },
          ),
        ),
      );
      await flushIo();
      final dynamic screen = tester.state(find.byType(ChapterNarrationScreen));
      expect(screen.loading, isFalse, reason: '${screen.error}');
      await tester.pumpAndSettle();
      expect(find.text('Pause'), findsOneWidget);
      // Background completion advances to chapter two while the screen was opened for one.
      await tester.runAsync(() async {
        player.complete();
        for (
          var i = 0;
          i < 50 && audioHandler.mediaItem.value?.id != 'book:1';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        player.position = const Duration(minutes: 30);
        player.positions.add(player.position);
      });
      await flushIo();
      await tester.pumpAndSettle();
      expect(audioHandler.readingLocation!.chapterIndex, 1);
      final loads = player.loads, stops = player.stops;
      final pauses = player.pauses, seeks = player.seeks;
      await tester.tap(find.text('Read from here'));
      await tester.pumpAndSettle();
      expect(find.byType(ReadingScreen), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      expect(saved.last.$1, 1);
      expect(player.position, const Duration(minutes: 30));
      expect(player.playing, isTrue);
      expect(player.speed, 1.5);
      expect(player.loads, loads);
      expect(player.stops, stops);
      expect(player.pauses, pauses);
      expect(player.seeks, seeks);
      final dynamic reader = tester.state(find.byType(ReadingScreen));
      final span = reader.styledPage(0, text.length) as TextSpan;
      expect(
        span.children!.whereType<TextSpan>().any(
          (s) => s.style?.backgroundColor != null,
        ),
        isTrue,
      );
      await tester.pump(const Duration(seconds: 3));
      final faded = reader.styledPage(0, text.length) as TextSpan;
      expect(
        faded.children!.whereType<TextSpan>().any(
          (s) => s.style?.backgroundColor != null,
        ),
        isFalse,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(player.position, const Duration(minutes: 30));
      expect(player.loads, loads);
      expect(player.playing, isTrue);
      // The existing reader-to-audio path pauses/seeks as before, then Read from
      // here returns to that reader rather than stacking another reader route.
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: ReadingScreen(
            book: book,
            chapterIndex: 1,
            initialOffset: 0,
            onSave: (chapter, offset) async {
              saved.add((chapter, offset));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Listen from this page'));
      await flushIo();
      final dynamic returnedPlayer = tester.state(
        find.byType(ChapterNarrationScreen),
      );
      // Do not pump an animating loader straight through the native-seek timeout
      // while real disk I/O is pending outside Flutter's fake clock.
      for (var i = 0; i < 6 && returnedPlayer.loading == true; i++) {
        await flushIo();
      }
      await flushIo();
      await tester.pumpAndSettle();
      expect(
        returnedPlayer.loading,
        isFalse,
        reason: '${returnedPlayer.error}',
      );
      expect(returnedPlayer.error, isNull);
      expect(
        tester
            .widget<ChapterNarrationScreen>(find.byType(ChapterNarrationScreen))
            .returnToReader,
        isTrue,
      );
      expect(audioHandler.readingLocation, isNotNull);
      expect(player.playing, isFalse);
      expect(player.position, Duration.zero);
      final pausedSeeks = player.seeks, pausedPauses = player.pauses;
      await tester.tap(find.text('Read from here'));
      await tester.pumpAndSettle();
      expect(find.byType(ReadingScreen), findsOneWidget);
      expect(find.byType(ChapterNarrationScreen), findsNothing);
      expect(player.position, Duration.zero);
      expect(player.playing, isFalse);
      expect(player.seeks, pausedSeeks);
      expect(player.pauses, pausedPauses);
      expect(player.loads, loads);
      await tester.pumpWidget(const SizedBox());
      // Drain handler persistence in the test's fake zone before tearDownAll.
      await flushIo();
      var disposed = false;
      final closing = audioHandler.dispose().then((_) => disposed = true);
      for (var i = 0; i < 6 && !disposed; i++) {
        await flushIo();
      }
      expect(disposed, isTrue);
      await closing;
    },
  );

  testWidgets(
    'long chapter displays the destination before all pages finish and expires its highlight',
    (tester) async {
      final text = List.filled(
        2000,
        'A paragraph with many words for long chapter pagination.\n',
      ).join();
      final book = ImportedBook(
        'Book',
        'Author',
        [ReaderChapter('Long', text, [])],
        'long',
        null,
      );
      final stopwatch = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: ReadingScreen(
            book: book,
            chapterIndex: 0,
            initialOffset: 12000,
            narrationPassage: const NarrationPassage(12000, 11990, 12040),
            onSave: (_, _) async {},
          ),
        ),
      );
      final dynamic reader = tester.state(find.byType(ReadingScreen));
      for (var i = 0; i < 300 && (reader.pages as List).isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 2));
      }
      expect((reader.pages as List).isNotEmpty, isTrue);
      expect((reader.pages as List).join().length, lessThan(text.length));
      expect(reader.currentOffset <= 12000, isTrue);
      expect(
        reader.currentOffset +
                (reader.pages[reader.currentPage] as String).length >
            12000,
        isTrue,
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    },
  );
}
