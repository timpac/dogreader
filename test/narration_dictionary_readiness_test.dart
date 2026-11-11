import 'dart:convert';

import 'package:audiobook_app/narration_dictionary.dart';
import 'package:audiobook_app/reader_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('word edges preserve astral letters and combining marks', () {
    const config = NarrationDictionaryConfig(
      rules: [
        NarrationRule('Cicero', 'SEE'),
        NarrationRule('𐐀', 'letter'),
        NarrationRule('Ann', 'An'),
      ],
    );
    const chapter = ReaderChapter(
      '',
      '𐐀Cicero Cicero𐐀 Cicero 𐐀 Anń Ann',
      [],
    );
    expect(
      config.transform(chapter).text,
      '𐐀Cicero Cicero𐐀 SEE letter Anń An',
    );
    expect(chapter.text, '𐐀Cicero Cicero𐐀 Cicero 𐐀 Anń Ann');
  });

  test('unversioned queued snapshots retain their exact pre-review matching on retry', () {
    const chapter = ReaderChapter('', 'Cicero𐐀 Anń', []);
    final legacy = NarrationDictionaryConfig.fromJson({
      'rules': [
        const NarrationRule('Cicero', 'SEE').toJson(),
        const NarrationRule('Ann', 'An').toJson(),
      ],
      'ignoreSeparators': false,
    });
    expect(legacy.version, 1);
    expect(legacy.transform(chapter).text, 'SEE𐐀 Ań');
    expect(
      NarrationDictionaryConfig.fromJson(legacy.toJson())
          .transform(chapter)
          .text,
      'SEE𐐀 Ań',
    );
    final regenerated = NarrationDictionaryConfig(
      rules: legacy.rules,
      ignoreSeparators: false,
    );
    expect(regenerated.toJson()['version'], 2);
    expect(regenerated.transform(chapter).text, chapter.text);
    expect(
      () => NarrationDictionaryConfig.fromJson({'version': 999}),
      throwsFormatException,
    );
  });

  test('one frozen book dictionary applies independently to every chapter', () {
    final dictionary = NarrationDictionary();
    addTearDown(dictionary.dispose);
    dictionary.global = [const NarrationRule('Cicero', 'SEE')];
    dictionary.books['book'] = [const NarrationRule('Cicero', 'KIK er oh')];
    final chapters = [
      parseReaderChapter('One', '<p>Cicero spoke.</p><p>***</p><p>End.</p>'),
      parseReaderChapter('Two', '<p>⁂</p><p>Cicero listened.</p>'),
    ];
    final frozen = NarrationDictionaryConfig.fromJson(
      jsonDecode(jsonEncode(dictionary.effective('book').toJson()))
          as Map<String, dynamic>,
    );
    final original = chapters.map((c) => c.text).toList();
    final expected = chapters.map(frozen.transform).toList();
    dictionary.global = [const NarrationRule('Cicero', 'different')];
    dictionary.books['book'] = [];
    for (var index = 0; index < chapters.length; index++) {
      final result = frozen.transform(chapters[index]);
      expect(result.text, expected[index].text);
      expect(result.text, contains('KIK er oh'));
      expect(result.text, isNot(contains('***')));
      expect(result.text, isNot(contains('⁂')));
      expect(result.offsets, expected[index].offsets);
      expect(result.offsets['sourceLength'], chapters[index].text.length);
      expect(result.offsets['spokenLength'], result.text.length);
      expect(narrationFraction(1, result.offsets), 1);
      expect(chapters[index].text, original[index]);
    }
  });

  test('direct article chapters keep exact UTF-16 text and version scope', () {
    final dictionary = NarrationDictionary();
    addTearDown(dictionary.dispose);
    dictionary.global = [const NarrationRule('Cicero', 'SEE')];
    dictionary.books['article_original'] = [
      const NarrationRule('Cicero', 'KIK'),
    ];
    const blocks = ['😀 Cicero.', '***', 'A meaningful* note.'];
    final text = blocks.join('\n\n');
    final separators = <StyledRange>[];
    var offset = 0;
    for (final block in blocks) {
      if (isDecorativeNarrationSeparator(block)) {
        separators.add(StyledRange(offset, offset + block.length));
      }
      offset += block.length + 2;
    }
    // Use the article's saved blocks, never the EPUB whitespace/indent policy.
    final chapter = ReaderChapter(
      'Article',
      text,
      const [],
      narrationSeparators: separators,
    );
    final result = dictionary.effective('article_original').transform(chapter);
    expect(result.text, '😀 KIK.\n\n\n\nA meaningful* note.');
    expect(
      dictionary.effective('article_summary').transform(chapter).text,
      '😀 SEE.\n\n\n\nA meaningful* note.',
    );
    final originalOffset = text.indexOf('A meaningful');
    expect(
      narrationFraction(originalOffset / text.length, result.offsets),
      closeTo(result.text.indexOf('A meaningful') / result.text.length, 1e-10),
    );
    expect(chapter.text, text);
  });
}
