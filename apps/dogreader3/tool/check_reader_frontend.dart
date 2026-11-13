// Real reader -> boundary adapter -> unchanged Misaki/ORT, without a large TTS model.
import 'dart:convert';
import 'dart:io';
import '../lib/reader_content.dart';
import '../lib/offline_reader_text.dart';
import '../lib/kokoro/english_frontend.dart';
import '../lib/kokoro/native_g2p.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main(List<String> args) {
  final data = args[0];
  final native = NativeG2p('$data/kokoro_g2p_fallback_en_us.onnx',
    File('$data/kokoro_g2p_fallback_en_us.json').readAsStringSync(),
    bridgePath: args[1], runtimePath: args[2]);
  try {
    check(native.runtimeVersion == '1.28.2', 'Unexpected ORT');
    final frontend = EnglishFrontend(data, readPhoneInventory('$data/tokens.txt'), native);
    final chapter = parseReaderChapter('A chapter', '<p>Alice read twelve books on Monday.</p>'
      '<p>The children don’t leave in 2026.</p>');
    check(chapter.text.contains('\u3000The'), 'Real reader must reproduce the EPUB indentation');
    var reproduced = false;
    try { frontend.prepare(chapter.text); }
    on FormatException catch (e) { reproduced = e.message.contains('Unsupported fallback character'); }
    check(reproduced, 'Expected build-149 failure was not reproduced');
    final spoken = offlineReaderText(chapter.text);
    check(spoken.length == chapter.text.length, 'Reader offsets changed');
    final accepted = frontend.prepare(spoken);
    final reference = frontend.prepare('Alice read twelve books on Monday.\n\nThe children don’t leave in 2026.');
    check(accepted.words > 0 && accepted.chunks.isNotEmpty, 'Empty accepted output');
    check(jsonEncode(accepted.chunks) == jsonEncode(reference.chunks), 'Phonemes differ from ordinary-space reference');
    check(accepted.normalized.text.contains('Alice') && accepted.normalized.text.contains('children') &&
      accepted.normalized.text.contains('leave'), 'Vocabulary disappeared');
    final cases = <String, String>{
      'heading-and-paragraphs': '<h1>Chapter One</h1><p>Alice arrived.</p><p>The children read.</p>',
      'dialogue-and-curly-quotes': '<p>“Are you ready?” Alice asked.</p><p>“Yes,” he answered.</p>',
      'scene-break': '<p>Alice read.</p><hr/><p>The children don’t leave.</p>',
    };
    final extra = <Map<String, dynamic>>[];
    for (final entry in cases.entries) {
      final source = parseReaderChapter(entry.key, entry.value).text;
      final text = offlineReaderText(source);
      check(source.length == text.length, 'Offset change in ${entry.key}');
      final output = frontend.prepare(text);
      check(output.words > 0 && output.chunks.isNotEmpty, 'Empty ${entry.key}');
      extra.add({'case': entry.key, 'pass': true, 'words': output.words, 'chunks': output.chunks.length});
    }
    final paragraphs = File('test/fixtures/chapter.txt').readAsStringSync().split('\n\n').take(4);
    final html = paragraphs.map((p) => '<p>${const HtmlEscape().convert(p)}</p>').join();
    final full = parseReaderChapter('Device fixture chapter', html);
    final fullOutput = frontend.prepare(offlineReaderText(full.text));
    check(fullOutput.words > 300 && fullOutput.chunks.isNotEmpty, 'Device chapter not accepted');
    extra.add({'case':'full-391-word-EPUB-chapter','pass':true,'words':fullOutput.words,'chunks':fullOutput.chunks.length});
    final result = {'platform': 'Linux host; NOT Android synthesis or Pixel measurements',
      'runtime': native.runtimeVersion, 'readerIndentFailureReproduced': reproduced,
      'normalizedInputAccepted': true, 'samePhonemesAsAsciiSpaceReference': true,
      'sameUtf16Length': true, 'additionalReaderCases': extra, 'words': accepted.words, 'chunks': accepted.chunks.length,
      'allPassed': true, 'frontend': accepted.toJson()};
    File(args[3]).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(result)}\n');
    print(jsonEncode(result));
  } finally { native.close(); }
}
