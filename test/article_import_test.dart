import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/article_library.dart';
import 'package:audiobook_app/article_share.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const paragraphs = '''
<h1>A careful trial</h1><p>Researchers tested a small pilot programme in two towns.
The results suggested that travel times fell by ten percent, but the sample
was small and the authors warned against applying the result everywhere.</p>
<h2>Limitations</h2><p>The central argument is that further controlled trials
are needed before expansion. The study did not establish a causal effect,
and the cost estimates exclude maintenance and future staffing.</p>''';

String page({String extra = ''}) =>
    '''<html><head>
<meta property="og:title" content="A careful trial">
<meta name="author" content="Ada Example">
<meta property="article:published_time" content="2026-10-30">
<link rel="canonical" href="https://example.org/trial">
</head><body><nav><p>Browse every page</p></nav>
<main><article>$paragraphs<div class="advertisement"><p>Buy things now</p></div>
<div id="cookie-notice"><p>Accept all cookies</p></div>
<aside><p>Other stories</p></aside>$extra</article></main>
<footer>Footer links</footer></body></html>''';

ImportedArticle fixture() => extractArticle(
  page(),
  Uri.parse('https://example.org/trial?utm_source=share'),
);

class ControlledFetcher extends ArticleFetcher {
  final calls = <String>[];
  final first = Completer<ImportedArticle>();
  @override
  Future<ImportedArticle> fetch(String value) async {
    calls.add(value);
    if (calls.length == 1) return first.future;
    if (value.contains('fail')) {
      throw const ArticleImportException('Website unavailable');
    }
    return extractArticle(
      page().replaceAll('https://example.org/trial', value),
      Uri.parse(value),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('immutable Unicode blocks, UTF-16 offsets and legacy restore preserve exact text', () {
    final input = [
      const ArticleBlock(''),
      const ArticleBlock('😀 e\u0301  ', heading: true),
      const ArticleBlock('Tail\nline  '),
    ];
    final article = ImportedArticle(
      title: 'Unicode',
      sourceUrl: 'https://example.org/unicode',
      blocks: input,
    );
    final original = article.text;
    input.clear();
    expect(article.text, original);
    expect(() => article.blocks.clear(), throwsUnsupportedError);
    expect(article.chapter.text, original);
    expect(article.blockOffsets[1], (start: 2, end: 9));
    expect(article.chapter.ranges.single.start, 2);
    expect(article.chapter.ranges.single.end, 9);
    for (var i = 0; i < article.blocks.length; i++) {
      final range = article.blockOffsets[i];
      expect(
        original.substring(range.start, range.end),
        article.blocks[i].text,
      );
    }
    final json =
        jsonDecode(jsonEncode(article.toJson())) as Map<String, dynamic>;
    final legacy = Map<String, dynamic>.from(json)
      ..remove('textSha256')
      ..remove('textLengthUtf16');
    expect(ImportedArticle.fromJson(legacy).text, original);
    expect(ImportedArticle.fromJson(json).chapter.text, original);
    (json['blocks'] as List)[1]['text'] = 'Changed';
    expect(() => ImportedArticle.fromJson(json), throwsFormatException);
  });
  test('saving a changed original cannot overwrite text, metadata or reading state', () async {
    final root = await Directory.systemTemp.createTemp('article-immutable-');
    try {
      final state = File('${root.path}/reading_state.json');
      await state.writeAsString(
        '{"positions":{"existing":{"chapter":0,"offset":7}}}',
      );
      final store = ArticleStore(Directory('${root.path}/articles'));
      final original = fixture();
      await store.save(original);
      final file = File('${root.path}/articles/${original.id}.json');
      final before = await file.readAsString();
      final replacement = ImportedArticle(
        title: 'Changed title',
        sourceUrl: original.sourceUrl,
        blocks: const [ArticleBlock('Changed text')],
      );
      await expectLater(
        store.save(replacement),
        throwsA(isA<ArticleImportException>()),
      );
      expect(await file.readAsString(), before);
      expect((await store.load()).single.text, original.text);
      expect(
        await state.readAsString(),
        '{"positions":{"existing":{"chapter":0,"offset":7}}}',
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('extracts metadata, main paragraphs and headings without clutter', () {
    final article = fixture();
    expect(article.title, 'A careful trial');
    expect(article.author, 'Ada Example');
    expect(article.published, '2026-10-30');
    expect(article.sourceUrl, 'https://example.org/trial');
    expect(article.text, contains('did not establish a causal effect'));
    for (final clutter in [
      'Buy things',
      'Accept all',
      'Other stories',
      'Browse every',
      'Footer',
    ]) {
      expect(article.text, isNot(contains(clutter)));
    }
    expect(article.blocks.where((b) => b.heading).map((b) => b.text), [
      'A careful trial',
      'Limitations',
    ]);
    expect(article.chapter.text, article.text);
    expect(article.chapter.ranges.length, 2);
    expect(
      article.chapter.text.substring(
        article.chapter.ranges.last.start,
        article.chapter.ranges.last.end,
      ),
      'Limitations',
    );
    expect(article.chapter.text.length, inInclusiveRange(100, 250000));
  });
  test(
    'preserves paragraph text rather than injecting HTML or outside content',
    () {
      final article = extractArticle(
        page(
          extra: '<p>Rock &amp; roll. <script>fake facts</script><em>Uncertain</em> result.</p>',
        ),
        Uri.parse('https://example.org/trial'),
      );
      expect(article.text, contains('Rock & roll. Uncertain result.'));
      expect(article.text, isNot(contains('fake facts')));
    },
  );
  test('JSON-LD metadata, optional author/date and canonical trust', () {
    final article = extractArticle(
      '''<head><link rel="canonical" href="https://unrelated.example/stolen">
      <script type="application/ld+json">{"@graph":[{"@type":"NewsArticle","headline":"Pilot","author":[{"name":"Ada"},{"name":"Ben"}],"datePublished":"2026-10-30"}]}</script></head>
      <article>$paragraphs</article>''',
      Uri.parse('https://example.org/pilot'),
    );
    expect(article.title, 'Pilot');
    expect(article.author, 'Ada, Ben');
    expect(article.sourceUrl, 'https://example.org/pilot');
    final optional = extractArticle(
      '<article>$paragraphs</article>',
      Uri.parse('https://example.org/pilot'),
    );
    expect(optional.author, isNull);
    expect(optional.published, isNull);
  });
  test('rejects gated metadata, subscription walls and unsupported pages', () {
    expect(
      () => extractArticle(
        page(
          extra: '<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>',
        ),
        Uri.parse('https://example.org/trial'),
      ),
      throwsA(isA<ArticleImportException>()),
    );
    expect(
      () => extractArticle(
        page(extra: '<div class="paywall">Subscribe to unlock</div>'),
        Uri.parse('https://example.org/trial'),
      ),
      throwsA(isA<ArticleImportException>()),
    );
    expect(
      () => extractArticle(
        '<title>Search</title><nav><p>Search results and navigation</p></nav>',
        Uri.parse('https://example.org'),
      ),
      throwsA(isA<ArticleImportException>()),
    );
  });
  test('validates URLs and normalizes only known tracking parameters', () {
    for (final value in [
      'file:///secret',
      'javascript:alert(1)',
      'https://user:pass@example.org',
      'http://127.0.0.1/a',
      'http://10.0.0.1',
      'https://[::1]',
      'https://localhost',
      'https://example.org:8080',
    ]) {
      expect(() => articleUrl(value), throwsA(isA<ArticleImportException>()));
    }
    expect(
      normalizedArticleUrl(
        articleUrl('https://EXAMPLE.org/a?id=2&utm_source=x#part'),
      ),
      'https://example.org/a?id=2',
    );
    expect(
      normalizedArticleUrl(articleUrl('https://example.org/a?utm_source=x')),
      'https://example.org/a',
    );
    expect(
      sharedArticleUrl('An article\nhttps://example.org/a?q=2'),
      'https://example.org/a?q=2',
    );
    expect(sharedArticleUrl('plain text'), isNull);
  });
  test('cold and warm Android shares reach Dart once', () async {
    final received = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ArticleShare.channel, (call) async {
      expect(call.method, 'takePendingTexts');
      return ['https://example.org/cold'];
    });
    await ArticleShare.listen(received.add);
    await messenger.handlePlatformMessage(
      ArticleShare.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('sharedText', 'https://example.org/warm'),
      ),
      (_) {},
    );
    expect(received, ['https://example.org/cold', 'https://example.org/warm']);
    ArticleShare.stop();
    messenger.setMockMethodCallHandler(ArticleShare.channel, null);
  });
  test(
    'atomic article and all summary depths restore with distinct narration IDs',
    () async {
      final root = await Directory.systemTemp.createTemp('article-store-');
      try {
        final store = ArticleStore(root);
        final original = fixture();
        await store.save(original);
        await store.save(original);
        for (final depth in SummaryDepth.values) {
          await store.save(
            ImportedArticle(
              title: original.title,
              sourceUrl: original.sourceUrl,
              author: original.author,
              published: original.published,
              blocks: original.blocks,
              depth: depth,
              originalId: original.id,
            ),
          );
        }
        await File('${root.path}/damaged.json').writeAsString('invalid');
        final restored = await ArticleStore(root).load();
        expect(restored.length, 4);
        expect(restored.map((a) => a.id).toSet().length, 4);
        expect(restored.every((a) => a.chapter.text == original.text), isTrue);
        expect(
          restored.singleWhere((a) => a.depth == null).toJson(),
          original.toJson(),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'sequential imports deduplicate, continue after failure and restore',
    () async {
      final root = await Directory.systemTemp.createTemp('article-queue-');
      final fetcher = ControlledFetcher();
      final library = ArticleLibrary(Future.value(root), fetcher: fetcher);
      try {
        final first = library.enqueue('https://example.org/trial');
        expect(
          identical(
            first,
            library.enqueue('https://example.org/trial?utm_source=chrome'),
          ),
          isTrue,
        );
        final failed = library.enqueue('https://example.org/fail');
        final second = library.enqueue('https://example.org/other');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(fetcher.calls.length, lessThanOrEqualTo(1));
        expect(second.status, 'Waiting');
        fetcher.first.complete(fixture());
        await library.settled;
        expect(first.status, 'Saved');
        expect(failed.error, 'Website unavailable');
        expect(second.status, 'Saved');
        expect(library.articles.length, 2);
        final restarted = ArticleLibrary(Future.value(root), fetcher: fetcher);
        await restarted.load();
        final cached = restarted.enqueue('https://example.org/trial');
        await restarted.settled;
        expect(cached.status, 'Saved');
        expect(fetcher.calls.length, 3);
        restarted.dispose();
      } finally {
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
