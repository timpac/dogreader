import 'dart:async';

/// Bounded preparation and seeking. False means navigation cancelled the work.
/// Success requires an observed player position, including targets near zero.
Future<bool> seekNarrationFromText({
  required double fraction,
  required Future<void> Function() load,
  required Future<void> Function() pause,
  required Future<void> Function(Duration) seek,
  required Duration? Function() duration,
  required Duration Function() position,
  required bool Function() isCurrent,
  Future<void> Function(Duration) wait = Future<void>.delayed,
}) async {
  if (!isCurrent()) return false;
  await load();
  if (!isCurrent()) return false;
  await pause();
  if (!isCurrent()) return false;
  final ratio = fraction.clamp(0.0, 1.0);
  Duration? total;
  if (ratio > 0) {
    for (var i = 0; i < 40; i++) {
      if (!isCurrent()) return false;
      total = duration();
      if (total != null && total > Duration.zero) break;
      await wait(const Duration(milliseconds: 250));
    }
    if (!isCurrent()) return false;
    total = duration();
    if (total == null || total <= Duration.zero) {
      throw StateError('Audio duration is unavailable; could not jump to your reading position.');
    }
  }
  final target = Duration(milliseconds: ((total?.inMilliseconds ?? 0) * ratio).round());
  Object? lastError;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (!isCurrent()) return false;
    try {
      await seek(target).timeout(const Duration(seconds: 3));
      for (var tick = 0; tick < 10; tick++) {
        if (!isCurrent()) return false;
        if ((position() - target).inMilliseconds.abs() <= 250) return true;
        await wait(const Duration(milliseconds: 100));
      }
    } on TimeoutException {
      // A timed-out native seek may still complete later. Do not issue another
      // concurrent seek; let the user explicitly retry once it has settled.
      if (!isCurrent()) return false;
      throw StateError('Audio seek timed out. Please retry Listen from this page.');
    } catch (e) {
      lastError = e;
    }
  }
  if (!isCurrent()) return false;
  throw StateError('Could not reach your reading position after 3 attempts. '
      'Please retry Listen from this page.${lastError == null ? '' : ' $lastError'}');
}
