import 'dart:math' as math;

class TrimmedAudio {
  const TrimmedAudio(
    this.samples, {
    required this.trimmedLeadingSamples,
    required this.trimmedTrailingSamples,
  });

  final List<double> samples;
  final int trimmedLeadingSamples;
  final int trimmedTrailingSamples;
}

/// Trims excessive model-generated leading/trailing digital silence while
/// preserving a short natural breath margin and applying a 5 ms edge ramp
/// to prevent clicks at chunk boundaries.
TrimmedAudio trimLeadingTrailingSilence(
  List<double> samples, {
  int sampleRate = 24000,
  double silenceThreshold = 120 / 32767.0,
  int keepLeadingMs = 15,
  int keepTrailingMs = 35,
  int fadeMs = 5,
}) {
  if (samples.isEmpty) {
    return TrimmedAudio(samples, trimmedLeadingSamples: 0, trimmedTrailingSamples: 0);
  }

  var firstVoice = -1;
  for (var i = 0; i < samples.length; i++) {
    if (samples[i].abs() > silenceThreshold) {
      firstVoice = i;
      break;
    }
  }
  if (firstVoice == -1) {
    return TrimmedAudio(samples, trimmedLeadingSamples: 0, trimmedTrailingSamples: 0);
  }

  var lastVoice = firstVoice;
  for (var i = samples.length - 1; i >= firstVoice; i--) {
    if (samples[i].abs() > silenceThreshold) {
      lastVoice = i;
      break;
    }
  }

  final keepLeading = (sampleRate * keepLeadingMs) ~/ 1000;
  final keepTrailing = (sampleRate * keepTrailingMs) ~/ 1000;
  final start = math.max(0, firstVoice - keepLeading);
  final end = math.min(samples.length, lastVoice + 1 + keepTrailing);

  if (start == 0 && end == samples.length) {
    return TrimmedAudio(samples, trimmedLeadingSamples: 0, trimmedTrailingSamples: 0);
  }

  final out = List<double>.from(samples.sublist(start, end), growable: false);
  final fadeSamples = math.min((sampleRate * fadeMs) ~/ 1000, out.length ~/ 4);
  if (fadeSamples > 0) {
    if (start > 0) {
      for (var i = 0; i < fadeSamples; i++) {
        out[i] *= i / fadeSamples;
      }
    }
    if (end < samples.length) {
      for (var i = 0; i < fadeSamples; i++) {
        out[out.length - 1 - i] *= i / fadeSamples;
      }
    }
  }

  return TrimmedAudio(
    out,
    trimmedLeadingSamples: start,
    trimmedTrailingSamples: samples.length - end,
  );
}
