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

enum OfflineModelVariant { int8, fp32 }

/// Separate from the cloud queue: no local request can become a cloud job.
class OfflineNarration extends ChangeNotifier with WidgetsBindingObserver {
  OfflineNarration({
    required this.beforeSelect,
    this.documentsDirectory = getApplicationDocumentsDirectory,
    this.isChapterPlaying,
    this.onStartStreaming,
    this.onAppendStreamingChunk,
    this.onFinishStreaming,
  });
  final Future<Directory> Function() documentsDirectory;
  final Future<void> Function(String, int) beforeSelect;
  final bool Function(String bookId, int index)? isChapterPlaying;
  final Future<void> Function({
    required String title,
    required String author,
    required String bookId,
    required int chapterIndex,
    required int chapterCount,
    required List<({String wavPath, int durationMs})> initialChunks,
  })? onStartStreaming;
  final Future<void> Function({
    required String bookId,
    required int chapterIndex,
    required int chunkIndex,
    required String wavPath,
    required int durationMs,
  })? onAppendStreamingChunk;
  final Future<void> Function({
    required String bookId,
    required int chapterIndex,
    String? finalWavPath,
  })? onFinishStreaming;

  String root = '', output = '', modelManifest = '', int8ModelManifest = '', frontendManifest = '';
  bool ready = false, int8Ready = false, fp32Ready = false, frontendReady = false, installing = false, _polling = false;
  OfflineModelVariant selectedVariant = OfflineModelVariant.int8;
  String status = 'Checking offline files…';
  Map<String, dynamic>? job;
  Map<String, dynamic> recordings = {};
  Timer? _timer;
  Timer? _streamTimer;
  Future<void>? _initializing;
  String? _selectedJob;

  String? _streamingJobId;
  String? _streamingBookId;
  String? _streamingChapterTitle;
  String? _streamingAuthor;
  int _streamingChapterIndex = 0;
  int _streamingChapterCount = 1;
  bool _streamingStartedPlayback = false;
  int _streamingAppendedCount = 0;
  DateTime? _streamingRequestedAt;
  int? timeToFirstAudioMs;

  bool get active => job?['active'] == true;
  bool get busy => installing || active;
  bool get isStreaming => _streamingJobId != null;

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    WidgetsBinding.instance.addObserver(this);
    modelManifest = await rootBundle.loadString('fp32-model-manifest.json');
    int8ModelManifest = await rootBundle.loadString('model-manifest.json');
    frontendManifest = await rootBundle.loadString('english-frontend-manifest.json');
    final paths = Map<String, dynamic>.from(await offlineChannel.invokeMethod('paths') as Map);
    root = paths['files'] as String;
    output = paths['output'] as String;
    final settings = File('$root/offline-settings.json');
    if (await settings.exists()) {
      try {
        final saved = jsonDecode(await settings.readAsString()) as Map;
        if (saved['variant'] == 'fp32') selectedVariant = OfflineModelVariant.fp32;
        if (saved['variant'] == 'int8') selectedVariant = OfflineModelVariant.int8;
      } catch (_) {}
    }
    await checkFiles();
    if (!int8Ready && fp32Ready) {
      selectedVariant = OfflineModelVariant.fp32;
      await checkFiles();
    }
    final promoted = File('$root/offline-promoted-job.txt');
    if (await promoted.exists()) _selectedJob = await promoted.readAsString();
    await poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed || _streamingJobId != null) {
        unawaited(poll());
      }
    });
  }

  void setVariant(OfflineModelVariant variant) {
    if (selectedVariant == variant) return;
    selectedVariant = variant;
    unawaited(checkFiles());
  }

  String _manifestFor(OfflineModelVariant variant) =>
      variant == OfflineModelVariant.int8 && int8ModelManifest.isNotEmpty
          ? int8ModelManifest
          : modelManifest;

  bool isVariantReady(OfflineModelVariant variant) =>
      variant == OfflineModelVariant.int8 ? int8Ready : fp32Ready;

  Future<void> checkFiles() async {
    bool marker(String raw, String key) {
      if (raw.isEmpty) return false;
      final spec = jsonDecode(raw) as Map;
      final file = File('$root/${spec['directory']}/READY');
      return file.existsSync() && file.readAsStringSync() == spec[key];
    }
    frontendReady = marker(frontendManifest, 'id');
    fp32Ready = frontendReady && marker(modelManifest, 'archiveSha256');
    int8Ready = frontendReady && marker(int8ModelManifest, 'archiveSha256');
    ready = selectedVariant == OfflineModelVariant.int8 ? int8Ready : fp32Ready;
    final label = selectedVariant == OfflineModelVariant.int8 ? 'INT8 (Fast)' : 'FP32';
    status = ready
        ? '$label and Misaki ready. Narration works offline.'
        : 'Download offline files once to begin.';
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(poll());
  }

  Future<void> _pumpStreaming() async {
    if (_streamingJobId == null || job == null || job!['jobId'] != _streamingJobId) return;
    final rawChunks = job!['readyChunks'];
    final totalChunks = job!['totalChunks'] as int? ?? 0;
    if (rawChunks is List && rawChunks.isNotEmpty) {
      final chunks = <({int index, String wavPath, int durationMs})>[];
      for (final entry in rawChunks) {
        if (entry is Map) {
          final idx = entry['index'] as int?;
          final wavPath = entry['wavPath'] as String?;
          final durationMs = entry['durationMs'] as int? ?? 0;
          if (idx != null && wavPath != null && File(wavPath).existsSync()) {
            chunks.add((index: idx, wavPath: wavPath, durationMs: durationMs));
          }
        }
      }
      chunks.sort((a, b) => a.index.compareTo(b.index));

      if (!_streamingStartedPlayback && chunks.isNotEmpty && onStartStreaming != null) {
        final enoughBuffer = chunks.length >= 2 ||
            (totalChunks > 0 && chunks.length >= totalChunks) ||
            (!active && job!['outcome'] == 'completed');
        if (enoughBuffer) {
          _streamingStartedPlayback = true;
          _streamingAppendedCount = chunks.length;
          if (_streamingRequestedAt != null) {
            timeToFirstAudioMs = DateTime.now().difference(_streamingRequestedAt!).inMilliseconds;
          }
          await onStartStreaming!(
            title: _streamingChapterTitle ?? 'Chapter',
            author: _streamingAuthor ?? 'Dogreader Offline',
            bookId: _streamingBookId!,
            chapterIndex: _streamingChapterIndex,
            chapterCount: _streamingChapterCount,
            initialChunks: [
              for (final c in chunks) (wavPath: c.wavPath, durationMs: c.durationMs),
            ],
          );
        }
      } else if (_streamingStartedPlayback && onAppendStreamingChunk != null) {
        while (_streamingAppendedCount < chunks.length) {
          final next = chunks[_streamingAppendedCount];
          await onAppendStreamingChunk!(
            bookId: _streamingBookId!,
            chapterIndex: _streamingChapterIndex,
            chunkIndex: next.index,
            wavPath: next.wavPath,
            durationMs: next.durationMs,
          );
          _streamingAppendedCount++;
        }
      }
    }

    if (!active) {
      final outcome = job!['outcome'];
      if (outcome == 'completed' && _streamingStartedPlayback && onFinishStreaming != null) {
        final chapter = job!['chapter'];
        String? finalPath;
        if (chapter is Map) {
          final item = recordings[chapter['key']];
          if (item is Map && item['result'] is Map) {
            finalPath = (item['result'] as Map)['path'] as String?;
          }
        }
        await onFinishStreaming!(
          bookId: _streamingBookId!,
          chapterIndex: _streamingChapterIndex,
          finalWavPath: finalPath,
        );
      }
      _stopStreamingMonitor();
    }
  }

  void _startStreamingMonitor() {
    _streamTimer?.cancel();
    _streamTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_streamingJobId != null) unawaited(poll());
    });
  }

  void _stopStreamingMonitor() {
    _streamTimer?.cancel();
    _streamTimer = null;
    _streamingJobId = null;
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
        await _pumpStreaming();
        // Completion promotion runs only on the UI owner, using the existing
        // serialized metadata writer. The service never races this shared file.
        final chapter = job!['chapter'];
        if (!active && job!['outcome'] == 'completed' && chapter is Map) {
          final item = recordings[chapter['key']];
          final bookId = chapter['bookId'] as String?;
          final chapterIndex = chapter['chapterIndex'] as int?;
          final isPlayingCurrent = bookId != null &&
              chapterIndex != null &&
              (isChapterPlaying?.call(bookId, chapterIndex) ?? false);
          if (item is Map &&
              item['jobId'] == job!['jobId'] &&
              _selectedJob != item['jobId'] &&
              !isPlayingCurrent) {
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

  Future<void> install({OfflineModelVariant? variant}) async {
    if (busy) return;
    final targetVariant = variant ?? selectedVariant;
    final manifest = _manifestFor(targetVariant);
    installing = true; notifyListeners();
    await offlineChannel.invokeMethod('keepAwake', true);
    try {
      await _installOperation({'operation': 'install', 'manifest': manifest, 'root': root});
      if (!frontendReady) {
        await _installOperation({'operation': 'installFrontend', 'frontendManifest': frontendManifest, 'root': root});
      }
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

  Future<void> generate({
    required String bookId,
    required String bookTitle,
    required int index,
    required ReaderChapter chapter,
    required int sid,
    required int threads,
    OfflineModelVariant? variant,
    String author = 'Dogreader Offline',
    int chapterCount = 1,
    bool streamPlayback = false,
  }) async {
    if (busy) throw StateError('One offline chapter can run at a time.');
    final targetVariant = variant ??
        (int8ModelManifest.isEmpty ? OfflineModelVariant.fp32 : selectedVariant);
    final manifestRaw = _manifestFor(targetVariant);
    final isTargetReady = manifestRaw.isNotEmpty &&
        ((targetVariant == OfflineModelVariant.int8 && int8Ready) ||
            (targetVariant == OfflineModelVariant.fp32 && fp32Ready) ||
            ready);
    if (!isTargetReady) {
      throw StateError('Download the ${targetVariant == OfflineModelVariant.int8 ? "INT8" : "FP32"} model and English frontend first.');
    }
    if (await offlineChannel.invokeMethod<bool>('notificationPermission') != true) {
      throw StateError('Allow notifications to generate in the background.');
    }
    final dictionary = narrationDictionary.effective(bookId);
    final spoken = dictionary.transform(chapter);
    final engineText = offlineReaderText(spoken.text);
    if (spoken.text.trim().isEmpty) throw StateError('Chapter is silent under the current dictionary.');
    final model = jsonDecode(manifestRaw) as Map;
    final modelFile = targetVariant == OfflineModelVariant.int8 ? 'model.int8.onnx' : 'model.onnx';
    final variantId = targetVariant == OfflineModelVariant.int8 ? 'int8' : 'fp32';
    final modelVersion = targetVariant == OfflineModelVariant.int8 ? 'kokoro-82m-int8' : 'kokoro-82m-fp32';
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final streamDir = '$root/generation-jobs/$id/chunks';
    final metadata = <String, dynamic>{
      'key': '$bookId:$index', 'bookId': bookId, 'chapterIndex': index,
      'bookTitle': bookTitle, 'chapterTitle': chapter.title,
      'engine': 'kokoro_offline', 'voice': offlineVoices[sid], 'model_version': modelVersion,
      'modelSha256': model['files'][modelFile]['sha256'],
      'frontend': 'misaki-fonnx-1.2.0-api28-v1',
      'settings': {'threads': threads, 'sid': sid, 'speed': 1.0, 'runtime': 'sherpa_onnx 2.0.1 CPU'},
      'sourceSha256': sha256.convert(utf8.encode(chapter.text)).toString(),
      'readerWhitespaceNormalization': 'reader-paragraph-indent-v1',
      'spokenSha256': sha256.convert(utf8.encode(engineText)).toString(),
      'narration_dictionary': dictionary.toJson(), 'narration_offsets': spoken.offsets,
    };

    if (streamPlayback) {
      _streamingJobId = id;
      _streamingBookId = bookId;
      _streamingChapterTitle = chapter.title;
      _streamingAuthor = author;
      _streamingChapterIndex = index;
      _streamingChapterCount = chapterCount;
      _streamingStartedPlayback = false;
      _streamingAppendedCount = 0;
      _streamingRequestedAt = DateTime.now();
      timeToFirstAudioMs = null;
      _startStreamingMonitor();
    } else {
      _stopStreamingMonitor();
    }

    await offlineChannel.invokeMethod('startGeneration', {
      'id': id, 'model': '$root/${model['directory']}', 'root': root, 'output': output,
      'streamDir': streamDir,
      'variant': variantId, 'modelFile': modelFile, 'modelSha': model['archiveSha256'],
      'modelFileSha': model['files'][modelFile]['sha256'],
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
    _stopStreamingMonitor();
    await offlineChannel.invokeMethod('cancelGeneration');
    await poll();
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
    _timer?.cancel();
    _streamTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
