import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'narration_files.dart';
import 'narration_options.dart';
import 'narration_storage.dart';

class DeliveryHttpError implements Exception {
  DeliveryHttpError(this.status);
  final int status;
}

/// App-owned delivery of existing job IDs. Never submits text or resets TTS.
/// The legacy queue/status fields remain readable; delivery fields are additive.
class NarrationDelivery extends ChangeNotifier {
  NarrationDelivery({
    required this.documentsDirectory,
    required this.beforeReplace,
    DateTime Function()? clock,
    this.responseTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 30),
  }) : clock = clock ?? DateTime.now;

  final Future<Directory> Function() documentsDirectory;
  final Future<void> Function(String, int) beforeReplace;
  final DateTime Function() clock;
  final Duration responseTimeout, idleTimeout;
  final Map<String, Map<int, Map<String, dynamic>>> books = {};
  final Map<String, Future<void>> _downloads = {};
  final List<String> diagnostics = [];
  String host = '', token = '';
  Future<void>? _loading, _checking;
  Timer? _timer;
  bool _loaded = false, _disposed = false;
  static const maxAttempts = 6;

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
        books[book.key.toString()] = jobs;
      }
    }
    _loaded = true;
  }

  void attachBook(String book, Map<int, Map<String, dynamic>> jobs) {
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

  void _log(String event, String book, int index, String id, [Object? error]) {
    // Never log URLs, headers, tokens, source text or raw exception messages.
    diagnostics.add(
      '${clock().toUtc().toIso8601String()} $event book=$book chapter=$index id=$id'
      '${error == null ? '' : ' error=${error.runtimeType}'}'
      '${error is DeliveryHttpError ? ' http=${error.status}' : ''}',
    );
    if (diagnostics.length > 80) diagnostics.removeAt(0);
    debugPrint('narration_delivery ${diagnostics.last}');
  }

  Future<void> reconcile() => _checking ??= _reconcile()
      .catchError((Object e) {
        // A metadata failure must not discard the durable queue or start paid work.
        _log('reconcile_failed', '', -1, '', e);
      })
      .whenComplete(() => _checking = null);

  Future<void> _reconcile() async {
    await load();
    if (host.isEmpty || token.isEmpty || _disposed) return;
    for (final book in books.entries.toList()) {
      for (final entry in book.value.entries.toList()) {
        if (_disposed) return;
        final job = entry.value;
        final id = job['id'];
        if (id is! String || id.isEmpty || job['status'] == 'waiting') continue;
        final key = '${book.key}:${entry.key}';
        if (_downloads.containsKey(key)) continue;
        final target = await audioFile(book.key, entry.key);
        await recoverNarrationFile(target);
        job['localAvailable'] =
            await target.exists() && await target.length() >= 1000;
        if (job['previousRecording'] == null &&
            await target.exists() &&
            await target.length() >= 1000 &&
            job['status'] == 'ready' &&
            (job['delivery'] == null || job['delivery'] == 'downloaded')) {
          if (job['delivery'] != 'downloaded') {
            job['localAvailable'] = true;
            job['delivery'] = 'downloaded';
            await save();
          }
          continue;
        }
        final next = (job['deliveryNextAttempt'] as num?)?.toInt() ?? 0;
        if (clock().millisecondsSinceEpoch < next) {
          continue;
        }
        try {
          // Probe existing bytes first, even with stale/error/missing job state.
          await retryDownload(book.key, entry.key, automatic: true);
        } on DeliveryHttpError catch (e) {
          if (e.status != 404 || job['status'] == 'ready') continue;
          // Only automatic reconciliation polls the existing recovery endpoint.
          // Manual Retry Download never makes this call (which may dispatch work).
          try {
            final result = await _status(id);
            if (!identical(book.value[entry.key], job)) continue;
            job.addAll(recordingMetadata(result));
            job['status'] = result['status'];
            job['error'] = result['error'];
            if (result['status'] == 'ready') {
              job['delivery'] = 'server_ready';
            } else {
              job['delivery'] = result['status'] == 'error'
                  ? 'failed'
                  : 'pending';
              job['failureStage'] = result['status'] == 'error'
                  ? 'generation'
                  : null;
              // Normal generation polling must not spend download failure budget.
              if (result['status'] != 'error') {
                job['deliveryAttempts'] = 0;
                job['deliveryNextAttempt'] = clock()
                    .add(const Duration(seconds: 12))
                    .millisecondsSinceEpoch;
              }
            }
            await save();
            _log('status_${result['status']}', book.key, entry.key, id);
          } catch (error) {
            _log('status_failed', book.key, entry.key, id, error);
          }
        } catch (_) {
          // Download already persisted bounded backoff and safe error details.
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

  bool downloading(String book, int index) =>
      _downloads.containsKey('$book:$index');

  Future<void> retryDownload(String book, int index, {bool automatic = false}) {
    final key = '$book:$index';
    return _downloads[key] ??= _download(book, index, automatic: automatic)
        .whenComplete(() {
          _downloads.remove(key);
        });
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
      job['delivery'] = 'downloading';
      if (!automatic) job['deliveryAttempts'] = 0;
      await save();
      _log('download_started', book, index, id);
      final req = await client
          .getUrl(_endpoint('/dogreader/audio/$id'))
          .timeout(responseTimeout);
      req.followRedirects = false;
      req.headers.set('X-Dogreader-Token', token);
      final response = await req.close().timeout(responseTimeout);
      if (response.statusCode != 200) {
        throw DeliveryHttpError(response.statusCode);
      }
      job['status'] = 'ready';
      job['delivery'] = 'server_ready';
      await save();
      if (response.contentLength < 1000 ||
          (response.headers.contentType != null &&
              response.headers.contentType!.mimeType != 'audio/mpeg')) {
        throw const FormatException('Incomplete audio response');
      }
      job['delivery'] = 'downloading';
      await save();
      final target = await audioFile(book, index);
      await target.parent.create(recursive: true);
      await replaceNarrationFile(
        target,
        response.timeout(idleTimeout),
        contentLength: response.contentLength,
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
      job['delivery'] = 'downloaded';
      job['deliveryAttempts'] = 0;
      job.remove('deliveryNextAttempt');
      job.remove('deliveryError');
      job.remove('failureStage');
      job.remove('previousRecording');
      await save();
      _log('download_completed', book, index, id);
    } catch (e) {
      final previousAttempts = (job['deliveryAttempts'] as num?)?.toInt() ?? 0;
      final attempts = previousAttempts >= maxAttempts
          ? maxAttempts
          : previousAttempts + 1;
      job['deliveryAttempts'] = attempts;
      // Six quick attempts, then one probe per 15 minutes. Reopening keeps
      // the cooldown; prolonged outages still recover without manual repair.
      job['deliveryNextAttempt'] = clock()
          .add(
            Duration(
              seconds: attempts >= maxAttempts
                  ? 900
                  : 15 * (1 << (attempts - 1)),
            ),
          )
          .millisecondsSinceEpoch;
      job['delivery'] = 'failed';
      job['failureStage'] = 'download';
      job['deliveryError'] = e is DeliveryHttpError
          ? 'Download HTTP ${e.status}'
          : e is TimeoutException
          ? 'Download timed out'
          : 'Download interrupted (${e.runtimeType})';
      await save();
      _log('download_failed', book, index, id, e);
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
