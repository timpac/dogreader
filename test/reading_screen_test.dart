import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/reader_content.dart' show parseReaderChapter;

void main() {
  testWidgets('font and viewport reflow save the selected page start; chapter change cancels old pagination', (tester) async {
    final saves = <int>[];
    final chapter = parseReaderChapter('One', List.filled(150,
      '<p>A paragraph with <em>styled words</em> for pagination.</p><hr/><p>* * *</p>').join());
    final book = ImportedBook('Book', 'Author', [chapter, const ReaderChapter('Two', 'Second chapter', [])], 'book', null);
    await tester.pumpWidget(MaterialApp(home: ReadingScreen(book: book,
      chapterIndex: 0, initialOffset: 2537,
      onSave: (_, offset) async { saves.add(offset); })));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(ReadingScreen));
    expect(state.currentOffset, state.starts[state.currentPage]);
    expect(saves.last, state.currentOffset);
    expect((state.pages as List).join(), chapter.text);
    final int pageStart = state.starts[state.currentPage] as int;
    final int pageLength = (state.pages[state.currentPage] as String).length;
    final TextSpan span = state.styledPage(pageStart, pageStart + pageLength) as TextSpan;
    expect(span.toPlainText(), chapter.text.substring(pageStart, pageStart + pageLength));
    state.jumpToPage(3);
    await tester.pumpAndSettle();
    final anchor = state.currentOffset as int;
    await tester.tap(find.byTooltip('Increase text size'));
    await tester.pumpAndSettle();
    final starts = List<int>.from(state.starts as List);
    expect(state.currentPage, starts.lastIndexWhere((v) => v <= anchor));
    expect(state.currentOffset, starts[state.currentPage as int]);
    expect(saves.last, state.currentOffset);
    await tester.binding.setSurfaceSize(const Size(650, 500));
    await tester.pumpAndSettle();
    expect(state.currentOffset, state.starts[state.currentPage]);
    expect(saves.last, state.currentOffset);
    // An app-bar callback from the preceding build cannot seek during reflow.
    final listen = tester.widget<IconButton>(find.byTooltip('Listen from this page'));
    state.calculatePages(200.0, 200.0);
    listen.onPressed!();
    await tester.pumpAndSettle();
    expect(find.byType(ChapterNarrationScreen), findsNothing);
    // A pending pagination request is invalidated by the next chapter.
    state.changeChapter(1);
    await tester.pumpAndSettle();
    expect(state.chapterIndex, 1);
    expect(state.starts, [0]);
    expect(state.currentOffset, 0);
    expect(find.text('Two'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
