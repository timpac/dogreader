import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'narration_options.dart';

Future<Map<String, dynamic>> narrationRequest(
  String host,
  String token,
  String method,
  String path, [
  Map<String, dynamic>? payload,
]) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client
        .openUrl(
          method,
          Uri.parse('${host.replaceAll(RegExp(r'/$'), '')}$path'),
        )
        .timeout(const Duration(seconds: 8));
    req.headers.set('X-Dogreader-Token', token);
    if (payload != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
    }
    final response = await req.close().timeout(const Duration(seconds: 15));
    final result = jsonDecode(
      await utf8.decoder.bind(response).join(),
    ) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw Exception(result['error'] ?? 'HTTP ${response.statusCode}');
    }
    return result;
  } finally {
    client.close(force: true);
  }
}

/// Uses the existing short-job API, selected engine and temporary preview path.
/// Never enters the chapter queue or replaces a chapter recording.
Future<File?> generateNarrationPreview({
  required String host,
  required String token,
  required NarrationPreference preference,
  required String sample,
  required bool Function() isCurrent,
}) async {
  if (host.isEmpty || token.isEmpty) {
    throw StateError('Connect Dogreader Cloud in narration settings first.');
  }
  final text = sample.length > 300 ? sample.substring(0, 300) : sample;
  if (text.trim().isEmpty) return null;
  var response = await narrationRequest(
    host,
    token,
    'POST',
    '/dogreader/jobs',
    {...preference.toJson(), 'title': 'Pronunciation preview', 'text': text},
  );
  final id = response['id'] as String;
  for (var attempt = 0; attempt < 60; attempt++) {
    if (!isCurrent()) return null;
    if (response['status'] == 'ready') break;
    if (response['status'] == 'error') {
      throw Exception(response['error'] ?? 'Preview generation failed');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!isCurrent()) return null;
    response = await narrationRequest(
      host,
      token,
      'GET',
      '/dogreader/jobs/$id',
    );
  }
  if (!isCurrent()) return null;
  if (response['status'] != 'ready') {
    throw StateError('Preview is still queued. Retry shortly.');
  }
  if ((response['engine'] ?? 'google') != preference.engine ||
      (response['voice'] != null && response['voice'] != preference.voice)) {
    throw StateError(
      'Server returned a different engine or voice. Update the backend.',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(
      Uri.parse('${host.replaceAll(RegExp(r'/$'), '')}/dogreader/audio/$id'),
    );
    req.headers.set('X-Dogreader-Token', token);
    final audio = await req.close().timeout(const Duration(seconds: 20));
    if (audio.statusCode != 200) {
      throw Exception('Preview download failed (${audio.statusCode})');
    }
    final root = await getTemporaryDirectory();
    final preview = File('${root.path}/preview_$id.mp3');
    final staged = File('${preview.path}.part');
    try {
      await audio.pipe(staged.openWrite());
      if (await staged.length() < 1000 ||
          (audio.contentLength >= 0 &&
              await staged.length() != audio.contentLength)) {
        throw StateError('Preview download was incomplete');
      }
      await staged.rename(preview.path);
    } finally {
      if (await staged.exists()) await staged.delete();
    }
    return isCurrent() ? preview : null;
  } finally {
    client.close(force: true);
  }
}
