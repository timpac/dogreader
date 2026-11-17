import 'dart:io';

import 'package:audiobook_app/book_progress.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:audiobook_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// Same locked platform test seam as the existing dictionary route tests.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'fake_player.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  testWidgets(
    'reader to audio and back preserves text position while player follows automatic section changes',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('progress-modes-'),
      ))!;
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() => PathProviderPlatform.instance = previousPaths);
      final progress = (await tester.runAsync(
        () async => BookProgress(documentsDirectory: () async => root),
      ))!;
      final player = FakePlayer();
      final handler = (await tester.runAsync(
        () async => DogreaderAudioHandler(
          player: player,
          documentsDirectory: () async => root,
          progress: progress,
        ),
      ))!;
      audioHandler = handler;
      final book = ImportedBook(
        'Book',
        'Author',
        [
          ReaderChapter(
            'Section 7',
            List.filled(300, 'Some text for this page. ').join(),
            const [],
          ),
          const ReaderChapter('Section 8', 'Next section.', []),
        ],
        'book',
        null,
      );
      await tester.runAsync(() async {
        await Directory('${root.path}/narration').create();
        for (var i = 0; i < 2; i++) {
          await File('${root.path}/narration/book_$i.mp3')
              .writeAsBytes(List.filled(1200, 1));
        }
        await progress.saveAudio('book', 0, const Duration(seconds: 80));
      });
      Future<void> drain() async {
        for (var i = 0; i < 60; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: ReadingScreen(
            progressStore: progress,
            book: book,
            chapterIndex: 0,
            initialOffset: 1800,
            onSave: (chapter, offset) =>
                progress.saveReading('book', chapter, offset),
            onCheckpoint: (chapter, offset) =>
                progress.saveReading('book', chapter, offset, activate: false),
          ),
        ),
      );
      await drain();
      final dynamic reader = tester.state(find.byType(ReadingScreen));
      final offset = reader.currentOffset as int;
      expect(offset, greaterThan(0));
      await tester.tap(find.byTooltip('Listen from this page'));
      await drain();
      expect(find.byType(ChapterNarrationScreen), findsOneWidget);
      expect(
        player.position.inMilliseconds,
        closeTo(offset / book.chapters[0].text.length * 100000, 2),
      );
      expect(progress.readingPosition('book')!['offset'], offset);
      await tester.runAsync(() => handler.play());
      player.position = const Duration(seconds: 100);
      player.complete();
      await drain();
      expect(handler.mediaItem.value?.id, 'book:1');
      expect(find.text('Section 8'), findsOneWidget);
      expect(progress.continuePosition('book')!['chapter'], 1);
      await tester.pageBack();
      await drain();
      expect(reader.currentOffset, offset);
      expect(progress.readingPosition('book')!['offset'], offset);
      expect(progress.continuePosition('book')!['chapter'], 1);
      expect(player.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
      await drain();
      await tester.runAsync(() async {
        await handler.dispose();
        progress.dispose();
        await root.delete(recursive: true);
      });
    },
  );
}
