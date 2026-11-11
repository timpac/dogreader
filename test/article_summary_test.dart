import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/article_summary.dart';
import 'package:audiobook_app/article_library.dart';
import 'package:audiobook_app/article_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'article_import_test.dart' show fixture;
import 'support/article_http.dart';

class ScreenLibrary extends ArticleLibrary {
  ScreenLibrary(super.documents) : super(summariesEnabled: true);
  final reviewed = <SummaryDepth>[];
  final generated = <SummaryDepth>[];
  @override
  Future<Map<String, dynamic>> estimate(
    ImportedArticle article,
    SummaryDepth depth,
  ) async {
    reviewed.add(depth);
    return {'estimatedCostUsd': 0.001};
  }

  @override
  Future<ImportedArticle> summarize(
    ImportedArticle article,
    SummaryDepth depth,
  ) async {
    generated.add(depth);
    return ImportedArticle(
      title: article.title,
      sourceUrl: article.sourceUrl,
      blocks: article.blocks,
      originalId: article.id,
      depth: depth,
    );
  }
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('article-summary-');
    await File('${root.path}/dogreader_queue.json').writeAsString(
      jsonEncode({
        'host': 'https://cloud.example',
        'token': 'user-entered-token',
        'books': {'existing': {}},
      }),
    );
  });
  tearDown(() async => root.delete(recursive: true));
  test(
    'summaries are disabled by default before settings or network access',
    () async {
      var createdClients = 0;
      expect(articleSummariesEnabled, isFalse);
      final library = ArticleLibrary(Future.value(root));
      await HttpOverrides.runZoned(
        () async {
          for (final request in [
            () =>
                ArticleSummaryClient(root)
                    .estimate(fixture(), SummaryDepth.brief),
            () =>
                ArticleSummaryClient(root)
                    .summarize(fixture(), SummaryDepth.brief),
            () => library.estimate(fixture(), SummaryDepth.brief),
            () => library.summarize(fixture(), SummaryDepth.brief),
          ]) {
            await expectLater(
              request(),
              throwsA(
                isA<ArticleImportException>().having(
                  (e) => e.message,
                  'message',
                  articleSummariesDisabledMessage,
                ),
              ),
            );
          }
        },
        createHttpClient: (_) {
          createdClients++;
          throw StateError('Network must stay disabled');
        },
      );
      expect(createdClients, 0);
      library.dispose();
    },
  );
  test(
    'summary output stays exact and never changes source text, hash or offsets',
    () async {
      final original = fixture();
      final sourceText = original.text;
      final sourceHash = original.contentHash;
      final offsets = original.blockOffsets;
      final output = '\n\n  😀 e\u0301  ${original.text.substring(0, 200)}\n\n\n\nTail  ';
      final client = ArticleHttpClient(
        ArticleHttpResponse(200, jsonEncode({'summary': output})),
      );
      await HttpOverrides.runZoned(() async {
        final summary = await ArticleSummaryClient(
          root,
          enabled: true,
        ).summarize(original, SummaryDepth.brief);
        expect(summary.text, output);
        expect(summary.chapter.text, output);
        expect(summary.originalContentHash, sourceHash);
        expect(original.text, sourceText);
        expect(original.contentHash, sourceHash);
        expect(original.blockOffsets, offsets);
      }, createHttpClient: (_) => client);
    },
  );
  testWidgets('disabled summary controls cannot submit a request', (
    tester,
  ) async {
    final library = ArticleLibrary(Future.value(root));
    await tester.pumpWidget(
      MaterialApp(
        home: ArticleDetailScreen(
          article: fixture(),
          library: library,
          openArticle: (_, _) {},
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text(articleSummariesDisabledMessage),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Review AI usage'), findsNothing);
    expect(find.text('Generate standard summary'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    library.dispose();
  });
  test('uses existing cloud auth and exact text/depth; saves each depth and deduplicates', () async {
    for (final depth in SummaryDepth.values) {
      final original = fixture();
      final client = ArticleHttpClient(
        ArticleHttpResponse(
          200,
          jsonEncode({
            'summary': original.text,
            'usage': {'costUsd': 0.0001},
          }),
        ),
      );
      final library = ArticleLibrary(
        Future.value(root),
        summariesEnabled: true,
      );
      await library.load();
      await HttpOverrides.runZoned(() async {
        final first = library.summarize(original, depth);
        final duplicate = library.summarize(original, depth);
        expect(identical(first, duplicate), isTrue);
        final summary = await first;
        expect(summary.depth, depth);
        expect(summary.originalId, original.id);
        expect(summary.chapter.text, original.text);
        expect(summary.id, isNot(original.id));
        expect(client.urls.single.path, '/dogreader/article-summaries');
        expect(client.requests.single.followRedirects, isFalse);
        expect(
          client.requests.single.headers.value('X-Dogreader-Token'),
          'user-entered-token',
        );
        final body = jsonDecode(client.requests.single.body.toString()) as Map;
        expect(body['text'], original.text);
        expect(body['depth'], depth.name);
        expect(body['contentHash'], original.contentHash);
        expect((await library.summarize(original, depth)).id, summary.id);
        expect(client.requests.length, 1);
      }, createHttpClient: (_) => client);
      library.dispose();
      final restarted = ArticleLibrary(Future.value(root));
      await restarted.load();
      expect((await restarted.summarize(original, depth)).depth, depth);
      restarted.dispose();
    }
    final settings = jsonDecode(
      await File('${root.path}/dogreader_queue.json').readAsString(),
    ) as Map;
    expect(settings['books'], {'existing': {}});
  });
  test(
    'estimate does not submit generation and supports unknown costs',
    () async {
      final client = ArticleHttpClient(
        ArticleHttpResponse(200, '{"estimatedCostUsd":null}'),
      );
      await HttpOverrides.runZoned(() async {
        final result = await ArticleSummaryClient(
          root,
          enabled: true,
        ).estimate(fixture(), SummaryDepth.brief);
        expect(result['estimatedCostUsd'], isNull);
        expect(
          client.urls.single.path,
          '/dogreader/article-summaries/estimate',
        );
      }, createHttpClient: (_) => client);
    },
  );
  test('missing endpoint, auth errors, HTML, and truncated summaries report errors', () async {
    for (final response in [
      ArticleHttpResponse(404, '<html>Not found</html>'),
      ArticleHttpResponse(401, '{"error":"Invalid Dogreader access token"}'),
      ArticleHttpResponse(200, '<html>Unexpected</html>'),
      ArticleHttpResponse(200, '{"summary":"too short"}'),
    ]) {
      final client = ArticleHttpClient(response);
      await HttpOverrides.runZoned(() async {
        await expectLater(
          ArticleSummaryClient(
            root,
            enabled: true,
          ).summarize(fixture(), SummaryDepth.brief),
          throwsA(isA<ArticleImportException>()),
        );
      }, createHttpClient: (_) => client);
    }
  });
  testWidgets(
    'summary depth slider reviews usage before generation and opens saved text',
    (tester) async {
      final original = fixture();
      final library = ScreenLibrary(Future.value(root));
      final opened = <ImportedArticle>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ArticleDetailScreen(
            article: original,
            library: library,
            openArticle: (article, _) => opened.add(article),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.byType(Slider),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(0);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Review AI usage'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Review AI usage'));
      await tester.pumpAndSettle();
      expect(library.reviewed, [SummaryDepth.brief]);
      expect(library.generated, isEmpty);
      expect(find.text('Estimated AI cost: US\$0.00100'), findsOneWidget);
      await tester.tap(find.text('Generate brief summary'));
      await tester.pumpAndSettle();
      expect(opened.single.depth, SummaryDepth.brief);
      expect(opened.single.chapter.text, original.text);
      expect(library.generated, [SummaryDepth.brief]);
      await tester.pumpWidget(const SizedBox());
      library.dispose();
    },
  );
}
