import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:audiobook_app/media_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_player.dart';

void main() {
  late Directory root;
  setUp(() async { root = await Directory.systemTemp.createTemp('media-log-'); });
  tearDown(() async { await root.delete(recursive: true); });

  test('rotates within bounds and a new process can retrieve previous events', () async {
    final log = MediaDiagnostics(directory: () async => root, maxBytes: 1024);
    for (var i = 0; i < 40; i++) {
      log.record(MediaDiagnosticEvent.commandReceived, {'id': i, 'command': 'play'});
      await log.flush();
    }
    for (final name in ['dart.jsonl', 'dart.previous.jsonl']) {
      expect(await File('${root.path}/$name').length(), lessThanOrEqualTo(1024));
    }
    final reopened = MediaDiagnostics(directory: () async => root, maxBytes: 1024);
    reopened.record(MediaDiagnosticEvent.processStarted, {'build': '136'});
    final exported = await reopened.export();
    expect(exported, contains(log.process));
    expect(exported, contains(reopened.process));
    expect(exported, contains('"id":39'));
    expect(exported, isNot(contains('"id":0,')));
  });

  test('disk fields reject raw messages, credentials, URLs and arbitrary origins', () async {
    const secret = 'token-secret-book-text';
    final log = MediaDiagnostics(directory: () async => root);
    log.record(MediaDiagnosticEvent.bridgeError, {
      'message': secret, 'path': '/data/private/$secret',
      'url': 'https://example.com/$secret', 'token': secret,
      'origin': secret, 'playerState': secret, 'code': secret,
      'build': secret, 'chapter': 2,
    });
    final exported = await log.export();
    expect(exported, isNot(contains(secret)));
    expect(exported, isNot(contains('https://')));
    expect(exported, contains('"chapter":2'));
  });

  test('slow storage has a bounded queue and never blocks transport', () async {
    final directory = Completer<Directory>();
    final log = MediaDiagnostics(directory: () => directory.future, maxPending: 4);
    final player = FakePlayer();
    final handler = DogreaderAudioHandler(
      player: player, documentsDirectory: () async => root, diagnostics: log,
    );
    try {
      await handler.loadChapter(
        path: '${root.path}/chapter.mp3', title: 'Private title', author: 'Private author',
        bookId: 'private-book', chapterIndex: 0, chapterCount: 1,
      ).timeout(const Duration(seconds: 1));
      await handler.play().timeout(const Duration(seconds: 1));
      expect(player.playing, isTrue);
      await handler.pause().timeout(const Duration(seconds: 1));
      expect(player.playing, isFalse);
      expect(log.dropped, greaterThan(0));
    } finally {
      await handler.dispose();
      directory.complete(Directory('${root.path}/logs'));
      await log.flush();
    }
  });

  test('storage failure is contained and a later event can retry', () async {
    final blocker = File('${root.path}/blocked');
    await blocker.writeAsString('not a directory');
    final log = MediaDiagnostics(directory: () async => Directory(blocker.path));
    log.record(MediaDiagnosticEvent.processStarted);
    await log.flush();
    expect(log.ioFailures, 1);
    expect(await log.export(), contains('ioFailures=1'));
    await blocker.delete();
    log.record(MediaDiagnosticEvent.handlerCreated);
    final exported = await log.export();
    expect(exported, contains('handlerCreated'));
    expect(exported, contains('"ioFailures":1'));
  });

  test('correlates command receipt, execution, and native acknowledgement', () async {
    final log = MediaDiagnostics(directory: () async => Directory('${root.path}/logs'));
    final handler = DogreaderAudioHandler(
      player: FakePlayer(), documentsDirectory: () async => root, diagnostics: log,
    );
    try {
      await handler.loadChapter(
        path: '${root.path}/chapter.mp3', title: 'Private title', author: 'Private author',
        bookId: 'private-book', chapterIndex: 0, chapterCount: 1,
      );
      await handler.play(origin: 'in-app');
      await handler.pause();
      final exported = await log.export();
      final records = exported.split('\n').where((line) => line.startsWith('{'))
          .map((line) => jsonDecode(line) as Map<String, dynamic>).toList();
      final pause = records.singleWhere((r) => r['event'] == 'commandReceived' && r['command'] == 'pause');
      final phases = records.where((r) => r['id'] == pause['id']).map((r) => r['event']).toList();
      expect(phases, ['commandReceived', 'commandExecuting', 'commandResult']);
      expect(exported, contains('completed (native Pause/Stop acknowledged)'));
      expect(exported, isNot(contains('Private title')));
      expect(exported, isNot(contains('private-book')));
    } finally {
      await handler.dispose();
      await log.flush();
    }
  });
}
