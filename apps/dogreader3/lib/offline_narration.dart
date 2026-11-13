import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'kokoro/worker.dart';
import 'narration_dictionary.dart';
import 'narration_storage.dart';
import 'reader_content.dart';
import 'offline_reader_text.dart';

const offlineChannel = MethodChannel('dogreader3.kokoro');
const offlineVoices = {3: 'af_heart', 16: 'am_michael', 21: 'bf_emma'};

/// Separate from the cloud queue: no local request can become a cloud job.
class OfflineNarration extends ChangeNotifier with WidgetsBindingObserver {
  OfflineNarration({required this.beforeSelect, this.documentsDirectory = getApplicationDocumentsDirectory});
  final Future<Directory> Function() documentsDirectory;
  final Future<void> Function(String, int) beforeSelect;
  String root = '', output = '', modelManifest = '', frontendManifest = '';
  bool ready = false, installing = false, _polling = false;
  String status = 'Checking offline files…';
  Map<String, dynamic>? job;
  Map<String, dynamic> recordings = {};
  Timer? _timer;
  Future<void>? _initializing;
  String? _selectedJob;
  bool get active => job?['active'] == true;
  bool get busy => installing || active;

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    WidgetsBinding.instance.addObserver(this);
    modelManifest = await rootBundle.loadString('fp32-model-manifest.json');
    frontendManifest = await rootBundle.loadString('english-frontend-manifest.json');
    final paths = Map<String, dynamic>.from(await offlineChannel.invokeMethod('paths') as Map);
    root = paths['files'] as String;
    output = paths['output'] as String;
    await checkFiles();
    final promoted = File('$root/offline-promoted-job.txt');
    if (await promoted.exists()) _selectedJob = await promoted.readAsString();
    await poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) unawaited(poll());
    });
  }

  Future<void> checkFiles() async {
    final model = jsonDecode(modelManifest) as Map;
    final frontend = jsonDecode(frontendManifest) as Map;
    bool marker(Map spec, String value) {
      final file = File('$root/${spec['directory']}/READY');
      return file.existsSync() && file.readAsStringSync() == value;
    }
    ready = marker(model, model['archiveSha256'] as String) && marker(frontend, frontend['id'] as String);
    status = ready ? 'FP32 and Misaki ready. Narration works offline.' : 'Download offline files once to begin.';
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(poll());
  }

  Future<void> poll() async {
    if (_polling || root.isEmpty || installing) return;
    _polling = true;
    try {
      final text = await offlineChannel.invokeMethod<String>('generationStatus');
      job = text == null ? null : Map<String, dynamic>.from(jsonDecode(text) as Map);
      final index = File('$root/offline-recordings.json');
      if (await index.exists()) recordings = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
      if (job != null) {
        status = job!['message'] as String? ?? job!['phase'] as String? ?? status;
        // Completion promotion runs only on the UI owner, using the existing
        // serialized metadata writer. The service never races this shared file.
        final chapter = job!['chapter'];
        if (!active && job!['outcome'] == 'completed' && chapter is Map) {
          final item = recordings[chapter['key']];
          if (item is Map && item['jobId'] == job!['jobId'] && _selectedJob != item['jobId']) {
            await select(Map<String, dynamic>.from(item));
            _selectedJob = item['jobId'] as String;
            await File('$root/offline-promoted-job.txt').writeAsString(_selectedJob!, flush: true);
          }
        }
      }
    } catch (e) {
      status = 'Offline status: $e';
    } finally {
      _polling = false;
      notifyListeners();
    }
  }

  Future<void> install() async {
    if (busy) return;
    installing = true; notifyListeners();
    await offlineChannel.invokeMethod('keepAwake', true);
    try {
      await _installOperation({'operation': 'install', 'manifest': modelManifest, 'root': root});
      await _installOperation({'operation': 'installFrontend', 'frontendManifest': frontendManifest, 'root': root});
      await checkFiles();
    } catch (e) {
      status = 'Offline installation: $e';
    } finally {
      await offlineChannel.invokeMethod('keepAwake', false);
      installing = false; notifyListeners();
    }
  }

  Future<void> _installOperation(Map<String, dynamic> args) async {
    final receive = ReceivePort();
    await Isolate.spawn(worker, {...args, 'port': receive.sendPort}, onError: receive.sendPort, onExit: receive.sendPort);
    try {
      await for (final event in receive) {
        if (event is! Map) throw StateError('Installer stopped unexpectedly: $event');
        if (event['error'] != null) throw StateError(event['error'].toString());
        if (event['done'] == true) return;
        if (event['status'] is String) { status = event['status'] as String; notifyListeners(); }
      }
    } finally { receive.close(); }
  }

  Future<void> generate({required String bookId, required String bookTitle,
      required int index, required ReaderChapter chapter, required int sid, required int threads}) async {
    if (busy) throw StateError('One offline chapter can run at a time.');
    if (!ready) throw StateError('Download the FP32 model and English frontend first.');
    if (await offlineChannel.invokeMethod<bool>('notificationPermission') != true) {
      throw StateError('Allow notifications to generate in the background.');
    }
    final dictionary = narrationDictionary.effective(bookId);
    final spoken = dictionary.transform(chapter);
    final engineText = offlineReaderText(spoken.text);
    if (spoken.text.trim().isEmpty) throw StateError('Chapter is silent under the current dictionary.');
    final model = jsonDecode(modelManifest) as Map;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final metadata = <String, dynamic>{
      'key': '$bookId:$index', 'bookId': bookId, 'chapterIndex': index,
      'bookTitle': bookTitle, 'chapterTitle': chapter.title,
      'engine': 'kokoro_offline', 'voice': offlineVoices[sid], 'model_version': 'kokoro-82m-fp32',
      'modelSha256': model['files']['model.onnx']['sha256'],
      'frontend': 'misaki-fonnx-1.2.0-api28-v1',
      'settings': {'threads': threads, 'sid': sid, 'speed': 1.0, 'runtime': 'sherpa_onnx 2.0.1 CPU'},
      'sourceSha256': sha256.convert(utf8.encode(chapter.text)).toString(),
      'readerWhitespaceNormalization': 'reader-paragraph-indent-v1',
      'spokenSha256': sha256.convert(utf8.encode(engineText)).toString(),
      'narration_dictionary': dictionary.toJson(), 'narration_offsets': spoken.offsets,
    };
    await offlineChannel.invokeMethod('startGeneration', {
      'id': id, 'model': '$root/${model['directory']}', 'root': root, 'output': output,
      'variant': 'fp32', 'modelFile': 'model.onnx', 'modelSha': model['archiveSha256'],
      'modelFileSha': model['files']['model.onnx']['sha256'],
      'frontend': 'misaki', 'frontendManifest': frontendManifest,
      'text': engineText, 'sid': sid, 'british': sid == 21, 'threads': threads,
      'repeats': 1, 'chapter': metadata,
    });
    await poll();
  }

  Future<void> resume() async {
    if (busy || job == null || job!['outcome'] == 'completed') return;
    final id = job!['jobId'] as String;
    final request = jsonDecode(await File('$root/generation-jobs/$id/request.json').readAsString()) as Map<String, dynamic>;
    if (await offlineChannel.invokeMethod<bool>('notificationPermission') != true) throw StateError('Allow notifications first.');
    await offlineChannel.invokeMethod('startGeneration', request);
    await poll();
  }

  Future<void> cancel() async {
    await offlineChannel.invokeMethod('cancelGeneration'); await poll();
  }

  Future<void> select(Map<String, dynamic> item) async {
    final result = item['result'] as Map;
    final wav = File(result['path'] as String);
    if (!await wav.exists() || await wav.length() != result['wavBytes']) throw StateError('Completed WAV is missing or incomplete.');
    final book = item['bookId'] as String, index = item['chapterIndex'] as int;
    await beforeSelect(book, index);
    final docs = await documentsDirectory();
    await updateNarrationJson(File('${docs.path}/narration_state.json'), (data) {
      final previous = data[item['key']];
      final same = previous is Map && previous['offlineJobId'] == item['jobId'];
      data[item['key'] as String] = {
        'path': wav.path, 'positionMs': same ? previous['positionMs'] ?? 0 : 0,
        'offlineJobId': item['jobId'],
        for (final key in ['engine', 'voice', 'model_version', 'modelSha256', 'frontend', 'settings',
          'sourceSha256', 'spokenSha256', 'readerWhitespaceNormalization', 'narration_dictionary', 'narration_offsets']) key: item[key],
      };
    });
  }

  Future<void> export(String path) async { await offlineChannel.invokeMethod('export', path); }

  @override
  void dispose() {
    _timer?.cancel(); WidgetsBinding.instance.removeObserver(this); super.dispose();
  }
}
