// Android-only test entrypoint. Never used by the shipped application.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';

class ProbeHandler extends DogreaderAudioHandler {
  final commands = <String, int>{};
  final commandPositionsMs = <String, int>{};
  void received(String name) {
    commands.update(name, (value) => value + 1, ifAbsent: () => 1);
    commandPositionsMs[name] = player.position.inMilliseconds;
  }

  @override
  Future<void> play() { received('play'); return super.play(); }
  @override
  Future<void> pause() { received('pause'); return super.pause(); }
  @override
  Future<void> stop() { received('stop'); return super.stop(); }
  @override
  Future<void> rewind() { received('rewind'); return super.rewind(); }
  @override
  Future<void> fastForward() { received('fastForward'); return super.fastForward(); }
  @override
  Future<void> seek(Duration position) { received('seek'); return super.seek(position); }
}

Future<File> makeTone(Directory root) async {
  const rate = 8000;
  const seconds = 300;
  const dataBytes = rate * seconds * 2;
  final header = ByteData(44)
    ..setUint32(0, 0x52494646)
    ..setUint32(4, dataBytes + 36, Endian.little)
    ..setUint32(8, 0x57415645)
    ..setUint32(12, 0x666d7420)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x64617461)
    ..setUint32(40, dataBytes, Endian.little);
  final second = ByteData(rate * 2);
  for (var i = 0; i < rate; i++) {
    second.setInt16(i * 2, (1000 * math.sin(2 * math.pi * 440 * i / rate)).round(), Endian.little);
  }
  final file = File('${root.path}/media-control-probe.wav');
  final sink = file.openWrite()..add(header.buffer.asUint8List());
  for (var i = 0; i < seconds; i++) {
    sink.add(second.buffer.asUint8List());
  }
  await sink.close();
  return file;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await getApplicationDocumentsDirectory();
  final handler = await AudioService.init(
    builder: ProbeHandler.new,
    // Exactly the production build-124 service configuration.
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.audiobook_app.audio',
      androidNotificationChannelName: 'Dogreader narration',
      androidNotificationOngoing: true,
    ),
  );
  var writing = false;
  String? fatal;
  final bridgeErrors = <String>[];
  AudioService.asyncError.listen((error) {
    final code = error is PlatformException ? error.code : error.runtimeType.toString();
    if (bridgeErrors.length == 8) bridgeErrors.removeAt(0);
    bridgeErrors.add(code);
    debugPrint(jsonEncode({'event': 'probe_media_bridge_error', 'code': code}));
  });
  Future<void> snapshot() async {
    if (writing) return;
    writing = true;
    try {
      final player = handler.player;
      final state = handler.playbackState.value;
      final file = File('${root.path}/media-control-probe.json.tmp');
      await file.writeAsString(jsonEncode({
        'commands': Map<String, int>.from(handler.commands),
        'commandPositionsMs': Map<String, int>.from(handler.commandPositionsMs),
        'bridgeErrors': List<String>.from(bridgeErrors),
        'playing': player.playing,
        'sessionPlaying': state.playing,
        'processing': player.processingState.name,
        'positionMs': player.position.inMilliseconds,
        'durationMs': player.duration?.inMilliseconds,
        'fatal': fatal,
      }));
      await file.rename('${root.path}/media-control-probe.json');
    } finally {
      writing = false;
    }
  }

  void failed(Object error) {
    fatal = error.runtimeType.toString();
    unawaited(snapshot());
  }

  runApp(MaterialApp(home: Scaffold(
    appBar: AppBar(title: const Text('DogReader media probe')),
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('Synthetic local audio. No cloud access.'),
      ElevatedButton(onPressed: () => unawaited(handler.pause().catchError(failed)),
          child: const Text('In-app Pause')),
      ElevatedButton(onPressed: () => unawaited(handler.play().catchError(failed)),
          child: const Text('In-app Play')),
      ElevatedButton(onPressed: () => unawaited(handler.stop().catchError(failed)),
          child: const Text('In-app Stop')),
    ])),
  )));
  Timer.periodic(const Duration(milliseconds: 250), (_) => unawaited(snapshot()));
  try {
    final tone = await makeTone(root);
    await handler.loadChapter(path: tone.path, title: 'Control probe',
        author: 'Synthetic fixture', bookId: 'probe', chapterIndex: 0,
        chapterCount: 1, startPosition: const Duration(seconds: 80));
    unawaited(handler.play().catchError(failed));
  } catch (error) {
    failed(error);
  }
}
