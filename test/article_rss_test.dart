import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/article_feed.dart';
import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/article_library.dart';
import 'package:audiobook_app/narration_dictionary.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/article_http.dart';

const requested = 'https://astralcodexten.com/p/fixture-public-article';
const canonical = 'https://www.astralcodexten.com/p/fixture-public-article';
String fixture(String file) =>
    File('test/fixtures/article_rss/$file').readAsStringSync();
ArticleHttpResponse reply(
  String body, {
  int status = 200,
  String type = 'text/html',
  String? location,
}) {
  final response = ArticleHttpResponse(status, body);
  response.headers.contentType = ContentType.parse(type);
  if (location != null) {
    response.headers.set(HttpHeaders.locationHeader, location);
  }
  return response;
}

class FixtureClient extends ArticleHttpClient {
  FixtureClient(this.pages) : super(reply('', status: 404));
  final Map<String, ArticleHttpResponse> pages;
  bool pinned = false;
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? factory,
  ) {
    pinned = factory != null;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    final request = ArticleHttpRequest(
      pages[url.toString()] ?? reply('', status: 404),
    );
    requests.add(request);
    return request;
  }
}

ArticleFetcher fetcher(
  FixtureClient client, {
  Future<List<InternetAddress>> Function(String)? lookup,
}) => ArticleFetcher(
  clientFactory: () => client,
  lookup: lookup ?? (_) async => [InternetAddress('93.184.216.34')],
);

void main() {
  test('description content needs explicit full-word-count evidence, not just length', () {
    final original = fixture('substack-full.xml');
    final body = original
        .split('<content:encoded><![CDATA[')[1]
        .split(']]></content:encoded>')[0];
    final feed = fixture('preview.xml').replaceFirst(
      '<description>Read more to see the complete article.</description>',
      '<description><![CDATA[$body]]></description>',
    );
    final page =
        '<script type="application/ld+json">{"@type":"Article","wordCount":80}</script>';
    expect(
      extractFeedArticle(
        feed,
        Uri.parse('https://astralcodexten.com/feed'),
        requested: Uri.parse(requested),
        page: page,
        pageUrl: Uri.parse(requested),
      )!.text,
      contains('The authors wrote: Keep the uncertainty visible.'),
    );
    expect(
      () => extractFeedArticle(
        feed,
        Uri.parse('https://astralcodexten.com/feed'),
        requested: Uri.parse(requested),
        page: '',
        pageUrl: Uri.parse(requested),
      ),
      throwsA(isA<FeedPreviewException>()),
    );
  });

  test('a long HTTP-200 preview is rejected by its declared word count before RSS fallback', () async {
    final shell = fixture('substack-shell.html')
        .replaceFirst(
          '</head>',
          '<script type="application/ld+json">{"@type":"Article","wordCount":80}</script></head>',
        )
        .replaceFirst(
          '</main>',
          '<article><p>${List.filled(8, 'This is an incomplete excerpt.').join(' ')}</p></article></main>',
        );
    final client = FixtureClient({
      requested: reply(shell),
      'https://astralcodexten.com/feed': reply(
        fixture('substack-full.xml'),
        type: 'application/rss+xml',
      ),
    });
    final article = await fetcher(client).fetch(requested);
    expect(client.urls.length, 2);
    expect(article.text, contains('This is a synthetic fixture'));
    expect(article.text, isNot(contains('incomplete excerpt')));
    for (final marked in [
      fixture('normal.html')
          .replaceFirst('<article>', '<article data-truncated="true">'),
      fixture('normal.html').replaceFirst(
        '</article>',
        '<button>Read full article</button></article>',
      ),
    ]) {
      expect(
        () => extractArticle(marked, Uri.parse(requested)),
        throwsA(isA<ArticleImportException>()),
      );
    }
    expect(
      () => extractFeedArticle(
        fixture('substack-full.xml'),
        Uri.parse('https://astralcodexten.com/feed'),
        requested: Uri.parse(requested),
        page: shell.replaceFirst('80', '1000'),
        pageUrl: Uri.parse(requested),
      ),
      throwsA(isA<FeedPreviewException>()),
    );
  });

  test('opaque stable IDs require an explicit publication metadata match', () {
    final feed = fixture('substack-full.xml')
        .replaceAll(canonical, 'https://www.astralcodexten.com/p/other-link')
        .replaceFirst(
          '<guid isPermaLink="false">https://www.astralcodexten.com/p/other-link</guid>',
          '<guid isPermaLink="false">stable-article-7</guid>',
        );
    ImportedArticle? extract(String page) => extractFeedArticle(
      feed,
      Uri.parse('https://astralcodexten.com/feed'),
      requested: Uri.parse(requested),
      page: page,
      pageUrl: Uri.parse(requested),
    );
    expect(extract(''), isNull);
    expect(
      extract('<meta name="article:id" content="stable-article-7">')!.sourceUrl,
      requested,
    );
  });

  test(
    'preformatted line breaks and section boundaries remain stable saved text',
    () {
      final article = extractArticle(
        fixture('normal.html').replaceFirst(
          '</article>',
          '<hr><pre>First line\nSecond line\n\nThird line</pre></article>',
        ),
        Uri.parse(requested),
      );
      expect(article.text, contains('First line\nSecond line\n\nThird line'));
      expect(article.blocks.any((b) => b.kind == 'break'), isTrue);
      expect(ImportedArticle.fromJson(article.toJson()).text, article.text);
    },
  );

  test('complete HTML is preferred without any feed request', () async {
    final client = FixtureClient({requested: reply(fixture('normal.html'))});
    final article = await fetcher(client).fetch(requested);
    expect(client.urls.map((u) => u.toString()), [requested]);
    expect(article.sourceUrl, canonical);
    expect(article.publication, 'Astral Codex Ten');
    expect(article.author, 'Fixture Author');
    expect(client.pinned, isTrue);
    expect(client.requests.single.followRedirects, isFalse);
  });

  test(
    'Substack shell falls back to its exact RSS entry and full encoded content',
    () async {
      final client = FixtureClient({
        requested: reply(fixture('substack-shell.html')),
        'https://astralcodexten.com/feed': reply(
          fixture('substack-full.xml'),
          type: 'application/rss+xml',
        ),
      });
      final article = await fetcher(client).fetch(requested);
      expect(client.urls.length, 2);
      expect(article.sourceUrl, canonical);
      expect(article.originalUrl, requested);
      expect(article.text, contains('Keep the uncertainty visible.'));
      expect(article.text, isNot(contains('short preview')));
      expect(article.publication, 'Astral Codex Ten');
      expect(article.published, 'Wed, 11 Nov 2026 12:00:00 GMT');
      expect(
        client.requests.every(
          (r) =>
              r.headers.value(HttpHeaders.authorizationHeader) == null &&
              r.headers.value(HttpHeaders.cookieHeader) == null,
        ),
        isTrue,
      );
    },
  );

  test('Atom XHTML, HTML and text content use the same cleanup and exact URL matching', () {
    final xhtml = fixture('atom-full.xml');
    final article = extractFeedArticle(
      xhtml,
      Uri.parse('https://astralcodexten.com/atom.xml'),
      requested: Uri.parse(requested),
      page: '',
      pageUrl: Uri.parse(requested),
    )!;
    expect(article.publication, 'Example Publication');
    expect(article.author, 'Fixture Author');
    expect(article.blocks.any((b) => b.kind == 'quote'), isTrue);
    expect(article.text, contains('😀 Cicero'));
    for (final type in ['html', 'text']) {
      final text = article.text;
      final content = type == 'html'
          ? '<![CDATA[<p>${htmlEscape.convert(text)}</p>]]>'
          : htmlEscape.convert(text);
      final feed =
          '<feed xmlns="http://www.w3.org/2005/Atom"><title>Publication</title><entry><title>Title</title><link href="$canonical"/><content type="$type">$content</content></entry></feed>';
      expect(
        extractFeedArticle(
          feed,
          Uri.parse('https://astralcodexten.com/atom.xml'),
          requested: Uri.parse(requested),
          page: '',
          pageUrl: Uri.parse(requested),
        )!.text,
        contains('Keep the uncertainty visible.'),
      );
    }
  });

  test('absent article never matches a similar title and explains the recent-post window', () async {
    final client = FixtureClient({
      requested: reply(fixture('substack-shell.html')),
      'https://astralcodexten.com/feed': reply(
        fixture('absent.xml'),
        type: 'application/rss+xml',
      ),
    });
    await expectLater(
      fetcher(client).fetch(requested),
      throwsA(
        isA<ArticleImportException>().having(
          (e) => e.message,
          'message',
          contains('recent-post window'),
        ),
      ),
    );
    expect(client.urls.length, lessThanOrEqualTo(5));
  });

  test('description-only and full-field previews are rejected, never saved as complete', () async {
    for (final feed in [
      fixture('preview.xml'),
      fixture(
        'substack-full.xml',
      ).replaceFirst('</h1>', '</h1><a href="/upgrade">Continue reading</a>'),
    ]) {
      final client = FixtureClient({
        requested: reply(fixture('substack-shell.html')),
        'https://astralcodexten.com/feed': reply(
          feed,
          type: 'application/rss+xml',
        ),
      });
      await expectLater(
        fetcher(client).fetch(requested),
        throwsA(
          isA<ArticleImportException>().having(
            (e) => e.message,
            'message',
            contains('preview'),
          ),
        ),
      );
    }
  });

  test('cleanup preserves wording, structure, inline styles, safe links and UTF-16 coordinates', () {
    final article = extractArticle(
      fixture('normal.html'),
      Uri.parse(requested),
    );
    for (final removed in [
      'Subscribe now',
      'Repeated navigation',
      'do_not_display',
      '<script>',
      'utm_source=feed',
    ]) {
      expect(article.text, isNot(contains(removed)));
    }
    expect(article.blocks.where((b) => b.heading).length, 2);
    expect(article.blocks.where((b) => b.kind == 'list').length, 2);
    expect(
      article.blocks.singleWhere((b) => b.kind == 'quote').text,
      'The authors wrote: Keep the uncertainty visible. A larger controlled trial is needed before drawing a general conclusion.',
    );
    expect(
      article.text,
      contains('source notes.\nKeep this intentional line break'),
    );
    expect(article.text, contains('Caption: uncertainty remains.'));
    final links = article.blocks
        .expand((b) => b.spans)
        .where((s) => s.url != null)
        .toList();
    expect(
      links.map((s) => s.url),
      contains('https://example.org/source?id=7'),
    );
    expect(links.map((s) => s.url), contains('$canonical#fn-1'));
    final restored = ImportedArticle.fromJson(
      jsonDecode(jsonEncode(article.toJson())),
    );
    expect(restored.text, article.text);
    expect(restored.chapter.text, article.chapter.text);
    final italic = restored.chapter.ranges.where((r) => r.italic).toList();
    expect(
      italic.any(
        (r) =>
            restored.text.substring(r.start, r.end) ==
            'promising but uncertain',
      ),
      isTrue,
    );
    expect(
      restored.chapter.ranges.any(
        (r) =>
            r.bold &&
            restored.text.substring(r.start, r.end) ==
                'Keep the uncertainty visible.',
      ),
      isTrue,
    );
    expect(
      restored.text.indexOf('Cicero'),
      'A measured experiment\n\n😀 '.length,
    ); // UTF-16, including the leading heading and astral emoji.
    final frozen = const NarrationDictionaryConfig(
      rules: [NarrationRule('Cicero', 'SEE')],
    ).transform(restored.chapter);
    expect(frozen.offsets['sourceLength'], restored.text.length);
    expect(frozen.text, contains('😀 SEE'));
    expect(restored.text, article.text);
  });

  test('HTML/RSS aliases deduplicate and saved text/progress remain immutable offline', () async {
    final root = await Directory.systemTemp.createTemp('rss-store-');
    final client = FixtureClient({
      requested: reply(fixture('substack-shell.html')),
      'https://astralcodexten.com/feed': reply(
        fixture('substack-full.xml'),
        type: 'application/rss+xml',
      ),
    });
    final library = ArticleLibrary(
      Future.value(root),
      fetcher: fetcher(client),
    );
    try {
      library.enqueue(requested);
      await library.settled;
      final article = library.articles.single;
      final file = File('${root.path}/articles/${article.id}.json');
      final saved = await file.readAsString();
      final reading = File('${root.path}/reading_state.json');
      await reading.writeAsString('{"offset":29}');
      library.enqueue('$canonical?utm_source=reader');
      await library.settled;
      expect(library.articles.length, 1);
      expect(client.urls.length, 2);
      expect(await file.readAsString(), saved);
      expect(await reading.readAsString(), '{"offset":29}');
      final stored = (await ArticleStore(
        Directory('${root.path}/articles'),
      ).load()).single;
      expect(stored.text, article.text);
      expect(
        stored.blocks.expand((b) => b.spans).map((s) => s.toJson()),
        article.blocks.expand((b) => b.spans).map((s) => s.toJson()),
      );
    } finally {
      library.dispose();
      await root.delete(recursive: true);
    }
  });

  test('unsafe schemes, private literals, DNS and redirects are rejected before requesting them', () async {
    for (final url in [
      'file:///secret',
      'javascript:alert(1)',
      'http://localhost/p',
      'http://10.1.2.3/p',
      'http://172.20.1.2/p',
      'http://192.168.1.1/p',
      'http://169.254.169.254/latest',
      'http://100.100.100.200/p',
      'http://168.63.129.16/p',
      'http://[::1]/',
      'http://[fc00::1]/',
      'http://metadata.google.internal/p',
      'https://user:password@example.org',
    ]) {
      expect(() => articleUrl(url), throwsA(isA<ArticleImportException>()));
    }
    for (final target in [
      'http://127.0.0.1/private',
      'https://private.example.org/p',
    ]) {
      final client = FixtureClient({
        requested: reply('', status: 302, location: target),
      });
      await expectLater(
        fetcher(
          client,
          lookup: (host) async => [
            InternetAddress(
              host == 'private.example.org' ? '10.0.0.1' : '93.184.216.34',
            ),
          ],
        ).fetch(requested),
        throwsA(isA<ArticleAccessException>()),
      );
      expect(client.urls.map((u) => u.toString()), [requested]);
    }
  });

  test('explicit access restrictions do not trigger feed requests; XML entities are rejected', () async {
    final client = FixtureClient({
      requested: reply(
        fixture('normal.html').replaceFirst(
          '</head>',
          '<script type="application/ld+json">{"@type":"Article","isAccessibleForFree":false}</script></head>',
        ),
      ),
    });
    await expectLater(
      fetcher(client).fetch(requested),
      throwsA(isA<ArticleAccessException>()),
    );
    expect(client.urls.length, 1);
    expect(
      () => extractFeedArticle(
        '<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss/>',
        Uri.parse('https://example.org/feed'),
        requested: Uri.parse(requested),
        page: '',
        pageUrl: Uri.parse(requested),
      ),
      throwsA(isA<ArticleImportException>()),
    );
  });
}
