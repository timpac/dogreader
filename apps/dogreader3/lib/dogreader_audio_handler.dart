import 'dart:async';
import 'dart:io';
import 'chapter_recording_path.dart';
import 'narration_storage.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'media_diagnostics.dart';

class _Recording {
  const _Recording(
    this.path,
    this.title,
    this.author,
    this.bookId,
    this.index,
    this.count, {
    this.preview = false,
  });
  final String path, title, author, bookId;
  final int index, count;
  final bool preview;
  String get key => '$bookId:$index';
}

/// The sole owner of audio output, source changes, focus and playback intent.
///
/// Source/seek/play preparation is serialized. Pause/Stop invalidate intent
/// synchronously and silence the engine immediately, even during preparation.
/// Never put the lifetime Future returned by just_audio.play() in this queue:
/// it completes at Pause/EOF, rather than when playback starts.
class DogreaderAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player;
  final MediaDiagnostics? diagnostics;
  String? _lastDiagnosticState;
  final Future<Directory> Function() _documentsDirectory;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _operations = Future<void>.value();
  Future<void> _silencing = Future<void>.value();
  Future<void> _pendingSave = Future<void>.value();
  AudioSession? _session;
  _Recording? _recording;
  int _sourceRevision = 0;
  int _engineRevision = 0;
  int _loadedRevision = -1;
  int _previewSequence = 0;
  bool _previewActive = false;
  int _intentRevision = 0;
  bool _wantsPlayback = false;
  bool _stopped = true;
  bool _pausedReleased = false;
  bool _disposed = false;
  bool _advancing = false;
  bool _preparing = false;
  bool _seeking = false;
  Completer<void> _engineReleased = Completer<void>();
  bool _interrupted = false;
  int? _resumeFocusRevision;
  int? _playbackError;
  int _lastSavedSecond = -1;
  Duration _resumePosition = Duration.zero;
  _Recording? _beforePreview;
  Duration _beforePreviewPosition = Duration.zero;
  Completer<void>? _previewDone;

  DogreaderAudioHandler({
    AudioPlayer? player,
    Future<Directory> Function()? documentsDirectory,
    this.diagnostics,
  }) : player =
           player ??
           AudioPlayer(
             handleInterruptions: false,
             handleAudioSessionActivation: false,
           ),
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory {
    recordDiagnostic(MediaDiagnosticEvent.handlerCreated);
    _subscriptions.add(
      this.player.positionStream.listen((position) {
        if (_recording == null ||
            _stopped ||
            _preparing ||
            _seeking ||
            this.player.processingState == ProcessingState.idle ||
            this.player.processingState == ProcessingState.loading ||
            _playbackError != null) {
          return;
        }
        _resumePosition = position;
        if (position.inSeconds != _lastSavedSecond &&
            position.inSeconds % 5 == 0) {
          _lastSavedSecond = position.inSeconds;
          unawaited(_savePosition(position));
        }
      }),
    );
    _subscriptions.add(
      this.player.processingStateStream.listen((state) {
        if (state == ProcessingState.completed &&
            !_stopped &&
            !_preparing &&
            _wantsPlayback &&
            !_interrupted) {
          unawaited(_advanceToNextChapter());
        }
      }),
    );
    _subscriptions.add(
      this.player.playbackEventStream.listen(
        (_) => _broadcastPlaybackState(),
        onError: _recordPlaybackError,
      ),
    );
    _subscriptions.add(
      this.player.playerStateStream.listen((_) {
        _broadcastPlaybackState();
        // Also enforce intent against a late native/internal resume. Publication
        // alone must never turn an unwanted audible stream into a paused icon.
        if (this.player.playing &&
            (!_wantsPlayback || _interrupted || _stopped) &&
            !_preparing) {
          unawaited(_silence().catchError(_recordPlaybackError));
        }
      }),
    );
    _subscriptions.add(
      this.player.speedStream.listen((_) => _broadcastPlaybackState()),
    );
    _subscriptions.add(
      this.player.durationStream.listen((duration) {
        final item = mediaItem.value;
        if (!_preparing &&
            item != null &&
            duration != null &&
            duration > Duration.zero &&
            item.duration != duration) {
          mediaItem.add(item.copyWith(duration: duration));
        }
        _broadcastPlaybackState();
      }),
    );
    _subscriptions.add(this.player.errorStream.listen(_recordPlaybackError));
    _subscriptions.add(
      AudioService.asyncError.listen((error) {
        diagnosticLastSessionError = _diagnosticReason(error);
        _logDiagnostic('SESSION ERROR $diagnosticLastSessionError');
        recordDiagnostic(MediaDiagnosticEvent.bridgeError);
      }),
    );
  }

  /// Called once at application startup. No screen owns session/focus listeners.
  Future<void> initializeAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    if (_disposed || _session != null) return;
    _session = session;
    recordDiagnostic(MediaDiagnosticEvent.sessionInitialized);
    bindInterruptions(
      session.interruptionEventStream,
      session.becomingNoisyEventStream,
    );
  }

  @visibleForTesting
  void bindInterruptions(
    Stream<AudioInterruptionEvent> interruptions,
    Stream<void> becomingNoisy,
  ) {
    _subscriptions.add(
      interruptions.listen((event) {
        diagnostics?.record(MediaDiagnosticEvent.focus, {
          ..._diagnosticFields,
          'begin': event.begin,
          'focusType': event.type.name,
        });
        _logDiagnostic(
          'FOCUS ${event.begin ? "begin" : "end"} ${event.type.name}',
        );
        if (event.begin) {
          _resumeFocusRevision =
              _wantsPlayback && event.type != AudioInterruptionType.unknown
              ? _intentRevision
              : null;
          if (event.type == AudioInterruptionType.unknown) {
            ++_intentRevision;
            _wantsPlayback = false;
          }
          _interrupted = true;
          unawaited(_silence().catchError(_recordPlaybackError));
        } else {
          final resume = _resumeFocusRevision;
          _resumeFocusRevision = null;
          _interrupted = false;
          if (event.type != AudioInterruptionType.unknown &&
              resume == _intentRevision &&
              _wantsPlayback &&
              !_stopped) {
            unawaited(play(origin: 'automatic resume'));
          }
        }
      }),
    );
    _subscriptions.add(
      becomingNoisy.listen(
        (_) => unawaited(pause(origin: 'headset disconnect')),
      ),
    );
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> _savePosition(Duration position) {
    final recording = _recording;
    if (recording == null || recording.preview) return Future<void>.value();
    final key = recording.key;
    final milliseconds = position.inMilliseconds.clamp(0, 2147483647);
    _pendingSave = _pendingSave.catchError((Object _) {}).then((_) async {
      try {
        final root = await _documentsDirectory();
        final file = File('${root.path}/narration_state.json');
        await updateNarrationJson(file, (data) {
          final chapter = Map<String, dynamic>.from((data[key] as Map?) ?? {});
          chapter['positionMs'] = milliseconds;
          data[key] = chapter;
        });
      } catch (_) {
        /* Progress I/O cannot interrupt transport. */
      }
    });
    return _pendingSave;
  }

  final diagnosticCommands = ValueNotifier<List<String>>(<String>[]);
  int diagnosticCommandCount = 0;
  final diagnosticStarted = DateTime.now();
  String? diagnosticLastError;
  String? diagnosticLastSessionError;
  bool get diagnosticWantsPlayback => _wantsPlayback;

  Map<String, Object?> get _diagnosticFields => {
    'playing': player.playing,
    'playerState': player.processingState.name,
    'sessionPlaying': playbackState.value.playing,
    'sessionState': playbackState.value.processingState.name,
    'wanted': _wantsPlayback,
    'positionMs': player.position.inMilliseconds,
    'intent': _intentRevision,
    'source': _sourceRevision,
    'engine': _engineRevision,
    'chapter': _recording?.index,
  };

  void recordDiagnostic(MediaDiagnosticEvent event) =>
      diagnostics?.record(event, _diagnosticFields);

  void _executing(int id) => diagnostics?.record(
    MediaDiagnosticEvent.commandExecuting, {'id': id, ..._diagnosticFields},
  );

  int _logCommand(String command, {String origin = 'external'}) {
    final id = ++diagnosticCommandCount;
    diagnostics?.record(MediaDiagnosticEvent.commandReceived, {
      'id': id, 'command': command, 'origin': origin, ..._diagnosticFields,
    });
    _logDiagnostic(
      '#$id $command received origin=$origin playing=${player.playing} '
      'state=${player.processingState.name} positionMs=${player.position.inMilliseconds} '
      'intent=$_intentRevision source=$_sourceRevision',
    );
    return id;
  }

  void _result(int id, String phase) {
    diagnostics?.record(MediaDiagnosticEvent.commandResult, {
      'id': id, 'phase': phase, ..._diagnosticFields,
    });
    _logDiagnostic(
      '#$id $phase '
      'playing=${player.playing} session=${playbackState.value.playing} '
      'wanted=$_wantsPlayback positionMs=${player.position.inMilliseconds}',
    );
  }

  void _logDiagnostic(String entry) {
    if (_disposed) return;
    final line = '${DateTime.now().toIso8601String()} $entry';
    diagnosticCommands.value = [line, ...diagnosticCommands.value.take(119)];
    if (const bool.fromEnvironment('DOGREADER_MEDIA_VERBOSE')) {
      debugPrint('dogreader_media $line');
    }
  }

  void _recordPlaybackError(Object error) {
    if (_disposed) return;
    if (!_seeking &&
        !_preparing &&
        (player.position > Duration.zero || _resumePosition == Duration.zero)) {
      _resumePosition = player.position;
    }
    _playbackError = error is PlayerException ? error.code : -1;
    diagnostics?.record(MediaDiagnosticEvent.playbackError, {
      ..._diagnosticFields, 'code': _playbackError,
    });
    final reason = _diagnosticReason(error);
    diagnosticLastError = '${error.runtimeType} code=$_playbackError: $reason';
    _logDiagnostic('ERROR $diagnosticLastError');
    _broadcastPlaybackState();
  }

  String _diagnosticReason(Object error) => error
      .toString()
      .replaceAll(RegExp(r'https?://\S+'), '[URL]')
      .replaceAll(RegExp(r'(?:file://)?/\S+'), '[path]');

  void _broadcastPlaybackState() {
    if (_disposed) return;
    final playing =
        !_stopped &&
        _playbackError == null &&
        player.playing &&
        player.processingState != ProcessingState.completed &&
        player.processingState != ProcessingState.idle;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.rewind,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.fastForward,
          MediaControl.stop,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _stopped
            ? AudioProcessingState.idle
            : _playbackError != null
            ? AudioProcessingState.error
            : switch (player.processingState) {
                ProcessingState.idle =>
                  // audio_service treats idle as stopService(), deactivating
                  // the Android MediaSession. Native decoder release/loading
                  // must not end a retained, resumable session. Only our
                  // explicit Stop above owns that lifecycle boundary.
                  _preparing || _recording == null
                      ? AudioProcessingState.loading
                      : AudioProcessingState.ready,
                ProcessingState.loading => AudioProcessingState.loading,
                ProcessingState.buffering => AudioProcessingState.buffering,
                ProcessingState.ready => AudioProcessingState.ready,
                ProcessingState.completed => AudioProcessingState.completed,
              },
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        errorCode: _stopped ? null : _playbackError,
        errorMessage: !_stopped && _playbackError != null
            ? 'Playback failed. Press Play to reload the recording.'
            : null,
      ),
    );
    if (diagnostics != null) {
      final state = '${player.processingState.name}:${player.playing}:'
          '${playbackState.value.processingState.name}:'
          '${playbackState.value.playing}:$_wantsPlayback:$_playbackError';
      if (state != _lastDiagnosticState) {
        _lastDiagnosticState = state;
        recordDiagnostic(MediaDiagnosticEvent.playbackState);
      }
    }
  }

  Future<void> _releaseNative() async {
    await player.stop().timeout(const Duration(seconds: 3));
    if (_seeking) {
      // Seek updates Dart position optimistically. Reset the now-inactive
      // platform to the last confirmed position before cancelling its waiter.
      try {
        await player.seek(_resumePosition).timeout(const Duration(seconds: 1));
      } catch (error) {
        _recordPlaybackError(error);
      }
    }
    // just_audio Android can abandon a Seek result when releasing ExoPlayer.
    // Only abandon our waiter after release is acknowledged: a later Play can
    // then create a fresh native engine without a competing old output stream.
    final released = _engineReleased;
    _engineReleased = Completer<void>();
    released.complete();
  }

  /// Native acknowledgement is awaited; a failed Pause must release the engine.
  /// Subsequent Play waits for this boundary, never for a disk write or EOF.
  Future<void> _silence({bool stop = false, bool release = false}) {
    final previous = _silencing;
    final result = () async {
      try {
        await previous;
      } catch (_) {
        /* Retry silencing after a previous native failure. */
      }
      if (stop) {
        await _releaseNative();
      } else {
        try {
          await player.pause().timeout(const Duration(seconds: 3));
          if (player.playing) {
            throw StateError('Pause completed with playing=true');
          }
        } catch (error) {
          _recordPlaybackError(error);
          _logDiagnostic('PAUSE fallback: release native decoder');
          await _releaseNative();
        }
        if (release) {
          await _releaseNative();
        }
      }
      _broadcastPlaybackState();
    }();
    _silencing = result;
    return result;
  }

  void _publish(_Recording recording) {
    _recording = recording;
    recordDiagnostic(MediaDiagnosticEvent.chapterLoaded);
    _lastSavedSecond = -1;
    mediaItem.add(
      MediaItem(
        id: recording.key,
        title: recording.title,
        album: 'Dogreader',
        artist: recording.author,
        duration: player.duration,
      ),
    );
    _broadcastPlaybackState();
  }

  Future<void> loadChapter({
    required String path,
    required String title,
    required String author,
    required String bookId,
    required int chapterIndex,
    required int chapterCount,
    Duration startPosition = Duration.zero,
    bool forceReload = false,
    bool Function()? isCurrent,
  }) {
    if (_disposed) return Future<void>.value();
    // Stable opaque correlation only; no book title, source path or book ID.
    var bookTag = 0x811c9dc5;
    for (final unit in bookId.codeUnits) {
      bookTag = ((bookTag ^ unit) * 0x01000193) & 0xffffffff;
    }
    diagnostics?.record(MediaDiagnosticEvent.chapterLoadRequested, {
      'bookTag': bookTag, 'chapter': chapterIndex, 'count': chapterCount,
      'positionMs': startPosition.inMilliseconds,
    });
    if (!forceReload &&
        _loadedRevision == _sourceRevision &&
        !_preparing &&
        _recording?.key == '$bookId:$chapterIndex' &&
        _recording?.path == path &&
        player.audioSource != null) {
      return Future<void>.value();
    }
    if (bookId != '__preview__') {
      _finishPreview();
      _previewActive = false;
      ++_previewSequence;
    }
    final seekPosition = _seeking ? _resumePosition : null;
    if (_seeking) {
      unawaited(_silence(stop: true).catchError(_recordPlaybackError));
    }
    final revision = ++_sourceRevision;
    ++_intentRevision;
    _wantsPlayback = false;
    _stopped = false;
    _pausedReleased = false;
    _resumeFocusRevision = null;
    final recording = _Recording(
      path,
      title,
      author,
      bookId,
      chapterIndex,
      chapterCount,
    );
    return _serial(() async {
      bool current() =>
          !_disposed &&
          revision == _sourceRevision &&
          (isCurrent?.call() ?? true);
      if (!current()) return;
      await _savePosition(_resumePosition = seekPosition ?? player.position);
      if (!current()) return;
      await _silence();
      if (!current()) return;
      _preparing = true;
      ++_engineRevision;
      _playbackError = null;
      _resumePosition = startPosition;
      try {
        await player.setFilePath(path, initialPosition: startPosition);
        if (!current()) {
          // A route can disappear without another load request following it.
          // Do not leave that unowned source associated with the old metadata.
          await _silence(stop: true);
          _recording = null;
          mediaItem.add(null);
          return;
        }
        _resumePosition = startPosition;
        _loadedRevision = revision;
        _publish(recording);
        if (_stopped || !_wantsPlayback) await _silence(stop: _stopped);
      } on PlayerInterruptedException {
        if (!current()) return;
        if (!_pausedReleased && !_stopped) rethrow;
        _resumePosition = startPosition;
        _loadedRevision = revision;
        _publish(recording);
      } catch (error) {
        diagnostics?.record(MediaDiagnosticEvent.chapterLoadFailed, {
          ..._diagnosticFields,
          'code': error is PlayerException ? error.code : -1,
        });
        rethrow;
      } finally {
        _preparing = false;
        _broadcastPlaybackState();
        recordDiagnostic(MediaDiagnosticEvent.chapterLoadEnded);
      }
    });
  }

  bool isChapterPlaying(String bookId, int index) {
    if (_recording?.key != '$bookId:$index') return false;
    return player.playing || playbackState.value.playing;
  }

  Future<void> unloadChapter(String bookId, int index) async {
    if (_recording?.key != '$bookId:$index') return;
    recordDiagnostic(MediaDiagnosticEvent.chapterUnloaded);
    final revision = ++_sourceRevision;
    await stop();
    await _serial(() async {
      if (revision != _sourceRevision) return;
      _recording = null;
      mediaItem.add(null);
    });
  }

  @override
  Future<void> play({String origin = 'external'}) {
    final id = _logCommand('play', origin: origin);
    final intent = ++_intentRevision;
    _wantsPlayback = true;
    _interrupted = false;
    _resumeFocusRevision = null;
    _stopped = false;
    return _serial(() async {
      _executing(id);
      bool current() =>
          !_disposed &&
          intent == _intentRevision &&
          _wantsPlayback &&
          !_interrupted &&
          !_stopped;
      try {
        await _silencing;
        if (!current()) {
          _result(id, 'cancelled');
          return;
        }
        final recording = _recording;
        if (recording == null) {
          _wantsPlayback = false;
          _stopped = true;
          _result(id, 'no source');
          return;
        }
        if (_playbackError != null ||
            player.processingState == ProcessingState.idle) {
          final position = _resumePosition;
          // stop() releases the failed native decoder before preparing another.
          _preparing = true;
          try {
            await _silence(stop: true);
            if (!current()) return;
            ++_engineRevision;
            _playbackError = null;
            await player.setFilePath(recording.path, initialPosition: position);
            _publish(recording);
          } finally {
            _preparing = false;
          }
          if (!current()) {
            await _silence(stop: _stopped);
            return;
          }
        }
        if (player.processingState == ProcessingState.completed) {
          await player.seek(Duration.zero);
          _resumePosition = Duration.zero;
        }
        if (!current()) return;
        if (_session != null && !await _session!.setActive(true)) {
          if (current()) _wantsPlayback = false;
          _result(id, 'focus denied');
          return;
        }
        if (!current()) return;
        _playbackError = null;
        final source = _engineRevision;
        _pausedReleased = false;
        final lifetime = player.play();
        _broadcastPlaybackState();
        _result(id, 'dispatched');
        unawaited(
          lifetime.then(
            (_) {
              if (source == _engineRevision) _broadcastPlaybackState();
              _result(id, 'settled (pause/end)');
            },
            onError: (Object error, StackTrace stack) {
              // A released decoder's Future must never poison the replacement.
              if (source == _engineRevision && intent == _intentRevision) {
                _recordPlaybackError(error);
              } else {
                _result(id, 'stale error ignored');
              }
            },
          ),
        );
      } catch (error) {
        if (current()) _recordPlaybackError(error);
        _result(id, current() ? 'failed' : 'cancelled');
      } finally {
        _broadcastPlaybackState();
      }
    });
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) {
    if (button != MediaButton.media) return super.click(button);
    return _wantsPlayback &&
            !_stopped &&
            player.processingState != ProcessingState.completed
        ? pause()
        : play();
  }

  @override
  Future<void> pause({String origin = 'external'}) async {
    final id = _logCommand('pause', origin: origin);
    _executing(id);
    ++_intentRevision;
    _wantsPlayback = false;
    _resumeFocusRevision = null;
    final saved = _preparing
        ? Future<void>.value()
        : _savePosition(
            _resumePosition = _seeking ? _resumePosition : player.position,
          );
    // just_audio.pause() returns without a platform call when its Dart playing
    // flag is false. Always release the native engine on deliberate Pause:
    // this is a real output boundary even if Dart/native state has drifted.
    // Keep the session resumable; Play reloads the retained source/position.
    _pausedReleased = true;
    try {
      await _silence(release: true);
      _result(id, 'completed (native Pause/Stop acknowledged)');
    } catch (error) {
      _recordPlaybackError(error);
      _result(id, 'failed to silence');
      rethrow;
    } finally {
      await saved;
    }
  }

  @override
  Future<void> stop() async {
    final id = _logCommand('stop');
    _executing(id);
    ++_intentRevision;
    _wantsPlayback = false;
    _resumeFocusRevision = null;
    _stopped = true;
    _pausedReleased = false;
    final saved = _preparing
        ? Future<void>.value()
        : _savePosition(
            _resumePosition = _seeking ? _resumePosition : player.position,
          );
    try {
      await _silence(stop: true);
      _playbackError = null;
      _result(id, 'completed');
    } finally {
      _broadcastPlaybackState();
      await saved;
    }
  }

  @override
  Future<void> seek(Duration position, {String origin = 'external'}) {
    final id = _logCommand('seek', origin: origin);
    final revision = _sourceRevision;
    return _serial(() async {
      _executing(id);
      if (_disposed || revision != _sourceRevision) {
        _result(id, 'cancelled');
        return;
      }
      await _silencing;
      final end = player.duration;
      var target = position < Duration.zero ? Duration.zero : position;
      if (end != null && end > Duration.zero && target > end) target = end;
      _resumePosition = player.position;
      _seeking = true;
      final released = _engineReleased.future;
      try {
        final completed =
            await Future.any<bool>([
              player.seek(target).then((_) => true),
              released.then((_) => false),
            ]).timeout(
              const Duration(seconds: 5),
              onTimeout: () async {
                await pause(origin: 'seek timeout');
                final error = TimeoutException(
                  'Native Seek did not complete; engine released',
                );
                _recordPlaybackError(error);
                throw error;
              },
            );
        if (!completed || revision != _sourceRevision) {
          _result(id, 'cancelled after native engine release');
          return;
        }
        _resumePosition = player.position;
        _broadcastPlaybackState();
        await _savePosition(player.position);
        _result(id, 'completed');
      } catch (_) {
        _result(id, 'failed');
        rethrow;
      } finally {
        _seeking = false;
      }
    });
  }

  @override
  Future<void> rewind() => seek(player.position - const Duration(seconds: 15));
  @override
  Future<void> fastForward() =>
      seek(player.position + const Duration(seconds: 30));

  // Preserve the inherited no-op behavior while making headset skip delivery
  // observable. Chapter navigation semantics are outside this investigation.
  @override
  Future<void> skipToNext() async {
    final id = _logCommand('next');
    _executing(id);
    await super.skipToNext();
    _result(id, 'unsupported');
  }

  @override
  Future<void> skipToPrevious() async {
    final id = _logCommand('previous');
    _executing(id);
    await super.skipToPrevious();
    _result(id, 'unsupported');
  }
  @override
  Future<void> setSpeed(double speed) => _serial(() async {
    final id = _logCommand('speed');
    _executing(id);
    try {
      await player.setSpeed(speed);
      _broadcastPlaybackState();
      _result(id, 'completed');
    } catch (_) {
      _result(id, 'failed');
      rethrow;
    }
  });

  Future<void> _advanceToNextChapter() async {
    if (_advancing || _recording == null || !_wantsPlayback || _stopped) return;
    _advancing = true;
    final source = _sourceRevision;
    final intent = _intentRevision;
    bool current() => !_disposed && source == _sourceRevision;
    bool continuePlaying() =>
        current() &&
        intent == _intentRevision &&
        _wantsPlayback &&
        !_stopped &&
        !_interrupted;
    var startNext = false;
    try {
      await _serial(() async {
        if (!continuePlaying()) return;
        final old = _recording!;
        await _silence();
        if (!continuePlaying()) return;
        if (old.preview) {
          _wantsPlayback = false;
          return;
        }
        final nextIndex = old.index + 1;
        final root = await _documentsDirectory();
        final next = await chapterRecordingFile(root, old.bookId, nextIndex);
        if (!continuePlaying()) return;
        final available =
            nextIndex < old.count &&
            await next.exists() &&
            await next.length() > 0;
        if (!continuePlaying()) return;
        if (!available) {
          _wantsPlayback = false;
          return;
        }
        await _savePosition(Duration.zero);
        if (!continuePlaying()) return;
        _preparing = true;
        ++_engineRevision;
        _resumePosition = Duration.zero;
        try {
          await player.setFilePath(next.path, initialPosition: Duration.zero);
          if (!current()) return;
          _resumePosition = Duration.zero;
          _publish(
            _Recording(
              next.path,
              'Chapter ${nextIndex + 1}',
              old.author,
              old.bookId,
              nextIndex,
              old.count,
            ),
          );
          if (!continuePlaying()) await _silence(stop: _stopped);
          startNext = continuePlaying();
        } on PlayerInterruptedException {
          if (!current() || (!_pausedReleased && !_stopped)) rethrow;
          _resumePosition = Duration.zero;
          _publish(
            _Recording(
              next.path,
              'Chapter ${nextIndex + 1}',
              old.author,
              old.bookId,
              nextIndex,
              old.count,
            ),
          );
        } finally {
          _preparing = false;
        }
      });
    } catch (error) {
      if (current()) _recordPlaybackError(error);
    } finally {
      _advancing = false;
    }
    if (_recording?.preview ?? false) {
      await stopPreview();
    } else if (startNext && continuePlaying()) {
      // Re-enter transport only after releasing the structural operation.
      unawaited(play(origin: 'chapter transition'));
    }
  }

  /// Voice samples use the same engine and external controls as narration.
  /// Returning to the chapter restores its position paused, never auto-resumes.
  Future<void> playPreview(String path, String title) async {
    await stopPreview();
    final sequence = ++_previewSequence;
    _beforePreview = _recording;
    _beforePreviewPosition = player.position;
    _previewActive = true;
    final done = _previewDone = Completer<void>();
    final loading = loadChapter(
      path: path,
      title: title,
      author: 'Voice preview',
      bookId: '__preview__',
      chapterIndex: 0,
      chapterCount: 1,
    );
    final intent = _intentRevision;
    try {
      await loading;
      if (sequence != _previewSequence || _recording?.bookId != '__preview__') {
        return;
      }
      _publish(
        _Recording(
          path,
          title,
          'Voice preview',
          '__preview__',
          0,
          1,
          preview: true,
        ),
      );
      if (intent == _intentRevision) await play(origin: 'voice preview');
      await done.future;
    } catch (_) {
      if (sequence == _previewSequence) await stopPreview();
      rethrow;
    }
  }

  void _finishPreview() {
    final done = _previewDone;
    _previewDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> stopPreview() async {
    if (!_previewActive) return;
    ++_previewSequence;
    _previewActive = false;
    final restore = _beforePreview;
    final position = _beforePreviewPosition;
    _beforePreview = null;
    _finishPreview();
    if (restore == null) {
      ++_sourceRevision;
      await stop();
      await _serial(() async {
        _recording = null;
        mediaItem.add(null);
      });
    } else {
      await loadChapter(
        path: restore.path,
        title: restore.title,
        author: restore.author,
        bookId: restore.bookId,
        chapterIndex: restore.index,
        chapterCount: restore.count,
        startPosition: position,
        forceReload: true,
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    recordDiagnostic(MediaDiagnosticEvent.handlerDisposed);
    ++_sourceRevision;
    await stop();
    _disposed = true;
    _finishPreview();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _operations;
    await player.dispose();
    diagnosticCommands.dispose();
  }
}
