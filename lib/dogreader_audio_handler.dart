import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

class DogreaderAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer();

  DogreaderAudioHandler() {
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

  Future<void> loadChapter({
    required String path,
    required String title,
    required String author,
    required String bookId,
    required int chapterIndex,
    Duration startPosition = Duration.zero,
  }) async {
    if (mediaItem.value?.id == '$bookId:$chapterIndex' &&
        player.audioSource != null) {
      return;
    }

    await player.pause();
    await player.setFilePath(path, initialPosition: startPosition);
    mediaItem.add(
      MediaItem(
        id: '$bookId:$chapterIndex',
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
  Future<void> pause() => player.pause();

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> rewind() => seek(player.position - const Duration(seconds: 15));

  @override
  Future<void> fastForward() =>
      seek(player.position + const Duration(seconds: 30));

  @override
  Future<void> setSpeed(double speed) => player.setSpeed(speed);
}
