import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'reader_content.dart';

class NarrationRule {
  final String original, replacement;
  final bool silence, enabled;
  const NarrationRule(
    this.original,
    this.replacement, {
    this.silence = false,
    this.enabled = true,
  });

  factory NarrationRule.fromJson(Map<String, dynamic> data) => NarrationRule(
    data['original'] as String,
    data['replacement'] as String? ?? '',
    silence: data['silence'] == true,
    enabled: data['enabled'] != false,
  );
  Map<String, dynamic> toJson() => {
    'original': original,
    'replacement': replacement,
    'silence': silence,
    'enabled': enabled,
  };
}

/// A frozen effective dictionary travels with a queued job so retries never
/// silently change its text, cache identity, or character mapping.
class NarrationDictionaryConfig {
  final List<NarrationRule> rules;
  final bool ignoreSeparators;
  final int version;
  const NarrationDictionaryConfig({
    this.rules = const [],
    this.ignoreSeparators = true,
    this.version = 2,
  });
  factory NarrationDictionaryConfig.fromJson(Map<String, dynamic> data) {
    final version = data['version'] as int? ?? 1;
    if (version != 1 && version != 2) {
      throw const FormatException('Unsupported narration dictionary version');
    }
    return NarrationDictionaryConfig(
      rules: (data['rules'] as List? ?? [])
          .map(
            (r) => NarrationRule.fromJson(Map<String, dynamic>.from(r as Map)),
          )
          .toList(),
      ignoreSeparators: data['ignoreSeparators'] == true,
      version: version,
    );
  }
  Map<String, dynamic> toJson() => {
    'version': version,
    'rules': rules.map((r) => r.toJson()).toList(),
    'ignoreSeparators': ignoreSeparators,
  };

  NarrationText transform(ReaderChapter chapter) {
    final source = chapter.text;
    final edits = <List<int>>[];
    final output = StringBuffer();
    final active =
        rules.where((r) => r.enabled && r.original.isNotEmpty).toList()
          ..sort((a, b) => b.original.length.compareTo(a.original.length));
    final separators = ignoreSeparators
        ? {for (final r in chapter.narrationSeparators) r.start: r.end}
        : <int, int>{};
    if (active.isEmpty && separators.isEmpty) {
      return NarrationText(source, {
        'sourceLength': source.length,
        'spokenLength': source.length,
        'edits': <List<int>>[],
      });
    }
    // Literal, case-sensitive, single-pass matching. Word edges keep a name
    // such as Ann from replacing the same letters inside another word.
    // Pre-review queued snapshots have no version. Preserve their exact input
    // on retry, including the old word-edge behavior; regeneration opts into v2.
    final word = RegExp(
      version == 1 ? r'[\p{L}\p{N}_]' : r'[\p{L}\p{M}\p{N}_]',
      unicode: true,
    );
    bool wordAt(String text, int offset) {
      if (version == 1) return word.hasMatch(text[offset]);
      var start = offset, end = offset + 1;
      final unit = text.codeUnitAt(offset);
      if (unit >= 0xdc00 && unit <= 0xdfff && offset > 0) {
        final previous = text.codeUnitAt(offset - 1);
        if (previous >= 0xd800 && previous <= 0xdbff) {
          start--;
        }
      } else if (unit >= 0xd800 && unit <= 0xdbff && end < text.length) {
        final next = text.codeUnitAt(end);
        if (next >= 0xdc00 && next <= 0xdfff) {
          end++;
        }
      }
      return word.hasMatch(text.substring(start, end));
    }

    bool matches(NarrationRule rule, int at) {
      final end = at + rule.original.length;
      return source.startsWith(rule.original, at) &&
          !(at > 0 && wordAt(rule.original, 0) && wordAt(source, at - 1)) &&
          !(end < source.length &&
              wordAt(rule.original, rule.original.length - 1) &&
              wordAt(source, end));
    }

    for (var at = 0; at < source.length;) {
      final separatorEnd = separators[at];
      if (separatorEnd != null) {
        edits.add([at, separatorEnd, output.length, output.length]);
        at = separatorEnd;
        continue;
      }
      NarrationRule? match;
      for (final rule in active) {
        if (matches(rule, at)) {
          match = rule;
          break;
        }
      }
      if (match == null) {
        output.write(source[at++]);
      } else {
        final end = at + match.original.length;
        final start = output.length;
        output.write(match.silence ? '' : match.replacement);
        edits.add([at, end, start, output.length]);
        at = end;
      }
    }
    return NarrationText(output.toString(), {
      'sourceLength': source.length,
      'spokenLength': output.length,
      'edits': edits,
    });
  }
}

class NarrationText {
  final String text;
  final Map<String, dynamic> offsets;
  const NarrationText(this.text, this.offsets);
}

/// Convert the reader's original UTF-16 fraction using the map belonging to the
/// actual recording. Timing remains build 135's character-based approximation.
/// Legacy/imported audio without a map keeps its previous behavior.
double narrationFraction(double fraction, dynamic offsets) {
  if (offsets is! Map) return fraction;
  try {
    final sourceLength = offsets['sourceLength'] as int;
    final spokenLength = offsets['spokenLength'] as int;
    if (sourceLength <= 0 || spokenLength <= 0) return 0;
    final source = fraction.clamp(0.0, 1.0) * sourceLength;
    var delta = 0;
    for (final raw in offsets['edits'] as List) {
      final edit = List<int>.from(raw as List);
      final a = edit[0], b = edit[1], c = edit[2], d = edit[3];
      if (source < a) break;
      if (source <= b) {
        return ((c + (source - a) / (b - a) * (d - c)) / spokenLength).clamp(
          0.0,
          1.0,
        );
      }
      delta = d - b;
    }
    return ((source + delta) / spokenLength).clamp(0.0, 1.0);
  } catch (_) {
    return fraction;
  }
}

final narrationDictionary = NarrationDictionary();

/// Same atomic JSON-file storage pattern as appearance preferences. No audio,
/// reading-state or EPUB file is touched when the dictionary is edited.
class NarrationDictionary extends ChangeNotifier {
  NarrationDictionary({Future<File> Function()? preferencesFile})
    : _preferencesFile = preferencesFile ?? _defaultFile;
  final Future<File> Function() _preferencesFile;
  List<NarrationRule> global = [];
  Map<String, List<NarrationRule>> books = {};
  bool ignoreSeparators = true;
  Future<void>? _loaded;
  Future<void> _pendingWrite = Future<void>.value();

  static Future<File> _defaultFile() async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/narration_dictionary.json');
  }

  Future<void> load() => _loaded ??= _load();
  Future<void> _load() async {
    try {
      final data =
          jsonDecode(await (await _preferencesFile()).readAsString()) as Map;
      List<NarrationRule> read(dynamic value) => (value as List? ?? [])
          .map(
            (r) => NarrationRule.fromJson(Map<String, dynamic>.from(r as Map)),
          )
          .where((r) => r.original.isNotEmpty)
          .toList();
      final loadedGlobal = read(data['global']);
      final loadedBooks = (data['books'] as Map? ?? {}).map(
        (k, v) => MapEntry(k.toString(), read(v)),
      );
      global = loadedGlobal;
      books = loadedBooks;
      ignoreSeparators = data['ignoreSeparators'] != false;
    } catch (_) {
      // Missing or corrupt preferences must not stop reading or playback.
    }
    notifyListeners();
  }

  List<NarrationRule> rules(String? bookId) => List.unmodifiable(
    bookId == null ? global : books[bookId] ?? const <NarrationRule>[],
  );

  NarrationDictionaryConfig effective(String? bookId) {
    final merged = {for (final r in global) r.original: r};
    // A disabled local rule also overrides the global rule, allowing opt-out.
    for (final r in rules(bookId).where((_) => bookId != null)) {
      merged[r.original] = r;
    }
    return NarrationDictionaryConfig(
      rules: merged.values.toList(),
      ignoreSeparators: ignoreSeparators,
    );
  }

  Future<void> setRules(String? bookId, List<NarrationRule> value) {
    if (bookId == null) {
      global = List.of(value);
    } else {
      books[bookId] = List.of(value);
    }
    return _save();
  }

  Future<void> setIgnoreSeparators(bool value) {
    ignoreSeparators = value;
    return _save();
  }

  Future<void> _save() {
    notifyListeners();
    final snapshot = jsonEncode({
      'global': global.map((r) => r.toJson()).toList(),
      'books': books.map(
        (k, v) => MapEntry(k, v.map((r) => r.toJson()).toList()),
      ),
      'ignoreSeparators': ignoreSeparators,
    });
    _pendingWrite = _pendingWrite.catchError((Object _) {}).then((_) async {
      final file = await _preferencesFile();
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(file.path);
    });
    return _pendingWrite;
  }
}
