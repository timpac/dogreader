import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';

class DogreaderAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player;
  final Future<Directory> Function() _documentsDirectory;
  int _loadGeneration = 0;
  int _transportGeneration = 0;
  int _stopGeneration = 0;
  bool _stopped = true;
  bool _disposed = false;
  int? _playbackError;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String? _chapterKey;
  String? _bookId;
  int? _chapterIndex;
  int? _chapterCount;
  String? _author;
  bool _advancing = false;
  int _lastSavedSecond = -1;
  Future<void> _pendingSave = Future<void>.value();

  // Owned by the handler so progress survives leaving the narration screen.
  Future<void> _savePosition(Duration position) {
    final key = _chapterKey;
    if (key == null) return Future<void>.value();
    final milliseconds = position.inMilliseconds.clamp(0, 2147483647);
    _pendingSave = _pendingSave.catchError((Object _) {}).then((_) async {
      try {
        final root = await _documentsDirectory();
        final file = File('${root.path}/narration_state.json');
        Map<String, dynamic> data = {};
        if (await file.exists()) {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) data = decoded;
        }
        final existing = data[key];
        final chapter = existing is Map
            ? Map<String, dynamic>.from(existing)
            : <String, dynamic>{};
        chapter['positionMs'] = milliseconds;
        data[key] = chapter;
        await file.writeAsString(jsonEncode(data));
      } catch (_) {
        // A failed progress write must not interrupt playback.
      }
    });
    return _pendingSave;
  }

  DogreaderAudioHandler({AudioPlayer? player,
      Future<Directory> Function()? documentsDirectory})
      : player = player ?? AudioPlayer(),
        _documentsDirectory = documentsDirectory ?? getApplicationDocumentsDirectory {
    _subscriptions.add(this.player.positionStream.listen((position) {
      if (_chapterKey == null || _stopped) return;
      final second = position.inSeconds;
      if (second != _lastSavedSecond && second % 5 == 0) {
        _lastSavedSecond = second;
        _savePosition(position);
      }
    }));
    _subscriptions.add(this.player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && !_stopped) {
        unawaited(_advanceToNextChapter());
      }
    }));
    _subscriptions.add(this.player.playbackEventStream.listen(
      (_) => _broadcastPlaybackState(), onError: _recordPlaybackError));
    // Playing can change without a playback event. Keep Android's media
    // session in sync so it advertises the correct play/pause action.
    _subscriptions.add(this.player.playerStateStream.listen((_) => _broadcastPlaybackState()));
    _subscriptions.add(this.player.speedStream.listen((_) => _broadcastPlaybackState()));
    _subscriptions.add(this.player.durationStream.listen((duration) {
      final item = mediaItem.value;
      if (item != null && duration != null && duration > Duration.zero &&
          item.duration != duration) {
        mediaItem.add(item.copyWith(duration: duration));
      }
      _broadcastPlaybackState();
    }));
    _subscriptions.add(this.player.errorStream.listen(_recordPlaybackError));
  }

  final diagnosticCommands = ValueNotifier<List<String>>(<String>[]);
  int diagnosticCommandCount = 0;
  final diagnosticStarted = DateTime.now();

  void _logCommand(String command) {
    diagnosticCommandCount++;
    final entry = '${DateTime.now().toIso8601String()} #$diagnosticCommandCount $command '
        'playing=${player.playing} state=${player.processingState.name} '
        'positionMs=${player.position.inMilliseconds}';
    diagnosticCommands.value = [
      entry, ...diagnosticCommands.value.take(39),
    ];
    debugPrint(jsonEncode({
      'event': 'dogreader_media_command', 'command': command,
      'chapter': _chapterKey, 'playing': player.playing,
      'processing': player.processingState.name,
    }));
  }

  void _recordPlaybackError(Object error) {
    if (_disposed) return;
    _playbackError = error is PlayerException ? error.code : -1;
    debugPrint(jsonEncode({'event': 'dogreader_media_error',
      'chapter': _chapterKey, 'error_type': error.runtimeType.toString(),
      'code': _playbackError}));
    _broadcastPlaybackState();
  }

  void _broadcastPlaybackState() {
      if (_disposed) return;
      final playing = !_stopped && _playbackError == null && player.playing &&
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
          processingState: _stopped ? AudioProcessingState.idle
              : _playbackError != null ? AudioProcessingState.error
              : switch (player.processingState) {
            ProcessingState.idle => AudioProcessingState.idle,
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
              ? 'Recording could not be played. Reopen the chapter or replace its MP3.'
              : null,
        ),
      );
  }

  Future<void> _advanceToNextChapter() async {
    if (_advancing || _stopped || _bookId == null || _chapterIndex == null ||
        _chapterCount == null || _author == null) {
      return;
    }
    _advancing = true;
    final generation = _loadGeneration;
    final transport = _transportGeneration;
    bool current() => generation == _loadGeneration;
    bool continuePlaying() => current() && !_stopped &&
        transport == _transportGeneration;
    var startNext = false;
    try {
      // At EOF just_audio retains playing=true. End in a resumable paused
      // state even when this is the last chapter or the next file is missing.
      await player.pause();
      _broadcastPlaybackState();
      if (!continuePlaying()) return;
      final nextIndex = _chapterIndex! + 1;
      if (nextIndex >= _chapterCount!) return;
      final root = await _documentsDirectory();
      if (!continuePlaying()) return;
      final next = File('${root.path}/narration/${_bookId!}_$nextIndex.mp3');
      if (!await next.exists() || await next.length() == 0) return;
      final oldKey = _chapterKey;
      await _savePosition(Duration.zero);
      await _pendingSave;
      if (_chapterKey != oldKey || !continuePlaying()) return;
      final bookId = _bookId!;
      final author = _author!;
      final count = _chapterCount!;
      await player.setFilePath(next.path, initialPosition: Duration.zero);
      if (!current()) return;
      _chapterKey = '$bookId:$nextIndex';
      _chapterIndex = nextIndex;
      _lastSavedSecond = -1;
      mediaItem.add(MediaItem(
        id: _chapterKey!,
        title: 'Chapter ${nextIndex + 1}',
        album: 'Dogreader',
        artist: author,
        duration: player.duration,
      ));
      _chapterCount = count;
      _broadcastPlaybackState();
      startNext = continuePlaying();
    } catch (error) {
      if (current()) _recordPlaybackError(error);
    } finally {
      _advancing = false;
    }
    // play() completes only at pause/end. Holding _advancing until that
    // Future completes drops the following chapter's completion event.
    if (startNext && continuePlaying()) {
      unawaited(_startPlayback().catchError(_recordPlaybackError));
    }
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
  }) async {
    final generation = ++_loadGeneration;
    ++_transportGeneration;
    final stopped = _stopGeneration;
    bool active() => generation == _loadGeneration &&
        stopped == _stopGeneration && (isCurrent?.call() ?? true);
    if (!active()) return;
    final key = '$bookId:$chapterIndex';
    if (!forceReload && mediaItem.value?.id == key && player.audioSource != null) {
      return;
    }

    await _savePosition(player.position);
    if (!active()) return;
    await player.pause();
    if (!active()) return;
    _chapterKey = null;
    mediaItem.add(null);
    _stopped = false;
    _playbackError = null;
    await player.setFilePath(path, initialPosition: startPosition);
    if (!active()) return;
    _chapterKey = key;
    _bookId = bookId;
    _chapterIndex = chapterIndex;
    _chapterCount = chapterCount;
    _author = author;
    _lastSavedSecond = -1;
    mediaItem.add(
      MediaItem(
        id: key,
        title: title,
        album: 'Dogreader',
        artist: author,
        duration: player.duration,
      ),
    );
    _broadcastPlaybackState();
  }

  Future<void> unloadChapter(String bookId, int index) async {
    if (_chapterKey != '$bookId:$index') return;
    final generation = ++_loadGeneration;
    await stop();
    if (generation != _loadGeneration) return;
    _chapterKey = null;
    _bookId = null;
    _chapterIndex = null;
    mediaItem.add(null);
  }

  @override
  Future<void> play() async {
    _logCommand('play');
    ++_transportGeneration;
    if (_chapterKey == null || player.audioSource == null) return;
    _stopped = false;
    _playbackError = null;
    try {
      if (player.processingState == ProcessingState.completed) {
        await player.seek(Duration.zero);
      }
      await _startPlayback();
    } catch (error) {
      _recordPlaybackError(error);
      rethrow;
    }
  }

  Future<void> _startPlayback() async {
    final playing = player.play();
    _broadcastPlaybackState();
    await playing;
    _broadcastPlaybackState();
  }

  @override
  Future<void> pause() async {
    _logCommand('pause');
    ++_transportGeneration;
    await player.pause();
    _broadcastPlaybackState();
    await _savePosition(player.position);
  }

  @override
  Future<void> stop() async {
    _logCommand('stop');
    ++_transportGeneration;
    ++_stopGeneration;
    _stopped = true;
    _playbackError = null;
    // Never leave idle+playing=true in Android, even if the native player
    // emits no event. Stop immediately instead of waiting on a disk write.
    _broadcastPlaybackState();
    final saved = _savePosition(player.position);
    try {
      await player.stop();
    } finally {
      _broadcastPlaybackState();
      await saved;
    }
  }

  @override
  Future<void> seek(Duration position) async {
    _logCommand('seek');
    ++_transportGeneration;
    final end = player.duration;
    var target = position < Duration.zero ? Duration.zero : position;
    if (end != null && end > Duration.zero && target > end) target = end;
    final key = _chapterKey;
    final generation = _loadGeneration;
    await player.seek(target);
    _broadcastPlaybackState();
    if (key == _chapterKey && generation == _loadGeneration) {
      await _savePosition(player.position);
    }
  }

  @override
  Future<void> rewind() => seek(player.position - const Duration(seconds: 15));

  @override
  Future<void> fastForward() =>
      seek(player.position + const Duration(seconds: 30));

  @override
  Future<void> setSpeed(double speed) async {
    _logCommand('speed');
    await player.setSpeed(speed);
    _broadcastPlaybackState();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    ++_loadGeneration;
    await stop();
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }
}
