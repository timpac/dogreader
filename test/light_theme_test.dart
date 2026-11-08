import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/app_theme.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/reader_content.dart' show parseReaderChapter;

double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return first > second
      ? (first + 0.05) / (second + 0.05)
      : (second + 0.05) / (first + 0.05);
}

void main() {
  test('light surfaces and functional text meet WCAG AA contrast', () {
    final theme = dogreaderLightTheme();
    final scheme = theme.colorScheme;
    expect(theme.brightness, Brightness.light);
    for (final surface in [background, panel]) {
      for (final foreground in [textPrimary, textSecondary, accent, scheme.error]) {
        expect(contrast(foreground, surface), greaterThanOrEqualTo(4.5));
      }
    }
    expect(contrast(scheme.onPrimary, scheme.primary), greaterThanOrEqualTo(4.5));
    expect(contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
        greaterThanOrEqualTo(4.5));
  });

  testWidgets('library and tabs stay readable at larger text on a phone', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: dogreaderLightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.5)),
        child: child!,
      ),
      home: const LibraryScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Dogreader'), findsOneWidget);
    expect(find.text('A new chapter begins'), findsOneWidget);
    final buttonFinder = find.byWidgetPredicate((widget) => widget is FilledButton);
    await tester.scrollUntilVisible(buttonFinder, 200);
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(buttonFinder);
    final context = tester.element(buttonFinder);
    final style = FilledButtonTheme.of(context).style!;
    expect(button.onPressed, isNotNull);
    expect(contrast(style.foregroundColor!.resolve({})!,
        style.backgroundColor!.resolve({})!), greaterThanOrEqualTo(4.5));
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('Narration'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader uses dark ink and retains EPUB emphasis and page jump', (tester) async {
    final chapter = parseReaderChapter('Chapter one',
        '<p>Some <em>italic</em> and <strong>bold</strong> words.</p>');
    final book = ImportedBook('Book', 'Author', [chapter], 'theme-book', null);
    await tester.pumpWidget(MaterialApp(
      theme: dogreaderLightTheme(),
      home: ReadingScreen(book: book, chapterIndex: 0, initialOffset: 0,
          onSave: (_, offset) async {}),
    ));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(ReadingScreen));
    final span = state.styledPage(0, chapter.text.length) as TextSpan;
    expect(span.toPlainText(), chapter.text);
    expect(contrast(span.style!.color!, background), greaterThanOrEqualTo(4.5));
    final children = span.children!.cast<TextSpan>();
    expect(children.any((s) => s.style?.fontStyle == FontStyle.italic), isTrue);
    expect(children.any((s) => s.style?.fontWeight == FontWeight.bold), isTrue);
    await tester.tap(find.textContaining('Tap to jump'));
    await tester.pumpAndSettle();
    expect(find.text('Jump to page'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ReadingScreen), findsOneWidget);
  });
}
