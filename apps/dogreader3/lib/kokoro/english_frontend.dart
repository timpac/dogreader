import 'dart:convert';
import 'dart:io';
import 'english_normalization.dart';
import 'native_g2p.dart';
import 'third_party/fonnx_misaki/misaki.dart';

class EnglishPrepared {
  EnglishPrepared(this.normalized, this.chunks, this.words, this.tokens, this.fallbacks, this.runtimeVersion, this.locale);
  final EnglishText normalized;
  final List<String> chunks;
  final int words;
  final List<Map<String, dynamic>> tokens, fallbacks;
  final String runtimeVersion, locale;
  Map<String, dynamic> toJson() => {
    'frontendId': 'misaki-fonnx-1.2.0-api28-v1', 'locale': locale,
    'runtimeVersion': runtimeVersion, 'normalizedText': normalized.text,
    'normalizationEdits': normalized.edits, 'tokens': tokens, 'fallbacks': fallbacks,
    'phonemeChunks': chunks, 'coverageChecked': true,
    'note': 'Coverage and successful generation do not prove pronunciation correctness. '
      'Accents are transliterated; OOV pronunciation is best effort. St. defaults to Saint.',
  };
}

Set<String> readPhoneInventory(String path) => File(path).readAsLinesSync()
    .where((line) => line.isNotEmpty)
    .map((line) => line.substring(0, line.lastIndexOf(' '))).toSet();

/// Licensed tokenizer/POS/G2P core, with fail-closed probe boundaries.
class EnglishFrontend {
  EnglishFrontend(String directory, this.inventory, this.backend, {this.locale = 'en-US'}) {
    final accent = locale == 'en-GB' ? 'gb' : 'us';
    String read(String name) => File('$directory/kokoro_$name').readAsStringSync();
    misaki = Misaki.load(
      gold: jsonDecode(read('misaki_${accent}_gold.json')) as Map<String, dynamic>,
      silver: jsonDecode(read('misaki_${accent}_silver.json')) as Map<String, dynamic>,
      spacyConfigJson: read('spacy_en_core_web_sm.json'),
      spacyWeights: File('$directory/kokoro_spacy_en_core_web_sm_tagger.bin').readAsBytesSync(),
      unk: '❓', british: locale == 'en-GB',
      fallback: (token) => backend.phonemize(token.text),
    );
  }
  final Set<String> inventory;
  final NativeG2p backend;
  final String locale;
  late final Misaki misaki;

  EnglishPrepared prepare(String input, {Map<String, dynamic>? dictionary}) {
    backend.events.clear();
    final normalized = normalizeEnglish(input, locale: locale, dictionary: dictionary);
    // Process paragraphs independently so whitespace never reaches neural G2P.
    // Offsets still refer to the complete normalized text; gaps force chunk boundaries.
    final items = <MToken>[];
    for (final paragraph in normalized.text.split(RegExp(r'\n\s*\n'))) {
      if (paragraph.trim().isNotEmpty) {
        items.addAll(misaki.phonemizeWithTokens(paragraph.trim()).$2);
      }
    }
    final coverage = <Map<String, dynamic>>[];
    final sourceCovered = List.filled(input.length, false);
    final chunks = <String>[];
    var current = '', currentSpeech = false, cursor = 0, phoneOffset = 0, words = 0;
    void flush() {
      if (currentSpeech) {
        chunks.add(current); current = ''; currentSpeech = false;
      }
    }
    for (final token in items) {
      if (token.text.isEmpty) continue;
      final start = normalized.text.indexOf(token.text, cursor);
      if (start < 0 || RegExp(r'\S').hasMatch(normalized.text.substring(cursor, start))) {
        throw FormatException('Frontend alignment failed near UTF-16 $cursor. No audio generated.');
      }
      final gap = normalized.text.substring(cursor, start);
      if (RegExp(r'\n\s*\n').hasMatch(gap)) flush();
      final end = start + token.text.length;
      final lexical = RegExp(r'[A-Za-z]').hasMatch(token.text);
      final phones = token.phonemes;
      final speech = phones != null && RegExp(r'[A-Za-zæðŋœθɐ-ʯᵊᵻ]').hasMatch(phones);
      if (phones == null || phones.contains('❓') || (lexical && !speech)) {
        throw FormatException('Unresolved word "${token.text}". No audio generated.');
      }
      for (final phone in phones.runes) {
        if (!inventory.contains(String.fromCharCode(phone))) {
          throw FormatException('Unsupported phoneme U+${phone.toRadixString(16)} in "${token.text}".');
        }
      }
      final ranges = normalized.sourceRanges(start, end);
      if (lexical) {
        words += RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)*").allMatches(token.text).length;
        for (final r in ranges) {
          for (var i = r[0]; i < r[1]; i++) { sourceCovered[i] = true; }
        }
      }
      final payload = phones + (token.whitespace.isEmpty ? '' : ' ');
      final length = payload.runes.length;
      if (length > 400) throw FormatException('Phoneme token too long: "${token.text}".');
      if (current.runes.length + length > 400) {
        if (!currentSpeech) throw const FormatException('Excessive punctuation before speech.');
        flush();
      }
      current += payload; currentSpeech |= lexical;
      coverage.add({'text': token.text, 'tag': token.tag, 'rating': token.rating,
        'normalizedStart': start, 'normalizedEnd': end, 'sourceRanges': ranges,
        'phonemes': phones, 'phonemeStart': phoneOffset, 'phonemeEnd': phoneOffset + phones.runes.length,
        'role': lexical ? 'speech' : 'punctuation'});
      phoneOffset += length;
      cursor = end;
      if (RegExp(r'[.!?…]').hasMatch(phones)) flush();
    }
    if (RegExp(r'\S').hasMatch(normalized.text.substring(cursor))) {
      throw const FormatException('Frontend left unprocessed text. No audio generated.');
    }
    flush();
    if (current.isNotEmpty) {
      if (chunks.isEmpty || chunks.last.runes.length + current.runes.length > 400) {
        throw const FormatException('Punctuation without a spoken chunk.');
      }
      chunks[chunks.length - 1] += current;
    }
    for (var i = 0; i < input.length; i++) {
      if (RegExp(r'[A-Za-z0-9À-ɏ]').hasMatch(input[i]) && !sourceCovered[i]) {
        throw FormatException('Missing source coverage at UTF-16 $i. No audio generated.');
      }
    }
    if (words == 0 || chunks.isEmpty) throw const FormatException('No spoken words. No audio generated.');
    return EnglishPrepared(normalized, chunks, words, coverage,
      List<Map<String, dynamic>>.from(backend.events), backend.runtimeVersion, locale);
  }
}
