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
    final sidecar = File('${target.path}.alignment.json');
    await sidecar.writeAsString('old timing');
    await replaceNarrationFile(target, Stream.value(List.filled(2200, 2)), contentLength: 2200,
      beforeReplace: () async {
        expect(await target.readAsBytes(), List.filled(2000, 1));
        released = true;
      });
    expect(released, isTrue);
    expect(await target.readAsBytes(), List.filled(2200, 2));
    expect(await File('${target.path}.bak').exists(), isFalse);
    expect(await sidecar.exists(), isFalse);
  });
  test('delete clears only this chapter audio and cloud job; reading progress survives', () async {
    final state = File('${root.path}/narration_state.json');
    await state.writeAsString(jsonEncode({'book:0': {'path': target.path, 'positionMs': 9000}, 'book:1': {'positionMs': 7000}}));
    final reading = File('${root.path}/reading_state.json');
    final sidecar = File('${target.path}.alignment.json');
    await sidecar.writeAsString('old timing');
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
    expect(await sidecar.exists(), isFalse);
    expect(jobs.containsKey(0), isFalse);
    expect(jobs[1]?['id'], 'keep');
    expect(selected, {1});
    expect(jsonDecode(await state.readAsString()), {'book:1': {'positionMs': 7000}});
    expect(await reading.readAsString(), saved);
  });
}
