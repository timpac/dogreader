import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/reader_content.dart';

void main() {
  test('linked publisher CSS, imports and fractional spacing create blank scenes', () {
    final chapter = parseReaderChapter('Title', '''
      <link rel="stylesheet" href="../Styles/book%20style.css"/>
      <p>Before</p><div class="gap">&#160;</div><p><em>After</em></p>
      ''', documentPath: 'OPS/Text/ch1.xhtml', styleSheets: {
      'OPS/Styles/book style.css': '@import "spacing.css";',
      'OPS/Styles/spacing.css': 'div.gap {margin: 0.5em 0;} ',
    });
    expect(chapter.text, 'Before\n\n\nAfter');
    final italic = chapter.ranges.singleWhere((r) => r.italic);
    expect(chapter.text.substring(italic.start, italic.end), 'After');
  });

  test('inline, semantic and hr scenes are coalesced without invented ornaments', () {
    final chapter = parseReaderChapter('', '''
      <div class="spacer"></div><p>One</p><hr/><div style="height:.8em"></div>
      <p>Two</p><div role="separator"></div>
      ''');
    expect(chapter.text, 'One\n\n\nTwo');
    expect(chapter.text, isNot(contains('⁂')));
  });

  test('publisher text ornaments survive and ordinary empty blocks stay empty', () {
    final chapter = parseReaderChapter('', '''
      <style>.ordinary {margin:0 2em;} .section {font-size:1em;}</style>
      <p>A</p><p class="ordinary"></p><p class="section"></p>
      <p class="ornament"><strong>* * *</strong></p><p>B</p>
      ''');
    expect(chapter.text, 'A\n　* * *\n　B');
    expect(chapter.ranges.where((r) => r.bold).map((r) => chapter.text.substring(r.start, r.end)), ['* * *']);
  });

  test('compound selectors do not mark unrelated empty elements', () {
    final chapter = parseReaderChapter('', '''
      <style>.wrapper .gap {padding-top: 1rem;}</style>
      <p>A</p><div class="wrapper"></div><p>B</p>
      <div class="wrapper"><div class="gap"></div></div><p>C</p>
      ''');
    expect(chapter.text, 'A\n　B\n\n\nC');
  });

  test('nested text styles use normalized UTF-16 offsets across block prefixes', () {
    final chapter = parseReaderChapter('', '''<h1>  A   <em>title</em> </h1>
      <p> Alpha   beta <em> italic  <strong>bold</strong> end </em> tail😀</p>
      <p>Next <strong> word</strong></p>''');
    expect(chapter.text, 'A title\nAlpha beta italic bold end tail😀\n　Next word');
    final styled = chapter.ranges.where((r) => r.bold).map((r) => chapter.text.substring(r.start, r.end)).toList();
    expect(styled, ['bold', 'word']);
    final heading = chapter.ranges.singleWhere((r) => r.heading);
    expect(chapter.text.substring(heading.start, heading.end), 'A title');
    for (final range in chapter.ranges) {
      expect(range.start, inInclusiveRange(0, chapter.text.length));
      expect(range.end, inInclusiveRange(range.start + 1, chapter.text.length));
    }
  });

  test('external URLs are never read as EPUB resources', () {
    expect(epubResourcePath('Text/ch.xhtml', 'https://example.org/x.css'), isNull);
    expect(epubResourcePath('Text/ch.xhtml', '../Style/x.css'), 'Style/x.css');
  });
}
