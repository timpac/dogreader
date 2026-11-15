import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:audiobook_app/kokoro/pcm_trim.dart';
import 'package:audiobook_app/offline_narration.dart';
import 'package:audiobook_app/reader_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'fake_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakePlayer player;
  late DogreaderAudioHandler handler;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dogreader-stream-');
    player = FakePlayer();
    handler = DogreaderAudioHandler(
      player: player,
      documentsDirectory: () async => root,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(offlineChannel, null);
    await handler.dispose();
    await root.delete(recursive: true);
  });

  test('streaming chapter starts playback, appends chunks, handles underrun, and finishes cleanly', () async {
    final chunk0 = '${root.path}/chunk_00000.wav';
    final chunk1 = '${root.path}/chunk_00001.wav';
    final chunk2 = '${root.path}/chunk_00002.wav';

    await handler.startStreamingChapter(
      title: 'Chapter 1',
      author: 'Author',
      bookId: 'book',
      chapterIndex: 0,
      chapterCount: 2,
      initialChunks: [(wavPath: chunk0, durationMs: 3200)],
    );

    expect(handler.isStreamingChapter, isTrue);
    expect(player.playlistSources, hasLength(1));
    expect(player.playing, isTrue);
    expect(handler.effectiveDuration, const Duration(milliseconds: 3200));

    // Append chunk 1 while chunk 0 is playing.
    await handler.appendStreamingChunk(
      bookId: 'book',
      chapterIndex: 0,
      chunkIndex: 1,
      wavPath: chunk1,
      durationMs: 4100,
    );
    expect(player.playlistSources, hasLength(2));
    expect(handler.effectiveDuration, const Duration(milliseconds: 7300));

    // Simulate playback reaching the end of buffered chunks before chunk 2 is ready.
    player.processing.add(ProcessingState.completed);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(handler.isStreamingBuffering, isTrue);
    expect(handler.playbackState.value.processingState, AudioProcessingState.buffering);

    // Chunk 2 arrives: handler should auto-resume playback on chunk 2.
    await handler.appendStreamingChunk(
      bookId: 'book',
      chapterIndex: 0,
      chunkIndex: 2,
      wavPath: chunk2,
      durationMs: 2700,
    );
    expect(handler.isStreamingBuffering, isFalse);
    expect(player.playlistSources, hasLength(3));
    expect(player.currentIndex, 2);
    expect(handler.effectiveDuration, const Duration(milliseconds: 10000));

    // Seek across cumulative chunk boundaries (5000 ms -> chunk 1 at 1800 ms).
    await handler.seek(const Duration(milliseconds: 5000));
    expect(player.currentIndex, 1);
    expect(player.position, const Duration(milliseconds: 1800));
    expect(handler.effectivePosition, const Duration(milliseconds: 5000));

    // Finish streaming with final assembled WAV path.
    await handler.finishStreamingChapter(
      bookId: 'book',
      chapterIndex: 0,
      finalWavPath: '${root.path}/chapter-int8-1.wav',
    );
    expect(handler.mediaItem.value?.id, 'book:0');
  });

  test('OfflineNarration buffers 2 chunks before starting playback and streams remaining chunks', () async {
    final chunk0File = File('${root.path}/chunk_00000.wav')..writeAsBytesSync([1, 2, 3]);
    final chunk1File = File('${root.path}/chunk_00001.wav')..writeAsBytesSync([4, 5, 6]);
    final chunk2File = File('${root.path}/chunk_00002.wav')..writeAsBytesSync([7, 8, 9]);
    Map<dynamic, dynamic>? sentRequest;
    String? currentJobId;
    var readyChunks = <Map<String, dynamic>>[];
    var active = true;
    String? outcome;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(offlineChannel, (call) async {
      if (call.method == 'notificationPermission') return true;
      if (call.method == 'startGeneration') {
        sentRequest = call.arguments as Map;
        currentJobId = sentRequest!['id'] as String;
      }
      if (call.method == 'generationStatus' && currentJobId != null) {
        return jsonEncode({
          'jobId': currentJobId,
          'active': active,
          'outcome': outcome,
          'totalChunks': 3,
          'completedChunks': readyChunks.length,
          'readyChunks': readyChunks,
          'chapter': {'key': 'book:0', 'bookId': 'book', 'chapterIndex': 0},
        });
      }
      return null;
    });

    var started = 0;
    var appended = 0;
    var finished = 0;
    final controller = OfflineNarration(
      beforeSelect: (_, _) async {},
      documentsDirectory: () async => root,
      onStartStreaming: ({
        required title,
        required author,
        required bookId,
        required chapterIndex,
        required chapterCount,
        required initialChunks,
      }) async {
        started++;
        expect(initialChunks, hasLength(2));
      },
      onAppendStreamingChunk: ({
        required bookId,
        required chapterIndex,
        required chunkIndex,
        required wavPath,
        required durationMs,
      }) async {
        appended++;
        expect(chunkIndex, 2);
      },
      onFinishStreaming: ({
        required bookId,
        required chapterIndex,
        finalWavPath,
      }) async {
        finished++;
      },
    )
      ..root = root.path
      ..output = root.path
      ..int8Ready = true
      ..frontendReady = true
      ..ready = true
      ..int8ModelManifest = File('model-manifest.json').readAsStringSync()
      ..modelManifest = File('fp32-model-manifest.json').readAsStringSync()
      ..frontendManifest = File('english-frontend-manifest.json').readAsStringSync();

    await controller.generate(
      bookId: 'book',
      bookTitle: 'Test Book',
      index: 0,
      chapter: const ReaderChapter('Chapter 1', 'Hello world. This is a test.', []),
      sid: 3,
      threads: 2,
      streamPlayback: true,
    );

    expect(sentRequest!['variant'], 'int8');
    expect(sentRequest!['modelFile'], 'model.int8.onnx');
    expect(sentRequest!['streamDir'], contains('chunks'));

    // With only 1 chunk of 3 ready, wait for chunk 1 so 1 chunk is buffered ahead.
    readyChunks = [
      {'index': 0, 'wavPath': chunk0File.path, 'frames': 80000, 'durationMs': 3333},
    ];
    await controller.poll();
    expect(started, 0);

    readyChunks = [
      {'index': 0, 'wavPath': chunk0File.path, 'frames': 80000, 'durationMs': 3333},
      {'index': 1, 'wavPath': chunk1File.path, 'frames': 60000, 'durationMs': 2500},
    ];
    await controller.poll();
    expect(started, 1);
    expect(appended, 0);

    readyChunks = [
      {'index': 0, 'wavPath': chunk0File.path, 'frames': 80000, 'durationMs': 3333},
      {'index': 1, 'wavPath': chunk1File.path, 'frames': 60000, 'durationMs': 2500},
      {'index': 2, 'wavPath': chunk2File.path, 'frames': 60000, 'durationMs': 2500},
    ];
    await controller.poll();
    expect(appended, 1);

    active = false;
    outcome = 'completed';
    await controller.poll();
    expect(finished, 1);
    expect(controller.isStreaming, isFalse);

    controller.dispose();
  });

  test('trimLeadingTrailingSilence removes excessive padding while keeping short margin', () {
    // 24000 Hz: 200ms leading silence (4800), 100ms speech (2400), 300ms trailing silence (7200).
    final samples = <double>[
      ...List<double>.filled(4800, 0.0),
      ...List<double>.filled(2400, 0.4),
      ...List<double>.filled(7200, 0.0),
    ];

    final trimmed = trimLeadingTrailingSilence(samples);
    // Keep 15ms leading (360) + 2400 speech + 35ms trailing (840) = 3600 samples.
    expect(trimmed.samples.length, 3600);
    expect(trimmed.trimmedLeadingSamples, 4800 - 360);
    expect(trimmed.trimmedTrailingSamples, 7200 - 840);
    // Edge ramp starts and ends at 0.0.
    expect(trimmed.samples.first, 0.0);
    expect(trimmed.samples.last, 0.0);
  });
}
