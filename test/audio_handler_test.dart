import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'fake_player.dart';

void main() {
  late Directory root;
  late FakePlayer player;
  late DogreaderAudioHandler handler;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dogreader-handler-');
    player = FakePlayer();
    handler = DogreaderAudioHandler(player: player, documentsDirectory: () async => root);
  });
  tearDown(() async { await handler.dispose(); await root.delete(recursive: true); });
  Future<void> load({bool force = false, bool Function()? active}) => handler.loadChapter(
    path: '${root.path}/book_0.mp3', title: 'Chapter', author: 'Author',
    bookId: 'book', chapterIndex: 0, chapterCount: 2,
    startPosition: const Duration(seconds: 12), forceReload: force, isCurrent: active);

  test('saved audio position restores and reopening preserves background playback', () async {
    await load();
    expect(player.position.inSeconds, 12);
    await handler.play();
    player.position = const Duration(seconds: 25);
    await load();
    expect(player.loads, 1);
    expect(player.playing, isTrue);
    expect(player.position.inSeconds, 25);
    await handler.pause();
    final data = jsonDecode(await File('${root.path}/narration_state.json').readAsString());
    expect(data['book:0']['positionMs'], 25000);
  });
  test('reading snapshot preserves playback, speed and position and rejects old chapters', () async {
    await load();
    await handler.play();
    await handler.setSpeed(1.5);
    player.position = const Duration(minutes: 30);
    final location = handler.readingLocation!;
    expect(location.position, const Duration(minutes: 30));
    expect(location.chapterIndex, 0);
    expect(handler.isReadingLocationCurrent(location), isTrue);
    expect(player.playing, isTrue);
    expect(player.speed, 1.5);
    expect(player.loads, 1);
    expect(player.stops, 0);
    await handler.loadChapter(path: '${root.path}/book_1.mp3', title: 'Next', author: 'Author',
        bookId: 'book', chapterIndex: 1, chapterCount: 2);
    expect(handler.isReadingLocationCurrent(location), isFalse);
    expect(handler.readingLocation!.chapterIndex, 1);
  });
  test('failed native seek never persists the requested but unobserved target', () async {
    await load();
    player.ignoreSeek = true;
    await handler.seek(const Duration(seconds: 70));
    final data = jsonDecode(await File('${root.path}/narration_state.json').readAsString());
    expect(data['book:0']['positionMs'], 12000);
  });
  test('deletion and repair unload matching audio so replacement bytes reload', () async {
    await load();
    await handler.play();
    await handler.unloadChapter('other', 0);
    expect(player.playing, isTrue);
    await handler.unloadChapter('book', 0);
    expect(player.stops, 1);
    expect(handler.mediaItem.value, isNull);
    await load();
    expect(player.loads, 2);
    await load(force: true);
    expect(player.loads, 3);
  });
  test('navigation while preparing cannot publish stale chapter metadata', () async {
    var active = true;
    player.preparing = Completer<void>();
    final loading = load(active: () => active);
    // Allow the serialized save and pause to reach setFilePath.
    for (var i = 0; i < 20 && player.loads == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(player.loads, 1);
    active = false;
    player.preparing!.complete();
    await loading;
    expect(handler.mediaItem.value, isNull);
  });
  test('background completion advances to the next downloaded chapter', () async {
    await Directory('${root.path}/narration').create();
    await File('${root.path}/narration/book_1.mp3').writeAsBytes([1]);
    await load();
    await handler.play();
    player.processing.add(ProcessingState.completed);
    for (var i = 0; i < 100 && handler.mediaItem.value?.id != 'book:1'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(handler.mediaItem.value?.id, 'book:1');
    expect(player.playing, isTrue);
  });
}
