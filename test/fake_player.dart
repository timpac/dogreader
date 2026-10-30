import 'dart:async';
import 'package:just_audio/just_audio.dart';

class FakePlayer implements AudioPlayer {
  final positions = StreamController<Duration>.broadcast();
  final processing = StreamController<ProcessingState>.broadcast();
  final events = StreamController<PlaybackEvent>.broadcast();
  final states = StreamController<PlayerState>.broadcast();
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
  Stream<Duration?> get durationStream => Stream.value(duration);
  @override
  Future<Duration?> setFilePath(String filePath, {Duration? initialPosition, bool preload = true, dynamic tag}) async {
    loads++;
    if (preparing != null) await preparing!.future;
    audioSource = AudioSource.uri(Uri.file(filePath));
    position = initialPosition ?? Duration.zero;
    return duration;
  }
  @override
  Future<void> pause() async { playing = false; }
  @override
  Future<void> play() async { playing = true; }
  @override
  Future<void> stop() async { playing = false; stops++; }
  @override
  Future<void> seek(Duration? target, {int? index}) async {
    if (!ignoreSeek) position = target ?? Duration.zero;
  }
  @override
  Future<void> setSpeed(double value) async { speed = value; }
  @override
  Future<void> dispose() async {
    await positions.close();
    await processing.close();
    await events.close();
    await states.close();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
