import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/narration_alignment.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> alignmentFixture(
  String text,
  List<int> audio,
  List<({int start, int end, String word})> times,
) {
  var offset = 0;
  return {
    'schema': 'dogreader-alignment-v1',
    'offset_unit': 'utf16',
    'precision': 'word',
    'reviewed': true,
    'text_sha256': sha256.convert(utf8.encode(text)).toString(),
    'audio_sha256': sha256.convert(audio).toString(),
    'duration_ms': 1900000,
    'words': times.map((t) {
      final start = text.indexOf(t.word, offset);
      offset = start + t.word.length;
      return {
        'start_ms': t.start,
        'end_ms': t.end,
        'text_start': start,
        'text_end': offset,
      };
    }).toList(),
  };
}

void main() {
  const text = 'Opening.\n　A 🐕 waits.\n\n\nThe final paragraph.';
  const audio = [1, 2, 3];
  Map<String, dynamic> fixture() => alignmentFixture(text, audio, [
    (start: 100, end: 200, word: 'Opening'),
    (start: 1000, end: 1500, word: 'A'),
    (start: 1500, end: 2000, word: 'waits'),
    (start: 1800000, end: 1800500, word: 'The'),
    (start: 1800500, end: 1801000, word: 'final'),
    (start: 1801000, end: 1802000, word: 'paragraph'),
  ]);

  test('actual timestamps resolve the spoken paragraph at 30 minutes with Unicode offsets', () {
    final map = NarrationAlignment.parse(fixture(), text);
    final passage = map.passageAt(const Duration(minutes: 30));
    expect(passage.offset, text.indexOf('The'));
    expect(
      text.substring(passage.paragraphStart, passage.paragraphEnd),
      'The final paragraph.',
    );
    final middle = map.passageAt(const Duration(milliseconds: 1500));
    expect(middle.offset, text.indexOf('waits'));
    expect(
      text.substring(middle.paragraphStart, middle.paragraphEnd),
      '　A 🐕 waits.',
    );
    expect(map.passageAt(Duration.zero).offset, 0);
    expect(
      map.passageAt(const Duration(hours: 3)).offset,
      text.indexOf('paragraph'),
    );
    expect(
      map.passageAt(const Duration(seconds: 8)).offset,
      text.indexOf('waits'),
    );
  });

  test(
    'rejects coarse, unreviewed, corrupt, missing-coverage and mismatched maps',
    () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (d) => d['schema'] = 'kokoro-chunks',
        (d) => d['reviewed'] = false,
        (d) => d['text_sha256'] = 'wrong',
        (d) => d['offset_unit'] = 'codepoints',
        (d) => d['audio_sha256'] = '',
        (d) => d['duration_ms'] = 0,
        (d) => (d['words'] as List).removeAt(1),
        (d) => d['words'][1]['start_ms'] = 0,
        (d) => d['words'][1]['end_ms'] = 999999999,
        (d) => d['words'][1]['text_end'] = 999999999,
        (d) => d['words'][2]['text_start'] = text.indexOf('🐕') + 1,
      ]) {
        final data = fixture();
        change(data);
        expect(
          () => NarrationAlignment.parse(data, text),
          throwsFormatException,
        );
      }
    },
  );

  test('valid downloaded sidecar works offline; replacement audio and text invalidate it', () async {
    final root = await Directory.systemTemp.createTemp('alignment-offline-');
    addTearDown(() => root.delete(recursive: true));
    final recording = File('${root.path}/book_0.mp3');
    await recording.writeAsBytes(audio);
    final sidecar = File('${recording.path}.alignment.json');
    await sidecar.writeAsString(jsonEncode(fixture()));
    Future<NarrationAlignment?> load(String sourceText) =>
        loadNarrationAlignment(
          root: root,
          bookId: 'book',
          chapterIndex: 0,
          audio: recording,
          text: sourceText,
        );
    expect(await load(text), isNotNull);
    expect(await load('$text Changed'), isNull);
    await recording.writeAsBytes([4, 5, 6]);
    expect(await load(text), isNull);
    await sidecar.writeAsString('broken');
    expect(await load(text), isNull);
  });
}
