import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/narration_files.dart';

void main() {
  late Directory root;
  late File target;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dogreader-');
    await Directory('${root.path}/narration').create();
    target = File('${root.path}/narration/book_0.mp3');
    await target.writeAsBytes(List.filled(2000, 1));
  });
  tearDown(() => root.delete(recursive: true));

  test('build 123 recovery preserves valid local audio on truncated downloads', () async {
    var released = false;
    await expectLater(replaceNarrationFile(target, Stream.value(List.filled(1200, 2)),
      contentLength: 2000, beforeReplace: () async { released = true; }), throwsStateError);
    expect(await target.readAsBytes(), List.filled(2000, 1));
    expect(await File('${target.path}.part').exists(), isFalse);
    expect(released, isFalse);
  });
  test('recovery rejects tiny audio and interrupted streams', () async {
    await expectLater(replaceNarrationFile(target, Stream.value([1, 2]), contentLength: -1), throwsStateError);
    await expectLater(replaceNarrationFile(target, Stream.error(const SocketException('offline')), contentLength: -1), throwsA(isA<SocketException>()));
    expect(await target.readAsBytes(), List.filled(2000, 1));
    expect(await File('${target.path}.part').exists(), isFalse);
  });
  test('validated recovery releases the old decoder before replacing bytes', () async {
    var released = false;
    await replaceNarrationFile(target, Stream.value(List.filled(2200, 2)), contentLength: 2200,
      beforeReplace: () async {
        expect(await target.readAsBytes(), List.filled(2000, 1));
        released = true;
      });
    expect(released, isTrue);
    expect(await target.readAsBytes(), List.filled(2200, 2));
    expect(await File('${target.path}.bak').exists(), isFalse);
  });
  test('metadata commit failure restores old audio or removes a failed first download', () async {
    for (final hadRecording in [true, false]) {
      if (!hadRecording) await target.delete();
      await expectLater(replaceNarrationFile(target, Stream.value(List.filled(2200, 2)),
        contentLength: 2200, afterReplace: () async {
          throw const FileSystemException('Metadata cannot be saved');
        }), throwsA(isA<FileSystemException>()));
      expect(await target.exists(), hadRecording);
      if (hadRecording) expect(await target.readAsBytes(), List.filled(2000, 1));
      expect(await File('${target.path}.part').exists(), isFalse);
      expect(await File('${target.path}.bak').exists(), isFalse);
    }
  });

  test(
    'process death rolls back audio and metadata together before commit',
    () async {
      final state = File('${root.path}/narration_state.json');
      final old = {
        'path': target.path,
        'positionMs': 17000,
        'recording_id': 'old',
      };
      await target.rename('${target.path}.bak');
      await target.writeAsBytes(List.filled(2200, 2));
      await state.writeAsString(
        jsonEncode({
          'book:0': {'recording_id': 'new', 'positionMs': 0},
          'other:0': {'positionMs': 11},
        }),
      );
      await File('${target.path}.transaction').writeAsString(
        jsonEncode({
          'file': state.path,
          'key': 'book:0',
          'entry': old,
          'hadTarget': true,
        }),
      );
      await File('${target.path}.part').writeAsBytes([1, 2]);
      await recoverNarrationFile(target);
      expect(await target.readAsBytes(), List.filled(2000, 1));
      final data = jsonDecode(await state.readAsString()) as Map;
      expect(data['book:0'], old);
      expect(data['other:0']['positionMs'], 11);
      expect(await File('${target.path}.part').exists(), isFalse);
    },
  );

  test('process death after commit retains completed replacement', () async {
    await target.rename('${target.path}.bak');
    await target.writeAsBytes(List.filled(2200, 2));
    await File('${target.path}.transaction.committed').writeAsString('{}');
    await recoverNarrationFile(target);
    expect(await target.readAsBytes(), List.filled(2200, 2));
    expect(await File('${target.path}.bak').exists(), isFalse);
  });

  test('uncommitted first download is never exposed as playable', () async {
    final state = File('${root.path}/narration_state.json');
    await state.writeAsString(
      jsonEncode({
        'book:0': {'recording_id': 'new'},
      }),
    );
    await File('${target.path}.transaction').writeAsString(
      jsonEncode({
        'file': state.path,
        'key': 'book:0',
        'entry': null,
        'hadTarget': false,
      }),
    );
    await recoverNarrationFile(target);
    expect(await target.exists(), isFalse);
    expect(jsonDecode(await state.readAsString()), isEmpty);
  });

  test('chapter discovery cannot delete an active download staging file', () async {
    final stream = StreamController<List<int>>();
    final replacement = replaceNarrationFile(target, stream.stream, contentLength: 2200);
    stream.add(List.filled(1100, 2));
    // Wait until the writer owns its staging file, then emulate chapter entry.
    while (!await File('${target.path}.part').exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await recoverNarrationFile(target);
    expect(await File('${target.path}.part').exists(), isTrue);
    stream.add(List.filled(1100, 2));
    await stream.close();
    await replacement;
    expect(await target.readAsBytes(), List.filled(2200, 2));
  });

  test('delete clears only this chapter audio and cloud job; reading progress survives', () async {
    final state = File('${root.path}/narration_state.json');
    await state.writeAsString(jsonEncode({'book:0': {'path': target.path, 'positionMs': 9000}, 'book:1': {'positionMs': 7000}}));
    final reading = File('${root.path}/reading_state.json');
    const saved = '{"positions":{"book":{"chapter":0,"offset":412}}}';
    await reading.writeAsString(saved);
    final jobs = <int, Map<String, dynamic>>{0: {'id': 'old-voice', 'status': 'ready'}, 1: {'id': 'keep'}};
    final selected = {0, 1};
    var paused = false;
    await deleteNarrationFile(root: root, bookId: 'book', index: 0,
      pause: () async { expect(await target.exists(), isTrue); paused = true; },
      jobs: jobs, selected: selected);
    expect(paused, isTrue);
    expect(await target.exists(), isFalse);
    expect(jobs.containsKey(0), isFalse);
    expect(jobs[1]?['id'], 'keep');
    expect(selected, {1});
    expect(jsonDecode(await state.readAsString()), {'book:1': {'positionMs': 7000}});
    expect(await reading.readAsString(), saved);
  });
}
