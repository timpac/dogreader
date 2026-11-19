import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'narration_dictionary.dart';
import 'narration_files.dart';
import 'narration_options.dart';
import 'narration_storage.dart';
import 'reader_content.dart';

class DeliveryHttpError implements Exception {
  DeliveryHttpError(this.status);
  final int status;
  @override
  String toString() => 'HTTP $status';
}

String narrationDeliveryLabel(Map<String, dynamic>? job) {
  if (job == null) return 'Not generated';
  final state = job['delivery'];
  if (state == 'downloading') return 'Downloading…';
  if (state == 'downloaded') return 'Downloaded — ready to listen';
  if (state == 'server_ready' ||
      (job['status'] == 'ready' && state != 'failed')) {
    return 'Waiting to download';
  }
  if (state == 'failed' || job['status'] == 'error') {
    final generation =
        job['failureStage'] == 'generation' || job['status'] == 'error';
    final message = generation ? job['error'] : job['deliveryError'];
    return 'Failed — ${message ?? 'Narration unavailable.'}'
        '${generation ? '' : ' Retrying automatically.'}';
  }
  final completed = job['progress'], total = job['chunks'];
  final progress =
      completed is int &&
          total is int &&
          total > 0 &&
          completed >= 0 &&
          completed <= total
      ? ' • $completed/$total chunks complete'
      : '';
  return switch (job['status']) {
    'generating' => 'Generating…$progress',
    'queued' => 'Queued in cloud$progress',
    'waiting' => 'Waiting to submit',
    _ => 'Checking narration…',
  };
}

bool canRetryNarrationDownload(Map<String, dynamic>? job) =>
    job?['id'] is String &&
    (job!['id'] as String).isNotEmpty &&
    job['status'] == 'ready';

/// App-owned submission and delivery of narration jobs.
/// The legacy queue/status fields remain readable; delivery fields are additive.
class NarrationDelivery extends ChangeNotifier {
  NarrationDelivery({
    required this.documentsDirectory,
    required this.beforeReplace,
    DateTime Function()? clock,
    this.responseTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 45),
    this.diagnosticSink,
    this.chapterResolver,
  }) : clock = clock ?? DateTime.now;

  final Future<Directory> Function() documentsDirectory;
  final Future<void> Function(String, int) beforeReplace;
  final DateTime Function() clock;
  final Duration responseTimeout, idleTimeout;
  final void Function(Map<String, Object?>)? diagnosticSink;
  FutureOr<ReaderChapter?> Function(String book, int index)? chapterResolver;
  final Map<String, Map<int, Map<String, dynamic>>> books = {};
  final Map<String, List<ReaderChapter>> _chapters = {};
  final Map<String, Future<void>> _downloads = {};
  final Map<String, Future<void>> _submissions = {};
  final List<String> diagnostics = [];
  String host = '', token = '';
  Future<void>? _loading, _checking;
  Timer? _timer;
  bool _loaded = false, _disposed = false, _reconcileRequested = false;
  static const maxAttempts = 6;

  void registerBookChapters(String book, List<ReaderChapter> chapters) {
    _chapters[book] = chapters;
  }

  Future<File> get queueFile async =>
      File('${(await documentsDirectory()).path}/dogreader_queue.json');

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    if (_loaded) return;
    final file = await queueFile;
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString()) as Map;
      host = data['host'] as String? ?? '';
      token = data['token'] as String? ?? '';
      for (final book in ((data['books'] as Map?) ?? {}).entries) {
        final jobs = <int, Map<String, dynamic>>{};
        for (final entry in (book.value as Map).entries) {
          final index = int.tryParse(entry.key.toString());
          if (index != null && entry.value is Map) {
            jobs[index] = Map<String, dynamic>.from(entry.value as Map);
          }
        }
        for (final job in jobs.values) {
          _normalizeInterruptedState(job);
        }
        books[book.key.toString()] = jobs;
      }
    }
    _loaded = true;
  }

  void attachBook(String book, Map<int, Map<String, dynamic>> jobs) {
    for (final index in jobs.keys.toList()) {
      final active = books[book]?[index];
      if ((deliveryInFlight(book, index) || submissionInFlight(book, index)) &&
          active != null) {
        // Opening the queue must not replace a live transfer or submission
        // with a stale disk snapshot.
        jobs[index] = active;
      } else {
        _normalizeInterruptedState(jobs[index]!);
      }
    }
    books[book] = jobs;
  }

  Future<void> save() async {
    final file = await queueFile;
    // Snapshot inside the serialized write, after earlier saves have completed.
    await updateNarrationJson(file, (data) {
      data['host'] = host;
      data['token'] = token;
      final stored = Map<String, dynamic>.from((data['books'] as Map?) ?? {});
      for (final book in books.entries) {
        stored[book.key] = book.value.map((k, v) => MapEntry('$k', v));
      }
      data['books'] = stored;
    });
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => reconcile());
    unawaited(reconcile());
  }

  void setActive(bool active) {
    _timer?.cancel();
    _timer = null;
    if (active) start();
  }

  void _normalizeInterruptedState(Map<String, dynamic> job) {
    if (job['status'] == 'waiting' &&
        job['id'] is String &&
        (job['id'] as String).isNotEmpty) {
      job['status'] = 'queued';
    }
    if (job['status'] == 'waiting' && job['failureStage'] == 'submission') {
      job.remove('deliveryError');
      job.remove('failureStage');
      job.remove('deliveryNextAttempt');
      job['deliveryAttempts'] = 0;
      if (job['delivery'] == 'failed') job.remove('delivery');
    }
    final pending = job['status'] == 'queued' || job['status'] == 'generating';
    // Build 143 recorded a normal not-ready probe as a failed download.
    if (pending && job['deliveryError'] == 'Download HTTP 404') {
      job.remove('deliveryError');
      job.remove('failureStage');
      job.remove('deliveryNextAttempt');
      job['deliveryAttempts'] = 0;
      job['delivery'] = 'pending';
    }
    if (job['delivery'] == 'downloading') {
      job['delivery'] = job['status'] == 'ready' ? 'server_ready' : 'pending';
    }
  }

  static const _statuses = {
    'waiting',
    'queued',
    'generating',
    'ready',
    'error',
  };
  static const _deliveries = {
    'pending',
    'server_ready',
    'downloading',
    'downloaded',
    'failed',
  };

  void _log(
    String event,
    String book,
    int index,
    String id, {
    Object? error,
    bool automatic = true,
    int? attempt,
    int? http,
    String? fromStatus,
    String? fromDelivery,
  }) {
    final job = books[book]?[index];
    final fields = <String, Object?>{
      'deliveryEvent': event,
      'jobId': RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ? id : 'unknown',
      'chapter': index,
      'retryMode': automatic ? 'automatic' : 'manual',
      'attempt': attempt ?? (job?['deliveryAttempts'] as int? ?? 0),
      'serverStatus': _statuses.contains(job?['status'])
          ? job!['status']
          : 'unknown',
      'deliveryState': _deliveries.contains(job?['delivery'])
          ? job!['delivery']
          : 'unknown',
      if (fromStatus != null)
        'fromServerStatus': _statuses.contains(fromStatus)
            ? fromStatus
            : 'unknown',
      if (fromDelivery != null)
        'fromDeliveryState': _deliveries.contains(fromDelivery)
            ? fromDelivery
            : 'unknown',
      if (http != null || error is DeliveryHttpError)
        'httpStatus': http ?? (error as DeliveryHttpError).status,
      if (error != null) 'errorKind': error.runtimeType.toString(),
      if (job?['progress'] is int) 'completedChunks': job!['progress'],
      if (job?['chunks'] is int) 'totalChunks': job!['chunks'],
    };
    // Only opaque job IDs and safe scalar state/error codes; no book IDs,
    // credentials, URLs, chapter text, paths or raw exception messages.
    diagnostics.add(
      '${clock().toUtc().toIso8601String()} ${jsonEncode(fields)}',
    );
    if (diagnostics.length > 80) diagnostics.removeAt(0);
    debugPrint('narration_delivery ${diagnostics.last}');
    try {
      diagnosticSink?.call(fields);
    } catch (_) {
      /* Diagnostics cannot stop delivery. */
    }
  }

  void _transition(
    Map<String, dynamic> job,
    String book,
    int index, {
    String? status,
    String? delivery,
    bool automatic = true,
  }) {
    final oldStatus = job['status'] as String? ?? 'unknown';
    final oldDelivery = job['delivery'] as String? ?? 'unknown';
    if (status != null) job['status'] = status;
    if (delivery != null) job['delivery'] = delivery;
    if (oldStatus != (job['status'] ?? 'unknown') ||
        oldDelivery != (job['delivery'] ?? 'unknown')) {
      _log(
        'state_transition',
        book,
        index,
        job['id'] as String? ?? '',
        automatic: automatic,
        fromStatus: oldStatus,
        fromDelivery: oldDelivery,
      );
    }
  }

  void _clearFailure(Map<String, dynamic> job) {
    job['deliveryAttempts'] = 0;
    job.remove('deliveryError');
    job.remove('failureStage');
    job.remove('deliveryNextAttempt');
  }

  Future<void> _failure(
    Map<String, dynamic> job,
    String book,
    int index,
    Object error, {
    required bool automatic,
    String stage = 'download',
  }) async {
    final previous = (job['deliveryAttempts'] as num?)?.toInt() ?? 0;
    final attempt = previous >= maxAttempts ? maxAttempts : previous + 1;
    job['deliveryAttempts'] = attempt;
    job['deliveryNextAttempt'] = clock()
        .add(
          Duration(
            seconds: attempt >= maxAttempts ? 900 : 15 * (1 << (attempt - 1)),
          ),
        )
        .millisecondsSinceEpoch;
    job['failureStage'] = stage;
    final action = switch (stage) {
      'status' => 'Status check',
      'submission' => 'Submission',
      _ => 'Download',
    };
    job['deliveryError'] = error is DeliveryHttpError
        ? '$action HTTP ${error.status}'
        : error is TimeoutException
        ? '$action timed out.'
        : '$action interrupted.';
    if (stage != 'submission') {
      _transition(job, book, index, delivery: 'failed', automatic: automatic);
    }
    _log(
      '${stage}_failed',
      book,
      index,
      job['id'] as String? ?? '',
      error: error,
      automatic: automatic,
      attempt: attempt,
    );
    await save();
  }

  Future<void> _notReady(
    Map<String, dynamic> job,
    String book,
    int index, {
    required bool automatic,
  }) async {
    _clearFailure(job);
    final failed = job['status'] == 'error';
    if (failed) job['failureStage'] = 'generation';
    job['deliveryNextAttempt'] = clock()
        .add(Duration(seconds: failed ? 900 : 12))
        .millisecondsSinceEpoch;
    _transition(
      job,
      book,
      index,
      delivery: failed ? 'failed' : 'pending',
      automatic: automatic,
    );
    await save();
  }

  static Map<String, dynamic> prepareSubmissionPayload(
    Map<String, dynamic> job, {
    ReaderChapter? chapter,
  }) {
    var title = job['title'];
    var text = job['text'];
    final sourceChapter =
        chapter ??
        (title is String && text is String && job['narration_offsets'] == null
            ? ReaderChapter(title, text, const [])
            : null);
    if ((title is! String ||
            text is! String ||
            job['narration_offsets'] == null) &&
        sourceChapter != null) {
      final snapshot = job['narration_dictionary'];
      final transformed = snapshot is Map
          ? NarrationDictionaryConfig.fromJson(
              Map<String, dynamic>.from(snapshot),
            ).transform(sourceChapter)
          : const NarrationDictionaryConfig(
              ignoreSeparators: false,
            ).transform(sourceChapter);
      if (transformed.text.trim().isEmpty) {
        throw StateError(
          'This chapter is silent under the current dictionary. Disable its silence rules to generate audio.',
        );
      }
      title = sourceChapter.title;
      text = transformed.text;
      job['title'] = title;
      job['text'] = text;
      job['narration_offsets'] = transformed.offsets;
    }
    if (title is! String || text is! String) {
      throw const FormatException('Chapter text unavailable for submission');
    }
    if (text.trim().isEmpty) {
      throw StateError(
        'This chapter is silent under the current dictionary. Disable its silence rules to generate audio.',
      );
    }
    return {
      'title': title,
      'text': text,
      'engine': job['engine'] ?? 'google',
      'voice': job['voice'] ?? 'en-US-Chirp3-HD-Achernar',
      for (final key in ['model_version', 'settings'])
        if (job.containsKey(key)) key: job[key],
    };
  }

  Future<ReaderChapter?> _resolveChapter(String book, int index) async {
    final cached = _chapters[book];
    if (cached != null && index >= 0 && index < cached.length) {
      return cached[index];
    }
    final resolver = chapterResolver;
    if (resolver != null) {
      return await resolver(book, index);
    }
    return null;
  }

  Future<void> submitWaitingJobs({
    String? bookId,
    bool automatic = false,
  }) async {
    await load();
    if (host.isEmpty || token.isEmpty || _disposed) return;
    final targetBooks = bookId != null
        ? [
            if (books.containsKey(bookId))
              MapEntry(bookId, books[bookId]!),
          ]
        : books.entries.toList();
    for (final book in targetBooks) {
      final indices = book.value.keys.toList()..sort();
      for (final index in indices) {
        if (_disposed) return;
        final job = book.value[index];
        if (job == null) continue;
        final id = job['id'];
        if (id is String && id.isNotEmpty) {
          if (job['status'] == 'waiting') {
            _transition(job, book.key, index, status: 'queued', automatic: automatic);
            await save();
          }
          continue;
        }
        if (job['status'] != 'waiting') continue;
        if (automatic) {
          final next = (job['deliveryNextAttempt'] as num?)?.toInt() ?? 0;
          if (clock().millisecondsSinceEpoch < next) continue;
        }
        await _submitSingle(book.key, index, automatic: automatic);
      }
    }
  }

  Future<void> _submitSingle(
    String book,
    int index, {
    required bool automatic,
  }) {
    final key = '$book:$index';
    final existing = _submissions[key];
    if (existing != null) {
      _log(
        'submission_joined',
        book,
        index,
        books[book]?[index]?['id'] as String? ?? '',
        automatic: automatic,
      );
      return existing;
    }
    return _submissions[key] = _doSubmit(book, index, automatic: automatic)
        .whenComplete(() {
          _submissions.remove(key);
        });
  }

  Future<void> _doSubmit(
    String book,
    int index, {
    required bool automatic,
  }) async {
    final job = books[book]?[index];
    if (job == null || job['status'] != 'waiting') return;
    final existingId = job['id'];
    if (existingId is String && existingId.isNotEmpty) {
      _transition(job, book, index, status: 'queued', automatic: automatic);
      await save();
      return;
    }
    Map<String, dynamic> payload;
    try {
      final hadText = job['title'] is String && job['text'] is String;
      final chapter = hadText ? null : await _resolveChapter(book, index);
      payload = prepareSubmissionPayload(job, chapter: chapter);
      if (!hadText) await save();
    } on StateError catch (e) {
      if (!identical(books[book]?[index], job)) return;
      _clearFailure(job);
      job['error'] = e.message;
      job['failureStage'] = 'generation';
      _transition(job, book, index, status: 'error', automatic: automatic);
      await save();
      return;
    } catch (_) {
      // Chapter text not yet loaded; leave in waiting to retry on next cycle.
      return;
    }

    if (!identical(books[book]?[index], job) ||
        job['status'] != 'waiting' ||
        (job['id'] is String && (job['id'] as String).isNotEmpty)) {
      return;
    }

    try {
      if (!automatic) job['deliveryAttempts'] = 0;
      _log(
        'submission_requested',
        book,
        index,
        '',
        automatic: automatic,
        attempt: (job['deliveryAttempts'] as int? ?? 0) + 1,
      );
      final response = await _postJob(payload);
      if (!identical(books[book]?[index], job)) return;
      final id = response['id'];
      if (id is! String || id.isEmpty) {
        throw const FormatException('Missing job ID in submission response');
      }
      final status = _statuses.contains(response['status'])
          ? response['status'] as String
          : 'queued';
      job.addAll(recordingMetadata(response));
      job['id'] = id;
      job.remove('text');
      job.remove('title');
      job.remove('submissionUncertain');
      _clearFailure(job);
      _transition(
        job,
        book,
        index,
        status: status,
        delivery: status == 'ready' ? 'server_ready' : 'pending',
        automatic: automatic,
      );
      _log('submission_accepted', book, index, id, automatic: automatic, http: 200);
      await save();
    } catch (error) {
      if (!identical(books[book]?[index], job)) return;
      if (error is TimeoutException || error is SocketException) {
        // Uncertain outcome: the server may have accepted the request during a
        // cold start. Keep waiting status and retry idempotently after a short delay.
        job['submissionUncertain'] = true;
        final previous = (job['deliveryAttempts'] as num?)?.toInt() ?? 0;
        final attempt = previous >= maxAttempts ? maxAttempts : previous + 1;
        job['deliveryAttempts'] = attempt;
        job['deliveryNextAttempt'] = clock()
            .add(const Duration(seconds: 5))
            .millisecondsSinceEpoch;
        _log(
          'submission_uncertain',
          book,
          index,
          '',
          error: error,
          automatic: automatic,
          attempt: attempt,
        );
        await save();
        return;
      }
      await _failure(
        job,
        book,
        index,
        error,
        automatic: automatic,
        stage: 'submission',
      );
    }
  }

  Future<Map<String, dynamic>> _postJob(Map<String, dynamic> payload) async {
    final client = HttpClient()..connectionTimeout = responseTimeout;
    try {
      final req = await client
          .postUrl(_endpoint('/dogreader/jobs'))
          .timeout(responseTimeout);
      req.followRedirects = false;
      req.headers.set('X-Dogreader-Token', token);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final response = await req.close().timeout(responseTimeout);
      final body = await utf8.decoder.bind(response.timeout(idleTimeout)).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DeliveryHttpError(response.statusCode);
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> reconcile() {
    if (_checking != null) {
      _reconcileRequested = true;
      return _checking!;
    }
    return _checking = _runReconcileLoop().whenComplete(() => _checking = null);
  }

  Future<void> _runReconcileLoop() async {
    do {
      _reconcileRequested = false;
      try {
        await _reconcile();
      } catch (e) {
        _log('reconcile_failed', '', -1, '', error: e);
      }
    } while (_reconcileRequested && !_disposed);
  }

  Future<void> _reconcile() async {
    await load();
    if (host.isEmpty || token.isEmpty || _disposed) return;
    await submitWaitingJobs(automatic: true);
    for (final book in books.entries.toList()) {
      final indices = book.value.keys.toList()..sort();
      for (final index in indices) {
        if (_disposed) return;
        final job = book.value[index];
        if (job == null) continue;
        final id = job['id'];
        if (id is! String || id.isEmpty || job['status'] == 'waiting') continue;
        final key = '${book.key}:$index';
        if (_downloads.containsKey(key) || _submissions.containsKey(key)) {
          continue;
        }
        final target = await audioFile(book.key, index);
        await recoverNarrationFile(target);
        job['localAvailable'] =
            await target.exists() && await target.length() >= 1000;
        if (job['previousRecording'] == null &&
            job['localAvailable'] == true &&
            job['status'] == 'ready' &&
            (job['delivery'] == null || job['delivery'] == 'downloaded')) {
          if (job['delivery'] != 'downloaded') {
            _transition(job, book.key, index, delivery: 'downloaded');
            await save();
          }
          continue;
        }
        final next = (job['deliveryNextAttempt'] as num?)?.toInt() ?? 0;
        if (clock().millisecondsSinceEpoch < next) continue;
        if (job['status'] != 'ready') {
          try {
            _log(
              'status_requested',
              book.key,
              index,
              id,
              attempt: (job['deliveryAttempts'] as int? ?? 0) + 1,
            );
            final result = await _status(id);
            // A manual fetch may have completed while the status request waited.
            if (!identical(books[book.key]?[index], job) ||
                _downloads.containsKey(key) ||
                job['status'] == 'ready') {
              continue;
            }
            final status = result['status'];
            if (!_statuses.contains(status)) {
              throw const FormatException('Invalid job status');
            }
            job.addAll(recordingMetadata(result));
            final total = result['chunks'], completed = result['progress'];
            if (total is int && total > 0) job['chunks'] = total;
            if (completed is int &&
                completed >= 0 &&
                (job['chunks'] is! int ||
                    completed <= (job['chunks'] as int))) {
              job['progress'] = completed;
            }
            job['error'] = result['error'];
            _transition(job, book.key, index, status: status as String);
            _log('status_received', book.key, index, id, http: 200);
            if (status != 'ready') {
              await _notReady(job, book.key, index, automatic: true);
              continue;
            }
            _clearFailure(job);
            _transition(job, book.key, index, delivery: 'server_ready');
            await save();
          } catch (error) {
            if (error is! DeliveryHttpError || error.status != 404) {
              await _failure(
                job,
                book.key,
                index,
                error,
                automatic: true,
                stage: 'status',
              );
              continue;
            }
            // Retain a quiet GET-only fallback for legacy/missing status records.
            _log('status_missing', book.key, index, id, error: error);
          }
        }
        try {
          // Known completed recordings never call the dispatching status endpoint.
          await retryDownload(book.key, index, automatic: true);
        } catch (_) {
          /* Download already persisted its bounded retry state. */
        }
      }
    }
  }

  Future<Map<String, dynamic>> _status(String id) async {
    final client = HttpClient()..connectionTimeout = responseTimeout;
    try {
      final req = await client
          .getUrl(_endpoint('/dogreader/jobs/$id'))
          .timeout(responseTimeout);
      req.followRedirects = false;
      req.headers.set('X-Dogreader-Token', token);
      final response = await req.close().timeout(responseTimeout);
      if (response.statusCode != 200) {
        throw DeliveryHttpError(response.statusCode);
      }
      return jsonDecode(
        await utf8.decoder.bind(response.timeout(idleTimeout)).join(),
      ) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Uri _endpoint(String path) =>
      Uri.parse('${host.replaceAll(RegExp(r'/$'), '')}$path');
  Future<File> audioFile(String book, int index) async =>
      File('${(await documentsDirectory()).path}/narration/${book}_$index.mp3');

  bool deliveryInFlight(String book, int index) =>
      _downloads.containsKey('$book:$index');

  bool submissionInFlight(String book, int index) =>
      _submissions.containsKey('$book:$index');

  bool downloading(String book, int index) =>
      deliveryInFlight(book, index) &&
      books[book]?[index]?['delivery'] == 'downloading';

  /// Source preparation waits for the audio/metadata transaction to settle.
  /// Failed repairs leave the previous recording available to the player.
  Future<void> waitForDownload(String book, int index) async {
    final pending = _downloads['$book:$index'];
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {
      /* Existing recording may still play. */
    }
  }

  Future<void> retryDownload(String book, int index, {bool automatic = false}) {
    final key = '$book:$index';
    final existing = _downloads[key];
    if (existing != null) {
      _log(
        'attempt_joined',
        book,
        index,
        books[book]?[index]?['id'] as String? ?? '',
        automatic: automatic,
      );
      return existing;
    }
    return _downloads[key] = _download(book, index, automatic: automatic)
        .whenComplete(() {
          _downloads.remove(key);
        });
  }

  static final _contentRangePattern = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');

  static bool _isAllowedRedirect(Uri uri) =>
      uri.scheme == 'https' ||
      (uri.scheme == 'http' &&
          (uri.host == '127.0.0.1' ||
              uri.host == 'localhost' ||
              uri.host == '::1'));

  static ({int start, int end, int total})? _parseContentRange(
    HttpHeaders headers,
  ) {
    final value = headers.value(HttpHeaders.contentRangeHeader);
    if (value == null) return null;
    final match = _contentRangePattern.firstMatch(value.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (start == null ||
        end == null ||
        total == null ||
        start < 0 ||
        end < start ||
        end >= total) {
      return null;
    }
    return (start: start, end: end, total: total);
  }

  Stream<List<int>> _streamAudioBytes({
    required HttpClient client,
    required HttpClientResponse initialResponse,
    required Uri downloadUri,
    required bool sendAuth,
    required int totalBytes,
    required bool rangeCapable,
    String? expectedSha256,
  }) async* {
    _SingleDigestSink? digestSink;
    ByteConversionSink? hashSink;
    final normalizedSha = expectedSha256?.trim().toLowerCase() ?? '';
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizedSha)) {
      digestSink = _SingleDigestSink();
      hashSink = sha256.startChunkedConversion(digestSink);
    }

    var received = 0;
    var currentResponse = initialResponse;
    var resumeRetries = 0;
    try {
      while (true) {
        var sliceBytes = 0;
        try {
          await for (final chunk in currentResponse.timeout(idleTimeout)) {
            if (chunk.isEmpty) continue;
            sliceBytes += chunk.length;
            received += chunk.length;
            hashSink?.add(chunk);
            yield chunk;
          }
          if (sliceBytes > 0) {
            resumeRetries = 0;
          }
        } catch (error) {
          if (!rangeCapable ||
              received <= 0 ||
              received >= totalBytes ||
              sliceBytes <= 0 ||
              resumeRetries >= 3) {
            rethrow;
          }
          resumeRetries++;
        }

        if (received >= totalBytes) {
          break;
        }
        if (!rangeCapable) {
          throw const FormatException('Incomplete audio response');
        }

        final req = await client
            .getUrl(downloadUri)
            .timeout(responseTimeout);
        req.followRedirects = false;
        if (sendAuth) {
          req.headers.set('X-Dogreader-Token', token);
        }
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
        final nextResponse = await req.close().timeout(responseTimeout);
        if (nextResponse.statusCode != 206) {
          await nextResponse.drain<void>().catchError((Object _) {});
          throw DeliveryHttpError(nextResponse.statusCode);
        }
        final range = _parseContentRange(nextResponse.headers);
        if (range == null ||
            range.start != received ||
            range.total != totalBytes ||
            (nextResponse.contentLength >= 0 &&
                nextResponse.contentLength != range.end - range.start + 1)) {
          await nextResponse.drain<void>().catchError((Object _) {});
          throw const FormatException('Invalid audio range response');
        }
        currentResponse = nextResponse;
      }

      if (received != totalBytes) {
        throw const FormatException('Incomplete audio transfer');
      }
      if (hashSink != null && digestSink != null) {
        hashSink.close();
        final actualDigest = digestSink.value;
        if (actualDigest == null || actualDigest.toString() != normalizedSha) {
          throw const FormatException('Audio SHA-256 verification failed');
        }
      }
    } finally {
      if (hashSink != null) {
        try {
          hashSink.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _download(
    String book,
    int index, {
    required bool automatic,
  }) async {
    await load();
    final job = books[book]?[index];
    final id = job?['id'];
    if (job == null || id is! String || id.isEmpty) {
      throw StateError('No cloud recording linked');
    }
    if (host.isEmpty || token.isEmpty) {
      throw StateError('Connect Dogreader Cloud first');
    }
    final client = HttpClient()..connectionTimeout = responseTimeout;
    try {
      final local = await audioFile(book, index);
      await recoverNarrationFile(local);
      job['localAvailable'] =
          await local.exists() && await local.length() >= 1000;
      if (!automatic) job['deliveryAttempts'] = 0;
      if (job['status'] == 'ready' && job['delivery'] != 'downloaded') {
        _transition(
          job,
          book,
          index,
          delivery: 'server_ready',
          automatic: automatic,
        );
      }
      await save();
      _log(
        'download_attempt',
        book,
        index,
        id,
        automatic: automatic,
        attempt: (job['deliveryAttempts'] as int? ?? 0) + 1,
      );
      final initialUri = _endpoint('/dogreader/audio/$id');
      final req = await client.getUrl(initialUri).timeout(responseTimeout);
      req.followRedirects = false;
      req.headers.set('X-Dogreader-Token', token);
      var response = await req.close().timeout(responseTimeout);
      if (response.statusCode == 404 && job['status'] != 'ready') {
        _log(
          'download_not_ready',
          book,
          index,
          id,
          http: 404,
          automatic: automatic,
        );
        await _notReady(job, book, index, automatic: automatic);
        return;
      }

      var downloadUri = initialUri;
      var sendAuth = true;
      var expectedSha256 = response.headers.value('x-dogreader-audio-sha256');
      var hintedTotal = int.tryParse(
        response.headers.value('x-dogreader-audio-bytes') ?? '',
      );

      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().catchError((Object _) {});
        if (location == null || location.isEmpty) {
          throw const FormatException('Missing audio redirect location');
        }
        downloadUri = initialUri.resolve(location);
        if (!_isAllowedRedirect(downloadUri)) {
          throw const FormatException('Disallowed audio redirect scheme');
        }
        sendAuth = false;
        final signedReq = await client
            .getUrl(downloadUri)
            .timeout(responseTimeout);
        signedReq.followRedirects = false;
        response = await signedReq.close().timeout(responseTimeout);
        expectedSha256 ??= response.headers.value('x-dogreader-audio-sha256');
        hintedTotal ??= int.tryParse(
          response.headers.value('x-dogreader-audio-bytes') ?? '',
        );
      }

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw DeliveryHttpError(response.statusCode);
      }

      final mimeType = response.headers.contentType?.mimeType;
      if (mimeType != null &&
          mimeType != 'audio/mpeg' &&
          mimeType != 'application/octet-stream') {
        throw const FormatException('Incomplete audio response');
      }

      final int totalBytes;
      if (response.statusCode == 206) {
        final range = _parseContentRange(response.headers);
        if (range == null ||
            range.start != 0 ||
            (response.contentLength >= 0 &&
                response.contentLength != range.end - range.start + 1)) {
          throw const FormatException('Incomplete audio response');
        }
        totalBytes = range.total;
      } else {
        totalBytes = response.contentLength >= 0
            ? response.contentLength
            : (hintedTotal ?? -1);
      }

      if (totalBytes < 1000) {
        throw const FormatException('Incomplete audio response');
      }

      final rangeCapable =
          response.statusCode == 206 ||
          response.headers.value(HttpHeaders.acceptRangesHeader) == 'bytes' ||
          !sendAuth;

      if (!identical(books[book]?[index], job)) {
        throw StateError('Recording changed');
      }
      _transition(
        job,
        book,
        index,
        status: 'ready',
        delivery: 'server_ready',
        automatic: automatic,
      );
      await save();
      final target = await audioFile(book, index);
      await target.parent.create(recursive: true);
      _transition(
        job,
        book,
        index,
        delivery: 'downloading',
        automatic: automatic,
      );
      await save();
      _log(
        'download_started',
        book,
        index,
        id,
        automatic: automatic,
        http: response.statusCode,
      );
      await replaceNarrationFile(
        target,
        _streamAudioBytes(
          client: client,
          initialResponse: response,
          downloadUri: downloadUri,
          sendAuth: sendAuth,
          totalBytes: totalBytes,
          rangeCapable: rangeCapable,
          expectedSha256: expectedSha256,
        ),
        contentLength: totalBytes,
        metadataFile: File(
          '${(await documentsDirectory()).path}/narration_state.json',
        ),
        metadataKey: '$book:$index',
        beforeReplace: () async {
          if (!identical(books[book]?[index], job)) {
            throw StateError('Recording changed');
          }
          await beforeReplace(book, index);
        },
        afterReplace: () async {
          final root = await documentsDirectory();
          await updateNarrationJson(File('${root.path}/narration_state.json'), (
            data,
          ) {
            final old = Map<String, dynamic>.from(
              (data['$book:$index'] as Map?) ?? {},
            );
            // Repair keeps the position; an explicitly different recording starts at zero.
            final replacement =
                job['previousRecording'] is Map &&
                (job['previousRecording'] as Map)['id'] != id;
            data['$book:$index'] = {
              ...old,
              'path': target.path,
              'positionMs': replacement ? 0 : old['positionMs'] ?? 0,
              ...recordingMetadata(job),
              'recording_id': id,
            };
          });
        },
      );
      job['localAvailable'] = true;
      _clearFailure(job);
      _transition(
        job,
        book,
        index,
        delivery: 'downloaded',
        automatic: automatic,
      );
      job.remove('previousRecording');
      await save();
      _log('download_completed', book, index, id, automatic: automatic);
    } catch (e) {
      await _failure(job, book, index, e, automatic: automatic);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
