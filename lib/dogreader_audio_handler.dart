import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';

class DogreaderAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer();
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
        final root = await getApplicationDocumentsDirectory();
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

  DogreaderAudioHandler() {
    player.positionStream.listen((position) {
      if (_chapterKey == null) return;
      final second = position.inSeconds;
      if (second != _lastSavedSecond && second % 5 == 0) {
        _lastSavedSecond = second;
        _savePosition(position);
      }
    });
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _advanceToNextChapter();
      }
    });
    player.playbackEventStream.listen((event) {
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            MediaControl.rewind,
            player.playing ? MediaControl.pause : MediaControl.play,
            MediaControl.fastForward,
            MediaControl.stop,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
          processingState: switch (player.processingState) {
            ProcessingState.idle => AudioProcessingState.idle,
            ProcessingState.loading => AudioProcessingState.loading,
            ProcessingState.buffering => AudioProcessingState.buffering,
            ProcessingState.ready => AudioProcessingState.ready,
            ProcessingState.completed => AudioProcessingState.completed,
          },
          playing: player.playing,
          updatePosition: player.position,
          bufferedPosition: player.bufferedPosition,
          speed: player.speed,
        ),
      );
    });
  }

  Future<void> _advanceToNextChapter() async {
    if (_advancing || _bookId == null || _chapterIndex == null ||
        _chapterCount == null || _author == null) return;
    final nextIndex = _chapterIndex! + 1;
    if (nextIndex >= _chapterCount!) return;
    _advancing = true;
    try {
      final root = await getApplicationDocumentsDirectory();
      final next = File('${root.path}/narration/${_bookId!}_$nextIndex.mp3');
      if (!await next.exists() || await next.length() == 0) return;
      final oldKey = _chapterKey;
      await _savePosition(Duration.zero);
      await _pendingSave;
      if (_chapterKey != oldKey) return;
      final bookId = _bookId!;
      final author = _author!;
      final count = _chapterCount!;
      await player.setFilePath(next.path, initialPosition: Duration.zero);
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
      await player.play();
    } catch (_) {
      // Missing or unreadable next chapters should stop gracefully.
    } finally {
      _advancing = false;
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
  }) async {
    final key = '$bookId:$chapterIndex';
    if (mediaItem.value?.id == key && player.audioSource != null) {
      return;
    }

    await _savePosition(player.position);
    await player.pause();
    await player.setFilePath(path, initialPosition: startPosition);
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
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() async {
    await player.pause();
    await _savePosition(player.position);
  }

  @override
  Future<void> stop() async {
    await _savePosition(player.position);
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    final end = player.duration;
    var target = position < Duration.zero ? Duration.zero : position;
    if (end != null && target > end) target = end;
    await player.seek(target);
    await _savePosition(target);
  }

  @override
  Future<void> rewind() => seek(player.position - const Duration(seconds: 15));

  @override
  Future<void> fastForward() =>
      seek(player.position + const Duration(seconds: 30));

  @override
  Future<void> setSpeed(double speed) => player.setSpeed(speed);
}
