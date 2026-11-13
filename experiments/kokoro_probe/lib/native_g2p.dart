import 'dart:convert';
import 'dart:ffi';
import 'third_party/fonnx_misaki/misaki_fallback.dart';
import 'third_party/fonnx_misaki/misaki_en.dart' show MisakiPs;

typedef _CreateC = Pointer<Void> Function(Pointer<Uint8>, Pointer<Uint8>, Int32, Pointer<Uint8>, Size);
typedef _Create = Pointer<Void> Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _ArgmaxC = Int32 Function(Pointer<Void>, Pointer<Int64>, Size, Pointer<Int64>, Size, Pointer<Uint8>, Size);
typedef _Argmax = int Function(Pointer<Void>, Pointer<Int64>, int, Pointer<Int64>, int, Pointer<Uint8>, int);

/// Owns one BART session in Sherpa's ORT; no FONNX runtime/package is imported.
class NativeG2p {
  NativeG2p(String model, String config, {int threads = 2, String? bridgePath, String? runtimePath})
      : library = DynamicLibrary.open(bridgePath ?? 'libkokoro_g2p.so'),
        vocab = MisakiFallbackVocab(config),
        allowed = (jsonDecode(config)['grapheme_chars'] as String).runes.toSet() {
    final error = _buffer(4096), modelName = _string(model);
    final runtimeName = _string(runtimePath ?? 'libonnxruntime.so');
    try {
      _engine = _create(modelName.cast(), runtimeName.cast(), threads, error.cast(), 4096);
      if (_engine == nullptr) throw StateError('English fallback: ${_read(error.cast(), 4096)}');
      runtimeVersion = _read(_version(_engine), 128);
    } finally {
      _free(runtimeName); _free(modelName); _free(error);
    }
  }

  final DynamicLibrary library;
  final MisakiFallbackVocab vocab;
  final Set<int> allowed;
  final events = <Map<String, dynamic>>[];
  final _cache = <String, String>{};
  late final String runtimeVersion;
  Pointer<Void> _engine = nullptr;
  late final _alloc = library.lookupFunction<Pointer<Void> Function(Size), Pointer<Void> Function(int)>('kokoro_g2p_alloc');
  late final _free = library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('kokoro_g2p_free');
  late final _destroy = library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('kokoro_g2p_destroy');
  late final _version = library.lookupFunction<Pointer<Uint8> Function(Pointer<Void>), Pointer<Uint8> Function(Pointer<Void>)>('kokoro_g2p_version');
  late final _create = library.lookupFunction<_CreateC, _Create>('kokoro_g2p_create');
  late final _argmax = library.lookupFunction<_ArgmaxC, _Argmax>('kokoro_g2p_argmax');

  Pointer<Void> _buffer(int bytes) {
    final p = _alloc(bytes);
    if (p == nullptr) throw StateError('English fallback allocation failed');
    return p;
  }
  Pointer<Void> _string(String value) {
    final bytes = utf8.encode(value);
    final p = _buffer(bytes.length + 1);
    p.cast<Uint8>().asTypedList(bytes.length + 1).setAll(0, bytes);
    return p;
  }
  static String _read(Pointer<Uint8> p, int limit) {
    final bytes = <int>[];
    for (var i = 0; i < limit && p[i] != 0; i++) { bytes.add(p[i]); }
    return utf8.decode(bytes);
  }

  MisakiPs phonemize(String word) {
    if (_engine == nullptr) throw StateError('English fallback is closed');
    if (word.runes.any((r) => !allowed.contains(r))) {
      throw FormatException('Unsupported fallback character in "$word". No audio generated.');
    }
    final source = vocab.source(word);
    if (source == null) throw FormatException('Fallback word exceeds 62 characters: "$word".');
    final cached = _cache[word];
    if (cached != null) {
      events.add({'word': word, 'phonemes': cached, 'cached': true});
      return (cached, 1);
    }
    final src = _buffer(source.length * sizeOf<Int64>());
    final dec = _buffer(vocab.maxPositions * sizeOf<Int64>());
    final error = _buffer(4096);
    try {
      src.cast<Int64>().asTypedList(source.length).setAll(0, source);
      final ids = <int>[MisakiFallbackVocab.bos];
      while (ids.last != MisakiFallbackVocab.eos) {
        // Never force EOS: that can disguise truncated words.
        if (ids.length >= vocab.maxPositions - 1) {
          throw FormatException('Fallback decoding limit reached for "$word".');
        }
        dec.cast<Int64>().asTypedList(ids.length).setAll(0, ids);
        final id = _argmax(_engine, src.cast(), source.length, dec.cast(), ids.length, error.cast(), 4096);
        if (id < 0) throw StateError('English fallback: ${_read(error.cast(), 4096)}');
        if (id != MisakiFallbackVocab.eos && id <= 3) {
          throw FormatException('Fallback returned a reserved/unknown token for "$word".');
        }
        ids.add(id);
      }
      final phones = vocab.phonemes(ids).$1;
      if (phones == null || phones.isEmpty) throw FormatException('No fallback pronunciation for "$word".');
      _cache[word] = phones;
      events.add({'word': word, 'phonemes': phones, 'cached': false});
      return (phones, 1);
    } finally {
      _free(error); _free(dec); _free(src);
    }
  }

  void close() {
    if (_engine != nullptr) { _destroy(_engine); _engine = nullptr; }
  }
}
