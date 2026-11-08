import 'dart:async';
import 'dart:io';

import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'fake_player.dart';

// Each prepare owns its own gate: a later load can finish before an older one.
class ReorderingPlayer extends FakePlayer {
  final firstLoad = Completer<void>();
  int requests = 0;
  @override
  Future<Duration?> setFilePath(
    String path, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    if (++requests == 1) await firstLoad.future;
    return super.setFilePath(path, initialPosition: initialPosition);
  }
}

void main() {
  late Directory root;
  late FakePlayer player;
  late DogreaderAudioHandler handler;
  Future<void> flush() => Future<void>.delayed(Duration.zero);
  Future<void> load(int chapter) => handler.loadChapter(
    path: '${root.path}/book_$chapter.mp3',
    title: 'Chapter $chapter',
    author: 'Author',
    bookId: 'book',
    chapterIndex: chapter,
    chapterCount: 3,
  );
  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dogreader-ownership-');
    player = FakePlayer();
    handler = DogreaderAudioHandler(
      player: player,
      documentsDirectory: () async => root,
    );
  });
  tearDown(() async {
    await handler.dispose();
    await root.delete(recursive: true);
  });

  test(
    'latest chapter source and session agree after reordered preparation',
    () async {
      await handler.dispose();
      final reordering = ReorderingPlayer();
      player = reordering;
      handler = DogreaderAudioHandler(
        player: player,
        documentsDirectory: () async => root,
      );
      final older = load(0);
      await waitFor(() => reordering.requests == 1);
      final newer = load(1);
      // Give an unserialized implementation time to prepare the newer source.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      reordering.firstLoad.complete();
      await Future.wait([older, newer]);
      expect(handler.mediaItem.value?.id, 'book:1');
      expect(
        (player.audioSource as UriAudioSource).uri.path,
        endsWith('book_1.mp3'),
      );
    },
  );

  test(
    'native Pause failure must stop output before reporting success',
    () async {
      await load(0);
      await handler.play();
      player.pauseError = PlayerException(
        1,
        'MediaCodecAudioRenderer error',
        null,
      );
      await handler.pause();
      expect(
        player.playing,
        isFalse,
        reason: 'An error icon does not stop audio',
      );
      expect(player.stops, greaterThan(0));
      player.pauseError = null;
    },
  );

  test('unsolicited resume after explicit Pause is stopped', () async {
    await load(0);
    await handler.play();
    await handler.pause();
    // Models just_audio interruption recovery, which calls play internally.
    player.playing = true;
    player.emitState();
    await flush();
    await flush();
    expect(player.playing, isFalse);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('old play failure cannot poison a newly loaded source', () async {
    await load(0);
    player.holdPlayFuture = true;
    final oldPlay = handler.play();
    await flush();
    final oldPlayback = player.playback!;
    // Keep the old operation pending across the source change, as platform
    // callbacks can arrive after a decoder has been released.
    player.playback = null;
    await load(1);
    player.holdPlayFuture = false;
    await handler.play();
    oldPlayback.completeError(PlayerException(1, 'old decoder failed', null));
    await oldPlay;
    await flush();
    expect(player.playing, isTrue);
    expect(handler.mediaItem.value?.id, 'book:1');
    expect(handler.playbackState.value.errorCode, isNull);
    expect(handler.playbackState.value.playing, isTrue);
  });
}
