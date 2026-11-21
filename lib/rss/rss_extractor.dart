import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;

import '../article_import.dart';
import 'rss_authors.dart';
import 'rss_models.dart';
import 'rss_parser.dart';

class RssHttpDocument {
  const RssHttpDocument({
    required this.finalUrl,
    required this.body,
    this.statusCode = 200,
    this.mimeType,
  });

  final Uri finalUrl;
  final String body;
  final int statusCode;
  final String? mimeType;
}

class RssHttpStatusException implements Exception {
  const RssHttpStatusException(this.statusCode, this.uri);
  final int statusCode;
  final Uri uri;

  @override
  String toString() => 'HTTP $statusCode from ${uri.origin}${uri.path}';
}

typedef RssDocumentLoader = Future<RssHttpDocument> Function(
  Uri uri, {
  bool preferFeed,
});

/// Full-text article extraction and 5-state content status classifier for RSS entries.
class RssExtractor {
  RssExtractor({
    RssDocumentLoader? documentLoader,
    HttpClient Function()? clientFactory,
    Future<List<InternetAddress>> Function(String)? lookup,
  }) : _documentLoader = documentLoader ??
            _createDefaultLoader(
              clientFactory: clientFactory ?? HttpClient.new,
              lookup: lookup ?? InternetAddress.lookup,
            );

  final RssDocumentLoader _documentLoader;

  /// Fetches and parses a feed from [urlOrSite], automatically discovering the
  /// RSS/Atom feed URL if the user entered a website homepage or article URL.
  Future<ParsedFeed> fetchAndDiscoverFeed(String urlOrSite) async {
    final validated = articleUrl(urlOrSite);
    final initialCandidates = RssParser.discoverCandidateFeedUrls(validated);

    Object? firstError;
    String? discoveredHtml;
    Uri? htmlBaseUri;

    try {
      final fetched = await _documentLoader(validated, preferFeed: true);
      final trimmed = fetched.body.trimLeft();
      if (_looksLikeXmlFeed(trimmed)) {
        return RssParser.parseFeedXml(fetched.body, feedUrl: fetched.finalUrl);
      }
      discoveredHtml = fetched.body;
      htmlBaseUri = fetched.finalUrl;
    } catch (error) {
      firstError = error;
    }

    final candidates = discoveredHtml != null && htmlBaseUri != null
        ? RssParser.discoverCandidateFeedUrls(
            htmlBaseUri,
            html: discoveredHtml,
          )
        : initialCandidates;

    for (final candidate in candidates) {
      if (htmlBaseUri != null && candidate == validated) continue;
      try {
        final fetched = await _documentLoader(candidate, preferFeed: true);
        if (_looksLikeXmlFeed(fetched.body.trimLeft())) {
          return RssParser.parseFeedXml(
            fetched.body,
            feedUrl: fetched.finalUrl,
          );
        }
      } catch (error) {
        firstError ??= error;
      }
    }

    if (firstError != null) {
      throw RssFeedFormatException(
        'Could not find a valid RSS or Atom feed at ${validated.host}: $firstError',
      );
    }
    throw RssFeedFormatException(
      'No RSS or Atom feed was found at $validated.',
    );
  }

  /// Attempts to upgrade an [RssArticle] whose feed entry was truncated or
  /// preview-only by fetching and extracting the original webpage.
  ///
  /// Explicitly classifies the resulting article into one of the five
  /// [ArticleContentStatus] states (`full`, `previewOnly`, `subscriberOnly`,
  /// `extractionFailed`, `unavailable`) and records a clear diagnostic
  /// `statusReason` without bypassing paywalls or overwriting usable preview blocks.
  Future<RssArticle> extractFullArticle(RssArticle article) async {
    final Uri targetUri;
    try {
      targetUri = articleUrl(article.url);
    } on ArticleImportException catch (e) {
      return article.copyWith(
        contentStatus: ArticleContentStatus.extractionFailed,
        statusReason: 'Invalid article URL: ${e.message}',
      );
    }

    RssHttpDocument fetched;
    try {
      fetched = await _documentLoader(targetUri, preferFeed: false);
    } on RssHttpStatusException catch (e) {
      if (e.statusCode == HttpStatus.unauthorized ||
          e.statusCode == HttpStatus.forbidden ||
          e.statusCode == HttpStatus.paymentRequired) {
        return article.copyWith(
          contentStatus: ArticleContentStatus.subscriberOnly,
          statusReason:
              'Publisher webpage returned HTTP ${e.statusCode} (subscriber or sign-in required). '
              'Showing the feed preview.',
        );
      }
      if (e.statusCode == HttpStatus.notFound ||
          e.statusCode == HttpStatus.gone) {
        return article.copyWith(
          contentStatus: ArticleContentStatus.unavailable,
          statusReason:
              'Original webpage is unavailable (HTTP ${e.statusCode}). '
              'Showing any cached feed preview.',
        );
      }
      return article.copyWith(
        contentStatus: ArticleContentStatus.extractionFailed,
        statusReason:
            'Webpage fetch failed with HTTP ${e.statusCode}. Showing cached feed content.',
      );
    } on ArticleAccessException catch (e) {
      return article.copyWith(
        contentStatus: ArticleContentStatus.subscriberOnly,
        statusReason: e.message,
      );
    } on ArticleImportException catch (e) {
      return article.copyWith(
        contentStatus: ArticleContentStatus.extractionFailed,
        statusReason: 'Could not load original webpage: ${e.message}',
      );
    } catch (e) {
      return article.copyWith(
        contentStatus: ArticleContentStatus.extractionFailed,
        statusReason: 'Network error while fetching webpage: $e',
      );
    }

    try {
      final extracted = extractArticle(
        fetched.body,
        fetched.finalUrl,
        originalSource: targetUri,
      );

      final hasMoreContentThanFeed =
          _totalChars(extracted.blocks) >= _totalChars(article.blocks);
      final bestBlocks = hasMoreContentThanFeed || article.blocks.isEmpty
          ? extracted.blocks
          : article.blocks;

      final bestAuthor = (extracted.author?.trim().isNotEmpty == true)
          ? extracted.author
          : article.author;
      final normalizedAuthors = RssAuthors.extractNormalizedAuthors(
        bestAuthor,
        fallbackTitleOrText: extracted.title,
      );

      return article.copyWith(
        title: extracted.title.isNotEmpty ? extracted.title : article.title,
        canonicalUrl: extracted.sourceUrl,
        author: bestAuthor,
        normalizedAuthors: normalizedAuthors.isNotEmpty
            ? normalizedAuthors
            : article.normalizedAuthors,
        blocks: bestBlocks,
        contentStatus: ArticleContentStatus.full,
        clearStatusReason: true,
      );
    } on ArticleAccessException catch (e) {
      return article.copyWith(
        contentStatus: ArticleContentStatus.subscriberOnly,
        statusReason:
            '${e.message} Showing the public feed excerpt (${article.wordCount} words).',
      );
    } on ArticleImportException catch (e) {
      if (_htmlHasPaywallPrompt(fetched.body)) {
        return article.copyWith(
          contentStatus: ArticleContentStatus.subscriberOnly,
          statusReason:
              'This article requires a publication subscription for the full text. '
              'Showing the public preview (${article.wordCount} words).',
        );
      }

      // Check if webpage has a partial/preview body
      final doc = html_parser.parse(fetched.body);
      final articleNode = doc.querySelector('article, main, [itemprop="articleBody"]');
      if (articleNode != null) {
        final partialBlocks = cleanArticleBlocks(articleNode, fetched.finalUrl);
        if (partialBlocks.isNotEmpty) {
          final bestBlocks =
              _totalChars(partialBlocks) > _totalChars(article.blocks)
                  ? partialBlocks
                  : article.blocks;
          return article.copyWith(
            blocks: bestBlocks,
            contentStatus: ArticleContentStatus.previewOnly,
            statusReason:
                'Both the RSS feed and webpage provide only a short preview or excerpt '
                '(${_wordCount(bestBlocks)} words). Open the original webpage to view the publisher page.',
          );
        }
      }

      if (article.blocks.isEmpty) {
        return article.copyWith(
          contentStatus: ArticleContentStatus.unavailable,
          statusReason: 'No readable article body was found: ${e.message}',
        );
      }
      return article.copyWith(
        contentStatus: ArticleContentStatus.extractionFailed,
        statusReason:
            'Full-text extraction could not parse the webpage layout (${e.message}). '
            'Showing the feed preview.',
      );
    } catch (e) {
      return article.copyWith(
        contentStatus: ArticleContentStatus.extractionFailed,
        statusReason: 'Full-text extraction failed: $e',
      );
    }
  }

  static RssDocumentLoader _createDefaultLoader({
    required HttpClient Function() clientFactory,
    required Future<List<InternetAddress>> Function(String) lookup,
  }) {
    return (Uri initial, {bool preferFeed = false}) async {
      final client = clientFactory()
        ..connectionTimeout = const Duration(seconds: 8);
      final pinned = <String, InternetAddress>{};
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        final address = pinned[uri.origin];
        if (proxyHost != null || address == null) {
          throw const ArticleAccessException(
            'Only direct public article connections are supported.',
          );
        }
        return connectValidatedArticleAddress(uri, address);
      };

      try {
        var url = articleUrl(initial.toString());
        for (var redirects = 0; redirects <= 5; redirects++) {
          final addresses = await lookup(url.host);
          if (addresses.isEmpty) {
            throw const ArticleImportException('Could not resolve host.');
          }
          pinned[url.origin] = addresses.first;
          final req = await client.getUrl(url);
          req.followRedirects = false;
          req.headers.set(
            HttpHeaders.acceptHeader,
            preferFeed
                ? 'application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8'
                : 'text/html, application/xhtml+xml',
          );
          if (preferFeed) {
            req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          }
          final response = await req.close().timeout(const Duration(seconds: 20));
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            await response.drain<void>();
            if (location == null) break;
            url = articleUrl(url.resolve(location).toString());
            continue;
          }
          if (response.statusCode != 200) {
            await response.drain<void>();
            throw RssHttpStatusException(response.statusCode, url);
          }
          final limit = 4 * 1024 * 1024;
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > limit) {
              throw const ArticleImportException('Response is too large.');
            }
            bytes.addAll(chunk);
          }
          final charset =
              response.headers.contentType?.charset?.toLowerCase() ?? 'utf-8';
          final decoder = {
            'utf-8': utf8,
            'utf8': utf8,
            'iso-8859-1': latin1,
            'us-ascii': ascii,
          }[charset] ??
              utf8;
          final decodedBody = decoder == utf8
              ? utf8.decode(bytes, allowMalformed: true)
              : latin1.decode(bytes, allowInvalid: true);
          return RssHttpDocument(
            finalUrl: url,
            body: decodedBody,
            statusCode: response.statusCode,
            mimeType: response.headers.contentType?.mimeType,
          );
        }
        throw const ArticleImportException('Too many redirects.');
      } finally {
        client.close(force: true);
      }
    };
  }

  static bool _looksLikeXmlFeed(String trimmed) {
    final head = trimmed.length > 600 ? trimmed.substring(0, 600) : trimmed;
    final lower = head.toLowerCase();
    if (lower.contains('<rss') ||
        lower.contains('<feed') ||
        lower.contains('<rdf:rdf')) {
      return true;
    }
    return false;
  }

  static int _totalChars(List<ArticleBlock> blocks) =>
      blocks.fold<int>(0, (sum, b) => sum + b.text.length);

  static int _wordCount(List<ArticleBlock> blocks) => blocks.fold<int>(
        0,
        (sum, b) =>
            sum +
            b.text
                .trim()
                .split(RegExp(r'\s+'))
                .where((w) => w.isNotEmpty)
                .length,
      );

  static bool _htmlHasPaywallPrompt(String html) {
    final lower = html.toLowerCase();
    return lower.contains('this post is for paid subscribers') ||
        lower.contains('subscribe to continue reading') ||
        lower.contains('for paying subscribers') ||
        lower.contains('paywall-title') ||
        lower.contains('class="paywall"');
  }
}
