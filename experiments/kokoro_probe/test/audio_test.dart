import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:kokoro_probe/audio.dart';

void main() {
  test('PCM16 matches build 145 scaling, rounding, clamping and byte order', () {
    final pcm = encodePcm16([0, 1, -1, 0.5, -0.5, 1.25, -1.25]);
    final data = ByteData.sublistView(pcm.bytes);
    expect(List.generate(7, (i) => data.getInt16(i * 2, Endian.little)),
        [0, 32767, -32767, 16384, -16384, 32767, -32767]);
    expect(pcm.clippedSamples, 2);
    expect(pcm.fullScaleSamples, 4);
    expect(pcm.peak, 1.25);
  });
  test('nonfinite audio fails before it can become WAV hiss', () {
    for (final value in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(() => encodePcm16([value]), throwsStateError);
    }
  });
  test('WAV declares 24 kHz mono PCM16 and exact data sizes', () {
    final header = wavHeader(3, 24000);
    final data = ByteData.sublistView(header);
    expect(ascii.decode(header.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(header.sublist(8, 12)), 'WAVE');
    expect(data.getUint32(4, Endian.little), 42);
    expect(data.getUint16(20, Endian.little), 1);
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(24, Endian.little), 24000);
    expect(data.getUint32(28, Endian.little), 48000);
    expect(data.getUint16(32, Endian.little), 2);
    expect(data.getUint16(34, Endian.little), 16);
    expect(data.getUint32(40, Endian.little), 6);
  });
  test('chunk concatenation retains samples without resampling or padding', () {
    final joined = [...encodePcm16([0.25, -0.25]).bytes, ...encodePcm16([0.5]).bytes];
    expect(joined, encodePcm16([0.25, -0.25, 0.5]).bytes);
  });
}
