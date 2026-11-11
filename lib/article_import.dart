import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'reader_content.dart';
import 'article_feed.dart';

class ArticleImportException implements Exception {
  final String message;
  const ArticleImportException(this.message, {this.allowFeedFallback = true});
  final bool allowFeedFallback;
  @override
  String toString() => message;
}

/// Explicit access restrictions are terminal, never a reason to try another URL.
class ArticleAccessException extends ArticleImportException {
  const ArticleAccessException(super.message);
}

enum SummaryDepth {
  brief('Brief', 'Main points'),
  standard('Standard', 'Meaningful detail'),
  detailed('Detailed', 'Thorough coverage');

  const SummaryDepth(this.label, this.description);
  final String label;
  final String description;
}

String articleDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

Uri articleUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 80 && uri.port != 443)) {
    throw const ArticleImportException(
      'Enter a public HTTP or HTTPS article URL.',
    );
  }
  final host = uri.host.toLowerCase();
  final address = InternetAddress.tryParse(
    host.replaceAll(RegExp(r'[\[\]]'), ''),
  );
  if (host == 'localhost' ||
      host.endsWith('.internal') ||
      host.endsWith('.lan') ||
      host.endsWith('.home') ||
      host.endsWith('.test') ||
      host.endsWith('.local') ||
      host.endsWith('.localhost') ||
      (address != null && !_publicAddress(address))) {
    throw const ArticleImportException(
      'Only public article websites are supported.',
    );
  }
  return uri.removeFragment();
}

bool _publicAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  final b = address.rawAddress;
  if (b.length == 4) {
    return b[0] != 0 &&
        b[0] != 10 &&
        b[0] != 127 &&
        b[0] < 224 &&
        address.address != '168.63.129.16' &&
        !(b[0] == 198 && b[1] == 51 && b[2] == 100) &&
        !(b[0] == 203 && b[1] == 0 && b[2] == 113) &&
        !(b[0] == 169 && b[1] == 254) &&
        !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
        !(b[0] == 192 && b[1] == 168) &&
        !(b[0] == 192 && b[1] == 0) &&
        !(b[0] == 198 && (b[1] == 18 || b[1] == 19)) &&
        !(b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  // Require globally routable IPv6; excludes mapped IPv4 and local ranges.
  return b[0] & 0xe0 == 0x20;
}

bool sameArticleUrl(Uri a, Uri b) {
  String identity(Uri value) {
    final clean = Uri.parse(normalizedArticleUrl(articleUrl(value.toString())));
    final host = clean.host.replaceFirst(RegExp(r'^www\.'), '');
    final path = clean.path.replaceFirst(RegExp(r'/+$'), '');
    return '$host:$path?${clean.query}';
  }

  return identity(a) == identity(b);
}

bool samePublication(Uri a, Uri b) =>
    a.host.replaceFirst(RegExp(r'^www\.'), '') ==
    b.host.replaceFirst(RegExp(r'^www\.'), '');

String? cleanArticleLink(String href, Uri source) {
  try {
    final link = source.resolve(href);
    final safe = articleUrl(link.toString());
    return Uri.parse(normalizedArticleUrl(safe))
        .replace(fragment: link.fragment.isEmpty ? null : link.fragment)
        .toString();
  } on ArticleImportException {
    return null;
  } on FormatException {
    return null;
  }
}

class ArticleSpan {
  const ArticleSpan(
    this.start,
    this.end, {
    this.italic = false,
    this.bold = false,
    this.url,
  });
  final int start, end;
  final bool italic, bold;
  final String? url;
  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    if (italic) 'italic': true,
    if (bold) 'bold': true,
    if (url != null) 'url': url,
  };
  factory ArticleSpan.fromJson(Map<String, dynamic> value) => ArticleSpan(
    value['start'] as int,
    value['end'] as int,
    italic: value['italic'] == true,
    bold: value['bold'] == true,
    url: value['url'] as String?,
  );
}

String normalizedArticleUrl(Uri uri) {
  final query = <String, List<String>>{};
  for (final key in uri.queryParametersAll.keys.toList()..sort()) {
    if (key.toLowerCase().startsWith('utm_') ||
        {'fbclid', 'gclid', 'msclkid'}.contains(key.toLowerCase())) {
      continue;
    }
    query[key] = uri.queryParametersAll[key]!;
  }
  final clean = uri.replace(host: uri.host.toLowerCase()).removeFragment();
  if (query.isEmpty) return clean.toString().split('?').first;
  return clean.replace(queryParameters: query).toString();
}

class ArticleBlock {
  const ArticleBlock(
    this.text, {
    this.heading = false,
    this.kind = 'paragraph',
    this.spans = const [],
  });
  final String text;
  final bool heading;
  final String kind;
  final List<ArticleSpan> spans;
  Map<String, dynamic> toJson() => {
    'text': text,
    'heading': heading,
    if (kind != 'paragraph') 'kind': kind,
    if (spans.isNotEmpty) 'spans': spans.map((s) => s.toJson()).toList(),
  };
  factory ArticleBlock.fromJson(Map<String, dynamic> value) {
    final text = value['text'] as String;
    final spans = (value['spans'] as List? ?? [])
        .map((s) => ArticleSpan.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList();
    for (final span in spans) {
      bool split(int offset) =>
          offset > 0 &&
          offset < text.length &&
          text.codeUnitAt(offset) >= 0xdc00 &&
          text.codeUnitAt(offset) <= 0xdfff;
      if (span.start < 0 ||
          span.end <= span.start ||
          span.end > text.length ||
          split(span.start) ||
          split(span.end)) {
        throw const FormatException('Invalid article span');
      }
    }
    return ArticleBlock(
      text,
      heading: value['heading'] == true,
      kind: value['kind'] as String? ?? 'paragraph',
      spans: List.unmodifiable(spans),
    );
  }
}

class ImportedArticle {
  ImportedArticle({
    required this.title,
    required this.sourceUrl,
    required List<ArticleBlock> blocks,
    this.author,
    this.published,
    this.publication,
    this.originalUrl,
    this.depth,
    this.originalId,
    this.originalContentHash,
    Map<String, dynamic>? usage,
  }) : blocks = List.unmodifiable(blocks),
       usage = usage == null ? null : Map.unmodifiable(usage);
  final String title, sourceUrl;
  final String? author, published, originalId, originalContentHash;
  final String? publication, originalUrl;
  final List<ArticleBlock> blocks;
  final SummaryDepth? depth;
  final Map<String, dynamic>? usage;
  String get text => blocks.map((b) => b.text).join('\n\n');
  String get contentHash => articleDigest(text);

  /// Half-open Dart UTF-16 ranges in the immutable reader/narration text.
  List<({int start, int end})> get blockOffsets {
    var offset = 0;
    return List.unmodifiable(
      blocks.map((block) {
        final start = offset;
        offset += block.text.length;
        final range = (start: start, end: offset);
        offset += 2; // Exactly the joiner's two newlines.
        return range;
      }),
    );
  }

  String get id => depth == null
      ? 'article_${articleDigest(sourceUrl)}'
      : '${originalId}_${depth!.name}_${contentHash.substring(0, 16)}';
  ReaderChapter get chapter {
    final output = StringBuffer();
    final ranges = <StyledRange>[];
    final separators = <StyledRange>[];
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (index > 0) output.write('\n\n');
      final start = output.length;
      output.write(block.text);
      if (isDecorativeNarrationSeparator(block.text)) {
        separators.add(StyledRange(start, output.length));
      }
      if (block.heading) {
        ranges.add(StyledRange(start, output.length, heading: true));
      }
      if (block.kind == 'quote' && block.text.isNotEmpty) {
        ranges.add(StyledRange(start, output.length, italic: true));
      }
      for (final span in block.spans) {
        if (span.italic || span.bold) {
          ranges.add(
            StyledRange(
              start + span.start,
              start + span.end,
              italic: span.italic,
              bold: span.bold,
            ),
          );
        }
      }
    }
    return ReaderChapter(
      depth == null ? title : '${depth!.label} summary',
      output.toString(),
      ranges,
      narrationSeparators: separators,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'title': title,
    'sourceUrl': sourceUrl,
    'author': author,
    'published': published,
    if (publication != null) 'publication': publication,
    if (originalUrl != null) 'originalUrl': originalUrl,
    'blocks': blocks.map((b) => b.toJson()).toList(),
    'depth': depth?.name,
    'originalId': originalId,
    'originalContentHash': originalContentHash,
    'textSha256': contentHash,
    'textLengthUtf16': text.length,
    'usage': usage,
  };
  factory ImportedArticle.fromJson(Map<String, dynamic> value) {
    final article = ImportedArticle(
      title: value['title'] as String,
      sourceUrl: value['sourceUrl'] as String,
      author: value['author'] as String?,
      published: value['published'] as String?,
      publication: value['publication'] as String?,
      originalUrl: value['originalUrl'] as String?,
      blocks: (value['blocks'] as List)
          .map(
            (b) => ArticleBlock.fromJson(Map<String, dynamic>.from(b as Map)),
          )
          .toList(),
      depth: value['depth'] == null
          ? null
          : SummaryDepth.values.byName(value['depth'] as String),
      originalId: value['originalId'] as String?,
      originalContentHash: value['originalContentHash'] as String?,
      usage: (value['usage'] as Map?)?.cast<String, dynamic>(),
    );
    // Legacy version-1 files without these additive checks retain exact text.
    if ((value.containsKey('textSha256') &&
            value['textSha256'] != article.contentHash) ||
        (value.containsKey('textLengthUtf16') &&
            value['textLengthUtf16'] != article.text.length)) {
      throw const FormatException(
        'Saved article text identity does not match.',
      );
    }
    return article;
  }
}

String _clean(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

List<ArticleBlock> cleanArticleBlocks(dom.Element root, Uri source) {
  const boundaries = {
    'article',
    'main',
    'section',
    'div',
    'p',
    'li',
    'ul',
    'ol',
    'blockquote',
    'pre',
    'figure',
    'figcaption',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'hr',
  };
  final blocks = <ArticleBlock>[];
  void container(dom.Element owner) {
    final inline = <dom.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      final raw = StringBuffer();
      final breaks = <int>{};
      final spans = <ArticleSpan>[];
      void walk(
        dom.Node node, {
        bool italic = false,
        bool bold = false,
        String? link,
      }) {
        if (node is dom.Text) {
          final start = raw.length;
          raw.write(node.text);
          if (owner.localName == 'pre') {
            for (var i = 0; i < node.text.length; i++) {
              if (node.text[i] == '\n') breaks.add(start + i);
            }
          }
          if (raw.length > start && (italic || bold || link != null)) {
            spans.add(
              ArticleSpan(
                start,
                raw.length,
                italic: italic,
                bold: bold,
                url: link,
              ),
            );
          }
        } else if (node is dom.Element) {
          if (node.localName == 'br') {
            breaks.add(raw.length);
            raw.write('\n');
            return;
          }
          if (node.localName == 'img') {
            return; // This reader renders text/captions only.
          }
          for (final child in node.nodes) {
            walk(
              child,
              italic: italic || {'em', 'i'}.contains(node.localName),
              bold: bold || {'strong', 'b'}.contains(node.localName),
              link: node.localName == 'a' && node.attributes.containsKey('href')
                  ? cleanArticleLink(node.attributes['href']!, source)
                  : link,
            );
          }
        }
      }

      for (final node in inline) {
        walk(node);
      }
      inline.clear();
      final input = raw.toString(), output = StringBuffer();
      final offsets = List<int>.filled(input.length + 1, 0);
      var last = '';
      var newlines = 0;
      for (var i = 0; i < input.length; i++) {
        offsets[i] = output.length;
        final c = input[i];
        if (breaks.contains(i)) {
          if (newlines < 2) output.write('\n');
          newlines++;
          last = '\n';
        } else if (RegExp(r'\s').hasMatch(c)) {
          if (output.isNotEmpty && last != ' ' && last != '\n') {
            output.write(' ');
            last = ' ';
          }
        } else {
          output.write(c);
          newlines = 0;
          last = c;
        }
      }
      offsets[input.length] = output.length;
      final normalized = output.toString();
      final leading = normalized.length - normalized.trimLeft().length;
      final stableText = normalized.trim();
      if (stableText.isEmpty) return;
      final boilerplate = RegExp(
        r'^(subscribe(?: now| to .*)?|sign (?:in|up)(?: to .*)?|log in(?: to .*)?|share this (?:post|article)|download the app|continue in (?:the )?app)[.!\s]*$',
        caseSensitive: false,
      );
      if (stableText.length < 160 && boilerplate.hasMatch(stableText)) return;
      bool inTag(String tag) {
        dom.Element? parent = owner;
        while (parent != null) {
          if (parent.localName == tag) return true;
          parent = parent.parent;
        }
        return false;
      }

      final mapped = <ArticleSpan>[];
      for (final span in spans) {
        final a = (offsets[span.start] - leading).clamp(0, stableText.length);
        final b = (offsets[span.end] - leading).clamp(0, stableText.length);
        if (b > a) {
          mapped.add(
            ArticleSpan(
              a,
              b,
              italic: span.italic,
              bold: span.bold,
              url: span.url,
            ),
          );
        }
      }
      // Keep the same UTF-16 text used to calculate every mapped range.
      blocks.add(
        ArticleBlock(
          stableText,
          heading: RegExp(r'^h[1-6]$').hasMatch(owner.localName ?? ''),
          kind: inTag('blockquote')
              ? 'quote'
              : inTag('li')
              ? 'list'
              : owner.localName == 'figcaption'
              ? 'caption'
              : 'paragraph',
          spans: List.unmodifiable(mapped),
        ),
      );
    }

    if (owner.localName == 'hr') {
      if (blocks.isNotEmpty && blocks.last.kind != 'break') {
        blocks.add(const ArticleBlock('', kind: 'break'));
      }
      return;
    }
    for (final node in owner.nodes) {
      if (node is dom.Element && boundaries.contains(node.localName)) {
        flush();
        container(node);
      } else {
        inline.add(node);
      }
    }
    flush();
  }

  container(root);
  if (blocks.isNotEmpty && blocks.last.kind == 'break') blocks.removeLast();
  return blocks;
}

bool articleLooksIncomplete(
  dom.Element root,
  List<ArticleBlock> blocks, {
  int? expectedWords,
}) {
  if (root.attributes['data-truncated'] == 'true' ||
      root.classes.contains('truncated') ||
      root.classes.contains('post-preview')) {
    return true;
  }
  if (root.querySelector(
        '[data-truncated="true"], .truncated, .post-preview',
      ) !=
      null) {
    return true;
  }
  final more = RegExp(
    r'^(read (?:more|(?:the )?full (?:article|post))|continue reading|subscribe to (?:continue|read|unlock).*)[.!…\s]*$',
    caseSensitive: false,
  );
  if (root
      .querySelectorAll('a, button')
      .any((a) => more.hasMatch(_clean(a.text)))) {
    return true;
  }
  final text = blocks.map((b) => b.text).join(' ');
  if (expectedWords != null &&
      expectedWords > 0 &&
      RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(text).length <
          expectedWords * .8) {
    return true;
  }
  return false;
}

ImportedArticle extractArticle(String page, Uri source, {Uri? originalSource}) {
  final document = html.parse(page);
  final metadata = <Map<String, dynamic>>[];
  void inspect(dynamic node) {
    if (node is List) {
      for (final child in node) {
        inspect(child);
      }
    }
    if (node is Map<String, dynamic>) {
      if (node['isAccessibleForFree'] == false ||
          node['isAccessibleForFree'] == 'false') {
        throw const ArticleAccessException(
          'This page requires payment or a subscription. Dogreader cannot import it.',
        );
      }
      final type = node['@type'].toString().toLowerCase();
      if (type.contains('article') || type.contains('blogposting')) {
        metadata.add(node);
      }
      for (final child in node.values) {
        if (child is List || child is Map) inspect(child);
      }
    }
  }

  for (final script in document.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    try {
      inspect(jsonDecode(script.text));
    } on FormatException {
      /* Broken publisher metadata. */
    }
  }
  String? meta(List<String> selectors) {
    for (final selector in selectors) {
      final content = _clean(
        document.querySelector(selector)?.attributes['content'] ?? '',
      );
      if (content.isNotEmpty) return content;
    }
    return null;
  }

  final structured = metadata.firstOrNull;
  final title =
      meta(['meta[property="og:title"]', 'meta[name="twitter:title"]']) ??
      structured?['headline']?.toString() ??
      document.querySelector('h1')?.text ??
      document.querySelector('title')?.text ??
      '';
  String? author = meta([
    'meta[name="author"]',
    'meta[property="article:author"]',
  ]);
  final names = structured?['author'];
  if (author == null && names != null) {
    final list = names is List ? names : [names];
    author = list
        .map((a) => a is Map ? a['name']?.toString() ?? '' : a.toString())
        .where((a) => a.isNotEmpty)
        .join(', ');
  }
  final published =
      meta(['meta[property="article:published_time"]', 'meta[name="date"]']) ??
      structured?['datePublished']?.toString() ??
      document.querySelector('time[datetime]')?.attributes['datetime'];
  var sourceUrl = normalizedArticleUrl(source);
  final canonical = document
      .querySelector('link[rel="canonical"]')
      ?.attributes['href'];
  if (canonical != null) {
    try {
      final candidate = articleUrl(source.resolve(canonical).toString());
      if (samePublication(candidate, source)) {
        sourceUrl = normalizedArticleUrl(candidate);
      }
    } on ArticleImportException {
      /* Untrusted canonical URL. */
    }
  }
  // Gate detection precedes removal: never turn a subscription preview into a full article.
  final gate = document.querySelector(
    '[class*="paywall"], [id*="paywall"], [data-testid*="paywall"]',
  );
  if (gate != null &&
      RegExp(
        r'subscribe|sign in|log in|subscription|unlock|purchase',
        caseSensitive: false,
      ).hasMatch(gate.text)) {
    throw const ArticleAccessException(
      'This article is paywalled or requires sign-in. Open it in your browser.',
    );
  }
  for (final element in document.querySelectorAll(
    'script, style, noscript, nav, aside, footer, form, iframe, svg, object, embed, input, textarea, select, [hidden], [aria-hidden="true"], [role="navigation"], [role="dialog"]',
  )) {
    element.remove();
  }
  final clutter = RegExp(
    r'(?:^|[\s_-])(ad|ads|advert|advertisement|advertising|cookie|cookies|consent|newsletter|subscribe|subscription|signup|login|related|recommended|recommendations?|social|share|sharing|comments?|sidebar|menu|navigation|promo)(?:$|[\s_-])',
    caseSensitive: false,
  );
  for (final element in document.querySelectorAll('[class], [id], [style]')) {
    final marker = '${element.className} ${element.id}';
    final style = element.attributes['style'] ?? '';
    if (clutter.hasMatch(marker) ||
        RegExp(
          r'display\s*:\s*none|visibility\s*:\s*hidden',
          caseSensitive: false,
        ).hasMatch(style)) {
      element.remove();
    }
  }
  final previewRoot =
      document.querySelector(
        'article, [itemprop="articleBody"], .body.markup',
      ) ??
      document.body;
  final previewMarked =
      previewRoot != null && articleLooksIncomplete(previewRoot, const []);
  for (final button in document.querySelectorAll('button')) {
    button.remove();
  }
  final candidates = document.querySelectorAll(
    'article, main, [role="main"], [itemprop="articleBody"], section, div',
  );
  dom.Element? best;
  var bestScore = 0.0;
  for (final candidate in candidates) {
    final paragraphs = candidate
        .querySelectorAll('p, li, pre, blockquote, figcaption')
        .where(
          (p) => p.querySelector('p, li, pre, blockquote, figcaption') == null,
        );
    final length = paragraphs.fold<int>(
      0,
      (sum, p) => sum + _clean(p.text).length,
    );
    final links = candidate
        .querySelectorAll('a')
        .fold<int>(0, (sum, a) => sum + _clean(a.text).length);
    final all = candidate.text.length;
    final density = all == 0 ? 1.0 : links / all;
    final semantic =
        candidate.localName == 'article' ||
        candidate.attributes['itemprop'] == 'articleBody';
    final score = length * (1 - density) * (semantic ? 1.3 : 1.0);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  // Do not fall back to all body text: menus and search results are not articles.
  if (best == null || bestScore < 200) {
    throw const ArticleImportException(
      'No readable public article was found. This page may require sign-in, JavaScript, or use an unsupported layout.',
    );
  }
  final blocks = cleanArticleBlocks(best, Uri.parse(sourceUrl));
  final text = blocks.map((b) => b.text).join('\n\n');
  if (text.length < 200 || _clean(title).isEmpty) {
    throw const ArticleImportException(
      'This page does not contain a supported readable article.',
    );
  }
  if (previewMarked ||
      articleLooksIncomplete(
        best,
        blocks,
        expectedWords: int.tryParse(structured?['wordCount']?.toString() ?? ''),
      )) {
    throw const ArticleImportException(
      'The page contains a preview or incomplete article body.',
    );
  }
  if (text.length > 250000) {
    throw const ArticleImportException(
      'This article is too long to import (maximum 250,000 characters).',
      allowFeedFallback: false,
    );
  }
  return ImportedArticle(
    title: _clean(title),
    sourceUrl: sourceUrl,
    author: author == null || author.isEmpty ? null : _clean(author),
    published: published,
    publication:
        meta(['meta[property="og:site_name"]']) ??
        (structured?['publisher'] is Map
            ? structured!['publisher']['name']?.toString()
            : null),
    originalUrl: normalizedArticleUrl(originalSource ?? source),
    blocks: blocks,
  );
}

class ArticleFetcher {
  ArticleFetcher({
    HttpClient Function()? clientFactory,
    Future<List<InternetAddress>> Function(String)? lookup,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _lookup = lookup ?? InternetAddress.lookup;
  final HttpClient Function() _clientFactory;
  final Future<List<InternetAddress>> Function(String) _lookup;

  Future<ImportedArticle> fetch(String value) async {
    final initial = articleUrl(value);
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 8);
    final pinned = <String, InternetAddress>{};
    // Connect to the validated address, avoiding a second, unvalidated DNS lookup.
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final address = pinned[uri.origin];
      if (proxyHost != null || address == null) {
        throw const ArticleAccessException(
          'Only direct public article connections are supported.',
        );
      }
      return Socket.startConnect(address, uri.port);
    };
    var remainingBytes = 8 * 1024 * 1024;
    Future<({String body, Uri url})> read(
      Uri initial, {
      bool feed = false,
    }) async {
      if (remainingBytes <= 0) {
        throw const ArticleImportException(
          'Article/feed response budget exceeded.',
          allowFeedFallback: false,
        );
      }
      var url = articleUrl(initial.toString());
      for (var redirects = 0; redirects <= 5; redirects++) {
        final addresses = await _lookup(url.host);
        if (addresses.isEmpty || addresses.any((a) => !_publicAddress(a))) {
          throw const ArticleAccessException(
            'Only public article websites are supported.',
          );
        }
        pinned[url.origin] = addresses.first;
        final req = await client.getUrl(url);
        req.followRedirects = false;
        req.headers.set(
          HttpHeaders.acceptHeader,
          feed
              ? 'application/rss+xml, application/atom+xml, application/xml, text/xml'
              : 'text/html, application/xhtml+xml',
        );
        if (feed) {
          // Ask intermediary caches to revalidate their recent-post snapshot.
          // This adds no retry and never sends credentials or changes access.
          req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        }
        final response = await req.close();
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          // Drain only a bounded redirect body; oversized/unending bodies abort.
          var count = 0;
          await for (final bytes in response) {
            count += bytes.length;
            remainingBytes -= bytes.length;
            if (count > 65536 || remainingBytes < 0) {
              throw const ArticleImportException(
                'Redirect response is too large.',
              );
            }
          }
          if (location == null) break;
          try {
            url = articleUrl(url.resolve(location).toString());
          } on ArticleImportException {
            throw const ArticleAccessException(
              'The publication redirected to an unsafe address.',
            );
          }
          continue;
        }
        if ({401, 402, 403, 429}.contains(response.statusCode)) {
          throw const ArticleAccessException(
            'This website requires sign-in/payment, blocks access, or asks you to try later. No alternative access was attempted.',
          );
        }
        if (response.statusCode != 200) {
          throw ArticleImportException(
            'HTTP ${response.statusCode} from ${url.origin}${url.path}.',
          );
        }
        final type = response.headers.contentType;
        if (!(feed
                ? {
                    'application/rss+xml',
                    'application/atom+xml',
                    'application/xml',
                    'text/xml',
                    'text/plain',
                    'text/html',
                  }
                : {'text/html', 'application/xhtml+xml'})
            .contains(type?.mimeType)) {
          throw const ArticleImportException(
            'The website returned an unsupported article/feed file type.',
          );
        }
        final limit = (feed ? 4 : 2) * 1024 * 1024;
        if (response.contentLength > limit) {
          throw const ArticleImportException(
            'This article/feed response is too large.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          remainingBytes -= chunk.length;
          if (bytes.length + chunk.length > limit || remainingBytes < 0) {
            throw const ArticleImportException(
              'This article/feed response is too large.',
            );
          }
          bytes.addAll(chunk);
        }
        final decoder = {
          'utf-8': utf8,
          'utf8': utf8,
          'iso-8859-1': latin1,
          'us-ascii': ascii,
        }[type?.charset?.toLowerCase() ?? 'utf-8'];
        if (decoder == null) {
          throw const ArticleImportException(
            'Unsupported article/feed text encoding.',
          );
        }
        return (body: decoder.decode(bytes), url: url);
      }
      throw const ArticleImportException(
        'This website redirects too many times. Use the direct article URL.',
      );
    }

    Future<ImportedArticle> import() async {
      var page = '', source = initial;
      try {
        final result = await read(initial);
        page = result.body;
        source = result.url;
        return extractArticle(page, source, originalSource: initial);
      } on ArticleAccessException {
        rethrow;
      } on ArticleImportException catch (error) {
        if (!error.allowFeedFallback) rethrow;
        /* Public but absent/incomplete HTML: inspect feeds. */
      }
      var matchedPreview = false;
      var readableFeeds = 0;
      final feedFailures = <String>[];
      for (final feed in discoverArticleFeeds(page, source)) {
        try {
          final result = await read(feed, feed: true);
          final article = extractFeedArticle(
            result.body,
            result.url,
            requested: initial,
            page: page,
            pageUrl: source,
          );
          if (article != null) return article;
          readableFeeds++;
        } on ArticleAccessException {
          rethrow;
        } on FeedPreviewException {
          matchedPreview = true;
        } on ArticleImportException catch (error) {
          if (!error.allowFeedFallback) rethrow;
          feedFailures.add('${feed.origin}${feed.path}: ${error.message}');
        } on FormatException {
          // Do not expose parser excerpts, which can contain article text.
          feedFailures.add(
            '${feed.origin}${feed.path}: the response could not be parsed as RSS/Atom XML.',
          );
        }
      }
      if (!matchedPreview && readableFeeds == 0 && feedFailures.isNotEmpty) {
        throw ArticleImportException(
          'The article page could not be extracted, and no usable RSS/Atom feed could be read. '
          '${feedFailures.first} '
          'This does not establish that the article is absent from the feed.',
        );
      }
      throw ArticleImportException(
        matchedPreview
            ? 'The matching feed entry provides only a preview or insufficient content. The full article was not imported.'
            : 'No complete matching article was found in the page or public RSS/Atom feeds. Older Substack posts may have fallen outside the feed’s recent-post window. Open the original article in your browser.',
      );
    }

    try {
      return await import().timeout(const Duration(seconds: 30));
    } on ArticleImportException {
      rethrow;
    } on TimeoutException {
      throw const ArticleImportException(
        'Article/feed import took too long. Try again later.',
      );
    } on SocketException {
      throw const ArticleImportException(
        'Cannot reach this publication. Check the URL and connection.',
      );
    } on HandshakeException {
      throw const ArticleImportException(
        'The publication has an invalid secure connection.',
      );
    } on FormatException {
      throw const ArticleImportException(
        'The publication returned unsupported article/feed content.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// Article data is additive; EPUBs, reading_state.json and narration paths stay intact.
class ArticleStore {
  ArticleStore(this.directory);
  final Directory directory;
  Future<List<ImportedArticle>> load() async {
    if (!await directory.exists()) return [];
    final result = <ImportedArticle>[];
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        result.add(
          ImportedArticle.fromJson(
            jsonDecode(await file.readAsString()) as Map<String, dynamic>,
          ),
        );
      } catch (_) {
        /* A damaged article must not hide the remaining library. */
      }
    }
    return result;
  }

  Future<void> save(ImportedArticle article) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/${article.id}.json');
    if (await file.exists()) {
      final previous = ImportedArticle.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      if (previous.text != article.text) {
        throw const ArticleImportException(
          'This saved article has different text. It was kept unchanged to preserve reading and narration positions.',
        );
      }
      return; // An existing version is immutable, including its saved metadata.
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(article.toJson()), flush: true);
    await temporary.rename(file.path);
  }
}
