import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import 'article_import.dart';

class FeedPreviewException extends ArticleImportException {
  const FeedPreviewException()
    : super('The matching feed entry is a preview, not verified full content.');
}

List<Uri> discoverArticleFeeds(String page, Uri source) {
  final document = html.parse(page);
  final candidates = <Uri>[];
  void add(String? href) {
    if (href == null || candidates.length >= 4) return;
    try {
      final candidate = articleUrl(source.resolve(href).toString());
      if (!candidates.contains(candidate)) candidates.add(candidate);
    } on ArticleImportException {
      /* Untrusted discovery links are not fetched. */
    } on FormatException {
      /* Invalid discovery URL. */
    }
  }

  for (final link in document.querySelectorAll('link[rel][href]')) {
    final rel = link.attributes['rel']!.toLowerCase().split(RegExp(r'\s+'));
    final type = link.attributes['type']?.toLowerCase().split(';').first.trim();
    if (rel.contains('alternate') &&
        {'application/rss+xml', 'application/atom+xml'}.contains(type)) {
      add(link.attributes['href']);
    }
  }
  for (final path in ['/feed', '/rss.xml', '/atom.xml', '/feed/atom']) {
    add(path);
  }
  return candidates;
}

Iterable<XmlElement> _children(XmlElement element, String name) =>
    element.childElements.where((e) => e.name.local == name);
String? _value(XmlElement element, String name) =>
    _children(element, name).firstOrNull?.innerText.trim();

ImportedArticle? extractFeedArticle(
  String feed,
  Uri feedUrl, {
  required Uri requested,
  required String page,
  required Uri pageUrl,
}) {
  // This parser never resolves external entities; reject declarations anyway.
  if (RegExp(r'<!\s*(DOCTYPE|ENTITY)\b', caseSensitive: false).hasMatch(feed)) {
    throw const ArticleImportException(
      'Feed document/entity declarations are unsupported.',
    );
  }
  final root = XmlDocument.parse(feed).rootElement;
  final atom =
      root.name.local == 'feed' &&
      root.name.namespaceUri == 'http://www.w3.org/2005/Atom';
  final channel = root.name.local == 'rss'
      ? _children(root, 'channel').firstOrNull
      : null;
  if (!atom && channel == null) {
    throw const ArticleImportException('Not a supported RSS 2.0 or Atom feed.');
  }
  final document = html.parse(page);
  final identities = <Uri>[requested, pageUrl];
  for (final node in document.querySelectorAll(
    'link[rel="canonical"], meta[property="og:url"]',
  )) {
    final value = node.attributes['href'] ?? node.attributes['content'];
    if (value == null) continue;
    try {
      final candidate = articleUrl(pageUrl.resolve(value).toString());
      if (samePublication(candidate, pageUrl) &&
          candidate.path.isNotEmpty &&
          candidate.path != '/') {
        identities.add(candidate);
      }
    } on ArticleImportException {
      /* Ignore untrusted identity metadata. */
    } on FormatException {
      /* Invalid identity metadata. */
    }
  }
  final stableIds = document
      .querySelectorAll(
        'meta[name="article:id"], meta[property="article:id"], meta[name="substack:post_id"]',
      )
      .map((e) => e.attributes['content'])
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .toSet();
  int? expectedWords;
  void identityMetadata(dynamic value) {
    if (value is List) {
      for (final child in value) {
        identityMetadata(child);
      }
    }
    if (value is Map) {
      if (value['@type'].toString().toLowerCase().contains('article') ||
          value['@type'].toString().toLowerCase().contains('blogposting')) {
        final id = value['identifier'];
        if (id is String && id.isNotEmpty) stableIds.add(id);
        expectedWords =
            int.tryParse(value['wordCount']?.toString() ?? '') ?? expectedWords;
      }
      for (final child in value.values) {
        if (child is List || child is Map) identityMetadata(child);
      }
    }
  }

  for (final script in document.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    try {
      identityMetadata(jsonDecode(script.text));
    } on FormatException {
      /* Broken metadata. */
    }
  }
  final entries = _children(atom ? root : channel!, atom ? 'entry' : 'item');
  for (final entry in entries) {
    final urls = <Uri>[];
    for (final link in _children(entry, 'link')) {
      if (atom && !{'alternate', null, ''}.contains(link.getAttribute('rel'))) {
        continue;
      }
      final value = atom ? link.getAttribute('href') : link.innerText.trim();
      if (value == null) continue;
      try {
        urls.add(articleUrl(feedUrl.resolve(value).toString()));
      } on ArticleImportException {
        /* Unsafe entry links are not identities. */
      } on FormatException {
        /* Invalid entry URL. */
      }
    }
    final id = _value(entry, atom ? 'id' : 'guid');
    if (id != null && Uri.tryParse(id)?.hasScheme == true) {
      try {
        urls.add(articleUrl(id));
      } on ArticleImportException {
        /* Opaque IDs require an explicit page match. */
      }
    }
    final byUrl = urls.any(
      (url) => identities.any((identity) => sameArticleUrl(url, identity)),
    );
    final byId =
        id != null &&
        stableIds.contains(id) &&
        samePublication(feedUrl, pageUrl);
    if (!byUrl && !byId) continue; // Never match titles or approximate slugs.
    var body = atom
        ? _children(entry, 'content')
              .where(
                (e) => e.name.namespaceUri == 'http://www.w3.org/2005/Atom',
              )
              .firstOrNull
        : entry.childElements
              .where(
                (e) =>
                    e.name.local == 'encoded' &&
                    e.name.namespaceUri ==
                        'http://purl.org/rss/1.0/modules/content/',
              )
              .firstOrNull;
    if (body == null) {
      final summary = _children(
        entry,
        atom ? 'summary' : 'description',
      ).firstOrNull;
      if (summary == null ||
          expectedWords == null ||
          expectedWords! <= 0 ||
          RegExp(r'[\p{L}\p{N}]+', unicode: true)
                  .allMatches(html.parseFragment(summary.innerText).text ?? '')
                  .length <
              expectedWords!) {
        throw const FeedPreviewException();
      }
      body = summary; // Positive page word-count evidence, not a length-only guess.
    }
    if (body.getAttribute('src') != null) {
      throw const FeedPreviewException();
    }
    String markup;
    final type = body.getAttribute('type') ?? (atom ? 'text' : 'html');
    if (atom && {'xhtml', 'application/xhtml+xml'}.contains(type)) {
      markup = body.children
          .map((n) => n.toXmlString())
          .join()
          .replaceAllMapped(
            RegExp(r'(<\/?)[\w-]+:([\w-]+)'),
            (m) => '${m[1]}${m[2]}',
          );
    } else if (atom && {'text', 'text/plain'}.contains(type)) {
      markup = body.innerText
          .split(RegExp(r'\n\s*\n'))
          .map(
            (p) => '<p>${htmlEscape.convert(p).replaceAll('\n', '<br>')}</p>',
          )
          .join();
    } else if (!atom || {'html', 'text/html'}.contains(type)) {
      markup = body.innerText;
    } else {
      throw const FeedPreviewException();
    }
    if (!RegExp(
      r'<(?:p|div|h[1-6]|ul|ol|blockquote)\b',
      caseSensitive: false,
    ).hasMatch(markup)) {
      markup = '<p>$markup</p>';
    }
    final canonical =
        urls
            .where(
              (url) =>
                  identities.any((identity) => sameArticleUrl(url, identity)),
            )
            .firstOrNull ??
        requested;
    final title = _value(entry, 'title') ?? '';
    final author = atom
        ? _children(
            entry,
            'author',
          ).map((a) => _value(a, 'name')).whereType<String>().join(', ')
        : _value(entry, 'creator') ?? _value(entry, 'author');
    final publication = _value(atom ? root : channel!, 'title');
    final published =
        _value(entry, atom ? 'published' : 'pubDate') ??
        (atom ? _value(entry, 'updated') : null);
    String meta(String name, String? value) => value == null
        ? ''
        : '<meta name="$name" content="${htmlEscape.convert(value)}">';
    try {
      final expectedMetadata = expectedWords == null
          ? ''
          : '<script type="application/ld+json">${jsonEncode({'@type': 'Article', 'wordCount': expectedWords})}</script>';
      final article = extractArticle(
        '<head><title>${htmlEscape.convert(title)}</title>$expectedMetadata'
        '${meta('author', author)}${meta('date', published)}'
        '<meta property="og:site_name" content="${htmlEscape.convert(publication ?? '')}">'
        '</head><article>$markup</article>',
        canonical,
      );
      return ImportedArticle(
        title: article.title,
        sourceUrl: normalizedArticleUrl(canonical),
        originalUrl: normalizedArticleUrl(requested),
        publication: publication,
        author: article.author,
        published: published,
        blocks: article.blocks,
      );
    } on ArticleAccessException {
      rethrow;
    } on ArticleImportException {
      throw const FeedPreviewException();
    }
  }
  return null;
}
