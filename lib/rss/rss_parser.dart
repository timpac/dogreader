import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../article_feed.dart';
import '../article_import.dart';
import 'rss_authors.dart';
import 'rss_models.dart';

class ParsedFeedEntry {
  const ParsedFeedEntry({
    required this.id,
    required this.title,
    required this.url,
    required this.canonicalUrl,
    this.guid,
    this.author,
    required this.normalizedAuthors,
    this.publishedAt,
    required this.summaryPreview,
    required this.blocks,
    required this.contentStatus,
    this.statusReason,
  });

  final String id;
  final String title;
  final String url;
  final String canonicalUrl;
  final String? guid;
  final String? author;
  final List<String> normalizedAuthors;
  final DateTime? publishedAt;
  final String summaryPreview;
  final List<ArticleBlock> blocks;
  final ArticleContentStatus contentStatus;
  final String? statusReason;
}

class ParsedFeed {
  const ParsedFeed({
    required this.feedUrl,
    this.siteUrl,
    required this.title,
    this.description,
    required this.entries,
  });

  final String feedUrl;
  final String? siteUrl;
  final String title;
  final String? description;
  final List<ParsedFeedEntry> entries;
}

class RssFeedFormatException implements Exception {
  const RssFeedFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

class RssParser {
  /// Parses an RSS 2.0, RSS 1.0/RDF, or Atom XML document into a [ParsedFeed]
  /// containing feed metadata and all parsed entries.
  static ParsedFeed parseFeedXml(
    String xmlText, {
    required Uri feedUrl,
    int maxEntries = 200,
  }) {
    final trimmed = xmlText.trim();
    if (trimmed.isEmpty) {
      throw const RssFeedFormatException('Feed response was empty.');
    }
    if (RegExp(r'<!\s*(DOCTYPE|ENTITY)\b', caseSensitive: false)
        .hasMatch(trimmed)) {
      throw const RssFeedFormatException(
        'Feed document/entity declarations are unsupported.',
      );
    }

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(trimmed);
    } on XmlException {
      throw const RssFeedFormatException(
        'The URL did not return a valid RSS or Atom XML document.',
      );
    }

    final root = doc.rootElement;
    final rootName = root.name.local.toLowerCase();
    if (rootName != 'rss' && rootName != 'feed' && rootName != 'rdf') {
      throw RssFeedFormatException(
        'Unsupported XML root <${root.name.local}>; expected <rss> or <feed>.',
      );
    }

    if (rootName == 'feed') {
      return _parseAtomFeed(root, feedUrl, maxEntries: maxEntries);
    }
    return _parseRssChannel(root, feedUrl, maxEntries: maxEntries);
  }

  /// Discovers candidate RSS/Atom feed URLs from a webpage URL and optional HTML.
  static List<Uri> discoverCandidateFeedUrls(Uri websiteOrFeedUrl, {String? html}) {
    final candidates = <Uri>[];
    final seen = <String>{};

    void addCandidate(Uri? uri) {
      if (uri == null) return;
      if (uri.scheme != 'http' && uri.scheme != 'https') return;
      final clean = uri.removeFragment();
      final normalized = clean.toString();
      if (seen.add(normalized)) {
        candidates.add(clean);
      }
    }

    if (html != null && html.trim().isNotEmpty) {
      for (final discovered in discoverArticleFeeds(html, websiteOrFeedUrl)) {
        addCandidate(discovered);
      }
    }

    final pathLower = websiteOrFeedUrl.path.toLowerCase();
    final looksLikeDirectFeed = pathLower.endsWith('.xml') ||
        pathLower.endsWith('.rss') ||
        pathLower.endsWith('.atom') ||
        pathLower.endsWith('/feed') ||
        pathLower.endsWith('/feed/') ||
        pathLower.endsWith('/rss') ||
        pathLower.endsWith('/atom');

    if (looksLikeDirectFeed) {
      final direct = websiteOrFeedUrl.removeFragment();
      candidates.removeWhere((u) => u.toString() == direct.toString());
      candidates.insert(0, direct);
      seen.add(direct.toString());
    } else {
      addCandidate(websiteOrFeedUrl);
    }

    final origin = Uri(
      scheme: websiteOrFeedUrl.scheme,
      userInfo: websiteOrFeedUrl.userInfo,
      host: websiteOrFeedUrl.host,
      port: websiteOrFeedUrl.hasPort ? websiteOrFeedUrl.port : null,
    );
    for (final suffix in const [
      '/feed',
      '/rss.xml',
      '/feed.xml',
      '/atom.xml',
      '/rss',
      '/index.xml',
      '/feed/atom',
    ]) {
      addCandidate(origin.resolve(suffix));
    }

    return candidates;
  }

  static ParsedFeed _parseRssChannel(
    XmlElement root,
    Uri feedUrl, {
    required int maxEntries,
  }) {
    final channel = _firstElement(root, const ['channel']) ?? root;
    final feedTitle = _cleanInline(_directChildText(channel, const ['title']) ?? '')
        .ifEmpty(feedUrl.host);
    final description =
        _cleanInline(_directChildText(channel, const ['description', 'subtitle']) ?? '')
            .nullIfEmpty;
    final siteUrl = _resolveChannelSiteUrl(channel, feedUrl);

    final itemElements = <XmlElement>[
      for (final el in channel.childElements)
        if (el.name.local.toLowerCase() == 'item') el,
      if (root.name.local.toLowerCase() == 'rdf')
        for (final el in root.childElements)
          if (el.name.local.toLowerCase() == 'item') el,
    ];

    final entries = <ParsedFeedEntry>[];
    final seenIds = <String>{};
    for (final item in itemElements.take(maxEntries)) {
      final parsed = _parseEntryElement(
        item,
        feedUrl: feedUrl,
        feedTitle: feedTitle,
        siteUrl: siteUrl,
      );
      if (parsed != null && seenIds.add(parsed.id)) {
        entries.add(parsed);
      }
    }

    return ParsedFeed(
      feedUrl: feedUrl.toString(),
      siteUrl: siteUrl,
      title: feedTitle,
      description: description,
      entries: entries,
    );
  }

  static ParsedFeed _parseAtomFeed(
    XmlElement root,
    Uri feedUrl, {
    required int maxEntries,
  }) {
    final feedTitle = _cleanInline(_directChildText(root, const ['title']) ?? '')
        .ifEmpty(feedUrl.host);
    final description =
        _cleanInline(_directChildText(root, const ['subtitle', 'tagline']) ?? '')
            .nullIfEmpty;
    final siteUrl = _resolveAtomSiteUrl(root, feedUrl);

    final entryElements = root.childElements
        .where((el) => el.name.local.toLowerCase() == 'entry')
        .take(maxEntries);

    final entries = <ParsedFeedEntry>[];
    final seenIds = <String>{};
    for (final entry in entryElements) {
      final parsed = _parseEntryElement(
        entry,
        feedUrl: feedUrl,
        feedTitle: feedTitle,
        siteUrl: siteUrl,
      );
      if (parsed != null && seenIds.add(parsed.id)) {
        entries.add(parsed);
      }
    }

    return ParsedFeed(
      feedUrl: feedUrl.toString(),
      siteUrl: siteUrl,
      title: feedTitle,
      description: description,
      entries: entries,
    );
  }

  static ParsedFeedEntry? _parseEntryElement(
    XmlElement item, {
    required Uri feedUrl,
    required String feedTitle,
    String? siteUrl,
  }) {
    final rawTitle = _cleanInline(_directChildText(item, const ['title']) ?? '');
    final entryLink = _resolveEntryLink(item, feedUrl, siteUrl);
    final guid = _cleanInline(_directChildText(item, const ['guid', 'id']) ?? '').nullIfEmpty;

    if (rawTitle.isEmpty && entryLink == null && guid == null) {
      return null;
    }

    final urlString = entryLink?.toString() ??
        (guid != null && guid.startsWith('http') ? guid : feedUrl.toString());
    final canonical = _safeCanonicalUrl(urlString);
    final title = rawTitle.isNotEmpty ? rawTitle : 'Untitled article';

    final author = _extractAuthor(item);
    final normalizedAuthors = RssAuthors.extractNormalizedAuthors(
      author,
      fallbackTitleOrText: title,
    );

    final pubDateText = _directChildText(
      item,
      const ['pubdate', 'published', 'updated', 'date'],
    );
    final publishedAt = _parseFeedDate(pubDateText);

    final encodedBody = _directChildText(item, const ['encoded', 'content']) ?? '';
    final summaryBody = _directChildText(item, const ['description', 'summary']) ?? '';

    final bestRawBody =
        encodedBody.trim().length >= summaryBody.trim().length && encodedBody.trim().isNotEmpty
            ? encodedBody
            : summaryBody;

    final parsedBlocks = _extractEntryBlocks(
      bestRawBody,
      baseUri: entryLink ?? feedUrl,
    );

    final summaryPreview = _buildSummaryPreview(summaryBody, parsedBlocks);

    final classification = classifyFeedEntryContent(
      rawHtmlOrText: bestRawBody,
      summaryHtmlOrText: summaryBody,
      blocks: parsedBlocks,
    );

    final uniqueKey = canonical.isNotEmpty && canonical != feedUrl.toString()
        ? canonical
        : (guid ?? '$feedUrl#$title');

    return ParsedFeedEntry(
      id: generateRssId('rss_article', uniqueKey),
      title: title,
      url: urlString,
      canonicalUrl: canonical,
      guid: guid,
      author: author,
      normalizedAuthors: normalizedAuthors,
      publishedAt: publishedAt,
      summaryPreview: summaryPreview,
      blocks: parsedBlocks,
      contentStatus: classification.$1,
      statusReason: classification.$2,
    );
  }

  /// Classifies a feed entry's content into one of the 5 explicit states
  /// and returns a human-readable diagnostic reason when not `full`.
  static (ArticleContentStatus, String?) classifyFeedEntryContent({
    required String rawHtmlOrText,
    required String summaryHtmlOrText,
    required List<ArticleBlock> blocks,
  }) {
    final combinedLower = '$rawHtmlOrText\n$summaryHtmlOrText'.toLowerCase();

    // 1. Check for explicit subscriber-only / paywall markers in the feed item
    if (_hasFeedPaywallMarkers(combinedLower)) {
      return (
        ArticleContentStatus.subscriberOnly,
        'This post is marked as subscriber-only in the publisher feed. '
            'Only the public preview is included.',
      );
    }

    if (blocks.isEmpty) {
      return (
        ArticleContentStatus.previewOnly,
        'Feed entry does not include article body text. Full text can be fetched from the original webpage.',
      );
    }

    // 2. Check for explicit truncation markers ("Continue reading...", "[...]", "Read more at...")
    final lastBlockText = blocks.last.text.trim();
    final hasTruncationTail = RegExp(
      r'(?:\[\.\.\.\]|\[…\]|continue reading|read the full (?:article|story|post)|read more\b|full story at\b)',
      caseSensitive: false,
    ).hasMatch(lastBlockText);

    // 3. Check if body is substantial enough to be considered complete
    final domFragment = html_parser.parseFragment('<div>$rawHtmlOrText</div>');
    final domElement = domFragment.querySelector('div') ?? html_parser.parse(rawHtmlOrText).body!;
    final totalChars = blocks.fold<int>(0, (sum, b) => sum + b.text.length);
    final paragraphCount = blocks.where((b) => !b.heading && b.kind != 'break').length;
    final looksSubstantial = totalChars >= 450 && paragraphCount >= 2;

    if (looksSubstantial &&
        !articleLooksIncomplete(domElement, blocks) &&
        !hasTruncationTail) {
      return (ArticleContentStatus.full, null);
    }

    return (
      ArticleContentStatus.previewOnly,
      'Feed includes an excerpt or summary only. DogReader can extract the full article from the webpage when publicly available.',
    );
  }

  static bool _hasFeedPaywallMarkers(String lower) {
    const markers = [
      'this post is for paid subscribers',
      'this episode is for paid subscribers',
      'for paid subscribers only',
      'subscribe to continue reading',
      'become a paying subscriber to read',
      'upgrade to paid to continue reading',
      'subscriber-only post',
      'members-only post',
      'paywall-content',
    ];
    for (final marker in markers) {
      if (lower.contains(marker)) return true;
    }
    return false;
  }

  static List<ArticleBlock> _extractEntryBlocks(
    String rawBody, {
    required Uri baseUri,
  }) {
    final trimmed = rawBody.trim();
    if (trimmed.isEmpty) return const [];

    final looksLikeHtml = RegExp(
      r'<(?:p|div|article|section|h[1-6]|blockquote|ul|ol|li|br|a|em|strong|figure|figcaption|hr)\b',
      caseSensitive: false,
    ).hasMatch(trimmed);

    final bodyHtml = looksLikeHtml
        ? trimmed
        : trimmed
            .split(RegExp(r'\n\s*\n'))
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .map((p) => '<p>${_escapeHtml(p)}</p>')
            .join('\n');

    final doc = html_parser.parse('<!doctype html><html><body><article>$bodyHtml</article></body></html>');
    final articleEl = doc.querySelector('article') ?? doc.body;
    if (articleEl == null) return const [];

    try {
      final cleaned = cleanArticleBlocks(articleEl, baseUri);
      if (cleaned.isNotEmpty) return cleaned;
    } catch (_) {}

    final plain = _stripTags(trimmed);
    if (plain.isEmpty) return const [];
    return [ArticleBlock(plain)];
  }

  static String _buildSummaryPreview(
    String summaryRaw,
    List<ArticleBlock> blocks,
  ) {
    final fromBlocks = blocks
        .where((b) =>
            !b.heading && (b.kind == 'paragraph' || b.kind == 'quote'))
        .map((b) => b.text.trim())
        .where((t) => t.isNotEmpty)
        .join(' ');
    final candidate = fromBlocks.isNotEmpty ? fromBlocks : _stripTags(summaryRaw);
    final normalized = candidate.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 260) return normalized;
    return '${normalized.substring(0, 257).trimRight()}…';
  }

  static String? _extractAuthor(XmlElement item) {
    for (final el in item.childElements) {
      final local = el.name.local.toLowerCase();
      if (local == 'author' || local == 'creator') {
        final nameChild = _firstElement(el, const ['name']);
        final raw = _cleanInline((nameChild ?? el).innerText);
        if (raw.isNotEmpty) {
          final match = RegExp(r'^[^\s@]+@[^\s@]+\s*\(([^)]+)\)$').firstMatch(raw);
          return match != null ? match.group(1)!.trim() : raw;
        }
      }
    }
    return null;
  }

  static String? _resolveChannelSiteUrl(XmlElement channel, Uri feedUrl) {
    for (final el in channel.childElements) {
      if (el.name.local.toLowerCase() != 'link') continue;
      final rel = (el.getAttribute('rel') ?? '').toLowerCase();
      if (rel == 'self') continue;
      final href = (el.getAttribute('href') ?? el.innerText).trim();
      if (href.isEmpty) continue;
      final resolved = feedUrl.resolveUri(Uri.tryParse(href) ?? Uri());
      if (resolved.scheme == 'http' || resolved.scheme == 'https') {
        return resolved.toString();
      }
    }
    return '${feedUrl.scheme}://${feedUrl.host}';
  }

  static String? _resolveAtomSiteUrl(XmlElement root, Uri feedUrl) {
    String? fallback;
    for (final el in root.childElements) {
      if (el.name.local.toLowerCase() != 'link') continue;
      final rel = (el.getAttribute('rel') ?? 'alternate').toLowerCase();
      final href = (el.getAttribute('href') ?? el.innerText).trim();
      if (href.isEmpty) continue;
      final parsed = Uri.tryParse(href);
      if (parsed == null) continue;
      final resolved = feedUrl.resolveUri(parsed).toString();
      if (rel == 'alternate') return resolved;
      if (rel != 'self') fallback ??= resolved;
    }
    return fallback ?? '${feedUrl.scheme}://${feedUrl.host}';
  }

  static Uri? _resolveEntryLink(
    XmlElement item,
    Uri feedUrl,
    String? siteUrl,
  ) {
    final base = (siteUrl != null ? Uri.tryParse(siteUrl) : null) ?? feedUrl;
    Uri? fallback;
    for (final el in item.childElements) {
      final local = el.name.local.toLowerCase();
      if (local == 'link') {
        final rel = (el.getAttribute('rel') ?? 'alternate').toLowerCase();
        final href = (el.getAttribute('href') ?? el.innerText).trim();
        if (href.isEmpty) continue;
        final uri = Uri.tryParse(href);
        if (uri == null) continue;
        final resolved = base.resolveUri(uri);
        if (resolved.scheme == 'http' || resolved.scheme == 'https') {
          if (rel == 'alternate') return resolved;
          fallback ??= resolved;
        }
      } else if (local == 'guid') {
        final isPermaLink =
            (el.getAttribute('isPermaLink') ?? 'true').toLowerCase() != 'false';
        if (isPermaLink) {
          final text = el.innerText.trim();
          final uri = Uri.tryParse(text);
          if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
            fallback ??= uri;
          }
        }
      }
    }
    return fallback;
  }

  static DateTime? _parseFeedDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.trim();
    final iso = DateTime.tryParse(value);
    if (iso != null) return iso.toUtc();

    final rfcMatch = RegExp(
      r'^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*([A-Za-z0-9+\-:]+)?$',
    ).firstMatch(value);
    if (rfcMatch != null) {
      const months = {
        'jan': 1,
        'feb': 2,
        'mar': 3,
        'apr': 4,
        'may': 5,
        'jun': 6,
        'jul': 7,
        'aug': 8,
        'sep': 9,
        'oct': 10,
        'nov': 11,
        'dec': 12,
      };
      final day = int.parse(rfcMatch.group(1)!);
      final month = months[rfcMatch.group(2)!.toLowerCase()];
      var year = int.parse(rfcMatch.group(3)!);
      if (year < 100) year += 2000;
      final hour = int.parse(rfcMatch.group(4)!);
      final minute = int.parse(rfcMatch.group(5)!);
      final second = int.parse(rfcMatch.group(6) ?? '0');
      if (month != null) {
        final dt = DateTime.utc(year, month, day, hour, minute, second);
        final tz = (rfcMatch.group(7) ?? 'UTC').trim();
        final offsetMatch = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(tz);
        if (offsetMatch != null) {
          final sign = offsetMatch.group(1) == '-' ? -1 : 1;
          final offsetMinutes =
              int.parse(offsetMatch.group(2)!) * 60 + int.parse(offsetMatch.group(3)!);
          return dt.subtract(Duration(minutes: sign * offsetMinutes));
        }
        return dt;
      }
    }
    return null;
  }

  static String _safeCanonicalUrl(String rawUrl) {
    try {
      return normalizedArticleUrl(articleUrl(rawUrl));
    } catch (_) {
      return rawUrl.trim();
    }
  }

  static XmlElement? _firstElement(XmlElement parent, List<String> names) {
    for (final child in parent.childElements) {
      if (names.contains(child.name.local.toLowerCase())) return child;
    }
    return null;
  }

  static String? _directChildText(XmlElement parent, List<String> names) {
    for (final name in names) {
      for (final child in parent.childElements) {
        if (child.name.local.toLowerCase() == name) {
          final text = child.innerText.trim();
          if (text.isNotEmpty) return text;
        }
      }
    }
    return null;
  }

  static String _stripTags(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _cleanInline(String text) =>
      _stripTags(text).replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _escapeHtml(String text) => const HtmlEscape().convert(text);
}

class HtmlEscape {
  const HtmlEscape();
  String convert(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

extension _StringFallbacks on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : trim();
  String? get nullIfEmpty => trim().isEmpty ? null : trim();
}
