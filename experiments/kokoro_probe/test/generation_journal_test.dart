import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/generation_journal.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('generation-journal-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('chunk evidence exists on disk without UI delivery', () async {
    final journal = GenerationJournal(
      '${dir.path}/events.jsonl',
      '${dir.path}/cancel',
    );
    journal.record('chunkStart', {'chunk': 1});
    await Future<void>.delayed(const Duration(milliseconds: 2));
    journal.record('chunkInferenceEnd', {'chunk': 1, 'frames': 24000});
    final events = File(journal.path)
        .readAsLinesSync()
        .map((line) => jsonDecode(line) as Map)
        .toList();
    expect(events.map((e) => e['event']), ['chunkStart', 'chunkInferenceEnd']);
    expect(
      events[1]['workerMonotonicMs'],
      greaterThanOrEqualTo(events[0]['workerMonotonicMs']),
    );
    expect(
      events.every(
        (e) => e['pid'] == pid && DateTime.parse(e['utc'] as String).isUtc,
      ),
      isTrue,
    );
    expect(events[1]['frames'], 24000);
  });

  test('native cancellation marker is observed without an isolate message', () {
    final journal = GenerationJournal(
      '${dir.path}/events.jsonl',
      '${dir.path}/cancel',
    );
    expect(journal.checkCancellation, returnsNormally);
    File(journal.cancelPath).writeAsStringSync('cancel');
    expect(journal.checkCancellation, throwsA(isA<GenerationCancelled>()));
  });
}
