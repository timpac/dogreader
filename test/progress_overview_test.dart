import 'dart:io';

import 'package:audiobook_app/book_progress.dart';
import 'package:audiobook_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'overview refreshes section, bars and completion after listening, then opens correct reader',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('progress-overview-'),
      ))!;
      final progress = (await tester.runAsync(
        () async => BookProgress(documentsDirectory: () async => root),
      ))!;
      Future<void> drainProgress() async {
        var done = false;
        progress.flushed.then((_) => done = true);
        for (var i = 0; i < 100 && !done; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(done, isTrue, reason: 'queued filesystem writes drained');
      }

      final book = ImportedBook(
        'Book',
        'Author',
        List.generate(
          8,
          (i) => ReaderChapter(
            'Section ${i + 1}',
            List.filled(100, 'word ').join(),
            const [],
          ),
        ),
        'book',
        null,
      );
      await tester.runAsync(() => progress.saveReading('book', 6, 80));
      await tester.pumpWidget(
        MaterialApp(
          home: ChapterListScreen(
            book: book,
            saved: progress.continuePosition('book'),
            chapterOffsets: const {},
            progressStore: progress,
            onSave: (chapter, offset) =>
                progress.saveReading('book', chapter, offset),
          ),
        ),
      );
      await tester.pumpAndSettle();
      ListTile continuation() => tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Continue reading'),
          matching: find.byType(ListTile),
        ),
      );
      expect((continuation().subtitle! as Text).data, 'Section 7');

      await tester.runAsync(() async {
        await progress.saveAudio(
          'book',
          6,
          const Duration(seconds: 100),
          duration: const Duration(seconds: 100),
          completed: true,
        );
        await progress.saveAudio(
          'book',
          7,
          const Duration(seconds: 30),
          duration: const Duration(seconds: 100),
        );
      });
      await tester.pumpAndSettle();
      expect((continuation().subtitle! as Text).data, 'Section 8');
      expect(find.text('Continue listening: Section 8'), findsOneWidget);
      await tester.tap(find.text('Continue reading'));
      await tester.pumpAndSettle();
      final dynamic reader = tester.state(find.byType(ReadingScreen));
      expect(reader.chapterIndex, 7);
      expect(reader.currentOffset, 0);
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      await drainProgress();
      // Reading an earlier section deliberately changes last active, but displays
      // furthest listening progress independently and preserves the resume button.
      await tester.runAsync(() => progress.saveReading('book', 2, 20));
      await tester.pumpAndSettle();
      expect((continuation().subtitle! as Text).data, 'Section 3');
      expect(find.text('Furthest reached: Section 8'), findsOneWidget);
      final section8 = find.text('Section 8');
      await tester.scrollUntilVisible(section8, 200);
      final tile8 = find.byKey(const ValueKey('chapter-row-7'));
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.descendant(
                of: tile8,
                matching: find.byType(LinearProgressIndicator),
              ),
            )
            .value,
        .3,
      );
      final tile7 = find.byKey(const ValueKey('chapter-row-6'));
      expect(
        find.descendant(
          of: tile7,
          matching: find.byIcon(Icons.check_circle_outline),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await drainProgress();
      await tester.runAsync(() async {
        await progress.flushed;
        progress.dispose();
        await root.delete(recursive: true);
      });
    },
  );

  testWidgets(
    'reader reflow, covered route and disposal use checkpoints; final page can complete',
    (tester) async {
      final active = <int>[];
      final checkpoints = <int>[];
      const book = ImportedBook(
        'Book',
        'Author',
        [ReaderChapter('Final', 'Last page.', [])],
        'book',
        null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ReadingScreen(
            book: book,
            chapterIndex: 0,
            initialOffset: 0,
            onSave: (_, offset) async {
              active.add(offset);
            },
            onCheckpoint: (_, offset) async {
              checkpoints.add(offset);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(active, [0]);
      expect(checkpoints, isNotEmpty);
      final dynamic reader = tester.state(find.byType(ReadingScreen));
      final pageView = tester.widget<PageView>(find.byType(PageView));
      reader.turnPage(1);
      expect(active.last, book.chapters.single.text.length);
      final context = tester.element(find.byType(ReadingScreen));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Audio route')),
        ),
      );
      await tester.pumpAndSettle();
      final before = active.length;
      pageView.onPageChanged!(0);
      await tester.pumpAndSettle();
      expect(active.length, before);
      await tester.pumpWidget(const SizedBox());
      expect(active.length, before);
      expect(checkpoints.last, 0);
    },
  );
}
