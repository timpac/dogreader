import 'dart:io';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_player.dart';

// just_audio.pause() returns early when its Dart playing flag is false.
// Keep output separate, so changing an icon cannot pass this regression.
class DriftedPlayer extends FakePlayer {
  bool outputActive = false;
  @override
  Future<void> play() {
    outputActive = true;
    return super.play();
  }
  @override
  Future<void> pause() async {
    if (!playing) return;
    outputActive = false;
    await super.pause();
  }
  @override
  Future<void> stop() async {
    outputActive = false;
    await super.stop();
  }
}

void main() {
  test('Pause reaches native output even when Dart already reports paused', () async {
    final root = await Directory.systemTemp.createTemp('dogreader-boundary-');
    final player = DriftedPlayer();
    final handler = DogreaderAudioHandler(player: player, documentsDirectory: () async => root);
    try {
      await handler.loadChapter(path: '${root.path}/book.mp3', title: 'Chapter',
          author: 'Author', bookId: 'book', chapterIndex: 0, chapterCount: 1);
      await handler.play();
      player.playing = false;
      expect(player.outputActive, isTrue);
      await handler.pause();
      expect(player.outputActive, isFalse);
      expect(player.stops, greaterThan(0));
      expect(handler.playbackState.value.playing, isFalse);
      await handler.play();
      expect(player.outputActive, isTrue);
    } finally {
      await handler.dispose();
      await root.delete(recursive: true);
    }
  });
}
