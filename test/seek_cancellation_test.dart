import 'dart:async';
import 'dart:io';

import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_audio/just_audio.dart';

import 'fake_player.dart';

// Android just_audio completes Seek on READY; dispose() can drop that callback.
class LostSeekPlayer extends FakePlayer {
  final seeking = Completer<void>();
  final seekReply = Completer<void>();
  @override
  Future<void> seek(Duration? target, {int? index}) async {
    if (processingState == ProcessingState.idle) {
      return super.seek(target, index: index);
    }
    // Real just_audio publishes its requested position before native READY.
    position = target ?? Duration.zero;
    if (!seeking.isCompleted) seeking.complete();
    await seekReply.future;
  }
}

void main() {
  test(
    'Pause releases an outstanding Seek so a subsequent Play can run',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dogreader-lost-seek-',
      );
      final player = LostSeekPlayer();
      final handler = DogreaderAudioHandler(
        player: player,
        documentsDirectory: () async => root,
      );
      var seekCompleted = false;
      try {
        await handler.loadChapter(
          path: '${root.path}/book.mp3',
          title: 'Chapter',
          author: 'Author',
          bookId: 'book',
          chapterIndex: 0,
          chapterCount: 1,
        );
        await handler.play();
        player.position = const Duration(seconds: 42);
        final seeking = handler
            .seek(const Duration(seconds: 90))
            .then((_) => seekCompleted = true);
        await player.seeking.future;
        await handler.pause();
        final playing = handler.play();
        await Future.any([
          playing,
          Future<void>.delayed(const Duration(seconds: 1)),
        ]);
        final cancelled = seekCompleted;
        final resumed = player.playing;
        // Always unblock the baseline's queue so a failing assertion can tear down.
        player.seekReply.complete();
        await seeking;
        await playing;
        expect(
          cancelled,
          isTrue,
          reason: 'Released engine cannot deliver its outstanding callback',
        );
        expect(
          resumed,
          isTrue,
          reason: 'Play must not wait for a dead native Seek',
        );
      } finally {
        if (!player.seekReply.isCompleted) player.seekReply.complete();
        await handler.dispose();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'chapter navigation cancels a dead Seek and ignores its late error',
    () async {
      final root = await Directory.systemTemp.createTemp('dogreader-seek-nav-');
      final player = LostSeekPlayer();
      final handler = DogreaderAudioHandler(
        player: player,
        documentsDirectory: () async => root,
      );
      Future<void> load(int chapter) => handler.loadChapter(
        path: '${root.path}/book_$chapter.mp3',
        title: 'Chapter $chapter',
        author: 'Author',
        bookId: 'book',
        chapterIndex: chapter,
        chapterCount: 2,
        startPosition: const Duration(seconds: 7),
      );
      try {
        await load(0);
        await handler.play();
        final seeking = handler.seek(const Duration(seconds: 90));
        await player.seeking.future;
        await load(1).timeout(const Duration(seconds: 1));
        await seeking;
        expect(handler.mediaItem.value?.id, 'book:1');
        expect(player.position, const Duration(seconds: 7));
        player.seekReply.completeError(
          StateError('reply from released native engine'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(handler.playbackState.value.errorCode, isNull);
        await handler.play();
        expect(player.playing, isTrue);
      } finally {
        if (!player.seekReply.isCompleted) player.seekReply.complete();
        await handler.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'a hung external Seek times out, silences output, and permits Play',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dogreader-seek-timeout-',
      );
      final player = LostSeekPlayer();
      final handler = DogreaderAudioHandler(
        player: player,
        documentsDirectory: () async => root,
      );
      try {
        await handler.loadChapter(
          path: '${root.path}/book.mp3',
          title: 'Chapter',
          author: 'Author',
          bookId: 'book',
          chapterIndex: 0,
          chapterCount: 1,
        );
        await handler.play();
        player.position = const Duration(seconds: 42);
        await expectLater(
          handler.seek(const Duration(seconds: 90)),
          throwsA(isA<TimeoutException>()),
        );
        expect(player.playing, isFalse);
        expect(player.stops, greaterThan(0));
        await handler.play().timeout(const Duration(seconds: 1));
        expect(player.playing, isTrue);
        expect(player.position, const Duration(seconds: 42));
        player.seekReply.completeError(StateError('late timeout reply'));
        await Future<void>.delayed(Duration.zero);
        expect(handler.playbackState.value.errorCode, isNull);
      } finally {
        if (!player.seekReply.isCompleted) player.seekReply.complete();
        await handler.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
