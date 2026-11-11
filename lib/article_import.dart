import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'reader_content.dart';

class ArticleImportException implements Exception {
  final String message;
  const ArticleImportException(this.message);
  @override
  String toString() => message;
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
        !(b[0] == 169 && b[1] == 254) &&
        !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
        !(b[0] == 192 && b[1] == 168) &&
        !(b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  // Require globally routable IPv6; excludes mapped IPv4 and local ranges.
  return b[0] & 0xe0 == 0x20;
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
  const ArticleBlock(this.text, {this.heading = false});
  final String text;
  final bool heading;
  Map<String, dynamic> toJson() => {'text': text, 'heading': heading};
  factory ArticleBlock.fromJson(Map<String, dynamic> value) =>
      ArticleBlock(value['text'] as String, heading: value['heading'] == true);
}

class ImportedArticle {
  ImportedArticle({
    required this.title,
    required this.sourceUrl,
    required List<ArticleBlock> blocks,
    this.author,
    this.published,
    this.depth,
    this.originalId,
    this.originalContentHash,
    Map<String, dynamic>? usage,
  }) : blocks = List.unmodifiable(blocks),
       usage = usage == null ? null : Map.unmodifiable(usage);
  final String title, sourceUrl;
  final String? author, published, originalId, originalContentHash;
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
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (index > 0) output.write('\n\n');
      final start = output.length;
      output.write(block.text);
      if (block.heading) {
        ranges.add(StyledRange(start, output.length, heading: true));
      }
    }
    return ReaderChapter(
      depth == null ? title : '${depth!.label} summary',
      output.toString(),
      ranges,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'title': title,
    'sourceUrl': sourceUrl,
    'author': author,
    'published': published,
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

ImportedArticle extractArticle(String page, Uri source) {
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
        throw const ArticleImportException(
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
      if (candidate.host == source.host) {
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
    throw const ArticleImportException(
      'This article is paywalled or requires sign-in. Open it in your browser.',
    );
  }
  for (final element in document.querySelectorAll(
    'script, style, noscript, nav, aside, footer, form, button, iframe, svg, [hidden], [aria-hidden="true"], [role="navigation"], [role="dialog"]',
  )) {
    element.remove();
  }
  final clutter = RegExp(
    r'(?:^|[\s_-])(ad|ads|advert|advertisement|advertising|cookie|cookies|consent|newsletter|related|recommended|social|share|sharing|comments?|sidebar|menu|navigation|promo)(?:$|[\s_-])',
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
  final candidates = document.querySelectorAll(
    'article, main, [role="main"], [itemprop="articleBody"], section, div',
  );
  dom.Element? best;
  var bestScore = 0.0;
  for (final candidate in candidates) {
    final paragraphs = candidate.querySelectorAll('p');
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
  final blocks = <ArticleBlock>[];
  for (final element in best.querySelectorAll(
    'h1, h2, h3, h4, h5, h6, p, li, pre, blockquote',
  )) {
    if (element.querySelector('p, li, pre, blockquote') != null) continue;
    final text = _clean(element.text);
    if (text.isNotEmpty) {
      blocks.add(
        ArticleBlock(text, heading: element.localName!.startsWith('h')),
      );
    }
  }
  final text = blocks.map((b) => b.text).join('\n\n');
  if (text.length < 200 || _clean(title).isEmpty) {
    throw const ArticleImportException(
      'This page does not contain a supported readable article.',
    );
  }
  if (text.length > 250000) {
    throw const ArticleImportException(
      'This article is too long to import (maximum 250,000 characters).',
    );
  }
  return ImportedArticle(
    title: _clean(title),
    sourceUrl: sourceUrl,
    author: author == null || author.isEmpty ? null : _clean(author),
    published: published,
    blocks: blocks,
  );
}

class ArticleFetcher {
  Future<ImportedArticle> fetch(String value) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      return await _fetch(
        client,
        articleUrl(value),
      ).timeout(const Duration(seconds: 30));
    } on ArticleImportException {
      rethrow;
    } on TimeoutException {
      throw const ArticleImportException(
        'The website took too long to respond. Try again later.',
      );
    } on SocketException {
      throw const ArticleImportException(
        'Cannot reach this website. Check the URL and your internet connection.',
      );
    } on HandshakeException {
      throw const ArticleImportException(
        'The website has an invalid secure connection.',
      );
    } on FormatException {
      throw const ArticleImportException(
        'This page uses an unsupported text encoding.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<ImportedArticle> _fetch(HttpClient client, Uri initial) async {
    var url = initial;
    for (var redirects = 0; redirects <= 5; redirects++) {
      // Resolve every redirect before requesting it. No browser cookies or credentials.
      final addresses = await InternetAddress.lookup(url.host);
      if (addresses.isEmpty || addresses.any((a) => !_publicAddress(a))) {
        throw const ArticleImportException(
          'Only public article websites are supported.',
        );
      }
      final req = await client.getUrl(url);
      req.followRedirects = false;
      req.headers.set(
        HttpHeaders.acceptHeader,
        'text/html, application/xhtml+xml',
      );
      final response = await req.close();
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) break;
        url = articleUrl(url.resolve(location).toString());
        continue;
      }
      if ({401, 402, 403}.contains(response.statusCode)) {
        throw const ArticleImportException(
          'This website requires payment, sign-in, or blocks article access. Dogreader cannot import it.',
        );
      }
      if (response.statusCode != 200) {
        throw ArticleImportException(
          'The website could not provide this article (HTTP ${response.statusCode}).',
        );
      }
      final type = response.headers.contentType;
      if (!{'text/html', 'application/xhtml+xml'}.contains(type?.mimeType)) {
        throw const ArticleImportException(
          'Only HTML web articles are supported. This link points to another file type.',
        );
      }
      const limit = 2 * 1024 * 1024;
      if (response.contentLength > limit) {
        throw const ArticleImportException('This page is too large to import.');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > limit) {
          throw const ArticleImportException(
            'This page is too large to import.',
          );
        }
      }
      final charset = type?.charset?.toLowerCase() ?? 'utf-8';
      final Encoding? decoder = {
        'utf-8': utf8,
        'utf8': utf8,
        'iso-8859-1': latin1,
        'us-ascii': ascii,
      }[charset];
      if (decoder == null) {
        throw const ArticleImportException(
          'This page uses an unsupported text encoding.',
        );
      }
      return extractArticle(decoder.decode(bytes), url);
    }
    throw const ArticleImportException(
      'This website redirects too many times. Use the direct article URL.',
    );
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
