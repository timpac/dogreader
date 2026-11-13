import 'dart:convert';
import 'dart:io';

/// Honor the explicitly selected recording, including an offline WAV. The
/// existing cloud filename remains the fallback; cloud job APIs do not change.
Future<File> chapterRecordingFile(Directory root, String book, int index) async {
  final metadata = File('${root.path}/narration_state.json');
  if (await metadata.exists()) {
    final data = jsonDecode(await metadata.readAsString()) as Map;
    final entry = data['$book:$index'];
    if (entry is Map && entry['path'] is String) {
      final file = File(entry['path'] as String);
      if (!file.path.endsWith('.part') && !file.path.endsWith('.bak') &&
          await file.exists() && await file.length() >= 1000) return file;
    }
  }
  return File('${root.path}/narration/${book}_$index.mp3');
}
