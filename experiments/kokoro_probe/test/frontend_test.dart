import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kokoro_probe/frontend.dart';

void main() {
  test('unknown words and unsupported normalization fail before inference', () {
    final lexicon = {'the': ['ð', 'ə'], 'dog': ['d', 'ɔ', 'ɡ']};
    expect(() => prepareText('The Zorblax.', lexicon), throwsFormatException);
    expect(() => prepareText('The dog costs \$12.', lexicon), throwsFormatException);
    expect(() => prepareText('<speak>The dog</speak>', lexicon), throwsFormatException);
    expect(() => prepareText("'The dog'", lexicon), throwsFormatException);
    expect(prepareText('The dog.', lexicon).words, 2);
  });

  test('long text chunks retain every word and bound phoneme context', () {
    final source = List.filled(1000, 'dog').join(' ');
    final result = prepareText(source, {'dog': List.filled(10, 'd')});
    expect(result.words, 1000);
    expect(result.chunks.join(), source);
    for (final chunk in result.chunks) {
      final words = RegExp('dog').allMatches(chunk).length;
      expect(words * 10 + words - 1, lessThanOrEqualTo(400));
    }
  });

  test('benchmark fixture is exactly one thousand words', () {
    final text = File('passage.txt').readAsStringSync();
    expect(RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)*").allMatches(text).length, 1000);
  });
}
