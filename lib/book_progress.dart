import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'narration_storage.dart';

/// One process-wide coordinator, shared by the reader and background handler.
/// Text offsets and audio timestamps retain their existing files and meanings.
/// Audio activity/completion is committed in the SAME atomic rename as its
/// timestamp, so a killed process cannot leave the overview behind that save.
class BookProgress extends ChangeNotifier {
  BookProgress({Future<Directory> Function()? documentsDirectory})
    : _directory = documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directory;
  Map<String, dynamic> _reading = {};
  Map<String, dynamic> _audio = {};
  Future<void>? _loading;
  Future<void> _pending = Future<void>.value();
  int _clock = 0;
  final Map<String, Object> _readerSessions = {};
  Object? lastError;

  Object startReading(String book) {
    final session = Object();
    _readerSessions[book] = session;
    return session;
  }

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  int _int(Object? value) => value is num ? value.toInt() : 0;

  Future<Map<String, dynamic>> _read(File file) async => await file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map)
      : {};

  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null; // Retry on the next event; never replace corrupt state.
    throw error;
  });

  Future<void> _load() async {
    final root = await _directory();
    // A damaged progress file must not hide the library or the other mode's
    // healthy resume data. Writes still read/validate the target file and
    // refuse to replace corrupt bytes.
    try {
      _reading = await _read(File('${root.path}/reading_state.json'));
    } catch (error) {
      lastError = error;
    }
    try {
      _audio = await _read(File('${root.path}/narration_state.json'));
    } catch (error) {
      lastError = error;
    }
    for (final activity in [
      ..._map(_reading['readingActivity']).values,
      ..._map(_audio['_bookProgress']).values,
    ]) {
      _clock = math.max(_clock, _int(_map(activity)['updatedAt']));
    }
  }

  int _stamp() =>
      _clock = math.max(_clock + 1, DateTime.now().microsecondsSinceEpoch);

  Future<void> _enqueue(Future<void> Function() action) {
    final result = _pending.then((_) async {
      try {
        await load();
        await action();
        lastError = null;
        notifyListeners();
      } catch (error) {
        lastError = error;
        rethrow;
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> get flushed => _pending;

  Map<String, int>? readingPosition(String book) {
    final value = _map(_reading['positions'])[book];
    if (value is! Map) return null;
    return {'chapter': _int(value['chapter']), 'offset': _int(value['offset'])};
  }

  int lastOpened(String book) => math.max(
    math.max(
      _int(_map(_reading['lastOpened'])[book]),
      _int(_map(_map(_reading['readingActivity'])[book])['updatedAt']),
    ),
    _int(_map(_map(_audio['_bookProgress'])[book])['updatedAt']),
  );

  Map<String, dynamic> audioSection(String book, int chapter) =>
      _map(_audio['$book:$chapter']);

  Iterable<int> _audioChapters(String book) sync* {
    for (final key in _audio.keys) {
      if (!key.startsWith('$book:')) continue;
      final index = int.tryParse(key.substring(book.length + 1));
      if (index != null && index >= 0) yield index;
    }
  }

  /// Continue reading follows the last active mode's SECTION. Within that
  /// section it restores only a genuine saved reader offset, never an estimated
  /// text/audio conversion. Furthest progress is displayed independently.
  Map<String, int>? continuePosition(String book) {
    final reader = readingPosition(book);
    final readingActivity = _map(_map(_reading['readingActivity'])[book]);
    final listeningActivity = _map(_map(_audio['_bookProgress'])[book]);
    int? chapter;
    if (listeningActivity.isNotEmpty &&
        _int(listeningActivity['updatedAt']) >
            _int(readingActivity['updatedAt'])) {
      chapter = _int(listeningActivity['chapter']);
    } else if (reader != null) {
      chapter = reader['chapter'];
    }
    // Legacy files have no activity clock. We cannot infer recency. For this
    // one-time fallback only, include evidence of listening beyond the reader;
    // neither resume record is changed. New events always use actual activity.
    if (readingActivity.isEmpty && listeningActivity.isEmpty) {
      for (final index in _audioChapters(book)) {
        if (_int(audioSection(book, index)['positionMs']) > 0) {
          chapter = math.max(chapter ?? 0, index);
        }
      }
    }
    if (chapter == null) return null;
    return {
      'chapter': chapter,
      'offset': reader?['chapter'] == chapter ? reader!['offset']! : 0,
    };
  }

  int? listeningChapter(String book) {
    final activity = _map(_map(_audio['_bookProgress'])[book]);
    if (activity.isNotEmpty) return _int(activity['chapter']);
    int? legacy;
    for (final index in _audioChapters(book)) {
      if (_int(audioSection(book, index)['positionMs']) > 0) {
        legacy = math.max(legacy ?? 0, index);
      }
    }
    return legacy;
  }

  int? furthestChapter(String book) {
    int? result = continuePosition(book)?['chapter'];
    final history = _map(_map(_reading['chapterProgress'])[book]);
    for (final entry in history.entries) {
      final index = int.tryParse(entry.key);
      if (index != null && _int(entry.value) >= 0) {
        result = math.max(result ?? 0, index);
      }
    }
    for (final index in _audioChapters(book)) {
      final section = audioSection(book, index);
      if (section['visited'] == true ||
          _int(section['furthestPositionMs']) > 0 ||
          _int(section['positionMs']) > 0 ||
          section['completed'] == true) {
        result = math.max(result ?? 0, index);
      }
    }
    return result;
  }

  double sectionFraction(String book, int chapter, int textLength) {
    final history = _map(_map(_reading['chapterProgress'])[book]);
    final reader = readingPosition(book);
    final offset = math.max(
      _int(history['$chapter']),
      reader?['chapter'] == chapter ? reader!['offset']! : 0,
    );
    final section = audioSection(book, chapter);
    final duration = _int(section['durationMs']);
    final audio = section['completed'] == true
        ? 1.0
        : duration > 0
        ? math.max(
                _int(section['furthestPositionMs']),
                _int(section['positionMs']),
              ) /
              duration
        : 0.0;
    return math.max(offset / math.max(1, textLength), audio).clamp(0.0, 1.0);
  }

  Future<void> opened(String book) {
    return _enqueue(() async {
      final stamp = _stamp();
      final file = File('${(await _directory()).path}/reading_state.json');
      Map<String, dynamic>? committed;
      await updateNarrationJson(file, (data) {
        final recent = _map(data['lastOpened']);
        recent[book] = stamp;
        data['lastOpened'] = recent;
        committed = data;
      });
      _reading = committed!;
    });
  }

  Future<void> saveReading(
    String book,
    int chapter,
    int offset, {
    bool activate = true,
    Object? session,
  }) {
    return _enqueue(() async {
      final stamp = _stamp();
      final file = File('${(await _directory()).path}/reading_state.json');
      Map<String, dynamic>? committed;
      await updateNarrationJson(file, (data) {
        final current =
            session == null || identical(session, _readerSessions[book]);
        if (current) {
          final positions = _map(data['positions']);
          positions[book] = {'chapter': chapter, 'offset': math.max(0, offset)};
          data['positions'] = positions;
        }
        final histories = _map(data['chapterProgress']);
        final history = _map(histories[book]);
        history['$chapter'] = math.max(_int(history['$chapter']), offset);
        histories[book] = history;
        data['chapterProgress'] = histories;
        if (activate && current) {
          final activity = _map(data['readingActivity']);
          activity[book] = {'chapter': chapter, 'updatedAt': stamp};
          data['readingActivity'] = activity;
        }
        committed = data;
      });
      _reading = committed!;
    });
  }

  Future<void> saveAudio(
    String book,
    int chapter,
    Duration position, {
    Duration? duration,
    bool completed = false,
    bool activate = true,
  }) {
    final milliseconds = position.inMilliseconds.clamp(0, 2147483647);
    return _enqueue(() async {
      final stamp = _stamp();
      final file = File('${(await _directory()).path}/narration_state.json');
      Map<String, dynamic>? committed;
      await updateNarrationJson(file, (data) {
        final key = '$book:$chapter';
        final section = _map(data[key]);
        final previousPosition = _int(section['positionMs']);
        section['positionMs'] = milliseconds;
        section['furthestPositionMs'] = math.max(
          milliseconds,
          math.max(_int(section['furthestPositionMs']), previousPosition),
        );
        if (duration != null && duration > Duration.zero) {
          section['durationMs'] = duration.inMilliseconds;
        }
        if (completed) section['completed'] = true;
        if (activate || completed) section['visited'] = true;
        data[key] = section;
        if (activate) {
          final activity = _map(data['_bookProgress']);
          activity[book] = {'chapter': chapter, 'updatedAt': stamp};
          data['_bookProgress'] = activity;
        }
        committed = data;
      });
      _audio = committed!;
    });
  }
}

final bookProgress = BookProgress();
