import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'audio.dart';

/// Durable, lossless PCM checkpoints. Only a complete, hash-verified chunk is reused.
/// The fingerprint includes phonemes and every synthesis setting, never just text.
class ChunkStore {
  ChunkStore(this.directory, this.fingerprint) {
    directory.createSync(recursive: true);
  }
  final Directory directory;
  final String fingerprint;

  Pcm16Chunk? read(int index) {
    final metadata = File('${directory.path}/$index.json');
    if (!metadata.existsSync()) return null;
    final item = jsonDecode(metadata.readAsStringSync()) as Map;
    if (item['fingerprint'] != fingerprint) {
      throw StateError('Saved chunk settings differ; start a new chapter job.');
    }
    final pcm = File('${directory.path}/$index.pcm');
    final bytes = pcm.readAsBytesSync();
    if (bytes.isEmpty || bytes.length.isOdd || bytes.length != item['bytes'] ||
        sha256.convert(bytes).toString() != item['sha256']) {
      throw StateError('Saved chunk $index failed integrity checks. No chapter completed.');
    }
    return Pcm16Chunk(bytes, (item['peak'] as num).toDouble(),
      (item['sum'] as num).toDouble(), (item['squareSum'] as num).toDouble(),
      item['clipped'] as int, item['fullScale'] as int,
      item['first'] as int, item['last'] as int);
  }

  void write(int index, Pcm16Chunk chunk) {
    final pcm = File('${directory.path}/$index.pcm.part');
    pcm.writeAsBytesSync(chunk.bytes, flush: true);
    pcm.renameSync('${directory.path}/$index.pcm');
    final metadata = File('${directory.path}/$index.json.part');
    metadata.writeAsStringSync(jsonEncode({
      'fingerprint': fingerprint, 'bytes': chunk.bytes.length,
      'sha256': sha256.convert(chunk.bytes).toString(),
      'peak': chunk.peak, 'sum': chunk.sum, 'squareSum': chunk.squareSum,
      'clipped': chunk.clippedSamples, 'fullScale': chunk.fullScaleSamples,
      'first': chunk.firstPcm, 'last': chunk.lastPcm,
    }), flush: true);
    metadata.renameSync('${directory.path}/$index.json');
  }
}

String chunkFingerprint(Map<String, dynamic> args, List<String> chunks) =>
    sha256.convert(utf8.encode(jsonEncode({
      'chunks': chunks, 'model': args['modelSha'], 'graph': args['modelFileSha'],
      'frontend': args['frontendManifest'], 'sid': args['sid'],
      'threads': args['threads'], 'speed': 1.0, 'british': args['british'],
      'sampleRate': 24000, 'channels': 1, 'pcmBits': 16,
    }))).toString();
