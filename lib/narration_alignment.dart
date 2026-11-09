import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Coordinates use Dart UTF-16 code units, not Unicode code points or bytes.
class NarrationPassage {
  final int offset, paragraphStart, paragraphEnd;
  const NarrationPassage(this.offset, this.paragraphStart, this.paragraphEnd);
}

class NarrationAlignment {
  final String audioSha256, text;
  final int durationMs;
  final List<({int start, int end, int offset, int textEnd})> _words;
  NarrationAlignment._(
    this.audioSha256,
    this.text,
    this.durationMs,
    this._words,
  );

  factory NarrationAlignment.parse(Map<String, dynamic> data, String text) {
    if (data['schema'] != 'dogreader-alignment-v1' ||
        data['offset_unit'] != 'utf16' ||
        data['precision'] != 'word' ||
        data['reviewed'] != true ||
        data['text_sha256'] != sha256.convert(utf8.encode(text)).toString() ||
        data['audio_sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['audio_sha256'] as String) ||
        data['duration_ms'] is! int ||
        (data['duration_ms'] as int) <= 0 ||
        data['words'] is! List ||
        (data['words'] as List).isEmpty ||
        (data['words'] as List).length > 250000) {
      throw const FormatException(
        'Unsupported or mismatched synchronization map',
      );
    }
    final words = <({int start, int end, int offset, int textEnd})>[];
    final lexical = RegExp(r'[\p{L}\p{N}]', unicode: true);
    final whitespace = RegExp(r'\s');
    var lastTime = 0, lastOffset = 0;
    for (final item in data['words'] as List) {
      if (item is! Map ||
          [
            'start_ms',
            'end_ms',
            'text_start',
            'text_end',
          ].any((key) => item[key] is! int)) {
        throw const FormatException('Invalid synchronization coordinates');
      }
      final a = item['start_ms'] as int, b = item['end_ms'] as int;
      final x = item['text_start'] as int, y = item['text_end'] as int;
      bool splitsSurrogate(int offset) =>
          offset > 0 &&
          offset < text.length &&
          text.codeUnitAt(offset) >= 0xdc00 &&
          text.codeUnitAt(offset) <= 0xdfff;
      if (a < lastTime ||
          b <= a ||
          b > data['duration_ms'] ||
          x < lastOffset ||
          y <= x ||
          y > text.length ||
          splitsSurrogate(x) ||
          splitsSurrogate(y) ||
          whitespace.hasMatch(text.substring(x, y)) ||
          lexical.hasMatch(text.substring(lastOffset, x))) {
        throw const FormatException(
          'Incomplete or non-monotonic synchronization map',
        );
      }
      words.add((start: a, end: b, offset: x, textEnd: y));
      lastTime = b;
      lastOffset = y;
    }
    if (lexical.hasMatch(text.substring(lastOffset))) {
      throw const FormatException('Incomplete synchronization map');
    }
    return NarrationAlignment._(
      data['audio_sha256'] as String,
      text,
      data['duration_ms'] as int,
      List.unmodifiable(words),
    );
  }

  NarrationPassage passageAt(Duration position) {
    final ms = position.inMilliseconds.clamp(0, durationMs);
    var low = 0, high = _words.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_words[mid].start <= ms) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final word = _words[low];
    final start = word.offset == 0
        ? 0
        : text.lastIndexOf('\n', word.offset - 1) + 1;
    final next = text.indexOf('\n', word.textEnd);
    return NarrationPassage(word.offset, start, next < 0 ? text.length : next);
  }
}

/// Optional metadata: a failure must never interrupt listening or downloading.
/// GET only; this never submits generation or alignment work to the server.
Future<NarrationAlignment?> loadNarrationAlignment({
  required Directory root,
  required String bookId,
  required int chapterIndex,
  required File audio,
  required String text,
}) async {
  final sidecar = File('${audio.path}.alignment.json');
  Future<NarrationAlignment> validate(Map<String, dynamic> data) async {
    final map = NarrationAlignment.parse(data, text);
    final digest = await sha256.bind(audio.openRead()).first;
    if (digest.toString() != map.audioSha256) {
      throw const FormatException(
        'Synchronization belongs to another recording',
      );
    }
    return map;
  }

  try {
    if (await sidecar.exists()) {
      if (await sidecar.length() > 16 * 1024 * 1024) return null;
      return await validate(
        jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>,
      );
    }
  } catch (_) {
    // A replaced recording must never inherit old timing. Try current metadata.
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  client.autoUncompress = false;
  try {
    final config = jsonDecode(
      await File('${root.path}/dogreader_queue.json').readAsString(),
    ) as Map;
    final state = jsonDecode(
      await File('${root.path}/narration_state.json').readAsString(),
    ) as Map;
    final entry = state['$bookId:$chapterIndex'];
    // Only downloads with retained recording identity can request a map.
    final id = entry is Map && entry.containsKey('jobId')
        ? entry['jobId']
        : (config['books'] as Map?)?[bookId]?['$chapterIndex']?['id'];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) return null;
    final host = Uri.parse(config['host'] as String);
    if (host.scheme != 'https' || host.host.isEmpty) return null;
    final request = await client
        .getUrl(host.resolve('/dogreader/jobs/$id/timing'))
        .timeout(const Duration(seconds: 5));
    request.followRedirects = false;
    request.headers.set('X-Dogreader-Token', config['token'] as String);
    final response = await request.close().timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) return null;
    Future<List<int>> readBody() async {
      final bytes = <int>[];
      await for (final block in response) {
        bytes.addAll(block);
        if (bytes.length > 16 * 1024 * 1024) {
          throw const FormatException('Oversized timing map');
        }
      }
      return bytes;
    }

    final bytes = await readBody().timeout(const Duration(seconds: 8));
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (data['job_id'] != id) return null;
    final map = await validate(data);
    final temporary = File('${sidecar.path}.part');
    await temporary.writeAsString(jsonEncode(data));
    await temporary.rename(sidecar.path);
    return map;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<void> invalidateNarrationAlignment(File audio) async {
  final sidecar = File('${audio.path}.alignment.json');
  if (await sidecar.exists()) await sidecar.delete();
}
