import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';

import 'fake_player.dart';

void main() {
  late Directory root;
  late FakePlayer player;
  late DogreaderAudioHandler handler;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> load({int chapter = 0, int count = 1}) => handler.loadChapter(
    path: '${root.path}/narration/book_$chapter.mp3',
    title: 'Chapter ${chapter + 1}',
    author: 'Author',
    bookId: 'book',
    chapterIndex: chapter,
    chapterCount: count,
  );

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dogreader-system-controls-');
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

  test('play/pause-only events update the media session without a screen', () async {
    await load();
    await handler.play();
    await flush();
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.controls[1], MediaControl.pause);
    await handler.pause();
    await flush();
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1], MediaControl.play);
  });

  test('Play reloads a failed source at the listening position', () async {
    await load();
    player.position = const Duration(minutes: 42);
    player.processingState = ProcessingState.idle;
    player.errors.add(PlayerException(42, 'decoder failed', null));
    await flush();
    await handler.play();
    expect(player.loads, 2);
    expect(player.position, const Duration(minutes: 42));
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.errorCode, isNull);
    expect(handler.diagnosticLastError, contains('decoder failed'));
    expect(handler.diagnosticCommandCount, 1);
  });

  test('Pause during recovery prevents playback after loading completes', () async {
    await load();
    player.processingState = ProcessingState.idle;
    player.preparing = Completer<void>();
    final recovering = handler.play();
    await waitFor(() => player.loads == 2);
    await handler.pause();
    player.preparing!.complete();
    await recovering;
    expect(player.plays, 0);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('failed recovery is reported without an unhandled media callback error', () async {
    await load();
    player.processingState = ProcessingState.idle;
    player.loadError = PlayerException(43, 'decoder unavailable', null);
    await handler.play();
    expect(handler.playbackState.value.processingState, AudioProcessingState.error);
    expect(handler.playbackState.value.controls[1], MediaControl.play);
    expect(player.plays, 0);
    expect(handler.diagnosticLastError, contains('decoder unavailable'));
  });

  test('Pause saves the position even when the native player fails', () async {
    await load();
    player.position = const Duration(seconds: 73);
    player.pauseError = PlayerException(44, 'pause failed', null);
    await handler.pause();
    expect(await File('${root.path}/narration_state.json').readAsString(),
        contains('73000'));
    expect(handler.playbackState.value.processingState, AudioProcessingState.error);
    player.pauseError = null;
  });

  test('diagnostic errors redact paths and URLs without changing command count', () async {
    await load();
    player.errors.add(PlayerException(45,
        'Cannot read /data/user/0/private.mp3 https://example.com/token', null));
    await flush();
    expect(handler.diagnosticLastError, contains('Cannot read'));
    expect(handler.diagnosticLastError, isNot(contains('/data/user')));
    expect(handler.diagnosticLastError, isNot(contains('example.com')));
    expect(handler.diagnosticCommandCount, 0);
  });

  test('media-button toggle dispatches through the published playing state', () async {
    await load();
    await handler.click();
    expect(player.playing, isTrue);
    await handler.click();
    expect(player.playing, isFalse);
    player.position = player.duration!;
    player.processingState = ProcessingState.completed;
    player.emitState();
    await flush();
    await handler.click();
    expect(player.position, Duration.zero);
    expect(player.playing, isTrue);
  });

  test('notification seeks clamp at zero and the known end', () async {
    await load();
    player.duration = null;
    await handler.rewind();
    expect(player.position, Duration.zero);
    player.duration = const Duration(seconds: 20);
    player.position = const Duration(seconds: 15);
    await handler.fastForward();
    expect(player.position, const Duration(seconds: 20));
    await handler.seek(const Duration(seconds: -10));
    expect(player.position, Duration.zero);
  });

  test('stop publishes idle and not-playing even without a native event', () async {
    await load();
    await handler.play();
    await flush();
    player.emitStateOnStop = false;
    await handler.stop();
    expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1], MediaControl.play);
    await handler.play();
    await flush();
    expect(handler.playbackState.value.processingState, AudioProcessingState.ready);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test('final completion publishes Play and replay starts at zero', () async {
    await load();
    await handler.play();
    player.position = player.duration!;
    player.complete();
    await flush();
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1], MediaControl.play);
    await handler.play();
    expect(player.position, Duration.zero);
    expect(player.playing, isTrue);
  });

  test('missing next recording ends paused with working replay', () async {
    await load(count: 2);
    await handler.play();
    player.position = player.duration!;
    player.complete();
    await flush();
    await flush();
    expect(handler.playbackState.value.playing, isFalse);
    await handler.play();
    expect(player.position, Duration.zero);
    expect(handler.mediaItem.value?.id, 'book:0');
  });

  test('notification metadata updates when duration arrives late', () async {
    player.duration = null;
    await load();
    player.duration = const Duration(minutes: 7);
    player.durations.add(player.duration);
    await flush();
    expect(handler.mediaItem.value?.duration, const Duration(minutes: 7));
  });

  test('speed changes publish without waiting for another playback event', () async {
    await load();
    await handler.setSpeed(1.5);
    await flush();
    expect(handler.playbackState.value.speed, 1.5);
  });

  test('asynchronous decoder failure publishes a safe media error', () async {
    await load();
    await handler.play();
    player.errors.add(PlayerException(42, 'private file path', null));
    await flush();
    expect(handler.playbackState.value.processingState, AudioProcessingState.error);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.errorCode, 42);
    expect(handler.playbackState.value.errorMessage, isNot(contains('private file path')));
  });

  test('continuous playback advances more than once with long play futures', () async {
    await Directory('${root.path}/narration').create();
    for (final chapter in [1, 2]) {
      await File('${root.path}/narration/book_$chapter.mp3').writeAsBytes([1]);
    }
    await load(count: 3);
    player.holdPlayFuture = true;
    final playing = handler.play();
    await flush();
    player.complete();
    await waitFor(() => handler.mediaItem.value?.id == 'book:1' && player.plays == 2);
    player.complete();
    await waitFor(() => handler.mediaItem.value?.id == 'book:2' && player.plays == 3);
    await handler.pause();
    await playing;
  });

  test('pause while next chapter is preparing prevents automatic restart', () async {
    await Directory('${root.path}/narration').create();
    await File('${root.path}/narration/book_1.mp3').writeAsBytes([1]);
    await load(count: 2);
    await handler.play();
    player.preparing = Completer<void>();
    player.complete();
    await waitFor(() => player.loads == 2);
    await handler.pause();
    player.preparing!.complete();
    await waitFor(() => handler.mediaItem.value?.id == 'book:1');
    await flush();
    expect(player.playing, isFalse);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('stop during next preparation cannot resurrect the media session', () async {
    await Directory('${root.path}/narration').create();
    await File('${root.path}/narration/book_1.mp3').writeAsBytes([1]);
    await load(count: 2);
    await handler.play();
    player.preparing = Completer<void>();
    player.complete();
    await waitFor(() => player.loads == 2);
    await handler.stop();
    player.preparing!.complete();
    await flush();
    await flush();
    expect(player.playing, isFalse);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
    // A source that finishes preparing after Stop must retain matching
    // metadata. If replay is requested later it must not play chapter 2
    // while Android still announces chapter 1.
    expect(handler.mediaItem.value?.id, 'book:1');
    await handler.play();
    expect((player.audioSource as UriAudioSource).uri.path, endsWith('book_1.mp3'));
    expect(handler.mediaItem.value?.id, 'book:1');
  });
}

