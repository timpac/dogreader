import 'dart:convert';
import 'dart:typed_data';

// Same conversion as build 145; no resampling, filtering, dithering or gain.
class Pcm16Chunk {
  final Uint8List bytes;
  final double peak, sum, squareSum;
  final int clippedSamples, fullScaleSamples, firstPcm, lastPcm;
  Pcm16Chunk(this.bytes, this.peak, this.sum, this.squareSum,
      this.clippedSamples, this.fullScaleSamples, this.firstPcm, this.lastPcm);
}

Pcm16Chunk encodePcm16(List<double> samples) {
  if (samples.isEmpty) throw StateError('Empty audio');
  final bytes = ByteData(samples.length * 2);
  double peak = 0, sum = 0, squares = 0;
  var clipped = 0, fullScale = 0;
  for (var j = 0; j < samples.length; j++) {
    final sample = samples[j];
    if (!sample.isFinite) throw StateError('Non-finite audio sample');
    if (sample.abs() > peak) peak = sample.abs();
    sum += sample;
    squares += sample * sample;
    if (sample.abs() > 1) clipped++;
    if (sample.abs() >= 1) fullScale++;
    bytes.setInt16(j * 2, (sample.clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return Pcm16Chunk(bytes.buffer.asUint8List(), peak, sum, squares,
      clipped, fullScale, bytes.getInt16(0, Endian.little),
      bytes.getInt16(bytes.lengthInBytes - 2, Endian.little));
}

Uint8List wavHeader(int frames, int rate) {
  final bytes = ByteData(44);
  final raw = bytes.buffer.asUint8List();
  void tag(int offset, String value) => raw.setRange(offset, offset + value.length, ascii.encode(value));
  tag(0, 'RIFF'); bytes.setUint32(4, 36 + frames * 2, Endian.little);
  tag(8, 'WAVE'); tag(12, 'fmt '); bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little); bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little); bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little); bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data'); bytes.setUint32(40, frames * 2, Endian.little);
  return raw;
}
