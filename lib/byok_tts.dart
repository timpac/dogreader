import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'narration_cost.dart';
import 'narration_files.dart';
import 'narration_options.dart';
import 'narration_storage.dart';

const _keystoreChannel = MethodChannel('dogreader/keystore');
final _azureRegionPattern = RegExp(r'^[a-z0-9-]+$');
final _invalidXmlControl = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]');

class ByokTtsException implements Exception {
  const ByokTtsException(this.message, {this.statusCode, this.retryable = false});

  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() => message;
}

/// Encrypted on-device storage for user-supplied TTS API keys (Google Chirp HD,
/// Azure AI Speech, Speechify). Uses Android Keystore via [MethodChannel] on
/// Android, with an in-memory fallback in unit tests.
class ByokCredentialStore extends ChangeNotifier {
  ByokCredentialStore({
    Future<Map<String, String>> Function()? readAll,
    Future<void> Function(String key, String value)? writeKey,
    Future<void> Function(String key)? deleteKey,
  }) : _readAll = readAll ?? _platformReadAll,
       _writeKey = writeKey ?? _platformWriteKey,
       _deleteKey = deleteKey ?? _platformDeleteKey;

  final Future<Map<String, String>> Function() _readAll;
  final Future<void> Function(String key, String value) _writeKey;
  final Future<void> Function(String key) _deleteKey;

  static const keyGoogleApiKey = 'google_api_key';
  static const keyAzureSpeechKey = 'azure_speech_key';
  static const keyAzureSpeechRegion = 'azure_speech_region';
  static const keySpeechifyApiKey = 'speechify_api_key';
  static const keyGeminiApiKey = 'gemini_api_key';

  String googleApiKey = '';
  String azureSpeechKey = '';
  String azureSpeechRegion = '';
  String speechifyApiKey = '';
  String geminiApiKey = '';
  bool _loaded = false;

  bool get loaded => _loaded;

  static Future<Map<String, String>> _platformReadAll() async {
    try {
      final raw = await _keystoreChannel.invokeMapMethod<String, String>(
        'readAll',
      );
      return raw ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }

  static Future<void> _platformWriteKey(String key, String value) async {
    try {
      await _keystoreChannel.invokeMethod<void>('write', {
        'key': key,
        'value': value,
      });
    } on MissingPluginException {
      // No native keystore in unit tests.
    }
  }

  static Future<void> _platformDeleteKey(String key) async {
    try {
      await _keystoreChannel.invokeMethod<void>('delete', {'key': key});
    } on MissingPluginException {
      // No native keystore in unit tests.
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    final values = await _readAll();
    if (googleApiKey.isEmpty) {
      googleApiKey = (values[keyGoogleApiKey] ?? '').trim();
    }
    if (azureSpeechKey.isEmpty) {
      azureSpeechKey = (values[keyAzureSpeechKey] ?? '').trim();
    }
    if (azureSpeechRegion.isEmpty) {
      azureSpeechRegion = (values[keyAzureSpeechRegion] ?? '').trim().toLowerCase();
    }
    if (speechifyApiKey.isEmpty) {
      speechifyApiKey = (values[keySpeechifyApiKey] ?? '').trim();
    }
    if (geminiApiKey.isEmpty) {
      geminiApiKey = (values[keyGeminiApiKey] ?? '').trim();
    }
    _loaded = true;
    notifyListeners();
  }

  bool get hasGoogleKey => googleApiKey.isNotEmpty;

  bool get hasAzureCredentials =>
      azureSpeechKey.isNotEmpty &&
      azureSpeechRegion.isNotEmpty &&
      _azureRegionPattern.hasMatch(azureSpeechRegion);

  bool get hasSpeechifyKey => speechifyApiKey.isNotEmpty;

  bool get hasGeminiKey => geminiApiKey.isNotEmpty;

  bool isConfigured(String engine) => switch (engine) {
    'kokoro_offline' => true,
    'google' => hasGoogleKey,
    'azure' => hasAzureCredentials,
    'speechify' => hasSpeechifyKey,
    'gemini' => hasGeminiKey,
    _ => false,
  };

  String missingConfigMessage(String engine) => switch (engine) {
    'google' => 'Add your Google Cloud TTS API key in API settings first.',
    'azure' => 'Add your Azure Speech key and region in API settings first.',
    'speechify' => 'Add your Speechify API key in API settings first.',
    'gemini' => 'Add your Gemini API key in API settings first.',
    _ => 'Configure an API key in API settings first.',
  };

  String statusSummary(String engine) => switch (engine) {
    'kokoro_offline' => 'Runs on this device (no API key needed).',
    'google' => hasGoogleKey
        ? 'Google Cloud API key saved on this device.'
        : 'Add your Google Cloud TTS API key.',
    'azure' => hasAzureCredentials
        ? 'Azure Speech key saved ($azureSpeechRegion).'
        : 'Add your Azure Speech key and region (e.g. eastus).',
    'speechify' => hasSpeechifyKey
        ? 'Speechify API key saved on this device.'
        : 'Add your Speechify API key.',
    'gemini' => hasGeminiKey
        ? 'Gemini API key saved on this device.'
        : 'Add your Gemini API key for AI article summaries.',
    _ => 'Not configured.',
  };

  Future<void> setGoogleApiKey(String value) async {
    final trimmed = value.trim();
    googleApiKey = trimmed;
    if (trimmed.isEmpty) {
      await _deleteKey(keyGoogleApiKey);
    } else {
      await _writeKey(keyGoogleApiKey, trimmed);
    }
    notifyListeners();
  }

  Future<void> setAzureCredentials({
    required String key,
    required String region,
  }) async {
    final cleanKey = key.trim();
    final cleanRegion = region.trim().toLowerCase();
    if (cleanRegion.isNotEmpty && !_azureRegionPattern.hasMatch(cleanRegion)) {
      throw const ByokTtsException(
        'Azure region must contain only lowercase letters, numbers, and hyphens (for example: eastus, westus2).',
      );
    }
    azureSpeechKey = cleanKey;
    azureSpeechRegion = cleanRegion;
    if (cleanKey.isEmpty) {
      await _deleteKey(keyAzureSpeechKey);
    } else {
      await _writeKey(keyAzureSpeechKey, cleanKey);
    }
    if (cleanRegion.isEmpty) {
      await _deleteKey(keyAzureSpeechRegion);
    } else {
      await _writeKey(keyAzureSpeechRegion, cleanRegion);
    }
    notifyListeners();
  }

  Future<void> setSpeechifyApiKey(String value) async {
    final trimmed = value.trim();
    speechifyApiKey = trimmed;
    if (trimmed.isEmpty) {
      await _deleteKey(keySpeechifyApiKey);
    } else {
      await _writeKey(keySpeechifyApiKey, trimmed);
    }
    notifyListeners();
  }

  Future<void> setGeminiApiKey(String value) async {
    final trimmed = value.trim();
    geminiApiKey = trimmed;
    if (trimmed.isEmpty) {
      await _deleteKey(keyGeminiApiKey);
    } else {
      await _writeKey(keyGeminiApiKey, trimmed);
    }
    notifyListeners();
  }
}

String buildAzureSsml(String text, String voiceName) {
  final cleaned = text.replaceAll(_invalidXmlControl, ' ');
  final escaped = cleaned
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  final locale = voiceName.length >= 5 ? voiceName.substring(0, 5) : 'en-US';
  return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='$locale'>"
      "<voice name='$voiceName'>$escaped</voice></speak>";
}

int _measureUnits(String text, bool utf8Bytes) =>
    utf8Bytes ? utf8.encode(text).length : text.length;

/// Splits [text] into non-empty chunks staying within [maxUnits] characters or
/// UTF-8 bytes, preferring paragraph breaks, then sentence endings, then spaces.
List<String> splitByokText(
  String text, {
  required int maxUnits,
  bool utf8Bytes = false,
}) {
  final paragraphs = text.split(RegExp(r'\n\s*\n'));
  final chunks = <String>[];
  var buffer = '';

  void flush() {
    if (buffer.isNotEmpty) {
      chunks.add(buffer);
      buffer = '';
    }
  }

  for (final paragraph in paragraphs) {
    final sentences = paragraph.trim().split(RegExp(r'(?<=[.!?])\s+'));
    for (var sentence in sentences) {
      sentence = sentence.trim();
      if (sentence.isEmpty) continue;
      while (_measureUnits(sentence, utf8Bytes) > maxUnits) {
        flush();
        var cut = sentence.length;
        while (cut > 1 &&
            _measureUnits(sentence.substring(0, cut), utf8Bytes) > maxUnits) {
          cut = (cut * 0.85).floor();
        }
        final space = sentence.lastIndexOf(' ', cut);
        if (space > cut ~/ 2) cut = space;
        if (cut <= 0) cut = 1;
        final part = sentence.substring(0, cut).trim();
        if (part.isNotEmpty) chunks.add(part);
        sentence = sentence.substring(cut).trim();
      }
      if (sentence.isEmpty) continue;
      final candidate = buffer.isEmpty ? sentence : '$buffer $sentence';
      if (_measureUnits(candidate, utf8Bytes) > maxUnits && buffer.isNotEmpty) {
        flush();
        buffer = sentence;
      } else {
        buffer = candidate;
      }
    }
  }
  flush();
  return chunks;
}

/// Direct HTTPS synthesis client for user-owned API keys (Google Chirp HD,
/// Azure AI Speech, and Speechify). No Dogreader Cloud server is involved.
class ByokTtsClient {
  ByokTtsClient({
    required this.credentials,
    HttpClient Function()? httpClientFactory,
    Future<void> Function(Duration)? sleep,
    Uri? googleEndpoint,
    Uri? speechifyEndpoint,
    Uri Function(String region)? azureEndpointBuilder,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _sleep = sleep ?? Future<void>.delayed,
       _googleEndpoint =
           googleEndpoint ??
           Uri.parse('https://texttospeech.googleapis.com/v1/text:synthesize'),
       _speechifyEndpoint =
           speechifyEndpoint ??
           Uri.parse('https://api.sws.speechify.com/v1/audio/speech'),
       _azureEndpointBuilder =
           azureEndpointBuilder ??
           ((region) => Uri.parse(
             'https://$region.tts.speech.microsoft.com/cognitiveservices/v1',
           ));

  final ByokCredentialStore credentials;
  final HttpClient Function() _httpClientFactory;
  final Future<void> Function(Duration) _sleep;
  final Uri _googleEndpoint;
  final Uri _speechifyEndpoint;
  final Uri Function(String region) _azureEndpointBuilder;

  static const azureOutputFormat = 'audio-24khz-48kbitrate-mono-mp3';

  Future<Uint8List> synthesizeChunk({
    required String engine,
    required String voice,
    required String text,
  }) async {
    await credentials.load();
    if (!credentials.isConfigured(engine)) {
      throw ByokTtsException(credentials.missingConfigMessage(engine));
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return switch (engine) {
          'google' => await _synthesizeGoogle(text, voice),
          'azure' => await _synthesizeAzure(text, voice),
          'speechify' => await _synthesizeSpeechify(text, voice),
          _ => throw ByokTtsException('Unsupported BYOK engine: $engine'),
        };
      } on ByokTtsException catch (e) {
        if (!e.retryable || attempt == 2) rethrow;
        await _sleep(Duration(seconds: 2 * (attempt + 1)));
      } on SocketException {
        if (attempt == 2) {
          throw const ByokTtsException(
            'Network error while contacting TTS provider. Check your connection and try again.',
            retryable: true,
          );
        }
        await _sleep(Duration(seconds: 2 * (attempt + 1)));
      } on TimeoutException {
        if (attempt == 2) {
          throw const ByokTtsException(
            'TTS request timed out. Please try again.',
            retryable: true,
          );
        }
        await _sleep(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    throw const ByokTtsException('Synthesis failed after retries.');
  }

  String? _extractJsonErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] is String) {
          final msg = (err['message'] as String).trim();
          if (msg.isNotEmpty) {
            return msg.length > 240 ? '${msg.substring(0, 240)}…' : msg;
          }
        }
        if (err is String && err.trim().isNotEmpty) return err.trim();
        if (decoded['message'] is String &&
            (decoded['message'] as String).trim().isNotEmpty) {
          return (decoded['message'] as String).trim();
        }
      }
    } catch (_) {}
    return null;
  }

  Future<Uint8List> _synthesizeGoogle(String text, String voice) async {
    final cleanedText = text.replaceAll(_invalidXmlControl, ' ');
    final parts = voice.split('-');
    final languageCode = parts.length >= 2 ? '${parts[0]}-${parts[1]}' : 'en-US';
    final bodyBytes = utf8.encode(
      jsonEncode({
        'input': {'text': cleanedText},
        'voice': {'languageCode': languageCode, 'name': voice},
        'audioConfig': {'audioEncoding': 'MP3'},
      }),
    );
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .postUrl(_googleEndpoint)
          .timeout(const Duration(seconds: 15));
      req.headers.set('X-Goog-Api-Key', credentials.googleApiKey);
      req.headers.contentType = ContentType.json;
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      final response = await req.close().timeout(const Duration(seconds: 60));
      final body = await utf8.decoder.bind(response).join();
      final detail = _extractJsonErrorMessage(body);
      final suffix = detail == null ? '' : ': $detail';
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw ByokTtsException(
          'Google Cloud TTS rejected the key (HTTP ${response.statusCode})$suffix',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode == 429 || response.statusCode >= 500) {
        throw ByokTtsException(
          'Google Cloud TTS temporarily unavailable (HTTP ${response.statusCode})$suffix',
          statusCode: response.statusCode,
          retryable: true,
        );
      }
      if (response.statusCode >= 400) {
        throw ByokTtsException(
          'Google Cloud TTS error (HTTP ${response.statusCode})$suffix',
          statusCode: response.statusCode,
        );
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final encodedAudio = decoded['audioContent'] as String?;
      if (encodedAudio == null || encodedAudio.isEmpty) {
        throw const ByokTtsException('Google Cloud TTS returned empty audio.');
      }
      return base64Decode(encodedAudio);
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _synthesizeAzure(String text, String voice) async {
    final uri = _azureEndpointBuilder(credentials.azureSpeechRegion);
    final ssml = utf8.encode(buildAzureSsml(text, voice));
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 15));
      req.headers.set('Ocp-Apim-Subscription-Key', credentials.azureSpeechKey);
      req.headers.set('Content-Type', 'application/ssml+xml');
      req.headers.set('X-Microsoft-OutputFormat', azureOutputFormat);
      req.headers.set('User-Agent', 'dogreader-android');
      req.contentLength = ssml.length;
      req.add(ssml);
      final response = await req.close().timeout(const Duration(seconds: 60));
      final bytes = await _readResponseBytes(response);
      if (response.statusCode == 401) {
        throw const ByokTtsException(
          'Azure Speech key or region was rejected (HTTP 401).',
          statusCode: 401,
        );
      }
      if (response.statusCode == 403) {
        throw const ByokTtsException(
          'Azure Speech access denied or monthly free quota exhausted (HTTP 403).',
          statusCode: 403,
        );
      }
      if (response.statusCode == 429 || response.statusCode >= 500) {
        throw ByokTtsException(
          'Azure Speech temporarily unavailable (HTTP ${response.statusCode}).',
          statusCode: response.statusCode,
          retryable: true,
        );
      }
      if (response.statusCode >= 400) {
        final rawText = utf8.decode(bytes, allowMalformed: true).trim();
        final detail = rawText.isEmpty
            ? ''
            : ': ${rawText.length > 180 ? '${rawText.substring(0, 180)}…' : rawText}';
        throw ByokTtsException(
          'Azure Speech rejected the request (HTTP ${response.statusCode})$detail',
          statusCode: response.statusCode,
        );
      }
      if (bytes.isEmpty) {
        throw const ByokTtsException('Azure Speech returned empty audio.');
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _synthesizeSpeechify(String text, String voice) async {
    final bodyBytes = utf8.encode(
      jsonEncode({
        'input': text,
        'voice_id': voice,
        'audio_format': 'mp3',
      }),
    );
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .postUrl(_speechifyEndpoint)
          .timeout(const Duration(seconds: 15));
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${credentials.speechifyApiKey}',
      );
      req.headers.contentType = ContentType.json;
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      final response = await req.close().timeout(const Duration(seconds: 60));
      final body = await utf8.decoder.bind(response).join();
      final detail = _extractJsonErrorMessage(body);
      final suffix = detail == null ? '' : ': $detail';
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw ByokTtsException(
          'Speechify API key was rejected (HTTP ${response.statusCode})$suffix',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode == 429 || response.statusCode >= 500) {
        throw ByokTtsException(
          'Speechify API temporarily unavailable (HTTP ${response.statusCode})$suffix',
          statusCode: response.statusCode,
          retryable: true,
        );
      }
      if (response.statusCode >= 400) {
        throw ByokTtsException(
          'Speechify API error (HTTP ${response.statusCode})$suffix',
          statusCode: response.statusCode,
        );
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final encodedAudio = decoded['audio_data'] as String?;
      if (encodedAudio == null || encodedAudio.isEmpty) {
        throw const ByokTtsException('Speechify API returned empty audio.');
      }
      return base64Decode(encodedAudio);
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _readResponseBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  List<String> splitForEngine(String engine, String text) => switch (engine) {
    'google' => splitByokText(text, maxUnits: 2000, utf8Bytes: true),
    'azure' => splitByokText(text, maxUnits: 2800),
    'speechify' => splitByokText(text, maxUnits: 2000),
    _ => splitByokText(text, maxUnits: 2500),
  };

  Future<void> synthesizeChapterToFile({
    required String engine,
    required String voice,
    required String text,
    required File outputFile,
    void Function(int completedChunks, int totalChunks)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final chunks = splitForEngine(engine, text);
    if (chunks.isEmpty) {
      throw const ByokTtsException('Chapter text is empty.');
    }
    final sink = outputFile.openWrite();
    try {
      for (var i = 0; i < chunks.length; i++) {
        if (isCancelled?.call() == true) {
          throw const ByokTtsException('Generation cancelled.');
        }
        final audioBytes = await synthesizeChunk(
          engine: engine,
          voice: voice,
          text: chunks[i],
        );
        sink.add(audioBytes);
        onProgress?.call(i + 1, chunks.length);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<File?> synthesizePreview({
    required NarrationPreference preference,
    required String sample,
    required bool Function() isCurrent,
  }) async {
    final trimmed = sample.trim();
    if (trimmed.isEmpty) return null;
    final snippet = trimmed.length > 260 ? trimmed.substring(0, 260) : trimmed;
    final bytes = await synthesizeChunk(
      engine: preference.engine,
      voice: preference.voice,
      text: snippet,
    );
    if (!isCurrent()) return null;
    final root = await getTemporaryDirectory();
    final preview = File(
      '${root.path}/byok_preview_${preference.engine}_${DateTime.now().microsecondsSinceEpoch}.mp3',
    );
    await preview.writeAsBytes(bytes, flush: true);
    return isCurrent() ? preview : null;
  }

  Future<String> testConnection(String engine) async {
    final voices = narrationVoices[engine];
    if (voices == null || voices.isEmpty) {
      throw ByokTtsException('Unsupported engine: $engine');
    }
    final voice = voices.keys.first;
    final bytes = await synthesizeChunk(
      engine: engine,
      voice: voice,
      text: 'Hello from Dogreader.',
    );
    if (bytes.length < 200) {
      throw const ByokTtsException('Provider returned unexpectedly short audio.');
    }
    return 'Connected! Synthesized test audio with ${voices[voice]}.';
  }
}

/// Runs queued BYOK chapter/article generation directly from the device and
/// commits completed audio + seek metadata atomically via [replaceNarrationFile].
class ByokNarrationRunner extends ChangeNotifier {
  ByokNarrationRunner({
    required this.client,
    required this.documentsDirectory,
    required this.beforeReplace,
    this.costTracker,
  });

  final ByokTtsClient client;
  final Future<Directory> Function() documentsDirectory;
  final Future<void> Function(String bookId, int index) beforeReplace;
  final NarrationCostTracker? costTracker;

  final Set<String> _inFlight = {};
  final Set<String> _activeBooks = {};
  final Set<String> _cancelledBooks = {};

  bool inFlight(String bookId, int index) => _inFlight.contains('$bookId:$index');
  bool bookBusy(String bookId) => _activeBooks.contains(bookId);

  void cancelBook(String bookId) {
    if (_activeBooks.contains(bookId)) {
      _cancelledBooks.add(bookId);
      notifyListeners();
    }
  }

  Future<void> runWaitingJobs({
    required String bookId,
    required Map<int, Map<String, dynamic>> jobs,
    required String Function(int index) textForChapter,
    required Future<void> Function() onSave,
  }) async {
    if (_activeBooks.contains(bookId)) return;
    _activeBooks.add(bookId);
    _cancelledBooks.remove(bookId);
    notifyListeners();
    try {
      final root = await documentsDirectory();
      final narrationDir = Directory('${root.path}/narration');
      if (!await narrationDir.exists()) {
        await narrationDir.create(recursive: true);
      }
      final indices = jobs.keys.toList()..sort();
      for (final index in indices) {
        if (_cancelledBooks.contains(bookId)) break;
        final job = jobs[index];
        if (job == null ||
            job['status'] != 'waiting' ||
            job['engine'] == 'kokoro_offline') {
          continue;
        }
        final engine = job['engine'] as String? ?? 'google';
        final voice =
            job['voice'] as String? ??
            narrationVoices[engine]?.keys.first ??
            '';
        final key = '$bookId:$index';
        _inFlight.add(key);

        final String spokenText;
        try {
          spokenText = textForChapter(index);
        } catch (e) {
          jobs[index] = {
            ...job,
            'status': 'error',
            'delivery': 'failed',
            'failureStage': 'generation',
            'error': e is StateError ? e.message : '$e',
          };
          _inFlight.remove(key);
          await onSave();
          notifyListeners();
          continue;
        }

        jobs[index] = {
          ...job,
          'status': 'generating',
          'delivery': 'pending',
          'engine': engine,
          'voice': voice,
        }
          ..remove('error')
          ..remove('deliveryError')
          ..remove('failureStage');
        await onSave();
        notifyListeners();

        final target = File('${narrationDir.path}/${bookId}_$index.mp3');
        final staged = File('${target.path}.byok');
        try {
          if (await staged.exists()) await staged.delete();
          await client.synthesizeChapterToFile(
            engine: engine,
            voice: voice,
            text: spokenText,
            outputFile: staged,
            isCancelled: () => _cancelledBooks.contains(bookId),
            onProgress: (completed, total) {
              final current = jobs[index];
              if (current == null) return;
              current['progress'] = completed;
              current['chunks'] = total;
              notifyListeners();
            },
          );

          final size = await staged.length();
          final stateFile = File('${root.path}/narration_state.json');
          final recordingId =
              'byok_${engine}_${DateTime.now().microsecondsSinceEpoch}_$index';
          final completed = Map<String, dynamic>.from(jobs[index] ?? {})
            ..['id'] = recordingId
            ..['engine'] = engine
            ..['voice'] = voice
            ..['model_version'] = 'byok-$engine-v1'
            ..['status'] = 'ready'
            ..['delivery'] = 'downloaded'
            ..['localAvailable'] = true
            ..remove('error')
            ..remove('deliveryError')
            ..remove('failureStage');
          final isReplacement = completed['previousRecording'] is Map;

          await replaceNarrationFile(
            target,
            staged.openRead(),
            contentLength: size,
            metadataFile: stateFile,
            metadataKey: '$bookId:$index',
            beforeReplace: () => beforeReplace(bookId, index),
            afterReplace: () async {
              await updateNarrationJson(stateFile, (data) {
                final old = Map<String, dynamic>.from(
                  (data['$bookId:$index'] as Map?) ?? {},
                );
                data['$bookId:$index'] = {
                  ...old,
                  'path': target.path,
                  'positionMs': isReplacement ? 0 : old['positionMs'] ?? 0,
                  ...recordingMetadata(completed),
                  'recording_id': recordingId,
                };
              });
            },
          );
          completed.remove('previousRecording');
          jobs[index] = completed;
          await onSave();
          if (costTracker != null && (engine == 'google' || engine == 'azure')) {
            await costTracker!.recordSubmission(
              engine: engine,
              characters: spokenText.runes.length,
              jobId: recordingId,
            );
          }
          notifyListeners();
        } catch (e) {
          final previous = jobs[index]?['previousRecording'];
          if (_cancelledBooks.contains(bookId) && previous is Map) {
            jobs[index] = Map<String, dynamic>.from(previous);
          } else {
            jobs[index] = {
              ...?jobs[index],
              'status': 'error',
              'delivery': 'failed',
              'failureStage': 'generation',
              'error': '$e',
            };
          }
          await onSave();
          notifyListeners();
        } finally {
          if (await staged.exists()) {
            try {
              await staged.delete();
            } catch (_) {}
          }
          _inFlight.remove(key);
        }
      }
    } finally {
      _activeBooks.remove(bookId);
      _cancelledBooks.remove(bookId);
      notifyListeners();
    }
  }
}
