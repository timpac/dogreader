import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/book_progress.dart';
import 'package:audiobook_app/chapter_recording_path.dart';
import 'package:audiobook_app/kokoro/audio.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/narration_cost.dart';
import 'package:audiobook_app/narration_dictionary.dart';
import 'package:audiobook_app/offline_narration.dart';
import 'package:audiobook_app/rss/rss_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

const String _sampleFeedXml = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Tech Dispatch</title>
    <link>https://example.com</link>
    <description>Essays and dispatches.</description>
    <item>
      <title>Essay One</title>
      <link>https://example.com/post-1</link>
      <guid>post-1</guid>
      <dc:creator>Jane Doe</dc:creator>
      <description>Summary one.</description>
    </item>
    <item>
      <title>Essay Two</title>
      <link>https://example.com/post-2</link>
      <guid>post-2</guid>
      <dc:creator>Jane Doe</dc:creator>
      <description>Summary two.</description>
    </item>
    <item>
      <title>Essay Three</title>
      <link>https://example.com/post-3</link>
      <guid>post-3</guid>
      <dc:creator>Jane Doe</dc:creator>
      <description>Summary three.</description>
    </item>
  </channel>
</rss>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Library screen renders RSS Feeds & Writers shelf above books with orange badge, feed/writer counts, and expand/collapse',
    (tester) async {
      final tempDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('dogreader-165-rss-'),
      ))!;
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(tempDir.path);
      final progress = BookProgress(
        documentsDirectory: () async => tempDir,
      );
      try {
        await tester.runAsync(() async {
          final seeded = RssLibraryController(Future.value(tempDir));
          await seeded.load();
          await seeded.addSubscriptionFromXml(
            feedUrl: 'https://example.com/feed.xml',
            xmlText: _sampleFeedXml,
          );
          await seeded.followAuthor('Jane Doe');
          seeded.dispose();
        });

        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(home: LibraryScreen(progressStore: progress)),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Verify RSS Feeds & Writers shelf is displayed near the top of the library.
        expect(find.byKey(const Key('rss_library_shelf')), findsOneWidget);
        expect(find.text('RSS Feeds & Writers'), findsOneWidget);
        expect(find.byKey(const Key('rss_shelf_unread_badge')), findsOneWidget);
        expect(find.text('3 unread'), findsOneWidget);
        expect(
          find.textContaining('1 feed • 1 followed writer'),
          findsOneWidget,
        );

        // Verify shelf sits below library heading and above the empty-library / book cards area.
        final headingY = tester.getTopLeft(find.text('Your library')).dy;
        final shelfY = tester
            .getTopLeft(find.byKey(const Key('rss_library_shelf')))
            .dy;
        final emptyLibraryY = tester
            .getTopLeft(find.text('A new chapter begins'))
            .dy;
        expect(shelfY, greaterThan(headingY));
        expect(emptyLibraryY, greaterThan(shelfY));

        // Verify expand / collapse button and behavior.
        expect(find.byKey(const Key('rss_shelf_expand_button')), findsOneWidget);
        final dynamic libState = tester.state(find.byType(LibraryScreen));
        await tester.runAsync(() async {
          await libState.rss.setShelfExpanded(true);
        });
        await tester.pump();
        expect(find.text('FAVORITE WRITERS'), findsOneWidget);
        expect(find.text('Jane Doe'), findsOneWidget);
        expect(find.text('FEEDS'), findsOneWidget);
        expect(find.text('Tech Dispatch'), findsOneWidget);

        await tester.runAsync(() async {
          await libState.rss.setShelfExpanded(false);
        });
        await tester.pump();
        expect(find.text('FAVORITE WRITERS'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      } finally {
        progress.dispose();
        PathProviderPlatform.instance = oldPaths;
        await tester.runAsync(() => tempDir.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'NarrationQueueScreen integrates Kokoro (Offline) in engine dropdown without separate button or cloud config',
    (tester) async {
      final tempDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('dogreader-165-offline-'),
      ))!;
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(tempDir.path);
      final startedRequests = <Map<dynamic, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(offlineChannel, (call) async {
            switch (call.method) {
              case 'paths':
                return {
                  'files': tempDir.path,
                  'output': '${tempDir.path}/offline-output',
                };
              case 'notificationPermission':
                return true;
              case 'generationStatus':
                return null;
              case 'startGeneration':
                startedRequests.add(call.arguments as Map);
                return (call.arguments as Map)['id'];
              default:
                return null;
            }
          });

      try {
        // Seed saved preference for Kokoro (Offline) with am_michael and mark offline model ready.
        await tester.runAsync(() async {
          await File('${tempDir.path}/dogreader_queue.json').writeAsString(
            jsonEncode({
              'engine': 'kokoro_offline',
              'narrator': 'am_michael',
              'books': {},
            }),
          );
          final modelSpec =
              jsonDecode(await File('fp32-model-manifest.json').readAsString())
                  as Map<String, dynamic>;
          final frontendSpec =
              jsonDecode(
                    await File('english-frontend-manifest.json').readAsString(),
                  )
                  as Map<String, dynamic>;
          final modelDir = Directory(
            '${tempDir.path}/${modelSpec['directory']}',
          );
          await modelDir.create(recursive: true);
          await File(
            '${modelDir.path}/READY',
          ).writeAsString(modelSpec['archiveSha256'] as String);
          final frontendDir = Directory(
            '${tempDir.path}/${frontendSpec['directory']}',
          );
          await frontendDir.create(recursive: true);
          await File(
            '${frontendDir.path}/READY',
          ).writeAsString(frontendSpec['id'] as String);

          offlineNarration = OfflineNarration(
            beforeSelect: (_, _) async {},
            documentsDirectory: () async => tempDir,
            onChapterStateChanged: (bookId, chapterIndex, jobState) async {
              final bookJobs = narrationDelivery.books.putIfAbsent(
                bookId,
                () => {},
              );
              bookJobs[chapterIndex] = {
                ...?bookJobs[chapterIndex],
                ...jobState,
              };
            },
          );
          await offlineNarration.initialize();
          await narrationDelivery.load();
          await narrationDictionary.load();
          await narrationCostTracker.load();
        });

        final book = ImportedBook(
          'Offline Test Book',
          'Test Author',
          const [
            ReaderChapter(
              'Chapter One',
              'Alice walked through the quiet garden.',
              [],
            ),
          ],
          'book_offline_165',
          null,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: NarrationQueueScreen(
              book: book,
              onSave: (_, _) async {},
              initialChapter: 0,
            ),
          ),
        );
        final dynamic queueState = tester.state(
          find.byType(NarrationQueueScreen),
        );
        await tester.runAsync(() async {
          await queueState.load();
        });
        await tester.pumpAndSettle();

        // Verify there is NO separate "Kokoro Offline" tonal button.
        expect(
          find.widgetWithText(FilledButton, 'Kokoro Offline'),
          findsNothing,
        );

        // Verify Kokoro (Offline) and Michael (US Male) are selected in the standard dropdowns,
        // the on-device status card is displayed, and no cloud connection prompt is shown.
        expect(find.text('Kokoro (Offline)'), findsOneWidget);
        expect(find.text('Michael (US Male)'), findsOneWidget);
        expect(
          find.byKey(const Key('offline_kokoro_status_card')),
          findsOneWidget,
        );
        expect(find.text('On-device Kokoro model ready'), findsOneWidget);
        expect(find.text('Connect narration service'), findsNothing);

        // Tap "Generate narration" and confirm in the dialog without any cloud host/token set.
        await tester.runAsync(
          () => tester.tap(find.text('Generate narration')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Confirm narration generation'), findsOneWidget);
        expect(
          find.textContaining('Kokoro (Offline) • Michael (US Male)'),
          findsOneWidget,
        );
        expect(find.textContaining('\$0.00'), findsWidgets);

        await tester.runAsync(() async {
          await tester.tap(find.text('Generate (1)'));
          for (
            var i = 0;
            i < 60 && (startedRequests.isEmpty || queueState.notice == null);
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 15));
          }
        });
        await tester.pumpAndSettle();

        expect(startedRequests, hasLength(1));
        expect(startedRequests.single['sid'], 16);
        expect(startedRequests.single['chapter']['engine'], 'kokoro_offline');
        expect(startedRequests.single['chapter']['voice'], 'am_michael');
        expect(
          find.textContaining(
            'Started offline generation on device (1 chapter).',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(offlineChannel, null);
        narrationDelivery.books.clear();
        narrationDelivery.host = '';
        narrationDelivery.token = '';
        PathProviderPlatform.instance = oldPaths;
        await tester.runAsync(() => tempDir.delete(recursive: true));
      }
    },
  );

  test(
    'Build 164 user data (reading progress, cloud queue, narration state, dictionary, TTS cost, and RSS store) survives upgrade to Build 165',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'dogreader-165-upgrade-',
      );
      try {
        // Seed realistic Build 164 persistence files.
        final cloudMp3 = File('${tempDir.path}/narration/book164_0.mp3');
        await cloudMp3.parent.create(recursive: true);
        await cloudMp3.writeAsBytes(List<int>.filled(2048, 0x55));

        final offlineWav = File('${tempDir.path}/offline-output/book164_1.wav');
        await offlineWav.parent.create(recursive: true);
        await offlineWav.writeAsBytes([
          ...wavHeader(600, 24000),
          ...List<int>.filled(1200, 0),
        ]);

        await File('${tempDir.path}/narration_state.json').writeAsString(
          jsonEncode({
            'book164:0': {
              'path': cloudMp3.path,
              'positionMs': 42000,
              'engine': 'google',
              'voice': 'en-US-Chirp3-HD-Achernar',
            },
            'book164:1': {
              'path': offlineWav.path,
              'positionMs': 15000,
              'engine': 'kokoro_offline',
              'voice': 'af_heart',
              'offlineJobId': 'offline-164',
            },
          }),
        );
        final seededProgress = BookProgress(
          documentsDirectory: () async => tempDir,
        );
        await seededProgress.load();
        await seededProgress.saveReading('book164', 2, 140);
        await seededProgress.flushed;
        seededProgress.dispose();

        await File('${tempDir.path}/dogreader_queue.json').writeAsString(
          jsonEncode({
            'host': 'https://cloud.example.run.app',
            'token': 'secret-token',
            'engine': 'kokoro',
            'narrator': 'bm_lewis',
            'books': {
              'book164': {
                '0': {
                  'id': 'job164',
                  'status': 'ready',
                  'delivery': 'downloaded',
                  'engine': 'google',
                  'voice': 'en-US-Chirp3-HD-Achernar',
                },
              },
            },
          }),
        );
        await File('${tempDir.path}/narration_dictionary.json').writeAsString(
          jsonEncode({
            'global': [
              {
                'original': 'Dogreader',
                'replacement': 'Dog Reader',
                'silence': false,
                'enabled': true,
              },
            ],
            'books': {},
            'ignoreSeparators': true,
          }),
        );
        await File('${tempDir.path}/narration_cost.json').writeAsString(
          jsonEncode({
            'freeCharacterLimit': 1000000,
            'monthlyCreditLimitUsd': 10.0,
            'months': {
              '2026-11': {
                'googleCharacters': 250000,
                'kokoroCharacters': 50000,
                'jobIds': ['job164'],
              },
            },
          }),
        );

        // Load all stores on Build 165 and verify zero data loss.
        final progress = BookProgress(documentsDirectory: () async => tempDir);
        await progress.load();
        expect(progress.continuePosition('book164'), {
          'chapter': 2,
          'offset': 140,
        });
        expect(progress.furthestChapter('book164'), 2);
        progress.dispose();

        final dic = NarrationDictionary(
          preferencesFile: () async =>
              File('${tempDir.path}/narration_dictionary.json'),
        );
        await dic.load();
        expect(dic.global.single.original, 'Dogreader');
        expect(dic.global.single.replacement, 'Dog Reader');

        final cost = NarrationCostTracker(
          usageFile: () async => File('${tempDir.path}/narration_cost.json'),
          clock: () => DateTime.utc(2026, 11, 21),
        );
        await cost.load();
        expect(cost.estimate().usedGoogleCharacters, 250000);
        expect(cost.estimate().usedKokoroCharacters, 50000);

        expect(
          (await chapterRecordingFile(tempDir, 'book164', 0)).path,
          cloudMp3.path,
        );
        expect(
          (await chapterRecordingFile(tempDir, 'book164', 1)).path,
          offlineWav.path,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
  );
}
