import 'whole_book_preflight.dart';

/// Read-only projection, not a queue or a persisted-data/API contract. Inputs
/// come from the frozen plan, latest server observations and validated local
/// downloads. A failed download leaves cloud-ready audio ready, not TTS-failed.
enum WholeBookChapterPhase {
  pending,
  queued,
  generating,
  ready,
  downloaded,
  failed,
  ineligible,
}

class WholeBookChapterProgress {
  final int index;
  final WholeBookChapterPhase phase;
  final bool downloadFailed;

  const WholeBookChapterProgress(this.index, this.phase, this.downloadFailed);
}

class WholeBookProgress {
  final List<WholeBookChapterProgress> chapters;

  WholeBookProgress._(this.chapters);

  factory WholeBookProgress({
    required WholeBookPreflight plan,
    required Map<int, Map<String, dynamic>> serverJobs,
    // Only IDs whose complete local MP3 has been validated against the
    // recording identity; file existence alone must not populate this map.
    Map<int, String> verifiedDownloads = const {},
    Set<int> downloadFailures = const {},
  }) {
    final chapters = <WholeBookChapterProgress>[];
    for (final entry in plan.entries) {
      final index = entry.chapter.index;
      final expected = entry.chapter.expectedRecordingId;
      final job = serverJobs[index];
      var phase = WholeBookChapterPhase.pending;
      if (expected != null &&
          expected.isNotEmpty &&
          verifiedDownloads[index] == expected) {
        // Valid offline audio remains usable if its cloud status is unavailable.
        phase = WholeBookChapterPhase.downloaded;
      } else if (expected != null &&
          expected.isNotEmpty &&
          job?['id'] == expected &&
          plan.settings.matches(job!)) {
        phase = switch (job['status']) {
          'queued' => WholeBookChapterPhase.queued,
          'generating' => WholeBookChapterPhase.generating,
          'ready' => WholeBookChapterPhase.ready,
          'error' => WholeBookChapterPhase.failed,
          _ => WholeBookChapterPhase.pending,
        };
      } else if (entry.disposition == WholeBookDisposition.ineligible) {
        phase = WholeBookChapterPhase.ineligible;
      }
      chapters.add(
        WholeBookChapterProgress(
          index,
          phase,
          phase == WholeBookChapterPhase.ready &&
              downloadFailures.contains(index),
        ),
      );
    }
    return WholeBookProgress._(List.unmodifiable(chapters));
  }

  int count(WholeBookChapterPhase phase) =>
      chapters.where((chapter) => chapter.phase == phase).length;

  int get total => chapters.length;
  int get completed =>
      count(WholeBookChapterPhase.ready) +
      count(WholeBookChapterPhase.downloaded);
  int get eligible => total - count(WholeBookChapterPhase.ineligible);
  int get failedDownloads =>
      chapters.where((chapter) => chapter.downloadFailed).length;
}
