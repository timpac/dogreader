import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

enum MediaDiagnosticEvent {
  processStarted,
  handlerCreated,
  handlerDisposed,
  sessionInitialized,
  commandReceived,
  commandExecuting,
  commandResult,
  playbackState,
  playbackError,
  bridgeError,
  focus,
  chapterLoadRequested,
  chapterLoaded,
  chapterLoadEnded,
  chapterLoadFailed,
  restoreRequested,
  restoreFinished,
  chapterUnloaded,
  nativeObserverUnavailable,
  narrationDelivery,
}

/// Process-local producer, bounded asynchronous disk consumer. Never awaited by
/// transport. Only allowlisted scalar fields reach disk; no exception messages,
/// titles, paths, URLs or device identities are accepted.
class MediaDiagnostics {
  MediaDiagnostics({
    required this.directory,
    this.maxBytes = 256 * 1024,
    this.maxPending = 128,
  }) : process = '$pid-${DateTime.now().microsecondsSinceEpoch}' {
    assert(maxBytes >= 1024);
    assert(maxPending > 0);
  }

  final Future<Directory> Function() directory;
  final int maxBytes;
  final int maxPending;
  final String process;
  final _pending = Queue<String>();
  Future<void>? _draining;
  Directory? _root;
  int dropped = 0;
  int ioFailures = 0;

  static const _numbers = {
    'id', 'positionMs', 'source', 'engine', 'intent', 'chapter', 'count',
    'code', 'bookTag', 'httpStatus', 'attempt', 'completedChunks', 'totalChunks',
  };
  static const _booleans = {'playing', 'sessionPlaying', 'wanted', 'begin'};
  static const _strings = <String, Set<String>>{
    'deliveryEvent': {
      'reconcile_failed', 'state_transition', 'status_requested', 'status_received',
      'status_missing', 'status_failed', 'download_attempt', 'download_not_ready',
      'download_started', 'download_completed', 'download_failed', 'attempt_joined',
    },
    'retryMode': {'automatic', 'manual'},
    'serverStatus': {'waiting', 'queued', 'generating', 'ready', 'error', 'unknown'},
    'fromServerStatus': {'waiting', 'queued', 'generating', 'ready', 'error', 'unknown'},
    'deliveryState': {'pending', 'server_ready', 'downloading', 'downloaded', 'failed', 'unknown'},
    'fromDeliveryState': {'pending', 'server_ready', 'downloading', 'downloaded', 'failed', 'unknown'},
    'errorKind': {'DeliveryHttpError', 'TimeoutException', 'SocketException',
      'HttpException', 'HandshakeException', 'FormatException', 'StateError', 'FileSystemException'},
    'command': {'play', 'pause', 'stop', 'seek', 'speed', 'next', 'previous'},
    'origin': {
      'external', 'in-app', 'in-app seek', 'reader jump', 'import audio',
      'automatic resume', 'headset disconnect', 'seek timeout',
      'chapter transition', 'voice preview',
    },
    'phase': {
      'cancelled', 'no source', 'focus denied', 'dispatched',
      'settled (pause/end)', 'stale error ignored', 'failed',
      'completed (native Pause/Stop acknowledged)', 'failed to silence',
      'completed', 'cancelled after native engine release',
      'unsupported',
    },
    'playerState': {'idle', 'loading', 'buffering', 'ready', 'completed'},
    'sessionState': {
      'idle', 'loading', 'buffering', 'ready', 'completed', 'error',
    },
    'focusType': {'pause', 'duck', 'unknown'},
  };

  void record(MediaDiagnosticEvent event, [Map<String, Object?> fields = const {}]) {
    final safe = <String, Object>{};
    for (final entry in fields.entries) {
      final value = entry.value;
      if ((_numbers.contains(entry.key) && value is int) ||
          (_booleans.contains(entry.key) && value is bool) ||
          (_strings[entry.key]?.contains(value) ?? false) ||
          (event == MediaDiagnosticEvent.narrationDelivery && entry.key == 'jobId' &&
              value is String && RegExp(r'^(unknown|[0-9a-f]{32})$').hasMatch(value)) ||
          (entry.key == 'build' && value is String &&
              RegExp(r'^(DEV|[0-9]{1,8})$').hasMatch(value))) {
        safe[entry.key] = value!;
      }
    }
    if (_pending.length >= maxPending) {
      dropped++;
      return;
    }
    _pending.add('${jsonEncode({
      'time': DateTime.now().toUtc().toIso8601String(),
      'process': process,
      'event': event.name,
      'dropped': dropped,
      'ioFailures': ioFailures,
      ...safe,
    })}\n');
    _draining ??= Future<void>.microtask(_drain);
  }

  Future<void> _drain() async {
    var inFlight = 0;
    try {
      final root = _root ??= await directory();
      await root.create(recursive: true);
      final current = File('${root.path}/dart.jsonl');
      final previous = File('${root.path}/dart.previous.jsonl');
      while (_pending.isNotEmpty) {
        final line = _pending.removeFirst();
        inFlight = 1;
        final bytes = utf8.encode(line);
        if (await current.exists() && await current.length() + bytes.length > maxBytes) {
          if (await previous.exists()) await previous.delete();
          await current.rename(previous.path);
        }
        await current.writeAsBytes(bytes, mode: FileMode.append);
        inFlight = 0;
      }
    } catch (_) {
      // Storage problems must never escape into audio callbacks or cause retries
      // in a tight loop. A future event can retry; dropped counts remain visible.
      ioFailures++;
      dropped += _pending.length + inFlight;
      _pending.clear();
    } finally {
      _draining = null;
    }
  }

  Future<void> flush() async {
    while (_draining != null) {
      await _draining;
    }
  }

  Future<String> export() async {
    await flush();
    final output = StringBuffer(
      'Dogreader media diagnostics v1\n'
      'Current process: $process; dropped=$dropped; ioFailures=$ioFailures\n'
      'An abrupt kill can omit the last queued events.\n',
    );
    try {
      final root = _root ?? await directory();
      for (final name in ['dart.previous.jsonl', 'dart.jsonl']) {
        final file = File('${root.path}/$name');
        if (await file.exists()) {
          output.writeln('\n--- $name ---');
          final length = await file.length();
          final bytes = await file.openRead(0, length < maxBytes ? length : maxBytes).fold<List<int>>(
            <int>[], (all, chunk) => all..addAll(chunk),
          );
          output.write(utf8.decode(bytes, allowMalformed: true));
        }
      }
    } catch (_) {
      output.writeln('Diagnostic storage unavailable.');
    }
    return output.toString();
  }
}
