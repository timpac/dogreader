// Keep this pure-Dart diagnostic harness runnable without Flutter imports.
// ignore_for_file: avoid_relative_lib_imports, avoid_print

import '../lib/whole_book_preflight.dart';
import '../lib/whole_book_progress.dart';

void main() {
  var checks = 0;
  void check(bool condition, String description) {
    if (!condition) throw StateError(description);
    checks++;
  }

  final settingsMap = <String, dynamic>{
    'encoding': 'MP3',
    'splitter': 'google-3800-v1',
  };
  final settings = WholeBookSettings(
    engine: 'google',
    voice: 'Charon',
    modelVersion: 'managed',
    settings: settingsMap,
  );
  Map<String, dynamic> job(String status, {String voice = 'Charon'}) => {
    'id': 'verified-id',
    'engine': 'google',
    'voice': voice,
    'model_version': 'managed',
    'settings': {'splitter': 'google-3800-v1', 'encoding': 'MP3'},
    'status': status,
  };
  WholeBookChapter chapter(
    int index, {
    String? text,
    String? id = 'verified-id',
  }) => WholeBookChapter(
    index: index,
    title: 'Chapter $index',
    text: text ?? List.filled(100, 'x').join(),
    expectedRecordingId: id,
  );
  WholeBookPreflight plan(
    List<WholeBookChapter> chapters,
    Map<int, Map<String, dynamic>> jobs, {
    double? rate = 30,
  }) => WholeBookPreflight(
    chapters: chapters,
    settings: settings,
    existing: jobs,
    usdPerMillionCharacters: rate,
  );

  final mixed = plan(
    [chapter(3), chapter(0), chapter(2), chapter(1), chapter(4)],
    {0: job('ready'), 1: job('queued'), 2: job('generating'), 3: job('error')},
  );
  check(
    mixed.entries.map((e) => e.chapter.index).join() == '01234',
    'Reading order',
  );
  check(mixed.count(WholeBookDisposition.reuse) == 1, 'Reuse completed audio');
  check(mixed.count(WholeBookDisposition.active) == 2, 'Retain active jobs');
  check(
    mixed.count(WholeBookDisposition.retry) == 1,
    'Explicit retry classification',
  );
  check(
    mixed.count(WholeBookDisposition.generate) == 1,
    'New chapter classification',
  );
  check(
    mixed.totalCharacters == 500 && mixed.estimatedBillableCharacters == 200,
    'Exclude completed and active work from new cost',
  );
  check((mixed.estimatedTtsUsd! - 0.006).abs() < 1e-10, 'Gross price estimate');
  check(
    plan([chapter(0)], {}, rate: null).estimatedTtsUsd == null,
    'Unknown price',
  );
  check(
    plan(
          [chapter(0)],
          {0: job('ready', voice: 'Puck')},
        ).count(WholeBookDisposition.reuse) ==
        0,
    'Different narrator',
  );
  check(
    plan(
          [chapter(0, id: null)],
          {0: job('ready')},
        ).count(WholeBookDisposition.reuse) ==
        0,
    'Unknown source identity',
  );
  check(
    plan(
          [chapter(0)],
          {
            0: {...job('ready'), 'id': 'old-text'},
          },
        ).count(WholeBookDisposition.reuse) ==
        0,
    'Changed source text',
  );
  check(
    plan(
          [chapter(0)],
          {
            0: {...job('ready'), 'model_version': 'old'},
          },
        ).count(WholeBookDisposition.reuse) ==
        0,
    'Changed model',
  );
  check(
    plan(
          [chapter(0)],
          {
            0: {
              ...job('ready'),
              'settings': {'speed': 2},
            },
          },
        ).count(WholeBookDisposition.reuse) ==
        0,
    'Changed settings',
  );
  check(
    plan(
          [chapter(0)],
          {
            0: {'id': 'verified-id', 'status': 'ready'},
          },
        ).count(WholeBookDisposition.reuse) ==
        0,
    'Unknown legacy metadata',
  );
  final large = List.filled(250001, 'x').join();
  final limits = plan([
    chapter(0, text: 'short'),
    chapter(1, text: large),
    chapter(2, text: List.filled(100, ' ').join()),
  ], {});
  check(
    limits.count(WholeBookDisposition.ineligible) == 3,
    'Preserve chapter limits',
  );
  check(limits.entries[1].chapter.text == large, 'Never truncate');
  check(
    limits.estimatedBillableCharacters == 0,
    'No estimate for rejected work',
  );
  check(
    plan(
          [chapter(0, text: large)],
          {0: job('ready')},
        ).count(WholeBookDisposition.reuse) ==
        1,
    'Preserve verified legacy completion',
  );
  check(
    chapter(0, text: List.filled(100, '🐕').join()).characters == 100,
    'Match backend Unicode character counts',
  );
  check(plan([], {}).estimatedTtsUsd == 0, 'Empty book');
  settingsMap['encoding'] = 'WAV';
  check(settings.matches(job('ready')), 'Freeze configuration snapshot');
  for (final rate in [-1.0, double.nan, double.infinity]) {
    try {
      plan([], {}, rate: rate);
      throw StateError('Accepted invalid rate');
    } on ArgumentError {
      checks++;
    }
  }
  try {
    plan([chapter(0), chapter(0)], {});
    throw StateError('Accepted duplicate chapter');
  } on ArgumentError {
    checks++;
  }
  try {
    mixed.entries.clear();
    throw StateError('Mutable plan');
  } on UnsupportedError {
    checks++;
  }
  final progressPlan = plan(List.generate(7, (i) => chapter(i)), {});
  final server = <int, Map<String, dynamic>>{
    0: job('ready'),
    1: job('ready'),
    2: job('queued'),
    3: job('generating'),
    4: job('error'),
    5: {...job('ready'), 'id': 'previous-recording'},
  };
  WholeBookProgress progress() => WholeBookProgress(
    plan: progressPlan,
    serverJobs: server,
    verifiedDownloads: {0: 'verified-id', 5: 'previous-recording'},
    downloadFailures: {1},
  );
  final beforeRestart = progress();
  check(
    beforeRestart.completed == 2 && beforeRestart.total == 7,
    'Completed count includes cloud ready and downloaded exactly once',
  );
  check(
    beforeRestart.count(WholeBookChapterPhase.queued) == 1 &&
        beforeRestart.count(WholeBookChapterPhase.generating) == 1,
    'Project active cloud states',
  );
  check(
    beforeRestart.count(WholeBookChapterPhase.failed) == 1 &&
        beforeRestart.failedDownloads == 1,
    'Failed downloads remain ready, separate from TTS failure',
  );
  check(
    beforeRestart.count(WholeBookChapterPhase.pending) == 2,
    'Previous recording and unknown work do not inflate completion',
  );
  check(
    progress().chapters.map((c) => c.phase).join() ==
        beforeRestart.chapters.map((c) => c.phase).join(),
    'Rebuild progress deterministically from retained inputs after restart',
  );
  check(
    WholeBookProgress(
          plan: progressPlan,
          serverJobs: {},
          verifiedDownloads: {0: 'verified-id'},
        ).completed ==
        1,
    'Valid offline audio remains completed without cloud connectivity',
  );
  check(
    WholeBookProgress(
          plan: progressPlan,
          serverJobs: {0: job('ready', voice: 'Puck')},
        ).completed ==
        0,
    'Reject mismatched server narrator in progress',
  );
  check(
    WholeBookProgress(plan: limits, serverJobs: {}).eligible == 0,
    'Display ineligible chapters without claiming completion',
  );
  server[1] = job('generating');
  check(
    beforeRestart.count(WholeBookChapterPhase.ready) == 1,
    'Published progress is immutable when server observations change',
  );
  check(
    WholeBookProgress(plan: plan([], {}), serverJobs: {}).total == 0,
    'Empty progress',
  );
  check(
    plan([chapter(0, text: '')], {}).count(WholeBookDisposition.ineligible) ==
        1,
    'Entirely silenced transformed text is not submitted',
  );
  check(
    plan([
          chapter(0, text: List.filled(250001, 'x').join()),
        ], {}).count(WholeBookDisposition.ineligible) ==
        1,
    'Limits apply after dictionary expansion',
  );
  print(
    'Whole-book planning/progress: $checks checks passed (no network or TTS).',
  );
}
