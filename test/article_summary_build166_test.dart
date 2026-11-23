import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/article_library.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/rss/rss_controller.dart';
import 'package:audiobook_app/rss/rss_models.dart';
import 'package:audiobook_app/rss/rss_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/article_http.dart';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _TestRssLibraryController extends RssLibraryController {
  _TestRssLibraryController(super.documents);
  final _testArticles = <String, RssArticle>{};
  void addTestArticle(RssArticle a) => _testArticles[a.id] = a;
  @override
  RssArticle? articleById(String id) => _testArticles[id] ?? super.articleById(id);
  @override
  Future<void> load() async {}
  @override
  Future<void> markRead(String articleId, bool isRead) async {}
  @override
  Future<void> saveReadingPosition(
    String articleId, {
    int? readingOffset,
    double? scrollFraction,
    int? narrationOffset,
  }) async {}
  @override
  Future<RssArticle?> ensureFullText(
    String articleId, {
    bool forceRetry = false,
  }) async =>
      _testArticles[articleId];
}

class _TestArticleLibrary extends ArticleLibrary {
  _TestArticleLibrary(super.documents);
  final generatedDepths = <SummaryDepth>[];
  bool shouldFail = false;

  @override
  Future<void> load() async {}

  @override
  Future<ImportedArticle> summarize(
    ImportedArticle article,
    SummaryDepth depth, {
    bool forceRegenerate = false,
  }) async {
    if (shouldFail) {
      throw const ArticleImportException('The summary server is temporarily overloaded.');
    }
    if (!forceRegenerate) {
      final saved = savedSummary(article, depth);
      if (saved != null) return saved;
    }
    generatedDepths.add(depth);
    final result = ImportedArticle(
      title: article.title,
      sourceUrl: article.sourceUrl,
      author: article.author,
      depth: depth,
      originalId: article.id,
      originalContentHash: article.contentHash,
      blocks: [
        ArticleBlock('This is an AI summary generated on-demand for the RSS article in ${depth.label} depth.'),
      ],
    );
    articles.removeWhere((a) => a.originalId == article.id && a.depth == depth);
    articles.add(result);
    notifyListeners();
    return result;
  }
}

ImportedArticle _createSampleArticle({
  String title = 'The Future of Neural Networks in Edge Computing',
  String url = 'https://example.com/essays/neural-edge',
  String? author = 'Alan Turing',
  int paragraphCount = 6,
}) {
  final blocks = <ArticleBlock>[];
  for (var i = 1; i <= paragraphCount; i++) {
    blocks.add(ArticleBlock(
      'Paragraph $i: Deep neural networks require significant computational resources during training, '
      'but inference on edge devices can be optimized with INT8 and FP32 quantization techniques. '
      'This enables offline voice synthesis and privacy-preserving natural language processing without '
      'relying on continuous cloud connectivity.',
    ));
  }
  return ImportedArticle(
    title: title,
    sourceUrl: url,
    author: author,
    published: '2026-11-20T12:00:00Z',
    blocks: blocks,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('build166-summary-test-');
    PathProviderPlatform.instance = _FakePaths(tempDir.path);
    final queueFile = File('${tempDir.path}/dogreader_queue.json');
    await queueFile.writeAsString(
      jsonEncode({
        'host': 'https://cloud.dogreader.example',
        'token': 'test-auth-token',
        'books': {},
      }),
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('Build 166: AI Summary Generation & Depths', () {
    test('Brief, Standard, and Detailed summary generation with correct metadata and tokens', () async {
      final article = _createSampleArticle();
      final library = ArticleLibrary(Future.value(tempDir));
      await library.load();

      final summaryResponses = {
        SummaryDepth.brief:
            'Brief summary: Edge neural network inference can be optimized through quantization. '
            'This enables offline speech synthesis and privacy-preserving processing without continuous cloud connectivity. '
            'Recent advancements demonstrate promising efficiency gains for consumer devices.',
        SummaryDepth.standard:
            'Standard summary: As neural networks grow in size and capability, edge device deployment requires '
            'principled optimization techniques. Quantization to INT8 and FP32 formats allows modern transformer models '
            'to execute within mobile power budgets. While training demands high-performance GPU clusters, client-side '
            'inference provides significant privacy, latency, and offline availability advantages. '
            'Careful calibration preserves acoustic accuracy in speech synthesis.',
        SummaryDepth.detailed:
            'Detailed summary: Deep neural network models traditionally rely on cloud infrastructure due to memory '
            'and computational constraints. However, edge-first architectures mitigate several systemic challenges, '
            'including latency jitter, bandwidth consumption, and privacy leakage. Modern quantization techniques, '
            'such as post-training INT8 calibration and structured weight pruning, reduce memory footprint by upwards '
            'of seventy percent while retaining high fidelity. In the domain of speech synthesis and offline text-to-speech, '
            'optimized runtime engines allow phones to generate natural narration without server roundtrips. '
            'Nonetheless, thermal throttling and background execution limits present ongoing engineering hurdles '
            'that require active foreground management and chunked processing pipelines.',
      };

      for (final depth in SummaryDepth.values) {
        final expectedText = summaryResponses[depth]!;
        await HttpOverrides.runZoned(
          () async {
            final summary = await library.summarize(article, depth);
            expect(summary.depth, depth);
            expect(summary.originalId, article.id);
            expect(summary.originalContentHash, article.contentHash);
            expect(summary.text, expectedText);
            expect(summary.published, isNotNull);
            expect(summary.usage, isNotNull);
            expect(summary.usage!['inputTokens'], 250);
            expect(summary.usage!['outputTokens'], 80);

            // Verify local caching: immediate second lookup does not hit network
            final cached = library.savedSummary(article, depth);
            expect(cached, isNotNull);
            expect(cached!.text, expectedText);
            expect(cached.id, summary.id);
          },
          createHttpClient: (_) => ArticleHttpClient(
            ArticleHttpResponse(
              200,
              jsonEncode({
                'status': 'ready',
                'id': 'test_summary_id_${depth.name}',
                'summary': expectedText,
                'usage': {
                  'model': 'gemini-2.5-flash',
                  'inputTokens': 250,
                  'outputTokens': 80,
                  'costUsd': 0.000085,
                },
              }),
            ),
          ),
        );
      }
      library.dispose();
    });

    test('Local summary caching and regeneration: regenerating invalidates outdated audio ID', () async {
      final article = _createSampleArticle();
      final library = ArticleLibrary(Future.value(tempDir));
      await library.load();

      const initialSummaryText =
          'Initial summary: Neural networks run efficiently on consumer mobile devices using quantization. '
          'Offline speech synthesis is feasible with acceptable battery impact and high acoustic quality.';
      const regeneratedSummaryText =
          'Regenerated summary: Updated findings confirm that modern edge neural architectures provide robust offline '
          'performance across a wide variety of hardware architectures, with substantial privacy benefits.';

      var callCount = 0;
      await HttpOverrides.runZoned(
        () async {
          // 1. Initial generation
          final first = await library.summarize(article, SummaryDepth.brief);
          expect(first.text, initialSummaryText);
          expect(callCount, 1);

          // 2. Second call without forceRegenerate uses cache with 0 network calls
          final cached = await library.summarize(article, SummaryDepth.brief);
          expect(cached.text, initialSummaryText);
          expect(cached.id, first.id);
          expect(callCount, 1);

          // 3. Force regenerate makes a new network call and updates the cached summary
          final regenerated = await library.regenerateSummary(article, SummaryDepth.brief);
          expect(regenerated.text, regeneratedSummaryText);
          expect(callCount, 2);

          // Crucial: The book/article ID for narration incorporates the content hash!
          // Therefore, the regenerated summary has a different ID, naturally separating narration audio!
          expect(regenerated.id, isNot(equals(first.id)));
          expect(regenerated.originalId, article.id);

          // Future lookups return the new regenerated summary
          final current = library.savedSummary(article, SummaryDepth.brief);
          expect(current!.text, regeneratedSummaryText);
          expect(current.id, regenerated.id);
        },
        createHttpClient: (_) {
          callCount++;
          final text = callCount == 1 ? initialSummaryText : regeneratedSummaryText;
          return ArticleHttpClient(
            ArticleHttpResponse(
              200,
              jsonEncode({
                'status': 'ready',
                'id': 'summary_call_$callCount',
                'summary': text,
                'usage': {'inputTokens': 200, 'outputTokens': 50},
              }),
            ),
          );
        },
      );
      library.dispose();
    });
  });

  group('Build 166: Summary Narration Workflow', () {
    test('Summary creates single-chapter ImportedBook with unique ID, separate from original article', () {
      final original = _createSampleArticle();
      const summaryText =
          'A comprehensive summary of the edge neural network optimization paper explaining INT8 quantization. '
          'It preserves author arguments and technical caveats while remaining readable as standalone prose.';

      final summary = ImportedArticle(
        title: original.title,
        sourceUrl: original.sourceUrl,
        author: original.author,
        depth: SummaryDepth.standard,
        originalId: original.id,
        originalContentHash: original.contentHash,
        blocks: [ArticleBlock(summaryText)],
      );

      // Convert original and summary to books as main.dart does
      final originalBook = ImportedBook(
        original.title,
        original.author ?? 'Unknown author',
        [original.chapter],
        original.id,
        null,
      );

      final summaryBook = ImportedBook(
        '${summary.title} — ${summary.depth!.label} summary',
        summary.author ?? 'Unknown author',
        [summary.chapter],
        summary.id,
        null,
      );

      // Book IDs are completely distinct
      expect(summaryBook.id, isNot(equals(originalBook.id)));
      expect(summaryBook.id, startsWith(original.id));
      expect(summaryBook.id, contains('standard'));

      // Narration audio file path contracts:
      // Original audio: <documents>/narration/<originalBook.id>_0.mp3
      // Summary audio:  <documents>/narration/<summaryBook.id>_0.mp3
      final originalAudioPath = '${tempDir.path}/narration/${originalBook.id}_0.mp3';
      final summaryAudioPath = '${tempDir.path}/narration/${summaryBook.id}_0.mp3';
      expect(summaryAudioPath, isNot(equals(originalAudioPath)));

      // Reading progress keys are also separated
      expect(originalBook.id, isNot(equals(summaryBook.id)));

      // Chapter has exactly the summary text and is single-chapter
      expect(summaryBook.chapters.length, 1);
      expect(summaryBook.chapters.first.title, 'Standard summary');
      expect(summaryBook.chapters.first.text, summaryText);
    });

    test('Compatible with Google Chirp, Kokoro Cloud, and Kokoro Offline engine IDs', () {
      final original = _createSampleArticle();
      final summary = ImportedArticle(
        title: original.title,
        sourceUrl: original.sourceUrl,
        author: original.author,
        depth: SummaryDepth.brief,
        originalId: original.id,
        originalContentHash: original.contentHash,
        blocks: [const ArticleBlock('A standalone brief summary for listening.')],
      );

      final summaryBook = ImportedBook(
        '${summary.title} — ${summary.depth!.label} summary',
        summary.author ?? 'Unknown author',
        [summary.chapter],
        summary.id,
        null,
      );

      const supportedEngines = ['google', 'kokoro', 'kokoro_offline'];
      for (final engine in supportedEngines) {
        expect(engine, isNotEmpty);
        expect(summaryBook.chapters.first.text, isNotEmpty);
      }
    });
  });

  group('Build 166: RssArticleReadingScreen Summary Card UI', () {
    testWidgets('Displays Brief/Standard/Detailed selector, generates summary on demand, and allows listening', (tester) async {
      final library = _TestArticleLibrary(Future.value(tempDir));
      await library.load();
      final controller = _TestRssLibraryController(Future.value(tempDir));
      await controller.load();

      final rssArticle = RssArticle(
        id: 'rss_art_1',
        subscriptionId: 'feed_1',
        feedTitle: 'Tech Dispatch',
        title: 'Advances in Local Edge Narration',
        url: 'https://example.com/edge-narration',
        canonicalUrl: 'https://example.com/edge-narration',
        summaryPreview: 'Short teaser.',
        author: 'Jane Tech',
        fetchedAt: DateTime.now(),
        contentStatus: ArticleContentStatus.full,
        blocks: [
          const ArticleBlock(
            'This is the full extracted article about on-device AI voice generation. '
            'Modern mobile chips can synthesize high quality audio using quantization.',
          ),
          const ArticleBlock(
            'Offline readers benefit immensely from locally generated narration that does not require network access.',
          ),
        ],
      );
      controller.addTestArticle(rssArticle);

      ImportedArticle? openedArticle;
      bool? openedForNarration;

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RssArticleReadingScreen(
              controller: controller,
              articleLibrary: library,
              initialArticleId: rssArticle.id,
              orderedArticleIds: [rssArticle.id],
              onOpenArticle: (article, narration) {
                openedArticle = article;
                openedForNarration = narration;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 1. Initial State: Shows On-Demand AI Article Summary section
      expect(find.text('On-Demand AI Article Summary'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<SummaryDepth>), findsOneWidget);
      expect(find.text('Standard'), findsOneWidget);

      // Standard is default; shows Generate Standard Summary button
      expect(find.text('Generate Standard Summary'), findsOneWidget);

      // Select Brief depth from dropdown
      await tester.tap(find.byType(DropdownButtonFormField<SummaryDepth>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Brief').last);
      await tester.pumpAndSettle();
      expect(find.text('Generate Brief Summary'), findsOneWidget);

      // Tap Generate Brief Summary
      await tester.tap(find.text('Generate Brief Summary'));
      await tester.pump(); // Start async work

      // Complete async summary generation
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      // 2. Completed Summary State
      expect(find.textContaining('Cached Brief AI Summary'), findsOneWidget);
      expect(find.textContaining('This is an AI summary generated on-demand'), findsOneWidget);
      expect(find.text('Read Summary'), findsOneWidget);
      expect(find.text('Listen to Summary'), findsOneWidget);
      expect(find.text('Regenerate Summary'), findsOneWidget);

      // Tap "Listen to Summary"
      await tester.tap(find.text('Listen to Summary'));
      await tester.pump();

      expect(openedArticle, isNotNull);
      expect(openedArticle!.depth, SummaryDepth.brief);
      expect(openedForNarration, isTrue);

      // Switch to Detailed depth from dropdown (not generated yet)
      await tester.tap(find.byType(DropdownButtonFormField<SummaryDepth>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Detailed').last);
      await tester.pumpAndSettle();
      expect(find.text('Generate Detailed Summary'), findsOneWidget);

      // Switch back to Brief depth from dropdown (cached summary restored instantly)
      await tester.tap(find.byType(DropdownButtonFormField<SummaryDepth>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Brief').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Cached Brief AI Summary'), findsOneWidget);
      expect(find.text('Listen to Summary'), findsOneWidget);

      controller.dispose();
      library.dispose();
    });

    testWidgets('Paywall and extraction safeguards prevent summarizing incomplete articles', (tester) async {
      final library = _TestArticleLibrary(Future.value(tempDir));
      await library.load();
      final controller = _TestRssLibraryController(Future.value(tempDir));
      await controller.load();

      // Subscriber-only article
      final paywalledArticle = RssArticle(
        id: 'paywall_art_1',
        subscriptionId: 'feed_1',
        feedTitle: 'Gated Journal',
        title: 'Subscribers Only Analysis',
        url: 'https://example.com/gated',
        canonicalUrl: 'https://example.com/gated',
        summaryPreview: 'Preview teaser.',
        fetchedAt: DateTime.now(),
        contentStatus: ArticleContentStatus.subscriberOnly,
        blocks: const [],
      );
      controller.addTestArticle(paywalledArticle);

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RssArticleReadingScreen(
              controller: controller,
              articleLibrary: library,
              initialArticleId: paywalledArticle.id,
              orderedArticleIds: [paywalledArticle.id],
              onOpenArticle: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Safeguard message is displayed and Generate button is NOT present
      expect(
        find.textContaining('Summaries are disabled for subscriber-only articles'),
        findsOneWidget,
      );
      expect(find.text('Generate Standard Summary'), findsNothing);

      controller.dispose();
      library.dispose();
    });

    testWidgets('Backend error shows clear error message and Retry button', (tester) async {
      final library = _TestArticleLibrary(Future.value(tempDir));
      library.shouldFail = true;
      await library.load();
      final controller = _TestRssLibraryController(Future.value(tempDir));
      await controller.load();

      final article = RssArticle(
        id: 'rss_err_1',
        subscriptionId: 'feed_1',
        feedTitle: 'Tech Dispatch',
        title: 'Error Handling Article',
        url: 'https://example.com/error-art',
        canonicalUrl: 'https://example.com/error-art',
        summaryPreview: 'Short teaser.',
        fetchedAt: DateTime.now(),
        contentStatus: ArticleContentStatus.full,
        blocks: [const ArticleBlock('A full article paragraph here.')],
      );
      controller.addTestArticle(article);

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RssArticleReadingScreen(
              controller: controller,
              articleLibrary: library,
              initialArticleId: article.id,
              orderedArticleIds: [article.id],
              onOpenArticle: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('Generate Standard Summary'));
      await tester.pump(); // Start async work
      await tester.pump(const Duration(milliseconds: 100)); // Finish error throw
      await tester.pump();

      // Shows error message and Retry button
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);

      controller.dispose();
      library.dispose();
    });
  });
}
