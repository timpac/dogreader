import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/narration_dictionary.dart';
import 'package:audiobook_app/reader_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late File file;
  late NarrationDictionary dictionary;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dogreader-dictionary-');
    file = File('${root.path}/narration_dictionary.json');
    dictionary = NarrationDictionary(preferencesFile: () async => file);
    await dictionary.load();
  });
  tearDown(() async {
    dictionary.dispose();
    await root.delete(recursive: true);
  });

  test(
    'global, book override, disabled override, delete and restart',
    () async {
      const chapter = ReaderChapter('', 'Cicero met Ann and Anna. cicero', []);
      await dictionary.setRules(null, [
        const NarrationRule('Cicero', 'SISS er oh'),
        const NarrationRule('Ann', 'An'),
      ]);
      await dictionary.setRules('book', [
        const NarrationRule('Cicero', 'KIK er oh'),
      ]);
      expect(
        dictionary.effective('book').transform(chapter).text,
        'KIK er oh met An and Anna. cicero',
      );
      expect(
        dictionary.effective('other').transform(chapter).text,
        'SISS er oh met An and Anna. cicero',
      );
      await dictionary.setRules('book', [
        const NarrationRule('Cicero', '', enabled: false),
      ]);
      expect(
        dictionary.effective('book').transform(chapter).text,
        'Cicero met An and Anna. cicero',
      );
      await dictionary.setIgnoreSeparators(false);
      final reopened = NarrationDictionary(preferencesFile: () async => file);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.ignoreSeparators, isFalse);
      expect(reopened.rules('book').single.enabled, isFalse);
      expect(
        reopened.effective('book').transform(chapter).text,
        dictionary.effective('book').transform(chapter).text,
      );
      await reopened.setRules('book', []);
      expect(
        reopened.effective('book').transform(chapter).text,
        'SISS er oh met An and Anna. cicero',
      );
    },
  );

  test('separators use EPUB blocks and semantic markup, preserving exact reader text', () {
    final chapter = parseReaderChapter('', '''<p>Before 😀</p>
      <p><strong>***</strong></p><p>⁂</p><p class="scene-break">— — —</p>
      <p>2 * 3 = 6; 2 × 3 = 6. A meaningful* note and ***inline*** emphasis.</p>
      <p><em>*emphasis*</em></p><p>*</p><p>---</p>
      <p class="separator">This prose is meaningful.</p><p>After</p>''');
    final before = chapter.text;
    final result = dictionary.effective('book').transform(chapter);
    expect(
      chapter.narrationSeparators.map(
        (r) => chapter.text.substring(r.start, r.end),
      ),
      ['***', '⁂', '— — —'],
    );
    expect(result.text, isNot(contains('***\n')));
    expect(result.text, isNot(contains('⁂')));
    expect(
      result.text,
      contains(
        '2 * 3 = 6; 2 × 3 = 6. A meaningful* note and ***inline*** emphasis.',
      ),
    );
    expect(result.text, contains('*emphasis*'));
    expect(result.text, contains('\n　*\n'));
    expect(result.text, contains('---'));
    expect(result.text, contains('This prose is meaningful.'));
    expect(chapter.text, before);
    expect(
      chapter.ranges
          .where((r) => r.bold)
          .map((r) => chapter.text.substring(r.start, r.end)),
      ['***'],
    );
    expect(
      const NarrationDictionaryConfig(ignoreSeparators: false)
          .transform(chapter)
          .text,
      before,
    );
  });

  test('literal silence is explicit; longest match wins without recursive replacement', () {
    const config = NarrationDictionaryConfig(
      ignoreSeparators: false,
      rules: [
        NarrationRule('[skip]', '', silence: true),
        NarrationRule('New York', 'York'),
        NarrationRule('New', 'Old'),
        NarrationRule('York', 'YAWK'),
        NarrationRule('a.b', 'dot'),
      ],
    );
    const chapter = ReaderChapter('', 'New York [skip] York a.b axb *', []);
    expect(config.transform(chapter).text, 'York  YAWK dot axb *');
  });

  test(
    'frozen job snapshot survives later edits and preserves UTF-16 mapping',
    () async {
      await dictionary.setRules(null, [
        const NarrationRule('Cicero', 'SEE'),
        const NarrationRule('[skip]', '', silence: true),
      ]);
      final frozen = jsonDecode(
        jsonEncode(dictionary.effective('book').toJson()),
      ) as Map<String, dynamic>;
      final chapter = parseReaderChapter(
        '',
        '<p>😀 Cicero [skip] speaks.</p><p>***</p><p>End.</p>',
      );
      final transformed = NarrationDictionaryConfig.fromJson(frozen)
          .transform(chapter);
      await dictionary.setRules(null, [
        const NarrationRule('Cicero', 'different pronunciation'),
      ]);
      expect(
        NarrationDictionaryConfig.fromJson(frozen).transform(chapter).text,
        transformed.text,
      );
      expect(transformed.text, startsWith('😀 SEE  speaks.'));
      final offsets = jsonDecode(jsonEncode(transformed.offsets));
      final endStart = chapter.text.indexOf('End.');
      expect(
        narrationFraction(endStart / chapter.text.length, offsets),
        closeTo(
          transformed.text.indexOf('End.') / transformed.text.length,
          1e-10,
        ),
      );
      final deletedStart = chapter.text.indexOf('[skip]');
      final deletedEnd = deletedStart + '[skip]'.length;
      expect(
        narrationFraction(deletedStart / chapter.text.length, offsets),
        closeTo(
          narrationFraction(deletedEnd / chapter.text.length, offsets),
          1e-10,
        ),
      );
      var previous = -1.0;
      for (var i = 0; i <= chapter.text.length; i++) {
        final current = narrationFraction(i / chapter.text.length, offsets);
        expect(current, greaterThanOrEqualTo(previous));
        previous = current;
      }
      expect(narrationFraction(0, offsets), 0);
      expect(narrationFraction(1, offsets), 1);
      expect(narrationFraction(.4, null), .4);
      expect(narrationFraction(.4, {'broken': true}), .4);
    },
  );

  test(
    'dictionary save never modifies existing audio, reading or queue data',
    () async {
      final untouched = <File, List<int>>{};
      for (final name in [
        'book_0.mp3',
        'reading_state.json',
        'narration_state.json',
        'dogreader_queue.json',
      ]) {
        final existing = File('${root.path}/$name');
        final bytes = utf8.encode('existing $name');
        await existing.writeAsBytes(bytes);
        untouched[existing] = bytes;
      }
      await Future.wait([
        dictionary.setRules(null, [const NarrationRule('Cicero', 'SEE')]),
        dictionary.setRules('book', [
          const NarrationRule('***', '', silence: true),
        ]),
        dictionary.setIgnoreSeparators(false),
      ]);
      final reopened = NarrationDictionary(preferencesFile: () async => file);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.rules(null).single.original, 'Cicero');
      expect(reopened.rules('book').single.silence, isTrue);
      expect(reopened.ignoreSeparators, isFalse);
      for (final entry in untouched.entries) {
        expect(await entry.key.readAsBytes(), entry.value);
      }
    },
  );

  test(
    'missing/corrupt file uses defaults; save failure is recoverable',
    () async {
      expect(dictionary.ignoreSeparators, isTrue);
      await file.writeAsString('broken');
      final reopened = NarrationDictionary(preferencesFile: () async => file);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.rules(null), isEmpty);
      expect(reopened.ignoreSeparators, isTrue);
      var fail = true;
      final recovering = NarrationDictionary(
        preferencesFile: () async {
          if (fail) throw const FileSystemException('unavailable');
          return file;
        },
      );
      addTearDown(recovering.dispose);
      await expectLater(
        recovering.setIgnoreSeparators(false),
        throwsA(isA<FileSystemException>()),
      );
      fail = false;
      await recovering.setRules(null, [const NarrationRule('name', 'naym')]);
      expect(
        (jsonDecode(await file.readAsString()) as Map)['ignoreSeparators'],
        false,
      );
    },
  );
}
