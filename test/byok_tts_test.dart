import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/api_settings_screen.dart';
import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/article_summary.dart';
import 'package:audiobook_app/byok_tts.dart';
import 'package:audiobook_app/narration_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

ByokCredentialStore _memoryStore([Map<String, String>? initial]) {
  final data = Map<String, String>.from(initial ?? const {});
  return ByokCredentialStore(
    readAll: () async => Map<String, String>.from(data),
    writeKey: (key, value) async => data[key] = value,
    deleteKey: (key) async => data.remove(key),
  );
}

void main() {
  test('ByokCredentialStore persists keys, validates Azure region, and reports status', () async {
    final backing = <String, String>{};
    final store = ByokCredentialStore(
      readAll: () async => Map<String, String>.from(backing),
      writeKey: (k, v) async => backing[k] = v,
      deleteKey: (k) async => backing.remove(k),
    );
    await store.load();
    expect(store.isConfigured('kokoro_offline'), isTrue);
    expect(store.isConfigured('google'), isFalse);
    expect(store.isConfigured('azure'), isFalse);
    expect(store.isConfigured('speechify'), isFalse);

    await store.setGoogleApiKey('  g-key-123  ');
    expect(store.isConfigured('google'), isTrue);
    expect(backing[ByokCredentialStore.keyGoogleApiKey], 'g-key-123');

    await expectLater(
      () => store.setAzureCredentials(key: 'az-key', region: 'East US!'),
      throwsA(isA<ByokTtsException>()),
    );
    await store.setAzureCredentials(key: 'az-key', region: ' EastUS ');
    expect(store.isConfigured('azure'), isTrue);
    expect(store.azureSpeechRegion, 'eastus');

    await store.setSpeechifyApiKey('sp-key-999');
    expect(store.isConfigured('speechify'), isTrue);

    await store.setGoogleApiKey('');
    expect(store.isConfigured('google'), isFalse);
    expect(backing.containsKey(ByokCredentialStore.keyGoogleApiKey), isFalse);
  });

  test('splitByokText respects limits and buildAzureSsml escapes XML safely', () {
    final text = 'First sentence. Second sentence.\n\nThird paragraph with more words.';
    final chunks = splitByokText(text, maxUnits: 35);
    expect(chunks.length, greaterThanOrEqualTo(2));
    for (final chunk in chunks) {
      expect(chunk.length, lessThanOrEqualTo(35));
    }
    final ssml = buildAzureSsml('Tom & Jerry <1>\x00 "hi"', 'en-GB-RyanNeural');
    expect(ssml, contains("xml:lang='en-GB'"));
    expect(ssml, contains("name='en-GB-RyanNeural'"));
    expect(ssml, contains('Tom &amp; Jerry &lt;1&gt;  &quot;hi&quot;'));
  });

  test('ByokTtsClient synthesizes directly with Google Chirp, Azure Speech, and Speechify', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final fakeMp3 = List<int>.filled(1200, 0x41);
      final requests = <Map<String, Object?>>[];

      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        requests.add({
          'path': req.uri.path,
          'googleKey': req.headers.value('X-Goog-Api-Key'),
          'auth': req.headers.value(HttpHeaders.authorizationHeader),
          'azureKey': req.headers.value('Ocp-Apim-Subscription-Key'),
          'outputFormat': req.headers.value('X-Microsoft-OutputFormat'),
          'body': body,
        });
        if (req.uri.path == '/google') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'audioContent': base64Encode(fakeMp3)}));
        } else if (req.uri.path == '/google-err') {
          req.response.statusCode = 400;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'error': {
                'code': 400,
                'message': 'API key not valid. Please pass a valid API key.',
              },
            }),
          );
        } else if (req.uri.path == '/azure/eastus') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType('audio', 'mpeg');
          req.response.add(fakeMp3);
        } else if (req.uri.path == '/speechify') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'audio_data': base64Encode(fakeMp3)}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final store = _memoryStore({
        ByokCredentialStore.keyGoogleApiKey: 'g-secret',
        ByokCredentialStore.keyAzureSpeechKey: 'az-secret',
        ByokCredentialStore.keyAzureSpeechRegion: 'eastus',
        ByokCredentialStore.keySpeechifyApiKey: 'sp-secret',
      });
      final base = 'http://127.0.0.1:${server.port}';
      final client = ByokTtsClient(
        credentials: store,
        sleep: (_) async {},
        googleEndpoint: Uri.parse('$base/google'),
        azureEndpointBuilder: (region) => Uri.parse('$base/azure/$region'),
        speechifyEndpoint: Uri.parse('$base/speechify'),
      );

      final googleBytes = await client.synthesizeChunk(
        engine: 'google',
        voice: 'en-US-Chirp3-HD-Achernar',
        text: 'Hello Google.',
      );
      expect(googleBytes, fakeMp3);

      final azureBytes = await client.synthesizeChunk(
        engine: 'azure',
        voice: 'en-US-AndrewMultilingualNeural',
        text: 'Hello Azure.',
      );
      expect(azureBytes, fakeMp3);

      final speechifyBytes = await client.synthesizeChunk(
        engine: 'speechify',
        voice: 'george',
        text: 'Hello Speechify.',
      );
      expect(speechifyBytes, fakeMp3);

      expect(requests[0]['googleKey'], 'g-secret');
      expect(requests[1]['azureKey'], 'az-secret');
      expect(requests[1]['outputFormat'], ByokTtsClient.azureOutputFormat);
      expect(requests[2]['auth'], 'Bearer sp-secret');

      final errClient = ByokTtsClient(
        credentials: store,
        sleep: (_) async {},
        googleEndpoint: Uri.parse('$base/google-err'),
      );
      await expectLater(
        () => errClient.synthesizeChunk(
          engine: 'google',
          voice: 'en-US-Chirp3-HD-Puck',
          text: 'Hello.',
        ),
        throwsA(
          isA<ByokTtsException>().having(
            (e) => e.message,
            'message',
            contains('API key not valid'),
          ),
        ),
      );

      final testResult = await client.testConnection('azure');
      expect(testResult, contains('Connected!'));
    }, _RealHttp());
  });

  test('ByokNarrationRunner writes chapter MP3 and narration_state atomically', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final fakeMp3 = List<int>.filled(1500, 0x55);
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('audio', 'mpeg');
        req.response.add(fakeMp3);
        await req.response.close();
      });

      final tempDir = await Directory.systemTemp.createTemp('byok_runner_');
      addTearDown(() => tempDir.delete(recursive: true));

      final store = _memoryStore({
        ByokCredentialStore.keyAzureSpeechKey: 'az-secret',
        ByokCredentialStore.keyAzureSpeechRegion: 'eastus',
      });
      final client = ByokTtsClient(
        credentials: store,
        sleep: (_) async {},
        azureEndpointBuilder: (_) =>
            Uri.parse('http://127.0.0.1:${server.port}/azure'),
      );
      final runner = ByokNarrationRunner(
        client: client,
        documentsDirectory: () async => tempDir,
        beforeReplace: (_, _) async {},
      );
      final jobs = <int, Map<String, dynamic>>{
        0: {
          'status': 'waiting',
          'engine': 'azure',
          'voice': 'en-US-AndrewMultilingualNeural',
          'narration_offsets': [0, 5],
        },
      };

      await runner.runWaitingJobs(
        bookId: 'b1',
        jobs: jobs,
        textForChapter: (_) => 'Chapter one text.',
        onSave: () async {},
      );

      final mp3 = File('${tempDir.path}/narration/b1_0.mp3');
      expect(await mp3.exists(), isTrue);
      expect(await mp3.length(), 1500);
      expect(jobs[0]?['status'], 'ready');
      expect(jobs[0]?['delivery'], 'downloaded');
      final state = jsonDecode(
        await File('${tempDir.path}/narration_state.json').readAsString(),
      ) as Map<String, dynamic>;
      expect(state['b1:0']['engine'], 'azure');
      expect(state['b1:0']['narration_offsets'], [0, 5]);
    }, _RealHttp());
  });

  testWidgets('ApiSettingsScreen saves Google, Azure, and Speechify keys', (tester) async {
    final store = _memoryStore();
    final client = ByokTtsClient(credentials: store);
    await tester.pumpWidget(
      MaterialApp(
        home: ApiSettingsScreen(credentials: store, ttsClient: client),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Kokoro (On-Device)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('google_api_key_field')), 'g-123');
    await tester.tap(find.byKey(const Key('save_google_key_button')));
    await tester.pumpAndSettle();
    expect(store.googleApiKey, 'g-123');

    await tester.scrollUntilVisible(
      find.byKey(const Key('save_azure_key_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byKey(const Key('azure_speech_key_field')), 'az-123');
    await tester.enterText(find.byKey(const Key('azure_speech_region_field')), 'westus2');
    await tester.ensureVisible(find.byKey(const Key('save_azure_key_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_azure_key_button')));
    await tester.pumpAndSettle();
    expect(store.azureSpeechKey, 'az-123');
    expect(store.azureSpeechRegion, 'westus2');

    await tester.scrollUntilVisible(
      find.byKey(const Key('save_speechify_key_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byKey(const Key('speechify_api_key_field')), 'sp-123');
    await tester.ensureVisible(find.byKey(const Key('save_speechify_key_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_speechify_key_button')));
    await tester.pumpAndSettle();
    expect(store.speechifyApiKey, 'sp-123');

    await tester.scrollUntilVisible(
      find.byKey(const Key('speechify_key_help_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('speechify_key_help_button')));
    await tester.pumpAndSettle();
    expect(find.text('How to get a Speechify API key'), findsWidgets);
    expect(find.text('https://platform.speechify.ai/api-keys'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(NarrationPreference.fromJson(const {}).engine, 'kokoro_offline');
  });

  test('ArticleSummaryClient summarizes directly with Gemini Flash-Lite BYOK key', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? receivedKey;
      server.listen((req) async {
        receivedKey = req.headers.value('X-Goog-Api-Key');
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text':
                          'This is a concise, clear prose summary generated directly by Gemini Flash-Lite for reading aloud on your phone without any backend server.',
                    },
                  ],
                },
              },
            ],
            'usageMetadata': {
              'promptTokenCount': 250,
              'candidatesTokenCount': 40,
            },
          }),
        );
        await req.response.close();
      });

      final tempDir = await Directory.systemTemp.createTemp('gemini_summary_');
      addTearDown(() => tempDir.delete(recursive: true));

      final store = _memoryStore({
        ByokCredentialStore.keyGeminiApiKey: 'gem-secret-key',
      });
      final article = ImportedArticle(
        title: 'Test Article',
        sourceUrl: 'https://example.org/test',
        blocks: [ArticleBlock(List.filled(40, 'Sample sentence. ').join())],
      );
      final client = ArticleSummaryClient(
        tempDir,
        enabled: true,
        credentials: store,
        geminiEndpoint: Uri.parse('http://127.0.0.1:${server.port}/gemini'),
      );

      final est = await client.estimate(article, SummaryDepth.brief);
      expect(est['model'], geminiSummaryModel);
      expect(est['estimatedInputTokens'], greaterThan(0));

      final summary = await client.summarize(article, SummaryDepth.brief);
      expect(receivedKey, 'gem-secret-key');
      expect(summary.depth, SummaryDepth.brief);
      expect(summary.text, contains('Gemini Flash-Lite'));
      expect(summary.usage?['inputTokens'], 250);
    }, _RealHttp());
  });
}
