import 'dart:convert';

/// Non-mutating preflight for a whole-book request. The caller must obtain the
/// expected recording IDs from the backend's canonical recording identity.
/// Missing identity is never evidence that an old recording can be reused.
class WholeBookSettings {
  final String engine;
  final String voice;
  final String modelVersion;
  final String _settings;

  WholeBookSettings({
    required this.engine,
    required this.voice,
    required this.modelVersion,
    required Map<String, dynamic> settings,
  }) : _settings = jsonEncode(_canonical(settings));

  bool matches(Map<String, dynamic> recording) =>
      recording['engine'] == engine &&
      recording['voice'] == voice &&
      recording['model_version'] == modelVersion &&
      recording['settings'] is Map &&
      jsonEncode(_canonical(recording['settings'])) == _settings;
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

class WholeBookChapter {
  final int index;
  final String title;

  /// Exact submitted speech text after the recording's frozen dictionary and
  /// silence transformations. Reader text and UTF-16 offset maps stay separate;
  /// never reapply today's dictionary during cost review, retry or recovery.
  final String text;

  /// Includes text, voice, engine, model and generation settings. This must be
  /// resolved by the backend, including its legacy-recording reuse rules.
  final String? expectedRecordingId;

  const WholeBookChapter({
    required this.index,
    required this.title,
    required this.text,
    this.expectedRecordingId,
  });

  // The Python backend uses len(text), which counts Unicode scalar values.
  int get characters => text.runes.length;

  String? get ineligibleReason {
    if (characters < 100) return 'Fewer than 100 characters';
    if (characters > 250000) {
      return 'Exceeds the 250,000-character chapter limit';
    }
    if (text.trim().isEmpty) return 'No narratable text';
    return null;
  }
}

enum WholeBookDisposition { generate, retry, active, reuse, ineligible }

class WholeBookPlanEntry {
  final WholeBookChapter chapter;
  final WholeBookDisposition disposition;
  final String? reason;

  const WholeBookPlanEntry(this.chapter, this.disposition, [this.reason]);
}

class WholeBookPreflight {
  final List<WholeBookPlanEntry> entries;
  final WholeBookSettings settings;
  final double? usdPerMillionCharacters;

  WholeBookPreflight._(
    this.entries,
    this.settings,
    this.usdPerMillionCharacters,
  );

  factory WholeBookPreflight({
    required Iterable<WholeBookChapter> chapters,
    required WholeBookSettings settings,
    // Only pass authoritative server results here. In particular, a local
    // 'ready' flag does not establish that the cloud MP3 is valid and complete.
    required Map<int, Map<String, dynamic>> existing,
    double? usdPerMillionCharacters,
  }) {
    final rate = usdPerMillionCharacters;
    if (rate != null && (!rate.isFinite || rate < 0)) {
      throw ArgumentError.value(rate, 'usdPerMillionCharacters');
    }
    final ordered = chapters.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final indices = <int>{};
    final entries = <WholeBookPlanEntry>[];
    for (final chapter in ordered) {
      if (chapter.index < 0 || !indices.add(chapter.index)) {
        throw ArgumentError('Chapter indices must be unique and non-negative');
      }
      final job = existing[chapter.index];
      final identity = chapter.expectedRecordingId;
      final matches =
          identity != null &&
          identity.isNotEmpty &&
          job?['id'] == identity &&
          settings.matches(job!);
      final status = job?['status'];
      final reason = chapter.ineligibleReason;
      // Reuse valid completed legacy audio even if current submission limits
      // would reject its original chapter. Do not generate it again.
      if (matches && status == 'ready') {
        entries.add(WholeBookPlanEntry(chapter, WholeBookDisposition.reuse));
      } else if (matches && (status == 'queued' || status == 'generating')) {
        entries.add(WholeBookPlanEntry(chapter, WholeBookDisposition.active));
      } else if (reason != null) {
        entries.add(
          WholeBookPlanEntry(chapter, WholeBookDisposition.ineligible, reason),
        );
      } else {
        entries.add(
          WholeBookPlanEntry(
            chapter,
            matches && status == 'error'
                ? WholeBookDisposition.retry
                : WholeBookDisposition.generate,
          ),
        );
      }
    }
    return WholeBookPreflight._(List.unmodifiable(entries), settings, rate);
  }

  int count(WholeBookDisposition disposition) =>
      entries.where((entry) => entry.disposition == disposition).length;

  int get totalCharacters =>
      entries.fold(0, (sum, entry) => sum + entry.chapter.characters);

  /// Baseline estimate for new work and explicitly retried failures. Checkpoint
  /// reuse can lower retry costs; provider retries and cloud costs can add to it.
  int get estimatedBillableCharacters => entries
      .where(
        (entry) =>
            entry.disposition == WholeBookDisposition.generate ||
            entry.disposition == WholeBookDisposition.retry,
      )
      .fold(0, (sum, entry) => sum + entry.chapter.characters);

  /// Gross TTS estimate before credits. An unknown price stays unknown.
  double? get estimatedTtsUsd => usdPerMillionCharacters == null
      ? null
      : estimatedBillableCharacters * usdPerMillionCharacters! / 1000000;
}
