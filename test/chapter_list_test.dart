import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audiobook_app/app_theme.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/dogreader_audio_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// Uses the transitive platform interface already mocked by the queue tests.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'fake_player.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;
}

class _LoopbackHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'chapter taps, selection and bulk generation keep existing audio and jobs',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('chapter-list-test-'),
      ))!;
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root);
      final posted = <Map<String, dynamic>>[];
      final server = (await tester.runAsync(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response.headers.contentType = ContentType.json;
          var id = request.uri.pathSegments.last;
          if (request.method == 'POST') {
            posted.add(
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>,
            );
            id = 'submitted-${posted.length}';
          }
          request.response.write(jsonEncode({'id': id, 'status': 'queued'}));
          await request.response.close();
        });
        return server;
      }))!;
      final handler = (await tester.runAsync(
        () async => DogreaderAudioHandler(
          player: FakePlayer(),
          documentsDirectory: () async => root,
        ),
      ))!;
      audioHandler = handler;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPaths;
        await server.close(force: true);
        await root.delete(recursive: true);
      });

      await tester.runAsync(() async {
        await File('${root.path}/dogreader_queue.json').writeAsString(
          jsonEncode({
            'host': 'http://127.0.0.1:${server.port}',
            'token': 'test-token',
            'engine': 'kokoro',
            'narrator': 'bm_lewis',
            'books': {
              'fixture': {
                '0': {
                  'status': 'ready',
                  'delivery': 'downloaded',
                  'localAvailable': true,
                },
                '1': {
                  'status': 'queued',
                  'id': 'existing',
                  'deliveryNextAttempt': DateTime.now()
                      .add(const Duration(hours: 1))
                      .millisecondsSinceEpoch,
                },
              },
            },
          }),
        );
        final file = File('${root.path}/narration/fixture_0.mp3');
        await file.parent.create();
        await file.writeAsBytes(List.filled(1200, 7));
        await narrationDelivery.load();
      });

      const book = ImportedBook(
        'The Wind in the Willows',
        'Kenneth Grahame',
        [
          ReaderChapter('The River Bank', 'One chapter.', []),
          ReaderChapter('The Open Road', 'Two chapter.', []),
          ReaderChapter('The Wild Wood', 'Three chapter.', []),
          ReaderChapter('Mr. Badger', 'Four chapter.', []),
          ReaderChapter('Dulce Domum', 'Five chapter.', []),
          ReaderChapter('Mr. Toad', 'Six chapter.', []),
        ],
        'fixture',
        null,
      );
      final capturePath = Platform.environment['DOGREADER_SCREENSHOTS'];
      final boundary = GlobalKey();
      final fontPath = Platform.environment['DOGREADER_SCREENSHOT_FONT'];
      if (fontPath != null) {
        final font = FontLoader('CaptureFont')
          ..addFont(
            Future.value(
              ByteData.sublistView(File(fontPath).readAsBytesSync()),
            ),
          );
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      }
      Future<void> capture(String name) async {
        if (capturePath == null) return;
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final bytes = (await tester.runAsync(() async {
          final image = await render.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          return data;
        }))!;
        File('$capturePath/$name.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes.buffer.asUint8List());
      }

      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final mode = ValueNotifier(ThemeMode.light);
      addTearDown(mode.dispose);
      ThemeData theme(ThemeData base) => fontPath == null
          ? base
          : base.copyWith(
              textTheme: base.textTheme.apply(fontFamily: 'CaptureFont'),
            );
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ValueListenableBuilder(
            valueListenable: mode,
            builder: (_, current, _) => MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme(dogreaderLightTheme()),
              darkTheme: theme(dogreaderDarkTheme()),
              themeMode: current,
              themeAnimationDuration: Duration.zero,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ChapterListScreen(
                          book: book,
                          saved: const {'chapter': 0, 'offset': 3},
                          chapterOffsets: const {},
                          onSave: (_, _) async {},
                        ),
                      ),
                    ),
                    child: const Text('Open book'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> frame() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 650));
      }

      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await frame();
        }
        expect(finder, findsOneWidget);
      }

      await tester.tap(find.text('Open book'));
      await frame();
      await tester.runAsync(() async {
        final context = tester.element(find.byType(ChapterListScreen));
        await precacheImage(
          const AssetImage('assets/images/chapter_headphones.webp'),
          context,
        );
      });
      await frame();

      final firstRow = find.byKey(const ValueKey('chapter-row-0'));
      final secondRow = find.byKey(const ValueKey('chapter-row-1'));
      expect(tester.getSize(firstRow).height, 56);
      expect(tester.getRect(firstRow).bottom, tester.getRect(secondRow).top);
      await capture('normal');
      mode.value = ThemeMode.dark;
      await frame();
      expect(Theme.of(tester.element(firstRow)).brightness, Brightness.dark);
      await capture('dark');
      mode.value = ThemeMode.light;
      await frame();

      await tester.tap(find.text('The Wild Wood'));
      await frame();
      expect(
        tester.widget<ReadingScreen>(find.byType(ReadingScreen)).chapterIndex,
        2,
      );
      await tester.binding.handlePopRoute();
      await frame();
      final headphones = find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.startsWith('Narration for The Wild Wood') ??
                false),
      );
      expect(tester.getSize(headphones).width, 56);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(headphones);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }, _LoopbackHttp()),
      );
      await frame();
      expect(
        tester
            .widget<NarrationQueueScreen>(find.byType(NarrationQueueScreen))
            .initialChapter,
        2,
      );
      expect(find.byType(ReadingScreen), findsNothing);
      await tester.binding.handlePopRoute();
      await frame();

      await tester.longPress(
        find.descendant(of: firstRow, matching: find.text('The River Bank')),
      );
      await frame();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('The Wild Wood'));
      await tester.tap(find.text('Dulce Domum'));
      await tester.tap(find.text('The Wild Wood'));
      await frame();
      expect(find.text('2 selected'), findsOneWidget);
      await capture('selection');
      await tester.tap(find.text('Generate (2)'));
      await frame();
      await waitFor(find.text('Review generation'));
      expect(find.text('2 chapters selected'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await frame();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Select All'));
      await frame();
      expect(find.text('6 selected'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await frame();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Generate (0)'),
            )
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await frame();
      expect(find.text('0 selected'), findsNothing);

      await tester.tap(find.text('Narration'));
      await frame();
      await tester.tap(find.text('Select chapters'));
      await frame();
      await tester.tap(find.text('Cancel'));
      await frame();
      expect(find.text('0 selected'), findsNothing);
      await tester.tap(find.text('Narration'));
      await frame();
      await tester.tap(find.text('Generate entire book'));
      await frame();
      await waitFor(find.text('Review generation'));
      expect(find.text('Lewis'), findsOneWidget);
      expect(find.text('Kokoro'), findsOneWidget);
      await capture('generation-settings');
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => tester.tap(find.text('Review generation')),
          _LoopbackHttp(),
        ),
      );
      await frame();
      expect(
        find.textContaining(
          '1 downloaded\n1 queued or generating\n4 new generation jobs',
        ),
        findsOneWidget,
      );

      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.text('Generate (4)'));
          for (var i = 0; i < 100 && posted.length < 4; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 15));
          }
          // Let the existing queue persist and reconcile its submitted job IDs.
          for (
            var i = 0;
            i < 100 &&
                !narrationDelivery.books['fixture']!.values.every(
                  (job) => job['status'] != 'waiting',
                );
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 15));
          }
        }, _LoopbackHttp()),
      );
      await waitFor(find.text('4 submitted.'));
      expect(posted.map((job) => job['title']), [
        'The Wild Wood',
        'Mr. Badger',
        'Dulce Domum',
        'Mr. Toad',
      ]);
      expect(
        posted.every(
          (job) => job['engine'] == 'kokoro' && job['voice'] == 'bm_lewis',
        ),
        isTrue,
      );
      expect(narrationDelivery.books['fixture']![1]!['id'], 'existing');
      expect(narrationDelivery.books['fixture']![0]!['delivery'], 'downloaded');
      expect(find.text('Generate (4)'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(handler.dispose);
    },
  );
}
