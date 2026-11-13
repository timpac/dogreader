import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'worker.dart';

const generationChannel = MethodChannel('dogreader.kokoro_generation');

/// Root isolate of the Service's headless engine, never attached to an Activity.
Future<void> runGenerationService() async {
  WidgetsFlutterBinding.ensureInitialized();
  final args = Map<String, dynamic>.from(
    jsonDecode(await generationChannel.invokeMethod<String>('request') ?? '{}')
        as Map,
  );
  final results = <Map<String, dynamic>>[], samples = <Map<String, dynamic>>[];
  var outcome = 'error',
      message = 'Generation worker stopped unexpectedly',
      sampling = false;
  var currentRun = 0;
  Future<void> sample() async {
    if (sampling) return;
    sampling = true;
    try {
      samples.add({
        ...Map<String, dynamic>.from(
          await generationChannel.invokeMethod('telemetry') as Map,
        ),
        'run': currentRun,
      });
    } catch (e) {
      samples.add({'telemetryError': '$e'});
    } finally {
      sampling = false;
    }
  }

  final receive = ReceivePort();
  Timer? timer;
  try {
    await sample();
    timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(sample()),
    );
    await Isolate.spawn(
      worker,
      {...args, 'operation': 'generate', 'port': receive.sendPort},
      onError: receive.sendPort,
      onExit: receive.sendPort,
    );
    await for (final event in receive) {
      if (event is! Map)
        throw StateError('Worker exited without a terminal result: $event');
      if (event['cancelled'] == true) {
        outcome = 'cancelled';
        message = 'Generation cancelled';
        break;
      }
      if (event['error'] != null) throw StateError(event['error']);
      if (event['done'] == true) {
        outcome = 'completed';
        message = 'Generation finished. Audio and measurements saved.';
        break;
      }
      if (event['runStart'] != null) currentRun = event['runStart'] as int;
      if (event['result'] != null)
        results.add(Map<String, dynamic>.from(event['result'] as Map));
      final progress = <String, dynamic>{};
      for (final key in ['phase', 'run', 'chunk', 'totalChunks', 'status']) {
        if (event.containsKey(key)) progress[key] = event[key];
      }
      if (progress.isNotEmpty)
        await generationChannel.invokeMethod('progress', jsonEncode(progress));
    }
  } catch (e) {
    message = '$e';
  } finally {
    timer?.cancel();
    receive.close();
  }
  await sample();
  final summary = {
    'experimentalBuild': args['experimentalBuild'],
    'completed': outcome == 'completed',
    'outcome': outcome,
    'status': message,
    'modelVariant': args['variant'],
    'modelArchiveSha256': args['modelSha'],
    'frontend': args['frontend'],
    'results': results,
    'samples': samples,
    'sampledPeakPssKb': samples
        .map((s) => (s['pssKb'] as num?) ?? 0)
        .fold<num>(0, (a, b) => a > b ? a : b),
    'sessionProcessCpuMs':
        samples.isNotEmpty &&
            samples.first['cpuMs'] != null &&
            samples.last['cpuMs'] != null
        ? (samples.last['cpuMs'] as num) - (samples.first['cpuMs'] as num)
        : null,
    'note':
        'Service process metrics, excluding the UI process. PSS sampled once/second is not a guaranteed peak. '
        'Battery temperature is not CPU temperature. Times include WAV writes; frontend/model load are separate. '
        'Worker journals are flushed during inference, independent of UI delivery. No automatic restart/resume.',
  };
  try {
    final partial = File('${args['reportPath']}.tmp');
    await partial.writeAsString(
      const JsonEncoder.withIndent('  ').convert(summary),
      flush: true,
    );
    await partial.rename(args['reportPath'] as String);
  } catch (e) {
    outcome = 'error';
    message = '$message; report error: $e';
  }
  await generationChannel.invokeMethod(
    'finished',
    jsonEncode({'outcome': outcome, 'message': message}),
  );
}
