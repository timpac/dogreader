import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';

Future<String> _hash(File file) async => (await sha256.bind(file.openRead()).first).toString();

Future<void> verifyEnglishFrontend(String path, Map<String, dynamic> spec) async {
  final marker = File('$path/READY');
  if (!marker.existsSync() || marker.readAsStringSync() != spec['id']) {
    throw StateError('Download the English frontend once before using Misaki.');
  }
  for (final entry in (spec['files'] as Map<String, dynamic>).entries) {
    final file = File('$path/${entry.key}');
    if (!file.existsSync() || file.lengthSync() != entry.value['bytes'] ||
        await _hash(file) != entry.value['sha256']) {
      throw StateError('English frontend file failed verification: ${entry.key}. Re-download it.');
    }
  }
}

Future<void> installEnglishFrontend(Map<String, dynamic> args, SendPort port) async {
  final spec = jsonDecode(args['frontendManifest'] as String) as Map<String, dynamic>;
  final root = args['root'] as String;
  final staging = Directory('$root/frontend-staging');
  final target = Directory('$root/${spec['directory']}');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final entries = (spec['files'] as Map<String, dynamic>).entries;
    var index = 0;
    for (final entry in entries) {
      if (!RegExp(r'^kokoro_[a-z0-9_.]+$').hasMatch(entry.key)) throw StateError('Invalid asset name');
      port.send({'status': 'Downloading English frontend: ${++index}/${entries.length} · ${entry.key}'});
      final item = entry.value as Map<String, dynamic>;
      final response = await (await client.getUrl(Uri.parse(item['url'] as String))).close()
        .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) throw HttpException('Frontend download HTTP ${response.statusCode}');
      final file = File('${staging.path}/${entry.key}');
      final sink = file.openWrite();
      var bytes = 0;
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 60))) {
          bytes += chunk.length;
          if (bytes > item['bytes']) throw StateError('Unexpected frontend file size');
          sink.add(chunk); await sink.flush();
        }
      } finally { await sink.close(); }
      if (bytes != item['bytes'] || await _hash(file) != item['sha256']) {
        throw StateError('English frontend checksum mismatch: ${entry.key}');
      }
    }
    File('${staging.path}/READY').writeAsStringSync(spec['id'] as String, flush: true);
    if (target.existsSync()) target.deleteSync(recursive: true);
    staging.renameSync(target.path);
    port.send({'frontendInstalled': true, 'status': 'English frontend verified. Enable airplane mode before generating.'});
  } finally {
    client.close(force: true);
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}
