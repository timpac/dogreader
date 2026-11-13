import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart';
import 'worker.dart';
import 'service_runner.dart';

const native = MethodChannel('dogreader.kokoro_probe');
const experimentBuild = String.fromEnvironment('DOGREADER_BUILD', defaultValue: 'local');
@pragma('vm:entry-point')
void generationMain() => unawaited(runGenerationService());

void main() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Experimental Misaki frontend'],
      await rootBundle.loadString('frontend-notices.txt'));
  });
  runApp(const MaterialApp(home: Probe()));
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> with WidgetsBindingObserver {
  final text = TextEditingController();
  String manifest = '', root = '', output = '', model = '', variant = 'fp32';
  String frontend = 'misaki', frontendManifest = '';
  bool frontendReady = false;
  String status = 'Starting…';
  final manifests = <String, String>{};
  final installed = <String, bool>{};
  final recordings = <String, Map<String, dynamic>>{};
  bool ready = false, busy = false;
  int threads = 2, repeats = 1, sid = 3;
  final results = <Map<String, dynamic>>[];
  Timer? servicePoll;
  bool pollingService = false, serviceActive = false;
  String? loadedReport, latestServiceReport;

  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this); initialize();
    servicePoll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(pollGeneration()));
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(pollGeneration());
  }

  Future<void> initialize() async {
    try {
      manifest = await rootBundle.loadString('model-manifest.json');
      manifests['int8'] = manifest;
      manifests['fp32'] = await rootBundle.loadString('fp32-model-manifest.json');
      frontendManifest = await rootBundle.loadString('english-frontend-manifest.json');
      text.text = await rootBundle.loadString('passage.txt');
      final paths = Map<String, dynamic>.from(await native.invokeMethod('paths'));
      root = paths['files'] as String;
      output = paths['output'] as String;
      for (final entry in manifests.entries) {
        final spec = jsonDecode(entry.value);
        final marker = File('$root/${spec['directory']}/READY');
        installed[entry.key] = await marker.exists() && await marker.readAsString() == spec['archiveSha256'];
      }
      final frontendSpec = jsonDecode(frontendManifest);
      final frontendMarker = File('$root/${frontendSpec['directory']}/READY');
      frontendReady = await frontendMarker.exists() && await frontendMarker.readAsString() == frontendSpec['id'];
      selectVariant('fp32');
      if (mounted) setState(() => status = ready ? 'Model ready. Enable airplane mode to test.' : 'Download the model once to begin.');
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    }
  }

  void selectVariant(String value) {
    variant = value;
    manifest = manifests[value]!;
    model = '$root/${jsonDecode(manifest)['directory']}';
    ready = installed[value] == true;
    results.clear();
  }

  Future<void> loadPassage(String asset) async {
    final passage = await rootBundle.loadString(asset);
    if (mounted) setState(() => text.text = passage);
  }

  Future<void> pollGeneration() async {
    if (pollingService || !mounted || (busy && !serviceActive)) return;
    pollingService = true;
    try {
      final raw = await native.invokeMethod<String>('generationStatus');
      if (raw == null) return;
      final value = jsonDecode(raw) as Map<String, dynamic>;
      final active = value['active'] == true;
      if (active || serviceActive) {
        if (mounted) setState(() { serviceActive = active; busy = active; status = value['message'] as String? ?? status; });
      }
      final report = value['reportPath'] as String?;
      if (!active && report != null && report != loadedReport && File(report).existsSync()) {
        final summary = jsonDecode(await File(report).readAsString()) as Map<String, dynamic>;
        results.clear();
        for (final item in summary['results'] as List? ?? []) {
          final result = Map<String, dynamic>.from(item as Map)..['report'] = report;
          results.add(result); recordings[result['modelVariant'] as String] = result;
        }
        loadedReport = report; latestServiceReport = report;
        if (mounted) setState(() { busy = false; serviceActive = false; status = summary['status'] as String? ?? value['message'] as String? ?? 'Generation stopped'; });
      }
    } catch (e) { if (mounted && serviceActive) setState(() => status = 'Generation status: $e'); }
    finally { pollingService = false; }
  }

  Future<void> startGeneration() async {
    setState(() { busy = true; status = 'Starting background generation…'; });
    try {
      if (await native.invokeMethod<bool>('notificationPermission') != true) {
        throw StateError('Allow notifications in Android settings to track and cancel background generation.');
      }
      await native.invokeMethod('stop');
      final spec = jsonDecode(manifest) as Map<String, dynamic>;
      final graph = variant == 'int8' ? 'model.int8.onnx' : 'model.onnx';
      final id = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      await native.invokeMethod('startGeneration', {
        'operation': 'generate', 'manifest': manifest, 'root': root, 'model': model, 'output': output,
        'frontend': frontend, 'frontendManifest': frontendManifest,
        'id': id, 'text': text.text, 'threads': threads, 'repeats': repeats,
        'sid': sid, 'british': sid == 21, 'modelSha': spec['archiveSha256'],
        'variant': variant, 'modelFile': graph, 'modelFileSha': spec['files'][graph]['sha256'],
      });
      results.clear(); serviceActive = true;
      await pollGeneration();
    } catch (e) { if (mounted) setState(() { busy = false; serviceActive = false; status = '$e'; }); }
  }

  Future<void> downloadModel() async {
    setState(() { busy = true; status = 'Connecting to model download…'; });
    final receive = ReceivePort();
    Isolate? isolate;
    try {
      await native.invokeMethod('keepAwake', true);
      isolate = await Isolate.spawn(worker, {'port': receive.sendPort, 'operation': 'install',
        'manifest': manifest, 'root': root}, onError: receive.sendPort, onExit: receive.sendPort);
      await for (final event in receive) {
        if (event is! Map) throw StateError('Installer stopped unexpectedly');
        if (event['error'] != null) throw StateError(event['error']);
        if (event['installed'] == true) { ready = true; installed[variant] = true; }
        if (event['status'] != null && mounted) setState(() => status = event['status'] as String);
        if (event['done'] == true) break;
      }
    } catch (e) { if (mounted) setState(() => status = '$e'); }
    finally {
      receive.close(); isolate?.kill(); await native.invokeMethod('keepAwake', false);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> installEnglish() async {
    setState(() { busy = true; status = 'Connecting to English frontend download…'; });
    final receive = ReceivePort();
    Isolate? isolate;
    try {
      await native.invokeMethod('keepAwake', true);
      isolate = await Isolate.spawn(worker, <String, dynamic>{
        'port': receive.sendPort, 'operation': 'installFrontend',
        'root': root, 'frontendManifest': frontendManifest,
      }, onError: receive.sendPort, onExit: receive.sendPort);
      await for (final message in receive) {
        if (message is! Map) throw StateError('Frontend installer stopped unexpectedly: $message');
        if (message['error'] != null) throw StateError(message['error'] as String);
        if (message['frontendInstalled'] == true) frontendReady = true;
        if (message['status'] != null && mounted) setState(() => status = message['status'] as String);
        if (message['done'] == true) break;
      }
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    } finally {
      receive.close(); isolate?.kill();
      await native.invokeMethod('keepAwake', false);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(String method, [Object? args]) async {
    try { await native.invokeMethod(method, args); }
    catch (error) { if (mounted) setState(() => status = '$error'); }
  }

  @override
  void dispose() { servicePoll?.cancel(); WidgetsBinding.instance.removeObserver(this); text.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kokoro offline probe')),
    body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Separate experimental app. No cloud calls or API keys. Generation continues with a progress notification while you switch apps or lock the screen.'),
        Text('Build $experimentBuild · Sherpa-ONNX 2.0.1 · CPU · 24 kHz WAV'),
        const SizedBox(height: 12),
        DropdownButton<String>(value: variant, isExpanded: true,
          items: const [DropdownMenuItem(value: 'int8', child: Text('INT8 · existing model · 132.4 MB download')),
            DropdownMenuItem(value: 'fp32', child: Text('FP32 · optional comparison · 349.9 MB download'))],
          onChanged: busy || manifests.isEmpty ? null : (value) => setState(() {
            selectVariant(value!);
            status = ready ? '${variant.toUpperCase()} ready. Enable airplane mode to test.' : 'Download ${variant.toUpperCase()} once to begin.';
          })),
        Text(variant == 'int8' ? 'INT8: allow 800 MB free during installation.' :
            'FP32: quality baseline. Allow 1.5 GB free during installation.'),
        const Text('Downloads are optional and separate. Existing INT8 stays installed. '
            'Then enable airplane mode, with Wi-Fi off. Only Download buttons use the network.'),
        FilledButton(onPressed: busy || root.isEmpty ? null : downloadModel,
            child: Text('${ready ? 'Re-download' : 'Download'} ${variant.toUpperCase()} model')),
        DropdownButton<String>(value: frontend, isExpanded: true,
          items: const [
            DropdownMenuItem(value: 'misaki', child: Text('Misaki English · ordinary prose')),
            DropdownMenuItem(value: 'lexicon', child: Text('Build 146 lexicon · reference')),
          ], onChanged: busy ? null : (value) => setState(() => frontend = value!)),
        if (frontend == 'misaki') ...[
          const Text('Download the English frontend once (22.2 MB). Numbers, book punctuation and '
            'unfamiliar words are processed offline. Name pronunciations are best effort. '
            'American voices use US dates; the British voice uses UK dates. No SSML.'),
          OutlinedButton(onPressed: busy || root.isEmpty ? null : installEnglish,
            child: Text(frontendReady ? 'Re-download English frontend' : 'Download English frontend')),
        ] else const Text('Reference frontend: dictionary words and simple punctuation only. Spell out numbers.'),
        TextField(controller: text, enabled: !busy, minLines: 5, maxLines: 9,
            decoration: const InputDecoration(labelText: 'Passage (default: exactly 1,000 words)', border: OutlineInputBorder())),
        Wrap(spacing: 10, children: [
          TextButton(onPressed: busy ? null : () => loadPassage('comparison-passage.txt'), child: const Text('Load short comparison passage')),
          TextButton(onPressed: busy ? null : () => loadPassage('passage.txt'), child: const Text('Load 1,000 words')),
        ]),
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
        FilledButton(onPressed: busy || !ready || (frontend == 'misaki' && !frontendReady) ? null : startGeneration, child: Text('Generate ${variant.toUpperCase()} offline audio')),
        if (busy) const LinearProgressIndicator(),
        if (serviceActive) OutlinedButton(onPressed: () => action('cancelGeneration'), child: const Text('Cancel generation')),
        if (latestServiceReport != null) OutlinedButton(onPressed: busy ? null : () => action('export', latestServiceReport), child: const Text('Save generation diagnostics…')),
        SelectableText(status),
        for (final r in results) Text('Run ${r['run']}: ${(r['generationAndWriteMs'] / 1000).toStringAsFixed(1)} s '
            'for ${(r['audioSeconds'] as num).toStringAsFixed(1)} s audio; '
            'RTF ${(r['rtf'] as num).toStringAsFixed(3)}. ${r['engineWarm'] == true ? 'Warm engine.' : 'Cold engine.'}'),
        for (final key in ['int8', 'fp32']) if (recordings.containsKey(key)) ...[
          Text('${key.toUpperCase()} latest recording · voice ${recordings[key]!['sid']} · ${recordings[key]!['threads']} threads'),
          Text('Peak ${(recordings[key]!['rawPeakAmplitude'] as num).toStringAsFixed(3)} · '
              'clamped samples ${recordings[key]!['clippedSamples']}'),
          Wrap(spacing: 10, children: [
            OutlinedButton(onPressed: busy ? null : () => action('play', recordings[key]!['path']), child: Text('Play ${key.toUpperCase()}')),
            OutlinedButton(onPressed: busy ? null : () => action('export', recordings[key]!['path']), child: Text('Save ${key.toUpperCase()} WAV…')),
            OutlinedButton(onPressed: busy || recordings[key]!['report'] == null ? null : () => action('export', recordings[key]!['report']), child: Text('Save ${key.toUpperCase()} measurements…')),
          ]),
        ],
        OutlinedButton(onPressed: () => action('stop'), child: const Text('Stop playback')),
        if (recordings.containsKey('int8') && recordings.containsKey('fp32'))
          Text(recordings['int8']!['comparisonSettingsSha256'] == recordings['fp32']!['comparisonSettingsSha256'] &&
              recordings['int8']!['chunksSha256'] == recordings['fp32']!['chunksSha256']
              ? 'Comparison controls match: text, voice, speed, threads and chunks.'
              : 'Comparison settings differ. Regenerate both with the same text, voice and thread count.'),
        const SizedBox(height: 12),
        const Text('Licenses: Kokoro weights/voice package and Sherpa-ONNX Apache-2.0; '
            'ONNX Runtime MIT. Sherpa 2.0.1 has no eSpeak-NG. Flutter and Dart BSD; '
            'archive MIT; crypto BSD. Misaki Apache-2.0; FONNX/spaCy MIT; diacritic BSD. See LICENSES.txt in the numbered experimental release '
            'and Flutter notices below. Model notices are retained with the download.'),
        TextButton(onPressed: () => showLicensePage(context: context), child: const Text('Component license notices')),
      ],
    )),
  );
}
