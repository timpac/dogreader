import 'dart:io';
import 'dart:convert';

import 'narration_storage.dart';

final Set<String> _replacing = {};
final Map<String, Future<void>> _recoveries = {};

/// UI discovery cannot remove staging bytes owned by an active download.
Future<void> recoverNarrationFile(File target) {
  if (_replacing.contains(target.path)) return Future<void>.value();
  // The common discovery path needs no queued recovery operation.
  if (![
    '.bak',
    '.part',
    '.transaction',
    '.transaction.committed',
  ].any((suffix) => File('${target.path}$suffix').existsSync())) {
    return Future<void>.value();
  }
  return _recoveries[target.path] ??= _recoverNarrationFile(target)
      .whenComplete(() {
        _recoveries.remove(target.path);
      });
}

/// Recover a terminated replacement before any existence/playability check.
Future<void> _recoverNarrationFile(File target) async {
  final backup = File('${target.path}.bak');
  final journal = File('${target.path}.transaction');
  final committed = File('${journal.path}.committed');
  if (await committed.exists()) {
    if (await backup.exists()) await backup.delete();
    await committed.delete();
  } else if (await journal.exists()) {
    final previous = jsonDecode(await journal.readAsString()) as Map;
    if (await backup.exists()) {
      if (await target.exists()) await target.delete();
      await backup.rename(target.path);
    } else if (previous['hadTarget'] == false && await target.exists()) {
      await target.delete();
    }
    await updateNarrationJson(File(previous['file'] as String), (data) {
      final key = previous['key'] as String;
      if (previous['entry'] == null) {
        data.remove(key);
      } else {
        data[key] = previous['entry'];
      }
    });
    await journal.delete();
  } else if (await backup.exists()) {
    // Compatibility with replacements interrupted before journals were added.
    if (await target.exists()) await target.delete();
    await backup.rename(target.path);
  }
  final partial = File('${target.path}.part');
  if (await partial.exists()) await partial.delete();
}

/// Replace a downloaded recording only after validating the complete response.
Future<void> replaceNarrationFile(
  File target,
  Stream<List<int>> bytes, {
  required int contentLength,
  File? metadataFile,
  String? metadataKey,
  Future<void> Function()? beforeReplace,
  Future<void> Function()? afterReplace,
}) async {
  final temp = File('${target.path}.part');
  final journal = File('${target.path}.transaction');
  final committed = File('${journal.path}.committed');
  if (!_replacing.add(target.path)) {
    throw StateError('Recording replacement already active');
  }
  try {
    await (_recoveries[target.path] ?? _recoverNarrationFile(target));
    await bytes.pipe(temp.openWrite());
    final handle = await temp.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    final size = await temp.length();
    if (size < 1000 || (contentLength >= 0 && size != contentLength)) {
      throw StateError('Audio file was empty or incomplete');
    }
    await beforeReplace?.call();
    if (metadataFile != null && metadataKey != null) {
      Object? oldEntry;
      await updateNarrationJson(metadataFile, (data) {
        oldEntry = data[metadataKey];
      });
      final stagedJournal = File('${journal.path}.tmp');
      await stagedJournal.writeAsString(
        jsonEncode({
          'file': metadataFile.path,
          'key': metadataKey,
          'entry': oldEntry,
          'hadTarget': await target.exists(),
        }),
        flush: true,
      );
      await stagedJournal.rename(journal.path);
    }
    Future<void> commit() async {
      await afterReplace?.call();
      // A rename is the commit marker for both audio bytes and their metadata.
      if (await journal.exists()) await journal.rename(committed.path);
    }

    if (await target.exists()) {
      final backup = File('${target.path}.bak');
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
      try {
        await temp.rename(target.path);
        await commit();
      } catch (_) {
        if (await target.exists()) await target.delete();
        if (await backup.exists()) await backup.rename(target.path);
        rethrow;
      }
      await backup.delete();
    } else {
      await temp.rename(target.path);
      try {
        await commit();
      } catch (_) {
        if (await target.exists()) await target.delete();
        rethrow;
      }
    }
  } catch (_) {
    await _recoverNarrationFile(target);
    rethrow;
  } finally {
    try {
      if (await temp.exists()) await temp.delete();
      if (await committed.exists() &&
          !await File('${target.path}.bak').exists()) {
        await committed.delete();
      }
    } finally {
      _replacing.remove(target.path);
    }
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
    await updateNarrationJson(stateFile, (data) {
      data.remove('$bookId:$index');
    });
  }
  jobs.remove(index);
  selected.remove(index);
}
