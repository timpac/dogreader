import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'worker.dart';

const native = MethodChannel('dogreader.kokoro_probe');
const experimentBuild = String.fromEnvironment('DOGREADER_BUILD', defaultValue: 'local');
void main() => runApp(const MaterialApp(home: Probe()));

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  final text = TextEditingController();
  String manifest = '', root = '', output = '', model = '';
  String status = 'Starting…', lastWav = '', lastReport = '';
  bool ready = false, busy = false;
  int threads = 2, repeats = 1, sid = 3;
  final results = <Map<String, dynamic>>[];
  final samples = <Map<String, dynamic>>[];
  Map<String, dynamic>? firstSample;
  bool sampling = false;
  int currentRun = 0;

  @override
  void initState() { super.initState(); initialize(); }

  Future<void> initialize() async {
    try {
      manifest = await rootBundle.loadString('model-manifest.json');
      text.text = await rootBundle.loadString('passage.txt');
      final paths = Map<String, dynamic>.from(await native.invokeMethod('paths'));
      root = paths['files'] as String;
      output = paths['output'] as String;
      final spec = jsonDecode(manifest);
      model = '$root/${spec['directory']}';
      final marker = File('$model/READY');
      ready = await marker.exists() && await marker.readAsString() == spec['archiveSha256'];
      if (mounted) setState(() => status = ready ? 'Model ready. Enable airplane mode to test.' : 'Download the model once to begin.');
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    }
  }

  Future<void> sample() async {
    if (sampling) return;
    sampling = true;
    try {
      final value = Map<String, dynamic>.from(await native.invokeMethod('telemetry'));
      value['run'] = currentRun;
      samples.add(value);
    } finally { sampling = false; }
  }

  Future<void> operate(bool installing) async {
    setState(() { busy = true; status = installing ? 'Connecting to model download…' : 'Checking text and loading model…'; });
    final receive = ReceivePort();
    Isolate? isolate;
    Timer? timer;
    var succeeded = false;
    final id = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    try {
      await native.invokeMethod('stop');
      await native.invokeMethod('keepAwake', true);
      if (!installing) {
        results.clear(); samples.clear(); currentRun = 0;
        await sample(); firstSample = samples.first;
        timer = Timer.periodic(const Duration(seconds: 1), (_) {
          unawaited(sample().catchError((Object error) {
            // Telemetry failure is recorded, not mistaken for a successful measurement.
            samples.add({'telemetryError': '$error'});
          }));
        });
      }
      isolate = await Isolate.spawn(worker, <String, dynamic>{
        'port': receive.sendPort, 'operation': installing ? 'install' : 'generate',
        'manifest': manifest, 'root': root, 'model': model, 'output': output,
        'id': id, 'text': text.text, 'threads': threads, 'repeats': repeats,
        'sid': sid, 'british': sid == 21, 'modelSha': jsonDecode(manifest)['archiveSha256'],
      }, onError: receive.sendPort, onExit: receive.sendPort);
      await for (final message in receive) {
        if (message is! Map) throw StateError('Worker stopped unexpectedly: $message');
        if (message['error'] != null) throw StateError(message['error'] as String);
        if (message['done'] == true) { succeeded = true; break; }
        if (message['installed'] == true) ready = true;
        if (message['runStart'] != null) currentRun = message['runStart'] as int;
        if (message['result'] != null) {
          final result = Map<String, dynamic>.from(message['result'] as Map);
          results.add(result); lastWav = result['path'] as String;
        }
        if (mounted) setState(() => status = message['status'] as String? ?? status);
      }
      if (mounted) setState(() => status = installing ? 'Model verified. Enable airplane mode before generating.' : 'Generation finished. Audio and measurements saved.');
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    } finally {
      timer?.cancel();
      receive.close(); isolate?.kill();
      try {
        if (!installing) {
          await sample();
          final summary = <String, dynamic>{
            'experimentalBuild': experimentBuild, 'completed': succeeded,
            'status': status, 'results': results, 'samples': samples,
            'sampledPeakPssKb': samples.map((s) => (s['pssKb'] as num?) ?? 0).fold<num>(0, (a, b) => a > b ? a : b),
            'sessionProcessCpuMs': (samples.last['cpuMs'] as num?) != null && firstSample?['cpuMs'] != null
                ? (samples.last['cpuMs'] as num) - (firstSample!['cpuMs'] as num) : null,
            'note': 'PSS sampled once/second, not a guaranteed peak. Battery temperature is not CPU temperature. '
                'Battery deltas include screen, OS and sampling overhead. Generation timing includes WAV writes. '
                'Run one is engine-cold; later runs reuse the engine. Each session loads a new engine.',
          };
          lastReport = '$output/benchmark-$id.json';
          await File(lastReport).writeAsString(const JsonEncoder.withIndent('  ').convert(summary), flush: true);
        }
      } catch (error) { status = '$status\nReport error: $error'; }
      await native.invokeMethod('keepAwake', false);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(String method, [Object? args]) async {
    try { await native.invokeMethod(method, args); }
    catch (error) { if (mounted) setState(() => status = '$error'); }
  }

  @override
  void dispose() { text.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kokoro offline probe')),
    body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Separate experimental app. No cloud calls or API keys. Keep this screen open during generation.'),
        Text('Build $experimentBuild · Sherpa-ONNX 2.0.1 · CPU · 24 kHz WAV'),
        const SizedBox(height: 12),
        const Text('One-time model download: 132.4 MB. Keep at least 800 MB free while installing. '
            'Then enable airplane mode, with Wi-Fi off. Only Download model uses the network.'),
        FilledButton(onPressed: busy || root.isEmpty ? null : () => operate(true),
            child: Text(ready ? 'Re-download verified model' : 'Download model')),
        const Text('English lexicon experiment: unknown words are rejected before synthesis. '
            'Spell out numbers; no SSML. This is not yet a complete audiobook frontend.'),
        TextField(controller: text, enabled: !busy, minLines: 5, maxLines: 9,
            decoration: const InputDecoration(labelText: 'Passage (default: exactly 1,000 words)', border: OutlineInputBorder())),
        Row(children: [
          const Text('Threads: '), DropdownButton<int>(value: threads,
              items: [1, 2, 4].map((n) => DropdownMenuItem(value: n, child: Text('$n'))).toList(),
              onChanged: busy ? null : (n) => setState(() => threads = n!)),
          const SizedBox(width: 20), const Text('Runs: '),
          DropdownButton<int>(value: repeats,
              items: [1, 3].map((n) => DropdownMenuItem(value: n, child: Text('$n'))).toList(),
              onChanged: busy ? null : (n) => setState(() => repeats = n!)),
        ]),
        DropdownButton<int>(value: sid, isExpanded: true,
            items: const [DropdownMenuItem(value: 3, child: Text('af_heart · American')),
              DropdownMenuItem(value: 16, child: Text('am_michael · American')),
              DropdownMenuItem(value: 21, child: Text('bf_emma · British'))],
            onChanged: busy ? null : (n) => setState(() => sid = n!)),
        FilledButton(onPressed: busy || !ready ? null : () => operate(false), child: const Text('Generate offline audio')),
        if (busy) const LinearProgressIndicator(),
        SelectableText(status),
        for (final r in results) Text('Run ${r['run']}: ${(r['generationAndWriteMs'] / 1000).toStringAsFixed(1)} s '
            'for ${(r['audioSeconds'] as num).toStringAsFixed(1)} s audio; '
            'RTF ${(r['rtf'] as num).toStringAsFixed(3)}. ${r['engineWarm'] == true ? 'Warm engine.' : 'Cold engine.'}'),
        Wrap(spacing: 10, children: [
          OutlinedButton(onPressed: busy || lastWav.isEmpty ? null : () => action('play', lastWav), child: const Text('Play latest WAV')),
          OutlinedButton(onPressed: () => action('stop'), child: const Text('Stop playback')),
          OutlinedButton(onPressed: busy || lastWav.isEmpty ? null : () => action('export', lastWav), child: const Text('Save WAV…')),
          OutlinedButton(onPressed: busy || lastReport.isEmpty ? null : () => action('export', lastReport), child: const Text('Save measurements…')),
        ]),
        const SizedBox(height: 12),
        const Text('Licenses: Kokoro weights/voice package and Sherpa-ONNX Apache-2.0; '
            'ONNX Runtime MIT. Sherpa 2.0.1 has no eSpeak-NG. Flutter and Dart BSD; '
            'archive MIT; crypto BSD. See LICENSES.txt in the numbered experimental release '
            'and Flutter notices below. Model notices are retained with the download.'),
        TextButton(onPressed: () => showLicensePage(context: context), child: const Text('Flutter dependency notices')),
      ],
    )),
  );
}
