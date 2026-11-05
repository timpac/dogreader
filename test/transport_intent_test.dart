import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'fake_player.dart';

class SlowPausePlayer extends FakePlayer {
  Completer<void>? pauseGate;
  @override
  Future<void> pause() async {
    if (pauseGate != null) await pauseGate!.future;
    await super.pause();
  }
}

void main() {
  late Directory root;
  late SlowPausePlayer player;
  late DogreaderAudioHandler handler;
  late StreamController<AudioInterruptionEvent> focus;
  late StreamController<void> noisy;
  Future<void> flush() => Future<void>.delayed(Duration.zero);
  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(condition(), isTrue);
  }

  Future<void> load({int chapter = 0}) => handler.loadChapter(
    path: '${root.path}/narration/book_$chapter.mp3',
    title: 'Chapter $chapter',
    author: 'Author',
    bookId: 'book',
    chapterIndex: chapter,
    chapterCount: 3,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dogreader-intent-');
    player = SlowPausePlayer();
    handler = DogreaderAudioHandler(
      player: player,
      documentsDirectory: () async => root,
    );
    focus = StreamController<AudioInterruptionEvent>.broadcast();
    noisy = StreamController<void>.broadcast();
    handler.bindInterruptions(focus.stream, noisy.stream);
  });
  tearDown(() async {
    player.pauseGate = null;
    await handler.dispose();
    await focus.close();
    await noisy.close();
    await root.delete(recursive: true);
  });

  test(
    'Play completes at dispatch even when playback lasts until Pause',
    () async {
      await load();
      player.holdPlayFuture = true;
      await handler.play().timeout(const Duration(seconds: 1));
      expect(player.playback!.isCompleted, isFalse);
      await handler.pause();
      expect(player.playback!.isCompleted, isTrue);
      expect(
        handler.diagnosticCommands.value.any(
          (e) => e.contains('native Pause/Stop acknowledged'),
        ),
        isTrue,
      );
    },
  );

  test('rapid alternating requests end in the latest intent', () async {
    await load();
    final operations = <Future<void>>[];
    for (var i = 0; i < 25; i++) {
      operations.add(handler.play());
      operations.add(handler.pause());
    }
    await Future.wait(operations);
    expect(player.playing, isFalse);
    expect(handler.playbackState.value.controls[1], MediaControl.play);
    await handler.play();
    expect(player.playing, isTrue);
    expect(handler.playbackState.value.controls[1], MediaControl.pause);
  });

  test('a delayed native Pause cannot overwrite a newer Play', () async {
    await load();
    await handler.play();
    player.pauseGate = Completer<void>();
    final pausing = handler.pause();
    final playing = handler.play();
    await flush();
    player.pauseGate!.complete();
    await Future.wait([pausing, playing]);
    player.pauseGate = null;
    expect(player.playing, isTrue);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test(
    'Pause during initial preparation is immediate and stays paused',
    () async {
      player.preparing = Completer<void>();
      final loading = load();
      await waitFor(() => player.loads == 1);
      await handler.pause().timeout(const Duration(seconds: 1));
      player.preparing!.complete();
      await loading;
      expect(player.playing, isFalse);
      expect(player.plays, 0);
    },
  );

  test(
    'Play during preparation is retained until the source is ready',
    () async {
      player.preparing = Completer<void>();
      final loading = load();
      await waitFor(() => player.loads == 1);
      final playing = handler.play();
      player.preparing!.complete();
      await Future.wait([loading, playing]);
      expect(player.playing, isTrue);
      expect(handler.mediaItem.value?.id, 'book:0');
    },
  );

  test(
    'Stop while preparation is pending cannot be undone by its completion',
    () async {
      player.preparing = Completer<void>();
      final loading = load();
      await waitFor(() => player.loads == 1);
      await handler.stop();
      player.preparing!.complete();
      await loading;
      expect(player.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      await handler.play();
      expect(player.playing, isTrue);
    },
  );

  test(
    'completion delivered after a deliberate Pause cannot advance',
    () async {
      await Directory('${root.path}/narration').create();
      await File('${root.path}/narration/book_1.mp3').writeAsBytes([1]);
      await load();
      await handler.play();
      await handler.pause();
      player.complete();
      await flush();
      await flush();
      expect(handler.mediaItem.value?.id, 'book:0');
      expect(player.playing, isFalse);
    },
  );

  test('focus regain resumes only if no deliberate Pause occurred', () async {
    await load();
    await handler.play();
    focus.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await waitFor(() => !player.playing);
    focus.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await waitFor(() => player.playing);
    focus.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await waitFor(() => !player.playing);
    await handler.pause();
    focus.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await flush();
    await flush();
    expect(player.playing, isFalse);
    expect(handler.diagnosticWantsPlayback, isFalse);
  });

  test('headset disconnect cancels focus resumption', () async {
    await load();
    await handler.play();
    focus.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await waitFor(() => !player.playing);
    noisy.add(null);
    await flush();
    focus.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await flush();
    await flush();
    expect(player.playing, isFalse);
  });

  test(
    'decoder recovery releases the old engine and Pause cancels restart',
    () async {
      await load();
      await handler.play();
      player.position = const Duration(seconds: 42);
      await handler.pause();
      player.errors.add(PlayerException(1, 'decoder failed', null));
      await flush();
      player.preparing = Completer<void>();
      final recovering = handler.play();
      await waitFor(() => player.loads == 2);
      expect(player.stops, greaterThan(0));
      await handler.pause();
      player.preparing!.complete();
      await recovering;
      expect(player.playing, isFalse);
      expect(player.position, const Duration(seconds: 42));
    },
  );

  test(
    'preview shares transport and restores chapter progress paused',
    () async {
      await load();
      player.position = const Duration(seconds: 42);
      await handler.play();
      final preview = handler.playPreview(
        '${root.path}/preview.mp3',
        'Voice sample',
      );
      await waitFor(
        () => handler.mediaItem.value?.id == '__preview__:0' && player.playing,
      );
      await handler.pause();
      expect(player.playing, isFalse);
      await handler.play();
      expect(player.playing, isTrue);
      await handler.stopPreview();
      await preview;
      expect(handler.mediaItem.value?.id, 'book:0');
      expect(player.position, const Duration(seconds: 42));
      expect(player.playing, isFalse);
      final progress = jsonDecode(
        await File('${root.path}/narration_state.json').readAsString(),
      ) as Map;
      expect(progress.containsKey('__preview__:0'), isFalse);
      expect(progress['book:0']['positionMs'], 42000);
    },
  );

  test(
    'leaving preview during preparation cannot start a hidden player',
    () async {
      await load();
      player.preparing = Completer<void>();
      final preview = handler.playPreview(
        '${root.path}/preview.mp3',
        'Voice sample',
      );
      await waitFor(() => player.loads == 2);
      final leaving = handler.stopPreview();
      player.preparing!.complete();
      await Future.wait([preview, leaving]);
      expect(handler.mediaItem.value?.id, 'book:0');
      expect(player.playing, isFalse);
    },
  );
}
