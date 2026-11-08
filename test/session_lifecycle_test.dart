import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'fake_player.dart';

class IdleDuringPreparePlayer extends FakePlayer {
  @override
  Future<Duration?> setFilePath(
    String path, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    processingState = ProcessingState.idle;
    emitState();
    await Future<void>.delayed(Duration.zero);
    return super.setFilePath(path, initialPosition: initialPosition);
  }
}

void main() {
  late Directory root;
  late IdleDuringPreparePlayer player;
  late DogreaderAudioHandler handler;
  late List<AudioProcessingState> published;
  late StreamSubscription<PlaybackState> subscription;
  Future<void> flush() => Future<void>.delayed(Duration.zero);
  Future<void> load(int chapter) => handler.loadChapter(
    path: '${root.path}/book_$chapter.mp3',
    title: 'Chapter',
    author: 'Author',
    bookId: 'book',
    chapterIndex: chapter,
    chapterCount: 2,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dogreader-session-life-');
    player = IdleDuringPreparePlayer();
    handler = DogreaderAudioHandler(
      player: player,
      documentsDirectory: () async => root,
    );
    published = [];
    subscription = handler.playbackState.listen(
      (s) => published.add(s.processingState),
    );
    await load(0);
    await handler.play();
    await flush();
    published.clear();
  });
  tearDown(() async {
    await subscription.cancel();
    await handler.dispose();
    await root.delete(recursive: true);
  });

  // audio_service Android interprets a non-idle -> idle publication as stopSelf(),
  // releases its MediaSession and clears the static native callback listener.
  // These test that application-level lifecycle contract, not Android UI delivery.
  test(
    'a player idle event before its decoder error cannot terminate the session',
    () async {
      player.processingState = ProcessingState.idle;
      player.emitState();
      await flush();
      player.errors.add(
        PlayerException(1, 'renderer error delivered later', null),
      );
      await flush();
      expect(published, isNot(contains(AudioProcessingState.idle)));
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
    },
  );
  test(
    'decoder recovery cannot publish a service shutdown while preparing',
    () async {
      player.errors.add(PlayerException(1, 'renderer failure', null));
      await flush();
      published.clear();
      await handler.play();
      await flush();
      expect(player.playing, isTrue);
      expect(published, isNot(contains(AudioProcessingState.idle)));
      await handler.pause();
      expect(player.playing, isFalse);
    },
  );
  test('chapter preparation keeps the media session alive', () async {
    await load(1);
    await flush();
    expect(published, isNot(contains(AudioProcessingState.idle)));
    expect(handler.mediaItem.value?.id, 'book:1');
  });
  test(
    'Pause during idle preparation keeps a resumable session without autoplay',
    () async {
      player.preparing = Completer<void>();
      final loading = load(1);
      for (var i = 0; i < 100 && player.loads != 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(player.loads, 2);
      await handler.pause();
      player.preparing!.complete();
      await loading;
      await flush();
      expect(published, isNot(contains(AudioProcessingState.idle)));
      expect(player.playing, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
      player.preparing = null;
      await handler.play();
      expect(player.playing, isTrue);
    },
  );
  test('automatic chapter transition does not terminate the session', () async {
    final next = File('${root.path}/narration/book_1.mp3');
    await next.parent.create();
    await next.writeAsBytes([1]);
    player.complete();
    for (var i = 0; i < 100 && handler.mediaItem.value?.id != 'book:1'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await flush();
    expect(handler.mediaItem.value?.id, 'book:1');
    expect(published, isNot(contains(AudioProcessingState.idle)));
    expect(player.playing, isTrue);
  });
  test('explicit Stop still publishes idle and silences playback', () async {
    await handler.stop();
    await flush();
    expect(published, contains(AudioProcessingState.idle));
    expect(player.playing, isFalse);
  });
}
