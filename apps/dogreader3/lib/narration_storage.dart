import 'dart:convert';
import 'dart:io';

/// Serialize read/modify/rename for narration metadata, including position saves.
/// A corrupt existing file is an error; never silently overwrite user state.
final Map<String, Future<void>> _writes = {};

Future<void> updateNarrationJson(
  File file,
  void Function(Map<String, dynamic>) change,
) {
  final previous = _writes[file.path] ?? Future<void>.value();
  final result = previous.then((_) async {
    final data = await file.exists()
        ? Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map,
          )
        : <String, dynamic>{};
    change(data);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(data), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  _writes[file.path] = tail;
  tail.then((_) {
    if (identical(_writes[file.path], tail)) _writes.remove(file.path);
  });
  return result;
}
