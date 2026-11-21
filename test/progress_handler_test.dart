import 'dart:async';
import 'dart:io';

import 'package:audiobook_app/book_progress.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_player.dart';

void main() {
  late Directory root;
  late FakePlayer player;
  late BookProgress progress;
  late DogreaderAudioHandler handler;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('progress-handler-');
    player = FakePlayer();
    progress = BookProgress(documentsDirectory: () async => root);
    handler = DogreaderAudioHandler(
      player: player,
      documentsDirectory: () async => root,
      progress: progress,
    );
  });
  tearDown(() async {
    await handler.dispose();
    await progress.flushed;
    progress.dispose();
    await root.delete(recursive: true);
  });
  Future<void> load(
    int chapter, {
    Duration start = Duration.zero,
    int count = 9,
    bool Function()? isCurrent,
  }) => handler.loadChapter(
    path: '${root.path}/narration/book_$chapter.mp3',
    title: 'Section ${chapter + 1}',
    author: 'Author',
    bookId: 'book',
    chapterIndex: chapter,
    chapterCount: count,
    startPosition: start,
    isCurrent: isCurrent,
  );
  Future<void> waitUntil(bool Function() ready) async {
    for (var i = 0; i < 1000 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(ready(), isTrue);
    await progress.flushed;
  }

  test('background section 7 to 8 commits completed old and active new section immediately', () async {
    await Directory('${root.path}/narration').create();
    await File('${root.path}/narration/book_7.mp3').writeAsBytes([1]);
    await progress.saveReading('book', 6, 42);
    await load(6, start: const Duration(seconds: 90));
    await handler.play();
    player.position = const Duration(seconds: 100);
    player.complete();
    await waitUntil(
      () => handler.mediaItem.value?.id == 'book:7' && player.playing,
    );
    expect(progress.continuePosition('book')!['chapter'], 7);
    expect(progress.audioSection('book', 6)['positionMs'], 100000);
    expect(progress.audioSection('book', 6)['completed'], isTrue);
    expect(progress.audioSection('book', 7)['positionMs'], 0);
    expect(progress.readingPosition('book'), {'chapter': 6, 'offset': 42});
    final restored = BookProgress(documentsDirectory: () async => root);
    await restored.load();
    expect(restored.listeningChapter('book'), 7);
    restored.dispose();
  });

  test(
    'external pause in section 8 persists exact observed timestamp for restart',
    () async {
      await load(7);
      await handler.play();
      player.position = const Duration(milliseconds: 32875);
      await handler.pause();
      final restored = BookProgress(documentsDirectory: () async => root);
      await restored.load();
      expect(restored.audioSection('book', 7)['positionMs'], 32875);
      expect(restored.continuePosition('book')!['chapter'], 7);
      final newPlayer = FakePlayer();
      final newHandler = DogreaderAudioHandler(
        player: newPlayer,
        documentsDirectory: () async => root,
        progress: restored,
      );
      await newHandler.loadChapter(
        path: 'existing.mp3',
        title: 'Section 8',
        author: 'Author',
        bookId: 'book',
        chapterIndex: restored.listeningChapter('book')!,
        chapterCount: 9,
        startPosition: Duration(
          milliseconds: restored.audioSection('book', 7)['positionMs'] as int,
        ),
      );
      expect(newPlayer.position.inMilliseconds, 32875);
      await newHandler.dispose();
      restored.dispose();
    },
  );

  test('position events skipping multiples of five still checkpoint within five seconds', () async {
    await load(7);
    await handler.play();
    for (final ms in [6123, 11999]) {
      player.position = Duration(milliseconds: ms);
      player.positions.add(player.position);
      await Future<void>.delayed(Duration.zero);
      await progress.flushed;
    }
    // No dispose, pause, UI or lifecycle callback before this disk read.
    final restored = BookProgress(documentsDirectory: () async => root);
    await restored.load();
    expect(restored.audioSection('book', 7)['positionMs'], 11999);
    expect(restored.continuePosition('book')!['chapter'], 7);
    restored.dispose();
  });

  test('audio to reading retains both resumes and opening earlier audio cannot erase later progress', () async {
    await load(7, start: const Duration(seconds: 55));
    await handler.play();
    await handler.pause();
    await progress.saveReading('book', 3, 68);
    await load(2, start: const Duration(seconds: 10));
    player.positions.add(player.position); // Prepared, but never played.
    await Future<void>.delayed(Duration.zero);
    await progress.flushed;
    await handler.pause(); // Redundant external Pause is not listening.
    expect(progress.continuePosition('book')!['chapter'], 3);
    expect(progress.listeningChapter('book'), 7);
    expect(progress.audioSection('book', 7)['positionMs'], 55000);
    expect(progress.furthestChapter('book'), 7);
    await handler.play();
    await progress.flushed;
    expect(progress.listeningChapter('book'), 2);
    expect(progress.audioSection('book', 7)['positionMs'], 55000);
  });

  test('lifecycle and task removal checkpoint without stopping background playback', () async {
    await load(7);
    await handler.play();
    player.position = const Duration(milliseconds: 12345);
    handler.didChangeAppLifecycleState(AppLifecycleState.paused);
    await progress.flushed;
    expect(progress.audioSection('book', 7)['positionMs'], 12345);
    expect(player.playing, isTrue);
    player.position = const Duration(milliseconds: 14321);
    await handler.onTaskRemoved();
    expect(progress.audioSection('book', 7)['positionMs'], 14321);
    expect(player.playing, isTrue);
  });

  test(
    'focus interruption saves without requiring screen or explicit Pause',
    () async {
      final focus = StreamController<AudioInterruptionEvent>();
      final noisy = StreamController<void>();
      handler.bindInterruptions(focus.stream, noisy.stream);
      await load(7);
      await handler.play();
      player.position = const Duration(milliseconds: 24321);
      focus.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await waitUntil(() => !player.playing);
      expect(progress.audioSection('book', 7)['positionMs'], 24321);
      await focus.close();
      await noisy.close();
    },
  );

  test(
    'rapid loads cannot attribute old position to a newer chapter',
    () async {
      await load(6, start: const Duration(seconds: 39));
      await handler.play();
      final loads = [
        load(2),
        load(4),
        load(7, start: const Duration(seconds: 18)),
      ];
      await Future.wait(loads);
      await handler.play();
      await handler.pause();
      expect(handler.mediaItem.value?.id, 'book:7');
      expect(progress.audioSection('book', 6)['positionMs'], 39000);
      expect(progress.audioSection('book', 7)['positionMs'], 18000);
      expect(progress.listeningChapter('book'), 7);
    },
  );

  test(
    'final section completion remains complete after stop and restart',
    () async {
      await load(7, count: 8);
      await handler.play();
      player.position = const Duration(seconds: 100);
      player.complete();
      await waitUntil(() => !handler.diagnosticWantsPlayback);
      await handler.stop();
      final restored = BookProgress(documentsDirectory: () async => root);
      await restored.load();
      expect(restored.listeningChapter('book'), 7);
      expect(restored.audioSection('book', 7)['positionMs'], 100000);
      expect(restored.sectionFraction('book', 7, 200), 1);
      expect(restored.audioSection('book', 7)['completed'], isTrue);
      restored.dispose();
    },
  );
}
