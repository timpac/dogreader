import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/kokoro/english_normalization.dart';

void main() {
  group('EPUB text validation and normalization regressions', () {
    test('normalizes brackets without throwing FormatException', () {
      final input = 'This is a footnote [1] and an author note [see Chapter 2].';
      final result = normalizeEnglish(input);
      expect(result.text, contains('This is a footnote'));
      expect(result.text, contains('one')); // [1] -> (one)
      expect(result.text, contains('see Chapter'));
    });

    test('normalizes curly brackets and chevrons', () {
      final input = 'Special {editor note} and <alternate reading>.';
      final result = normalizeEnglish(input);
      expect(result.text, contains('editor note'));
      expect(result.text, contains('alternate reading'));
    });

    test('normalizes realistic dialogue with em-dashes and quotes', () {
      final input = '“Wait!” she shouted—‘don’t go yet!’ He replied: “I must.”';
      final result = normalizeEnglish(input);
      expect(result.text, contains('Wait!'));
      expect(result.text, contains('she shouted —'));
      expect(result.text, contains('don\'t go yet!'));
    });

    test('normalizes slashes in and/or and dates safely', () {
      final input = 'Choose left and/or right by 11/13/2026 or 99/99/9999.';
      final result = normalizeEnglish(input);
      expect(result.text, contains('Choose left'));
      expect(result.text, contains('and or right'));
      expect(result.text, contains('November thirteenth, twenty twenty-six'));
    });

    test('normalizes section breaks, asterisks, and ornaments', () {
      final input = 'Chapter One\n\n* * *\n\nShe arrived later.';
      final result = normalizeEnglish(input);
      expect(result.text, contains('Chapter One'));
      expect(result.text, contains('She arrived later.'));
    });

    test('normalizes underscores and symbols without dropping words', () {
      final input = 'This was _very_ important (#1 on the list).';
      final result = normalizeEnglish(input);
      expect(result.text, contains('very'));
      expect(result.text, contains('important'));
      expect(result.text, contains('number one on the list'));
    });

    test('normalizes accented and foreign names without crashing', () {
      final input = 'Renée visited the naïve façade in São Paulo with François.';
      final result = normalizeEnglish(input);
      expect(result.text, contains('Renee'));
      expect(result.text, contains('naive'));
      expect(result.text, contains('facade'));
      expect(result.text, contains('Sao Paulo'));
      expect(result.text, contains('Francois'));
    });

    test('preserves sourceRanges mapping back to original text', () {
      final input = 'See [note 1] here.';
      final result = normalizeEnglish(input);
      final noteIndex = result.text.indexOf('note');
      final spans = result.sourceRanges(noteIndex, noteIndex + 4);
      expect(spans, isNotEmpty);
      expect(input.substring(spans.first[0], spans.last[1]), 'note');
    });
  });
}
