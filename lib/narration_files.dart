import 'dart:convert';
import 'dart:io';

/// Replace a downloaded recording only after validating the complete response.
Future<void> replaceNarrationFile(File target, Stream<List<int>> bytes,
    {required int contentLength, Future<void> Function()? beforeReplace}) async {
  final temp = File('${target.path}.part');
  try {
    await bytes.pipe(temp.openWrite());
    final size = await temp.length();
    if (size < 1000 || (contentLength >= 0 && size != contentLength)) {
      throw StateError('Audio file was empty or incomplete');
    }
    await beforeReplace?.call();
    if (await target.exists()) {
      final backup = File('${target.path}.bak');
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
      try {
        await temp.rename(target.path);
        await backup.delete();
      } catch (_) {
        if (await backup.exists()) await backup.rename(target.path);
        rethrow;
      }
    } else {
      await temp.rename(target.path);
    }
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}

Future<void> deleteNarrationFile({
  required Directory root,
  required String bookId,
  required int index,
  required Future<void> Function() pause,
  required Map<int, Map<String, dynamic>> jobs,
  required Set<int> selected,
}) async {
  await pause();
  final file = File('${root.path}/narration/${bookId}_$index.mp3');
  if (await file.exists()) await file.delete();
  final stateFile = File('${root.path}/narration_state.json');
  if (await stateFile.exists()) {
    final data = jsonDecode(await stateFile.readAsString());
    if (data is Map<String, dynamic>) {
      data.remove('$bookId:$index');
      await stateFile.writeAsString(jsonEncode(data));
    }
  }
  jobs.remove(index);
  selected.remove(index);
}
