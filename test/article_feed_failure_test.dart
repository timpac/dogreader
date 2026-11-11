import 'package:audiobook_app/article_import.dart';
import 'package:flutter_test/flutter_test.dart';

import 'article_rss_test.dart' as fixtures;

void main() {
  test(
    'failed feed requests report their HTTP cause rather than article absence',
    () async {
      final client = fixtures.FixtureClient({
        fixtures.requested: fixtures.reply(
          fixtures.fixture('substack-shell.html'),
        ),
        'https://astralcodexten.com/feed': fixtures.reply('', status: 503),
      });
      await expectLater(
        fixtures.fetcher(client).fetch(fixtures.requested),
        throwsA(
          isA<ArticleImportException>()
              .having((e) => e.message, 'cause', contains('HTTP 503'))
              .having(
                (e) => e.message,
                'feed',
                contains('astralcodexten.com/feed'),
              )
              .having(
                (e) => e.message,
                'classification',
                isNot(contains('recent-post window')),
              ),
        ),
      );
    },
  );

  test('unparseable feed responses identify the failing feed without leaking content', () async {
    final client = fixtures.FixtureClient({
      fixtures.requested: fixtures.reply(
        fixtures.fixture('substack-shell.html'),
      ),
      'https://astralcodexten.com/feed': fixtures.reply(
        '<rss><private-text>',
        type: 'application/xml',
      ),
    });
    await expectLater(
      fixtures.fetcher(client).fetch(fixtures.requested),
      throwsA(
        isA<ArticleImportException>()
            .having((e) => e.message, 'cause', contains('could not be parsed'))
            .having(
              (e) => e.message,
              'privacy',
              isNot(contains('private-text')),
            )
            .having(
              (e) => e.message,
              'classification',
              isNot(contains('recent-post window')),
            ),
      ),
    );
  });

  test(
    'a valid feed without a match still reports the recent-post window',
    () async {
      final client = fixtures.FixtureClient({
        fixtures.requested: fixtures.reply(
          fixtures.fixture('substack-shell.html'),
        ),
        'https://astralcodexten.com/feed': fixtures.reply(
          fixtures.fixture('absent.xml'),
          type: 'application/rss+xml',
        ),
      });
      await expectLater(
        fixtures.fetcher(client).fetch(fixtures.requested),
        throwsA(
          isA<ArticleImportException>().having(
            (e) => e.message,
            'classification',
            contains('recent-post window'),
          ),
        ),
      );
    },
  );

  test('the reported ACT URL matches full content and requests feed revalidation', () async {
    const actual =
        'https://www.astralcodexten.com/p/escaping-the-outside-criticism-trap';
    String substitute(String value) =>
        value.replaceAll(fixtures.canonical, actual);
    final client = fixtures.FixtureClient({
      actual: fixtures.reply(
        substitute(fixtures.fixture('substack-shell.html')),
      ),
      'https://www.astralcodexten.com/feed': fixtures.reply(
        substitute(fixtures.fixture('substack-full.xml')),
        type: 'application/xml',
      ),
    });
    final article = await fixtures.fetcher(client).fetch(actual);
    expect(article.sourceUrl, actual);
    expect(article.text, contains('Keep the uncertainty visible.'));
    expect(client.requests[1].headers.value('cache-control'), 'no-cache');
    expect(client.requests.first.headers.value('cache-control'), isNull);
    expect(client.urls.length, 2);
  });
}
