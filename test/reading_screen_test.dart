import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/main.dart';

void main() {
  testWidgets('font and viewport reflow save the selected page start; chapter change cancels old pagination', (tester) async {
    final saves = <int>[];
    final text = List.filled(300, 'A paragraph with words for pagination. ').join();
    final book = ImportedBook('Book', 'Author', [ReaderChapter('One', text, []), const ReaderChapter('Two', 'Second chapter', [])], 'book', null);
    await tester.pumpWidget(MaterialApp(home: ReadingScreen(book: book,
      chapterIndex: 0, initialOffset: 2537,
      onSave: (_, offset) async { saves.add(offset); })));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(ReadingScreen));
    expect(state.currentOffset, state.starts[state.currentPage]);
    expect(saves.last, state.currentOffset);
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
