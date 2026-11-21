import 'package:audiobook_app/kokoro/native_g2p.dart';
import 'package:audiobook_app/kokoro/third_party/fonnx_misaki/misaki_fallback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native decoding retains phonemes after an unknown token', () {
    final vocab = MisakiFallbackVocab('''
      {"grapheme_chars":"0123a", "phoneme_chars":"0123æ", "max_positions":64}
    ''');
    final predictions = [3, 4, 2].iterator;
    final prefixes = <List<int>>[];

    final phonemes = NativeG2p.decodePhonemes(vocab, (ids) {
      prefixes.add(List.of(ids));
      expect(predictions.moveNext(), isTrue);
      return predictions.current;
    });

    expect(phonemes, 'æ');
    expect(prefixes, [[1], [1, 3], [1, 3, 4]]);
  });
}
