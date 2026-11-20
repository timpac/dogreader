import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/book_progress.dart';
import 'package:audiobook_app/narration_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late BookProgress progress;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('book-progress-');
    progress = BookProgress(documentsDirectory: () async => root);
    await progress.load();
  });
  tearDown(() async {
    await progress.flushed;
    progress.dispose();
    await root.delete(recursive: true);
  });
  Future<BookProgress> restart() async {
    final restored = BookProgress(documentsDirectory: () async => root);
    await restored.load();
    addTearDown(restored.dispose);
    return restored;
  }

  test('newly imported book has no fabricated progress', () async {
    expect(progress.continuePosition('new'), isNull);
    expect(progress.listeningChapter('new'), isNull);
    expect(progress.furthestChapter('new'), isNull);
    expect(progress.sectionFraction('new', 0, 100), 0);
    await progress.opened('new');
    expect(progress.lastOpened('new'), greaterThan(0));
    expect((await restart()).continuePosition('new'), isNull);
  });

  test(
    'late checkpoint from an older reader cannot replace a newer reader cursor',
    () async {
      final old = progress.startReading('book');
      await progress.saveReading('book', 6, 40, session: old);
      final next = progress.startReading('book');
      final newer = progress.saveReading('book', 7, 60, session: next);
      final lateDisposal = progress.saveReading(
        'book',
        6,
        45,
        session: old,
        activate: false,
      );
      await Future.wait([newer, lateDisposal]);
      expect(progress.readingPosition('book'), {'chapter': 7, 'offset': 60});
      expect(progress.continuePosition('book'), {'chapter': 7, 'offset': 60});
      expect(progress.sectionFraction('book', 6, 100), .45);
    },
  );

  test('restarting after a clock rollback still orders new reading after old listening', () async {
    final file = File('${root.path}/narration_state.json');
    await file.writeAsString(
      jsonEncode({
        '_bookProgress': {
          'book': {'chapter': 7, 'updatedAt': 9000000000000000},
        },
        'book:7': {'positionMs': 10000},
      }),
    );
    final restored = await restart();
    await restored.saveReading('book', 3, 50);
    expect(restored.continuePosition('book'), {'chapter': 3, 'offset': 50});
    expect(restored.listeningChapter('book'), 7);
  });

  test(
    'corrupt audio metadata does not hide healthy reading progress',
    () async {
      await progress.saveReading('book', 6, 40);
      final file = File('${root.path}/narration_state.json');
      await file.writeAsString('{broken');
      final restored = await restart();
      expect(restored.readingPosition('book'), {'chapter': 6, 'offset': 40});
      await restored.saveReading('book', 7, 50);
      expect(restored.readingPosition('book'), {'chapter': 7, 'offset': 50});
      expect(await file.readAsString(), '{broken');
    },
  );

  test(
    'listening section 7 to 8 preserves independent text and audio resumes',
    () async {
      await progress.saveReading('book', 6, 73);
      await progress.saveAudio(
        'book',
        6,
        const Duration(seconds: 100),
        duration: const Duration(seconds: 100),
        completed: true,
      );
      await progress.saveAudio(
        'book',
        7,
        const Duration(seconds: 24),
        duration: const Duration(seconds: 100),
      );
      expect(progress.continuePosition('book'), {'chapter': 7, 'offset': 0});
      expect(progress.readingPosition('book'), {'chapter': 6, 'offset': 73});
      expect(progress.sectionFraction('book', 6, 100), 1);
      expect(progress.sectionFraction('book', 7, 100), .24);
      final restored = await restart();
      expect(restored.listeningChapter('book'), 7);
      expect(restored.audioSection('book', 7)['positionMs'], 24000);
      expect(restored.continuePosition('book')!['chapter'], 7);
    },
  );

  test('reading earlier moves last active but retains furthest and audio timestamp', () async {
    await progress.saveAudio(
      'book',
      7,
      const Duration(seconds: 80),
      duration: const Duration(seconds: 100),
    );
    await progress.saveReading('book', 2, 16);
    expect(progress.continuePosition('book'), {'chapter': 2, 'offset': 16});
    expect(progress.furthestChapter('book'), 7);
    expect(progress.listeningChapter('book'), 7);
    expect(progress.audioSection('book', 7)['positionMs'], 80000);
    await progress.saveAudio(
      'book',
      7,
      const Duration(seconds: 20),
      duration: const Duration(seconds: 100),
    );
    expect(progress.sectionFraction('book', 7, 100), .8);
    expect(progress.audioSection('book', 7)['positionMs'], 20000);
  });

  test(
    'covered reader and lifecycle checkpoint cannot reclaim audio activity',
    () async {
      await progress.saveReading('book', 6, 73);
      await progress.saveAudio('book', 7, const Duration(seconds: 12));
      await progress.saveReading('book', 6, 69, activate: false);
      expect(progress.continuePosition('book')!['chapter'], 7);
      expect(progress.readingPosition('book')!['offset'], 69);
      await progress.saveReading('book', 3, 50);
      await progress.saveAudio(
        'book',
        7,
        const Duration(seconds: 12),
        activate: false,
      );
      expect(progress.continuePosition('book')!['chapter'], 3);
    },
  );

  test(
    'rapid navigation commits in event order despite stalled first operation',
    () async {
      final gate = Completer<void>();
      var calls = 0;
      final stalled = BookProgress(
        documentsDirectory: () async {
          if (++calls == 1) await gate.future;
          return root;
        },
      );
      addTearDown(stalled.dispose);
      final saves = [
        stalled.saveReading('book', 6, 70),
        stalled.saveAudio('book', 7, const Duration(seconds: 11)),
        stalled.saveReading('book', 2, 30),
        stalled.saveAudio('book', 7, const Duration(seconds: 22)),
      ];
      gate.complete();
      await Future.wait(saves);
      final restored = await restart();
      expect(restored.continuePosition('book')!['chapter'], 7);
      expect(restored.readingPosition('book'), {'chapter': 2, 'offset': 30});
      expect(restored.audioSection('book', 7)['positionMs'], 22000);
    },
  );

  test('overlapping metadata and progress writes preserve downloaded recording fields', () async {
    final file = File('${root.path}/narration_state.json');
    await Future.wait([
      progress.saveAudio('book', 7, const Duration(seconds: 25)),
      updateNarrationJson(file, (data) {
        final section = Map<String, dynamic>.from(data['book:7'] as Map? ?? {});
        data['book:7'] = {
          ...section,
          'path': '/existing/audio.mp3',
          'recording_id': 'cloud-recording',
          'narration_offsets': {'sourceLength': 300},
        };
      }),
      progress.saveAudio('book', 7, const Duration(seconds: 34)),
    ]);
    final section = (await restart()).audioSection('book', 7);
    expect(section['positionMs'], 34000);
    expect(section['path'], '/existing/audio.mp3');
    expect(section['recording_id'], 'cloud-recording');
    expect(section['narration_offsets'], {'sourceLength': 300});
  });

  test('atomic audio checkpoint restores section and timestamp without a shutdown save', () async {
    await progress.saveAudio('book', 7, const Duration(milliseconds: 45123));
    // New instance reads disk without disposing or calling a lifecycle callback.
    final restored = await restart();
    expect(restored.continuePosition('book')!['chapter'], 7);
    expect(restored.audioSection('book', 7)['positionMs'], 45123);
    expect(
      await File('${root.path}/narration_state.json.tmp').exists(),
      isFalse,
    );
  });

  test('legacy books include audio evidence but never replace saved resumes or unknown fields', () async {
    final reading = File('${root.path}/reading_state.json');
    final audio = File('${root.path}/narration_state.json');
    await reading.writeAsString(
      jsonEncode({
        'positions': {
          'old': {'chapter': 6, 'offset': 87},
        },
        'chapterProgress': {
          'old': {'5': 100, '6': 87},
        },
        'lastOpened': {'old': 123},
        'futureField': 'preserved',
      }),
    );
    await audio.writeAsString(
      jsonEncode({
        'old:7': {
          'positionMs': 80000,
          'path': '/unchanged.mp3',
          'recording_id': 'old-id',
        },
        'old:3': {'positionMs': 25000},
      }),
    );
    final restored = await restart();
    expect(restored.continuePosition('old')!['chapter'], 7);
    expect(restored.readingPosition('old'), {'chapter': 6, 'offset': 87});
    expect(restored.audioSection('old', 7)['positionMs'], 80000);
    expect(restored.sectionFraction('old', 5, 100), 1);
    await restored.saveReading('old', 2, 20);
    expect(restored.continuePosition('old')!['chapter'], 2);
    expect(restored.furthestChapter('old'), 7);
    expect(
      jsonDecode(await reading.readAsString())['futureField'],
      'preserved',
    );
    expect(
      jsonDecode(await audio.readAsString())['old:7']['path'],
      '/unchanged.mp3',
    );
  });

  test('corrupt state is retained; a failed operation does not poison later writes', () async {
    final file = File('${root.path}/narration_state.json');
    await file.writeAsString('{broken');
    await expectLater(
      progress.saveAudio('book', 7, const Duration(seconds: 12)),
      throwsFormatException,
    );
    expect(await file.readAsString(), '{broken');
    expect(progress.continuePosition('book'), isNull);
    expect(progress.lastError, isNotNull);
    await file.writeAsString('{}');
    await progress.saveAudio('book', 7, const Duration(seconds: 13));
    expect(progress.lastError, isNull);
    expect((await restart()).audioSection('book', 7)['positionMs'], 13000);
  });
}
