import 'package:xml/xml.dart';

import 'rss_models.dart';

class OpmlFeedItem {
  const OpmlFeedItem({
    required this.title,
    required this.feedUrl,
    this.siteUrl,
    this.folderName,
  });

  final String title;
  final String feedUrl;
  final String? siteUrl;
  final String? folderName;
}

class OpmlFailure {
  const OpmlFailure({
    required this.titleOrContext,
    required this.reason,
  });

  final String titleOrContext;
  final String reason;
}

class OpmlParseResult {
  const OpmlParseResult({
    required this.folderNames,
    required this.feeds,
    required this.skippedDuplicates,
    required this.failures,
  });

  final List<String> folderNames;
  final List<OpmlFeedItem> feeds;
  final List<String> skippedDuplicates;
  final List<OpmlFailure> failures;
}

class RssOpml {
  /// Parses an OPML 1.0 or 2.0 XML document into folders, feed subscriptions,
  /// skipped duplicates, and any failed/invalid outline entries.
  static OpmlParseResult parseOpml(
    String xmlText, {
    Set<String> existingFeedUrls = const {},
  }) {
    final trimmed = xmlText.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('OPML file is empty.');
    }

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(trimmed);
    } on XmlException catch (e) {
      throw FormatException('Invalid OPML XML: ${e.message}');
    }

    final root = doc.rootElement;
    if (root.name.local.toLowerCase() != 'opml') {
      throw FormatException(
        'Expected <opml> root element, found <${root.name.local}>.',
      );
    }

    final body = root.childElements
        .where((el) => el.name.local.toLowerCase() == 'body')
        .firstOrNull;
    if (body == null) {
      throw const FormatException('OPML document is missing a <body> element.');
    }

    final folderNames = <String>[];
    final folderSeen = <String>{};
    final feeds = <OpmlFeedItem>[];
    final skippedDuplicates = <String>[];
    final failures = <OpmlFailure>[];
    final seenUrls = <String>{
      for (final url in existingFeedUrls) normalizeFeedUrlKey(url),
    };

    void visitOutline(XmlElement outline, String? parentFolder) {
      final rawTitle = (outline.getAttribute('title') ??
              outline.getAttribute('text') ??
              outline.getAttribute('description') ??
              '')
          .trim();
      final xmlUrl = (outline.getAttribute('xmlUrl') ??
              outline.getAttribute('xmlurl') ??
              outline.getAttribute('url') ??
              '')
          .trim();
      final htmlUrl = (outline.getAttribute('htmlUrl') ??
              outline.getAttribute('htmlurl') ??
              '')
          .trim();
      final type = (outline.getAttribute('type') ?? '').trim().toLowerCase();
      final childOutlines = outline.childElements
          .where((c) => c.name.local.toLowerCase() == 'outline')
          .toList(growable: false);

      if (xmlUrl.isNotEmpty) {
        final uri = Uri.tryParse(xmlUrl);
        if (uri == null ||
            (uri.scheme != 'http' && uri.scheme != 'https') ||
            uri.host.isEmpty) {
          failures.add(
            OpmlFailure(
              titleOrContext: rawTitle.isNotEmpty ? rawTitle : xmlUrl,
              reason: 'Invalid http/https feed URL: "$xmlUrl"',
            ),
          );
          return;
        }
        final normKey = normalizeFeedUrlKey(xmlUrl);
        if (!seenUrls.add(normKey)) {
          skippedDuplicates.add(rawTitle.isNotEmpty ? rawTitle : xmlUrl);
          return;
        }
        if (parentFolder != null &&
            parentFolder.isNotEmpty &&
            folderSeen.add(parentFolder.toLowerCase())) {
          folderNames.add(parentFolder);
        }
        feeds.add(
          OpmlFeedItem(
            title: rawTitle.isNotEmpty ? rawTitle : uri.host,
            feedUrl: uri.toString(),
            siteUrl: htmlUrl.isNotEmpty ? htmlUrl : null,
            folderName: parentFolder,
          ),
        );
        return;
      }

      // If this outline has child outlines, treat it as a folder
      if (childOutlines.isNotEmpty) {
        final folderLabel = rawTitle.isNotEmpty ? rawTitle : 'Imported Folder';
        final nextFolder = parentFolder == null || parentFolder.isEmpty
            ? folderLabel
            : '$parentFolder / $folderLabel';
        if (folderSeen.add(nextFolder.toLowerCase())) {
          folderNames.add(nextFolder);
        }
        for (final child in childOutlines) {
          visitOutline(child, nextFolder);
        }
        return;
      }

      // Leaf outline with no xmlUrl: check if it declared type="rss" or similar
      if (type == 'rss' || type == 'atom' || type == 'feed' || htmlUrl.isNotEmpty) {
        failures.add(
          OpmlFailure(
            titleOrContext:
                rawTitle.isNotEmpty ? rawTitle : (htmlUrl.isNotEmpty ? htmlUrl : 'Unnamed outline'),
            reason: 'Outline is missing an xmlUrl attribute.',
          ),
        );
      } else if (rawTitle.isNotEmpty) {
        // Empty folder outline
        final folderLabel = parentFolder == null || parentFolder.isEmpty
            ? rawTitle
            : '$parentFolder / $rawTitle';
        if (folderSeen.add(folderLabel.toLowerCase())) {
          folderNames.add(folderLabel);
        }
      }
    }

    for (final outline in body.childElements) {
      if (outline.name.local.toLowerCase() == 'outline') {
        visitOutline(outline, null);
      }
    }

    return OpmlParseResult(
      folderNames: folderNames,
      feeds: feeds,
      skippedDuplicates: skippedDuplicates,
      failures: failures,
    );
  }

  /// Exports [folders] and [subscriptions] into a standard OPML 2.0 XML string.
  static String exportOpml({
    required List<RssFolder> folders,
    required List<RssSubscription> subscriptions,
    DateTime? exportedAt,
  }) {
    final now = (exportedAt ?? DateTime.now()).toUtc();
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'opml',
      attributes: {'version': '2.0'},
      nest: () {
        builder.element(
          'head',
          nest: () {
            builder.element('title', nest: 'DogReader 2.0 RSS Subscriptions');
            builder.element('dateCreated', nest: now.toIso8601String());
          },
        );
        builder.element(
          'body',
          nest: () {
            final folderById = {for (final f in folders) f.id: f};
            final sortedFolders = [...folders]
              ..sort((a, b) {
                final cmp = a.sortOrder.compareTo(b.sortOrder);
                return cmp != 0
                    ? cmp
                    : a.name.toLowerCase().compareTo(b.name.toLowerCase());
              });

            for (final folder in sortedFolders) {
              final folderSubs = subscriptions
                  .where((s) => s.folderId == folder.id)
                  .toList()
                ..sort((a, b) => a.displayTitle
                    .toLowerCase()
                    .compareTo(b.displayTitle.toLowerCase()));
              builder.element(
                'outline',
                attributes: {
                  'text': folder.name,
                  'title': folder.name,
                },
                nest: () {
                  for (final sub in folderSubs) {
                    _writeSubscriptionOutline(builder, sub);
                  }
                },
              );
            }

            final ungrouped = subscriptions
                .where((s) => s.folderId == null || !folderById.containsKey(s.folderId))
                .toList()
              ..sort((a, b) => a.displayTitle
                  .toLowerCase()
                  .compareTo(b.displayTitle.toLowerCase()));
            for (final sub in ungrouped) {
              _writeSubscriptionOutline(builder, sub);
            }
          },
        );
      },
    );

    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  static void _writeSubscriptionOutline(
    XmlBuilder builder,
    RssSubscription sub,
  ) {
    final attrs = <String, String>{
      'type': 'rss',
      'text': sub.displayTitle,
      'title': sub.displayTitle,
      'xmlUrl': sub.feedUrl,
      if (sub.siteUrl != null && sub.siteUrl!.isNotEmpty)
        'htmlUrl': sub.siteUrl!,
    };
    builder.element('outline', attributes: attrs);
  }

  static String normalizeFeedUrlKey(String rawUrl) {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed.toLowerCase();
    var path = uri.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host.toLowerCase(),
      port: uri.hasPort &&
              !((uri.scheme == 'http' && uri.port == 80) ||
                  (uri.scheme == 'https' && uri.port == 443))
          ? uri.port
          : null,
      path: path.isEmpty ? '/' : path,
      query: uri.hasQuery ? uri.query : null,
    ).toString();
  }
}
