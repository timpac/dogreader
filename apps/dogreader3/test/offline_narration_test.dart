import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/offline_narration.dart';
import 'package:audiobook_app/chapter_recording_path.dart';
import 'package:audiobook_app/reader_content.dart';
import 'package:audiobook_app/offline_reader_text.dart';
import 'package:audiobook_app/kokoro/audio.dart';
import 'package:audiobook_app/kokoro/chunk_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async { root = await Directory.systemTemp.createTemp('dogreader3-'); });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(offlineChannel, null);
    await root.delete(recursive: true);
  });

  test('reader indentation becomes whitespace without dropping text or changing offsets', () {
    const raw = 'Alice read.\n　The children don’t leave.\n\n　There are 12 books.';
    final spoken = offlineReaderText(raw);
    expect(spoken, 'Alice read.\n\nThe children don’t leave.\n\n\nThere are 12 books.');
    expect(spoken.length, raw.length);
    expect(spoken.indexOf('The'), raw.indexOf('The'));
    expect(spoken.indexOf('12'), raw.indexOf('12'));
  });

  test('PCM checkpoints preserve exact bytes and reject corruption or different settings', () {
    final pcm = encodePcm16([-1, -.4, 0, .4, 1]);
    final store = ChunkStore(Directory('${root.path}/chunks'), 'settings-a');
    expect(store.read(0), isNull);
    store.write(0, pcm);
    expect(store.read(0)!.bytes, pcm.bytes);
    expect(store.read(0)!.squareSum, pcm.squareSum);
    expect(() => ChunkStore(store.directory, 'settings-b').read(0), throwsStateError);
    File('${store.directory.path}/0.pcm').writeAsBytesSync([0, 0]);
    expect(() => store.read(0), throwsStateError);
  });

  test('an uncommitted chunk is never treated as completed', () {
    final store = ChunkStore(Directory('${root.path}/chunks'), 'settings-a');
    File('${store.directory.path}/1.pcm.part').writeAsBytesSync([1, 2]);
    File('${store.directory.path}/1.pcm').writeAsBytesSync([1, 2]);
    expect(store.read(1), isNull);
  });

  test('offline chapter request freezes identity and sends no cloud job', () async {
    Map<dynamic, dynamic>? request;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(offlineChannel, (call) async {
      if (call.method == 'notificationPermission') return true;
      if (call.method == 'startGeneration') request = call.arguments as Map;
      return null;
    });
    final controller = OfflineNarration(beforeSelect: (_, _) async {})
      ..root = root.path ..output = root.path ..ready = true
      ..modelManifest = File('fp32-model-manifest.json').readAsStringSync()
      ..frontendManifest = File('english-frontend-manifest.json').readAsStringSync();
    await controller.generate(bookId: 'book', bookTitle: 'A novel', index: 2,
      chapter: const ReaderChapter('Chapter 3', '“Hello,” Alice said.\n　There were 12 birds.', []), sid: 3, threads: 2);
    expect(request!['text'], contains('Alice'));
    expect(request!['text'], contains('\n\nThere were 12 birds.'));
    expect(request!['text'], isNot(contains('\u3000')));
    expect(request!['chapter']['readerWhitespaceNormalization'], 'reader-paragraph-indent-v1');
    expect(request!['variant'], 'fp32');
    expect(request!['frontend'], 'misaki');
    expect(request!['chapter']['engine'], 'kokoro_offline');
    expect(request!['chapter']['key'], 'book:2');
    expect(request!['chapter']['voice'], 'af_heart');
    expect(request!['chapter']['sourceSha256'], hasLength(64));
    expect(request!['chapter']['narration_dictionary'], isMap);
    expect(request!['chapter']['narration_offsets'], isMap);
    expect(request!.containsKey('host'), isFalse);
    expect(request!.containsKey('token'), isFalse);
    controller.dispose();
  });

  test('notification refusal dispatches no inference', () async {
    var starts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(offlineChannel, (call) async {
      if (call.method == 'startGeneration') starts++;
      return false;
    });
    final controller = OfflineNarration(beforeSelect: (_, _) async {})..ready = true;
    await expectLater(controller.generate(bookId: 'book', bookTitle: 'Novel', index: 0,
      chapter: const ReaderChapter('Chapter', 'A paragraph.', []), sid: 3, threads: 2), throwsStateError);
    expect(starts, 0);
    controller.dispose();
  });

  test('selecting completed offline audio preserves cloud bytes and unrelated positions', () async {
    final wav = File('${root.path}/chapter.wav');
    await wav.writeAsBytes([...wavHeader(600, 24000), ...List.filled(1200, 0)]);
    final cloud = File('${root.path}/cloud.mp3'); await cloud.writeAsBytes([1,2,3]);
    final queue = File('${root.path}/dogreader_queue.json');
    await queue.writeAsString('{"host":"https://cloud.invalid","books":{"book":{"0":{"engine":"kokoro","id":"cloud-id"}}}}');
    final queueBefore = await queue.readAsString();
    await File('${root.path}/narration_state.json').writeAsString(jsonEncode({'other:0': {'positionMs': 900}}));
    var unloads = 0;
    final controller = OfflineNarration(beforeSelect: (book, index) async {
      expect(book, 'book'); expect(index, 0); unloads++;
    }, documentsDirectory: () async => root);
    await controller.select({'key':'book:0', 'bookId':'book', 'chapterIndex':0, 'jobId':'local-1',
      'engine':'kokoro_offline', 'voice':'af_heart', 'result':{'path':wav.path, 'wavBytes':await wav.length()}});
    final state = jsonDecode(await File('${root.path}/narration_state.json').readAsString());
    expect(state['book:0']['engine'], 'kokoro_offline');
    expect(state['other:0']['positionMs'], 900);
    expect(await cloud.readAsBytes(), [1,2,3]);
    expect(await queue.readAsString(), queueBefore);
    expect((await chapterRecordingFile(root, 'book', 0)).path, wav.path);
    expect(unloads, 1);
    controller.dispose();
  });

  test('missing completed WAV never changes selected chapter metadata', () async {
    final controller = OfflineNarration(beforeSelect: (_, _) async {}, documentsDirectory: () async => root);
    await expectLater(controller.select({'result': {'path': '${root.path}/missing.wav', 'wavBytes': 5000}}), throwsStateError);
    expect(await File('${root.path}/narration_state.json').exists(), isFalse);
    controller.dispose();
  });
}
