// Targeted integration test: real tokenizer/POS + real BART/ORT; no Flutter SDK needed.
import 'dart:convert';
import 'dart:io';
import '../lib/english_frontend.dart';
import '../lib/native_g2p.dart';

Never fail(String message) => throw StateError(message);
void check(bool condition, String message) { if (!condition) fail(message); }

void main(List<String> args) {
  if (args.length != 4) fail('Usage: check_english.dart DATA_DIR BRIDGE.so SHERPA_ORT.so OUTPUT.json');
  final data = args[0];
  final inventory = readPhoneInventory('$data/tokens.txt');
  final native = NativeG2p('$data/kokoro_g2p_fallback_en_us.onnx',
    File('$data/kokoro_g2p_fallback_en_us.json').readAsStringSync(),
    bridgePath: args[1], runtimePath: args[2]);
  final results = <Map<String, dynamic>>[], failures = <String>[];
  try {
    check(native.runtimeVersion == '1.28.2', 'Unexpected runtime version');
    final frontends = {for (final locale in ['en-US', 'en-GB'])
      locale: EnglishFrontend(data, inventory, native, locale: locale)};
    final corpus = jsonDecode(File('research/english-corpus.json').readAsStringSync());
    check((corpus['cases'] as List).length == 16, 'Corpus must have 16 cases');
    for (final item in corpus['cases'] as List) {
      final c = Map<String, dynamic>.from(item as Map);
      for (final locale in c['locales'] as List? ?? ['en-US']) {
        final shouldFail = c['expected_outcome'] != null;
        try {
          final result = frontends[locale]!.prepare(c['text'] as String,
            dictionary: c['dictionary_snapshot'] == null ? null :
              Map<String, dynamic>.from(c['dictionary_snapshot'] as Map));
          check(!shouldFail, 'Expected visible error for ${c['id']}');
          check(result.words > 0 && result.chunks.isNotEmpty, 'Empty result');
          check(result.chunks.every((p) => p.runes.length <= 400), 'Chunk over limit');
          if (c['id'] == 'dictionary-substitution') {
            check(result.normalized.text == c['expected_transformed_text'], 'Substitution mismatch');
          }
          if (c['id'] == 'ambiguous-date') {
            check(result.normalized.text.contains(locale == 'en-US' ? 'March fourth' : 'April third'), 'Wrong date policy');
          }
          if (c['id'] == 'numbers-money') {
            for (final word in ['three','dollars','fifty cents','twelve point five percent','two point five kilometers']) {
              check(result.normalized.text.contains(word), 'Missing number expansion: $word');
            }
          }
          if (c['id'] == 'unicode-epub') {
            for (final word in ['cafe', 'fine', 'facade', 'cooperate', 'Cafe']) {
              check(result.normalized.text.contains(word), 'Missing Unicode normalization: $word');
            }
          }
          if (c['id'] == 'inline-prose-preserved') {
            check(result.normalized.text.contains('bright') && result.normalized.text.contains('three times four'), 'Lost inline meaning');
          }
          results.add({'id':c['id'], 'locale':locale, 'pass':true, 'outcome':'accepted', ...result.toJson()});
        } on FormatException catch (e) {
          final acceptedError = shouldFail &&
            (c['id'] == 'punctuation-only' ? e.message.contains('No spoken words') : e.message.contains('Unsupported English input'));
          results.add({'id':c['id'], 'locale':locale, 'pass':acceptedError, 'outcome':'visible_error', 'error':'$e'});
          if (!acceptedError) failures.add('${c['id']} ($locale): $e');
        } catch (e) {
          failures.add('${c['id']} ($locale): $e');
          results.add({'id':c['id'], 'locale':locale, 'pass':false, 'error':'$e'});
        }
      }
    }
    for (final word in ['Xylophonia', 'Quvenzhane']) {
      check(native.phonemize(word).$1!.isNotEmpty, 'Fallback empty');
    }
    for (final text in ['Anna read 😀 aloud.', 'The price was \$1.234.', 'The date was 02/31/2026.']) {
      var rejected = false;
      try { frontends['en-US']!.prepare(text); } on FormatException { rejected = true; }
      check(rejected, 'Unsupported input should fail: $text');
    }
    for (final word in ['a' * 63, '你好']) {
      var rejected = false;
      try { native.phonemize(word); } on FormatException { rejected = true; }
      check(rejected, 'Invalid fallback input accepted');
    }
    final restricted = EnglishFrontend(data, <String>{}, native);
    var rejected = false;
    try { restricted.prepare('Hello.'); } on FormatException { rejected = true; }
    check(rejected, 'Unknown phoneme must fail');
    final ortPaths = File('/proc/self/maps').readAsLinesSync()
      .where((line) => line.contains('/libonnxruntime.so'))
      .map((line) => line.split(RegExp(r'\s+')).last).toSet();
    check(ortPaths.length == 1, 'Duplicated runtime libraries: $ortPaths');
    final report = {'platform':'Linux x86_64 host, NOT Android/Pixel', 'runtime':native.runtimeVersion,
      'loadedOrtPaths':ortPaths.toList(), 'corpusCases':16, 'results':results,
      'allPassed':failures.isEmpty, 'failures':failures,
      'pronunciationCorrectness':'Not established by acceptance; manual listening required',
      'audioGeneratedByThisTest':false};
    File(args[3]).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    for (final r in results) {
      print("${r['pass'] == true ? 'PASS' : 'FAIL'} ${r['id']} ${r['locale']} ${r['outcome']} ${r['error'] ?? ''}");
    }
    check(failures.isEmpty, failures.join('\n'));
  } finally { native.close(); }
  var closedRejected = false;
  try { native.phonemize('hello'); } on StateError { closedRejected = true; }
  check(closedRejected, 'Closed native session must fail safely');
}
