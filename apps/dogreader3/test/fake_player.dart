import 'dart:async';
import 'package:just_audio/just_audio.dart';

class FakePlayer implements AudioPlayer {
  final positions = StreamController<Duration>.broadcast();
  final processing = StreamController<ProcessingState>.broadcast();
  final events = StreamController<PlaybackEvent>.broadcast();
  final states = StreamController<PlayerState>.broadcast();
  final durations = StreamController<Duration?>.broadcast();
  final speeds = StreamController<double>.broadcast();
  final errors = StreamController<PlayerException>.broadcast();
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration = const Duration(seconds: 100);
  @override
  bool playing = false;
  @override
  AudioSource? audioSource;
  @override
  double speed = 1;
  @override
  Duration get bufferedPosition => position;
  @override
  ProcessingState processingState = ProcessingState.ready;
  int loads = 0;
  int stops = 0;
  int plays = 0;
  bool emitStateOnStop = true;
  bool holdPlayFuture = false;
  Object? pauseError;
  Object? loadError;
  Completer<void>? playback;
  bool ignoreSeek = false;
  Completer<void>? preparing;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<ProcessingState> get processingStateStream => processing.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<double> get speedStream => speeds.stream;
  @override
  Stream<PlayerException> get errorStream => errors.stream;

  void emitState() => states.add(PlayerState(playing, processingState));

  void complete() {
    processingState = ProcessingState.completed;
    processing.add(processingState);
    emitState();
    if (playback != null && !playback!.isCompleted) playback!.complete();
  }
  @override
  Future<Duration?> setFilePath(String filePath, {Duration? initialPosition, bool preload = true, dynamic tag}) async {
    loads++;
    if (preparing != null) await preparing!.future;
    if (loadError != null) throw loadError!;
    audioSource = AudioSource.uri(Uri.file(filePath));
    position = initialPosition ?? Duration.zero;
    processingState = ProcessingState.ready;
    emitState();
    return duration;
  }
  @override
  Future<void> pause() async {
    if (pauseError != null) {
      position = Duration.zero;
      throw pauseError!;
    }
    playing = false;
    emitState();
    if (playback != null && !playback!.isCompleted) playback!.complete();
  }
  @override
  Future<void> play() {
    playing = true;
    plays++;
    if (processingState == ProcessingState.idle) {
      processingState = ProcessingState.ready;
    }
    emitState();
    if (!holdPlayFuture) return Future<void>.value();
    playback = Completer<void>();
    return playback!.future;
  }
  @override
  Future<void> stop() async {
    playing = false;
    stops++;
    processingState = ProcessingState.idle;
    if (emitStateOnStop) emitState();
    if (playback != null && !playback!.isCompleted) playback!.complete();
  }
  @override
  Future<void> seek(Duration? target, {int? index}) async {
    if (!ignoreSeek) {
      position = target ?? Duration.zero;
      if (processingState == ProcessingState.completed) {
        processingState = ProcessingState.ready;
      }
      emitState();
    }
  }
  @override
  Future<void> setSpeed(double value) async {
    speed = value;
    speeds.add(value);
  }
  @override
  Future<void> dispose() async {
    await positions.close();
    await processing.close();
    await events.close();
    await states.close();
    await durations.close();
    await speeds.close();
    await errors.close();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

