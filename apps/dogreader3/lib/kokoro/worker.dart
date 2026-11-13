import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'frontend.dart';
import 'audio.dart';
import 'english_frontend.dart';
import 'native_g2p.dart';
import 'frontend_install.dart';
import 'generation_journal.dart';
import 'chunk_store.dart';

Future<String> fileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

// Each operation owns its resources. No model pointers cross isolate boundaries.
void worker(Map<String, dynamic> args) async {
  final port = args['port'] as SendPort;
  try {
    if (args['operation'] == 'install') {
      await install(args, port);
    } else if (args['operation'] == 'installFrontend') {
      await installEnglishFrontend(args, port);
    } else {
      await generate(args, port);
    }
    port.send({'done': true});
  } on GenerationCancelled {
    port.send({'cancelled': true});
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
          port.send({'status': 'Downloading ${(received / 1000000).toStringAsFixed(1)} / ${((manifest['archiveBytes'] as int) / 1000000).toStringAsFixed(1)} MB'});
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
      BZip2Decoder().decodeStream(compressed, uncompressed, verify: true);
    } finally {
      compressed.closeSync();
      uncompressed.closeSync();
    }
    final input = InputFileStream(tarFile.path);
    try {
      final archive = TarDecoder().decodeBuffer(input);
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
  final journal = args['journalPath'] == null ? null :
      GenerationJournal(args['journalPath'] as String, args['cancelPath'] as String);
  journal?.record('workerStarted');
  journal?.checkCancellation();
  final variant = args['variant'] as String;
  final modelFile = args['modelFile'] as String;
  final lexiconName = args['british'] == true ? 'lexicon-gb-en.txt' : 'lexicon-us-en.txt';
  final frontendTimer = Stopwatch()..start();
  final useMisaki = args['frontend'] == 'misaki';
  final frontendId = useMisaki ? 'misaki-fonnx-1.2.0-api28-v1' : 'probe-145-lexicon-chunker';
  final PreparedText prepared;
  EnglishPrepared? english;
  sherpa.initBindings(); // Loads Sherpa and its existing ORT before the adapter.
  if (useMisaki) {
    final spec = jsonDecode(args['frontendManifest'] as String) as Map<String, dynamic>;
    final path = '${args['root']}/${spec['directory']}';
    await verifyEnglishFrontend(path, spec);
    final backend = NativeG2p('$path/kokoro_g2p_fallback_en_us.onnx',
      File('$path/kokoro_g2p_fallback_en_us.json').readAsStringSync(),
      threads: args['threads'] as int);
    try {
      english = EnglishFrontend(path, readPhoneInventory('$root/tokens.txt'), backend,
        locale: args['british'] == true ? 'en-GB' : 'en-US').prepare(
          args['text'] as String, dictionary: args['dictionary'] as Map<String, dynamic>?);
      prepared = PreparedText(english.chunks, english.words);
    } finally { backend.close(); } // Release BART before loading the large FP32 model.
  } else {
    final lexicon = parseLexicon(File('$root/$lexiconName').readAsStringSync());
    prepared = prepareText(args['text'] as String, lexicon);
    final tokens = readPhoneInventory('$root/tokens.txt');
    for (final chunk in prepared.chunks) {
      for (final word in RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)*").allMatches(chunk)) {
        if (lexicon[word.group(0)!.toLowerCase()]!.any((phone) => !tokens.contains(phone))) {
          throw FormatException('Unsupported phoneme in ${word.group(0)}. No audio generated.');
        }
      }
    }
  }
  frontendTimer.stop();
  final chunks = args['checkpointPath'] == null ? null : ChunkStore(
    Directory(args['checkpointPath'] as String), chunkFingerprint(args, prepared.chunks));
  await Future<void>.delayed(Duration.zero);
  journal?.checkCancellation();
  final loadTimer = Stopwatch()..start();
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      kokoro: sherpa.OfflineTtsKokoroModelConfig(
        model: '$root/$modelFile', voices: '$root/voices.bin',
        tokens: '$root/tokens.txt', lexicon: '$root/$lexiconName',
        lang: args['british'] == true ? 'en-gb' : 'en-us',
      ),
      numThreads: args['threads'] as int, provider: 'cpu', debug: false,
    ), maxNumSentences: 1,
  ));
  loadTimer.stop();
  try {
    for (var run = 1; run <= (args['repeats'] as int); run++) {
      journal?.checkCancellation();
      port.send({'runStart': run});
      final timer = Stopwatch()..start();
      final path = '${args['output']}/probe-$variant-${args['id']}-$run.wav';
      final partial = File('$path.part');
      final wav = partial.openSync(mode: FileMode.write);
      var frames = 0;
      var firstAudioMs = 0;
      double peak = 0, sum = 0, squares = 0;
      var clipped = 0, fullScale = 0;
      int? previousPcm;
      final boundaries = <Map<String, dynamic>>[];
      var complete = false;
      try {
        wav.writeFromSync(Uint8List(44));
        for (var i = 0; i < prepared.chunks.length; i++) {
          await Future<void>.delayed(Duration.zero);
          journal?.checkCancellation();
          journal?.record('chunkStart', {'run': run, 'chunk': i + 1, 'totalChunks': prepared.chunks.length});
          port.send({'phase': 'generating', 'run': run, 'chunk': i + 1,
            'totalChunks': prepared.chunks.length, 'status': 'Run $run: generating chunk ${i + 1}/${prepared.chunks.length}'});
          var pcm = chunks?.read(i);
          if (pcm == null) {
            final audio = useMisaki
                ? tts.generateWithConfig(text: '', config: sherpa.OfflineTtsGenerationConfig(
                    sid: args['sid'] as int, speed: 1.0, phonemeCodepoints: [prepared.chunks[i].runes.toList()]))
                : tts.generate(text: prepared.chunks[i], sid: args['sid'] as int, speed: 1.0);
            journal?.record('chunkInferenceEnd', {'run': run, 'chunk': i + 1, 'frames': audio.samples.length});
            if (audio.sampleRate != 24000 || audio.samples.isEmpty) throw StateError('Empty or unexpected audio');
            pcm = encodePcm16(audio.samples);
            chunks?.write(i, pcm);
            journal?.record('chunkCommitted', {'run': run, 'chunk': i + 1, 'frames': audio.samples.length});
          } else {
            journal?.record('chunkRestored', {'run': run, 'chunk': i + 1, 'frames': pcm.bytes.length ~/ 2});
          }
          journal?.checkCancellation();
          if (i == 0) firstAudioMs = timer.elapsedMilliseconds;
          final chunkFrames = pcm.bytes.length ~/ 2;
          peak = math.max(peak, pcm.peak);
          sum += pcm.sum; squares += pcm.squareSum;
          clipped += pcm.clippedSamples; fullScale += pcm.fullScaleSamples;
          boundaries.add({'chunk': i + 1, 'startFrame': frames,
            'frames': chunkFrames, 'firstPcm': pcm.firstPcm, 'lastPcm': pcm.lastPcm,
            'joinDeltaPcm': previousPcm == null ? null : pcm.firstPcm - previousPcm});
          previousPcm = pcm.lastPcm;
          wav.writeFromSync(pcm.bytes);
          frames += chunkFrames;
          journal?.record('chunkWritten', {'run': run, 'chunk': i + 1, 'totalFrames': frames});
          port.send({'phase': 'generating', 'run': run, 'chunk': i + 1,
            'totalChunks': prepared.chunks.length, 'completedChunks': i + 1, 'status': 'Run $run: ${i + 1}/${prepared.chunks.length} chunks saved'});
        }
        wav.setPositionSync(0);
        wav.writeFromSync(wavHeader(frames, 24000));
        wav.flushSync();
        journal?.checkCancellation();
        complete = true;
      } finally {
        wav.closeSync();
        if (!complete && partial.existsSync()) partial.deleteSync();
      }
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
        'frontend': frontendId, 'frontendDiagnostics': english?.toJson(),
        'modelVariant': variant, 'modelFile': modelFile, 'modelFileSha256': args['modelFileSha'],
        'sampleRate': 24000, 'channels': 1, 'pcmBits': 16, 'sampleFrames': frames,
        'rawPeakAmplitude': peak, 'rawRmsAmplitude': math.sqrt(squares / frames),
        'rawMeanAmplitude': sum / frames, 'clippedSamples': clipped,
        'samplesAtOrBeyondFullScale': fullScale, 'chunkBoundaries': boundaries,
        'chunksSha256': sha256.convert(utf8.encode(jsonEncode(prepared.chunks))).toString(),
        'comparisonSettingsSha256': sha256.convert(utf8.encode(jsonEncode({
          'text': args['text'], 'sid': args['sid'], 'threads': args['threads'], 'speed': 1.0,
          'runtime': 'sherpa_onnx 2.0.1 CPU', 'frontend': frontendId, 'dictionary': args['dictionary'],
        }))).toString(),
        'textSha256': sha256.convert(utf8.encode(args['text'] as String)).toString(),
        'wavBytes': File(path).lengthSync(), 'wavSha256': await fileHash(File(path)),
      }});
    }
  } finally { tts.free(); journal?.record('nativeResourcesReleased'); }
}
