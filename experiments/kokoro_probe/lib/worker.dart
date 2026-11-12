import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'frontend.dart';

Future<String> fileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

// Each operation owns its resources. No model pointers cross isolate boundaries.
void worker(Map<String, dynamic> args) async {
  final port = args['port'] as SendPort;
  try {
    if (args['operation'] == 'install') {
      await install(args, port);
    } else {
      await generate(args, port);
    }
    port.send({'done': true});
  } catch (error, stack) {
    port.send({'error': '$error', 'stack': '$stack'});
  }
}

Future<void> install(Map<String, dynamic> args, SendPort port) async {
  final manifest = jsonDecode(args['manifest'] as String) as Map<String, dynamic>;
  final root = args['root'] as String;
  final target = Directory('$root/${manifest['directory']}');
  final staging = Directory('$root/staging');
  // Interrupted installs are never treated as ready; retry starts cleanly.
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);
  final archiveFile = File('$root/model.part');
  final tarFile = File('$root/model.tar');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final response = await (await client.getUrl(Uri.parse(manifest['url'] as String)))
        .close().timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) throw HttpException('Download HTTP ${response.statusCode}');
    final output = archiveFile.openWrite();
    var received = 0;
    var lastUpdate = 0;
    try {
      await for (final bytes in response.timeout(const Duration(seconds: 60))) {
        received += bytes.length;
        if (received > (manifest['archiveBytes'] as int)) throw StateError('Unexpected download size');
        output.add(bytes);
        // Flush applies backpressure, keeping a fast connection from buffering the model in RAM.
        await output.flush();
        if (received - lastUpdate > 2 * 1024 * 1024) {
          port.send({'status': 'Downloading ${(received / 1000000).toStringAsFixed(1)} / 132.4 MB'});
          lastUpdate = received;
        }
      }
    } finally {
      await output.close();
    }
    if (received != manifest['archiveBytes'] ||
        await fileHash(archiveFile) != manifest['archiveSha256']) {
      throw StateError('Download checksum/size mismatch. Retry installation.');
    }
    port.send({'status': 'Verifying and unpacking on device. This can take several minutes.'});
    final compressed = InputFileStream(archiveFile.path);
    final uncompressed = OutputFileStream(tarFile.path);
    try {
      if (!BZip2Decoder().decodeStream(compressed, uncompressed, verify: true)) {
        throw StateError('Invalid bzip2 archive');
      }
    } finally {
      compressed.closeSync();
      uncompressed.closeSync();
    }
    final input = InputFileStream(tarFile.path);
    try {
      final archive = TarDecoder().decodeStream(input);
      final files = manifest['files'] as Map<String, dynamic>;
      // Extract only pinned regular files. No archive paths or links become destination paths.
      for (final name in files.keys) {
        final entry = archive.findFile('${manifest['directory']}/$name');
        if (entry == null || !entry.isFile || entry.isSymbolicLink) {
          throw StateError('Missing regular file $name');
        }
        final out = OutputFileStream('${staging.path}/$name');
        try { entry.writeContent(out); } finally { out.closeSync(); }
        final file = File('${staging.path}/$name');
        if (file.lengthSync() != files[name]['bytes'] ||
            await fileHash(file) != files[name]['sha256']) {
          throw StateError('Installed file verification failed: $name');
        }
      }
    } finally { input.closeSync(); }
    File('${staging.path}/READY').writeAsStringSync(manifest['archiveSha256'] as String, flush: true);
    if (target.existsSync()) target.deleteSync(recursive: true);
    staging.renameSync(target.path);
    port.send({'installed': true, 'status': 'Model verified. Enable airplane mode before generating.'});
  } finally {
    client.close(force: true);
    if (archiveFile.existsSync()) archiveFile.deleteSync();
    if (tarFile.existsSync()) tarFile.deleteSync();
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}

Future<void> generate(Map<String, dynamic> args, SendPort port) async {
  final root = args['model'] as String;
  final lexiconName = args['british'] == true ? 'lexicon-gb-en.txt' : 'lexicon-us-en.txt';
  final frontendTimer = Stopwatch()..start();
  final lexicon = parseLexicon(File('$root/$lexiconName').readAsStringSync());
  final prepared = prepareText(args['text'] as String, lexicon);
  // Native lexicon-to-token conversion must not silently drop unfamiliar phonemes either.
  final tokens = File('$root/tokens.txt').readAsLinesSync()
      .map((line) => line.substring(0, line.lastIndexOf(' '))).toSet();
  for (final chunk in prepared.chunks) {
    for (final word in RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)*").allMatches(chunk)) {
      if (lexicon[word.group(0)!.toLowerCase()]!.any((phone) => !tokens.contains(phone))) {
        throw FormatException('Unsupported phoneme in ${word.group(0)}. No audio generated.');
      }
    }
  }
  frontendTimer.stop();
  sherpa.initBindings();
  final loadTimer = Stopwatch()..start();
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      kokoro: sherpa.OfflineTtsKokoroModelConfig(
        model: '$root/model.int8.onnx', voices: '$root/voices.bin',
        tokens: '$root/tokens.txt', lexicon: '$root/$lexiconName',
        lang: args['british'] == true ? 'en-gb' : 'en-us',
      ),
      numThreads: args['threads'] as int, provider: 'cpu', debug: false,
    ), maxNumSentences: 1,
  ));
  loadTimer.stop();
  try {
    for (var run = 1; run <= (args['repeats'] as int); run++) {
      port.send({'runStart': run});
      final timer = Stopwatch()..start();
      final path = '${args['output']}/probe-${args['id']}-$run.wav';
      final partial = File('$path.part');
      final wav = partial.openSync(mode: FileMode.write);
      var frames = 0;
      var firstAudioMs = 0;
      try {
        wav.writeFromSync(Uint8List(44));
        for (var i = 0; i < prepared.chunks.length; i++) {
          final audio = tts.generate(text: prepared.chunks[i], sid: args['sid'] as int, speed: 1.0);
          if (audio.sampleRate != 24000 || audio.samples.isEmpty) throw StateError('Empty or unexpected audio');
          if (i == 0) firstAudioMs = timer.elapsedMilliseconds;
          final bytes = ByteData(audio.samples.length * 2);
          for (var j = 0; j < audio.samples.length; j++) {
            final sample = audio.samples[j];
            if (!sample.isFinite) throw StateError('Non-finite audio sample');
            bytes.setInt16(j * 2, (sample.clamp(-1.0, 1.0) * 32767).round(), Endian.little);
          }
          wav.writeFromSync(bytes.buffer.asUint8List());
          frames += audio.samples.length;
          port.send({'status': 'Run $run: ${i + 1}/${prepared.chunks.length} chunks'});
        }
        wav.setPositionSync(0);
        wav.writeFromSync(wavHeader(frames, 24000));
        wav.flushSync();
      } finally { wav.closeSync(); }
      partial.renameSync(path);
      timer.stop();
      final audioSeconds = frames / 24000;
      port.send({'result': {
        'run': run, 'engineWarm': run > 1, 'path': path,
        'wordCount': prepared.words, 'chunkCount': prepared.chunks.length,
        'frontendMs': frontendTimer.elapsedMilliseconds, 'modelLoadMs': loadTimer.elapsedMilliseconds,
        'generationAndWriteMs': timer.elapsedMilliseconds, 'firstChunkMs': firstAudioMs,
        'audioSeconds': audioSeconds, 'rtf': timer.elapsedMilliseconds / 1000 / audioSeconds,
        'threads': args['threads'], 'sid': args['sid'], 'speed': 1.0,
        'runtime': 'sherpa_onnx 2.0.1 CPU', 'modelArchiveSha256': args['modelSha'],
        'textSha256': sha256.convert(utf8.encode(args['text'] as String)).toString(),
        'wavBytes': File(path).lengthSync(), 'wavSha256': await fileHash(File(path)),
      }});
    }
  } finally { tts.free(); }
}

Uint8List wavHeader(int frames, int rate) {
  final bytes = ByteData(44);
  final raw = bytes.buffer.asUint8List();
  void tag(int offset, String value) => raw.setRange(offset, offset + value.length, ascii.encode(value));
  tag(0, 'RIFF'); bytes.setUint32(4, 36 + frames * 2, Endian.little);
  tag(8, 'WAVE'); tag(12, 'fmt '); bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little); bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little); bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little); bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data'); bytes.setUint32(40, frames * 2, Endian.little);
  return raw;
}
