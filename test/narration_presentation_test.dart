import 'package:audiobook_app/narration_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

ChapterAudioPresentation chapter(
  Map<String, dynamic>? job, {
  bool local = false,
  bool playing = false,
  bool downloading = false,
}) => ChapterAudioPresentation.from(
  job,
  hasFile: local,
  playing: playing,
  downloading: downloading,
);

void main() {
  test(
    'reader and chapter actions follow generation and delivery independently',
    () {
      expect(chapter(null).action, ChapterAudioAction.generate);
      expect(chapter({'status': 'waiting'}).label, 'Waiting to submit');
      expect(chapter({'status': 'waiting'}).action, isNull);
      expect(chapter({'status': 'queued'}).label, 'Queued');
      expect(chapter({'status': 'queued'}).action, isNull);
      expect(
        chapter({'status': 'generating', 'progress': 2, 'chunks': 4}).label,
        'Generating… · 2/4',
      );
      const ready = {
        'id': 'job',
        'status': 'ready',
        'delivery': 'server_ready',
      };
      expect(chapter(ready).action, ChapterAudioAction.download);
      expect(chapter(ready, downloading: true).label, 'Downloading…');
      expect(chapter(ready, downloading: true).action, isNull);
      expect(chapter(null, local: true).action, ChapterAudioAction.play);
      expect(chapter(null, playing: true).action, ChapterAudioAction.pause);
      expect(
        chapter({'status': 'error'}).action,
        ChapterAudioAction.retryGeneration,
      );
      expect(
        chapter({...ready, 'delivery': 'failed'}).action,
        ChapterAudioAction.retryDownload,
      );
    },
  );

  test('a playable recording remains accessible throughout replacement', () {
    final queued = chapter({'status': 'queued'}, local: true);
    expect(queued.label, 'Queued');
    expect(queued.action, ChapterAudioAction.play);
    final downloading = chapter(
      {'status': 'ready'},
      local: true,
      downloading: true,
    );
    expect(downloading.action, ChapterAudioAction.play);
    final failure = chapter({'status': 'error'}, local: true, playing: true);
    expect(failure.label, 'Generation failed · Previous recording available');
    expect(failure.action, ChapterAudioAction.pause);
    final missingFile = chapter({
      'status': 'error',
      'previousRecording': {'id': 'old'},
    });
    expect(missingFile.hasRecording, isFalse);
    expect(missingFile.action, ChapterAudioAction.retryGeneration);
  });
}
