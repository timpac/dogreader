import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../article_import.dart';
import '../reader_content.dart';

/// Explicit 5-state classification for article content completeness.
///
/// DogReader 2.0 never silently presents a truncated preview as a complete
/// article. Every RSS article is classified into one of these five states.
enum ArticleContentStatus {
  /// Full article text was present in the feed or extracted from the webpage.
  full('Full article available', 'Full text'),

  /// Only a teaser, summary, or truncated preview is available.
  previewOnly('Preview or excerpt only', 'Preview only'),

  /// The publisher restricts the full text to paid/authenticated subscribers.
  subscriberOnly('Subscriber-only content', 'Subscriber-only'),

  /// Full-text extraction from the original webpage failed (network/layout error).
  extractionFailed('Extraction failed', 'Extraction failed'),

  /// The article URL is unavailable (HTTP 404/410 or empty content).
  unavailable('Article unavailable', 'Unavailable');

  const ArticleContentStatus(this.label, this.badgeLabel);

  final String label;
  final String badgeLabel;

  bool get isComplete => this == ArticleContentStatus.full;

  bool get showsDiagnosticBanner => this != ArticleContentStatus.full;

  static ArticleContentStatus fromName(String? value) =>
      ArticleContentStatus.values
          .where((status) => status.name == value)
          .firstOrNull ??
      ArticleContentStatus.previewOnly;
}

class RssFolder {
  const RssFolder({
    required this.id,
    required this.name,
    this.collapsed = false,
    this.sortOrder = 0,
    required this.createdAt,
  });

  final String id;
  final String name;
  final bool collapsed;
  final int sortOrder;
  final DateTime createdAt;

  RssFolder copyWith({
    String? name,
    bool? collapsed,
    int? sortOrder,
  }) =>
      RssFolder(
        id: id,
        name: name ?? this.name,
        collapsed: collapsed ?? this.collapsed,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'collapsed': collapsed,
        'sortOrder': sortOrder,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  static RssFolder fromJson(Map<String, Object?> json) => RssFolder(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Untitled Folder',
        collapsed: json['collapsed'] as bool? ?? false,
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

class RssSubscription {
  const RssSubscription({
    required this.id,
    required this.feedUrl,
    this.siteUrl,
    required this.title,
    this.customTitle,
    this.description,
    this.folderId,
    this.lastRefreshedAt,
    this.lastError,
    this.etag,
    this.lastModified,
    required this.createdAt,
  });

  final String id;
  final String feedUrl;
  final String? siteUrl;
  final String title;
  final String? customTitle;
  final String? description;
  final String? folderId;
  final DateTime? lastRefreshedAt;
  final String? lastError;
  final String? etag;
  final String? lastModified;
  final DateTime createdAt;

  String get displayTitle {
    final custom = customTitle?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final clean = title.trim();
    return clean.isNotEmpty ? clean : feedUrl;
  }

  RssSubscription copyWith({
    String? feedUrl,
    String? siteUrl,
    String? title,
    String? customTitle,
    bool clearCustomTitle = false,
    String? description,
    String? folderId,
    bool clearFolderId = false,
    DateTime? lastRefreshedAt,
    String? lastError,
    bool clearLastError = false,
    String? etag,
    String? lastModified,
  }) =>
      RssSubscription(
        id: id,
        feedUrl: feedUrl ?? this.feedUrl,
        siteUrl: siteUrl ?? this.siteUrl,
        title: title ?? this.title,
        customTitle: clearCustomTitle ? null : (customTitle ?? this.customTitle),
        description: description ?? this.description,
        folderId: clearFolderId ? null : (folderId ?? this.folderId),
        lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        etag: etag ?? this.etag,
        lastModified: lastModified ?? this.lastModified,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'feedUrl': feedUrl,
        'siteUrl': siteUrl,
        'title': title,
        'customTitle': customTitle,
        'description': description,
        'folderId': folderId,
        'lastRefreshedAt': lastRefreshedAt?.toUtc().toIso8601String(),
        'lastError': lastError,
        'etag': etag,
        'lastModified': lastModified,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  static RssSubscription fromJson(Map<String, Object?> json) => RssSubscription(
        id: json['id'] as String? ?? '',
        feedUrl: json['feedUrl'] as String? ?? '',
        siteUrl: json['siteUrl'] as String?,
        title: json['title'] as String? ?? 'Untitled Feed',
        customTitle: json['customTitle'] as String?,
        description: json['description'] as String?,
        folderId: json['folderId'] as String?,
        lastRefreshedAt: json['lastRefreshedAt'] is String
            ? DateTime.tryParse(json['lastRefreshedAt'] as String)?.toUtc()
            : null,
        lastError: json['lastError'] as String?,
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

/// Represents a followed writer across one or more publications.
class FollowedAuthor {
  const FollowedAuthor({
    required this.id,
    required this.name,
    required this.normalizedName,
    this.aliases = const [],
    this.favorite = true,
    this.autoNarrateEligible = false,
  });

  final String id;
  final String name;
  final String normalizedName;
  final List<String> aliases;
  final bool favorite;

  /// Data-model hook for future automatic narration of favorite authors.
  /// Remains opt-in and never triggers background paid cloud jobs automatically.
  final bool autoNarrateEligible;

  FollowedAuthor copyWith({
    String? name,
    String? normalizedName,
    List<String>? aliases,
    bool? favorite,
    bool? autoNarrateEligible,
  }) =>
      FollowedAuthor(
        id: id,
        name: name ?? this.name,
        normalizedName: normalizedName ?? this.normalizedName,
        aliases: aliases ?? this.aliases,
        favorite: favorite ?? this.favorite,
        autoNarrateEligible: autoNarrateEligible ?? this.autoNarrateEligible,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'normalizedName': normalizedName,
        'aliases': aliases,
        'favorite': favorite,
        'autoNarrateEligible': autoNarrateEligible,
      };

  static FollowedAuthor fromJson(Map<String, Object?> json) => FollowedAuthor(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        normalizedName: json['normalizedName'] as String? ?? '',
        aliases: (json['aliases'] as List<Object?>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        favorite: json['favorite'] as bool? ?? true,
        autoNarrateEligible: json['autoNarrateEligible'] as bool? ?? false,
      );
}

class RssArticle {
  const RssArticle({
    required this.id,
    required this.subscriptionId,
    required this.feedTitle,
    this.folderId,
    required this.title,
    required this.url,
    required this.canonicalUrl,
    this.guid,
    this.author,
    this.normalizedAuthors = const [],
    this.publishedAt,
    required this.fetchedAt,
    required this.summaryPreview,
    required this.blocks,
    required this.contentStatus,
    this.statusReason,
    this.isRead = false,
    this.isStarred = false,
    this.isHidden = false,
    this.isPrioritized = false,
    this.isSavedToLibrary = false,
    this.readingOffset = 0,
    this.readingScrollFraction = 0.0,
    this.narrationOffset = 0,
    this.matchedRuleIds = const [],
  });

  final String id;
  final String subscriptionId;
  final String feedTitle;
  final String? folderId;
  final String title;
  final String url;
  final String canonicalUrl;
  final String? guid;
  final String? author;
  final List<String> normalizedAuthors;
  final DateTime? publishedAt;
  final DateTime fetchedAt;
  final String summaryPreview;
  final List<ArticleBlock> blocks;
  final ArticleContentStatus contentStatus;
  final String? statusReason;
  final bool isRead;
  final bool isStarred;
  final bool isHidden;
  final bool isPrioritized;
  final bool isSavedToLibrary;
  final int readingOffset;
  final double readingScrollFraction;
  final int narrationOffset;
  final List<String> matchedRuleIds;

  String get displayAuthor {
    final clean = author?.trim();
    if (clean != null && clean.isNotEmpty) return clean;
    return feedTitle.isNotEmpty ? feedTitle : 'Unknown author';
  }

  int get wordCount {
    var count = 0;
    for (final block in blocks) {
      if (block.kind == 'break') continue;
      count += block.text
          .trim()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .length;
    }
    return count;
  }

  /// Converts this RSS article into an [ImportedArticle] compatible with
  /// DogReader's existing chapter reader, narration queue, and AI summary UI.
  ImportedArticle toImportedArticle() {
    final effectiveBlocks = blocks.isNotEmpty
        ? blocks
        : <ArticleBlock>[
            if (summaryPreview.trim().isNotEmpty)
              ArticleBlock(summaryPreview.trim()),
            if (summaryPreview.trim().isEmpty)
              ArticleBlock(title),
          ];
    return ImportedArticle(
      title: title,
      sourceUrl: canonicalUrl.isNotEmpty ? canonicalUrl : url,
      originalUrl: url,
      author: displayAuthor,
      published: publishedAt?.toUtc().toIso8601String(),
      publication: feedTitle,
      blocks: effectiveBlocks,
    );
  }

  ReaderChapter get chapter => toImportedArticle().chapter;

  RssArticle copyWith({
    String? feedTitle,
    String? folderId,
    bool clearFolderId = false,
    String? title,
    String? url,
    String? canonicalUrl,
    String? guid,
    String? author,
    List<String>? normalizedAuthors,
    DateTime? publishedAt,
    DateTime? fetchedAt,
    String? summaryPreview,
    List<ArticleBlock>? blocks,
    ArticleContentStatus? contentStatus,
    String? statusReason,
    bool clearStatusReason = false,
    bool? isRead,
    bool? isStarred,
    bool? isHidden,
    bool? isPrioritized,
    bool? isSavedToLibrary,
    int? readingOffset,
    double? readingScrollFraction,
    int? narrationOffset,
    List<String>? matchedRuleIds,
  }) =>
      RssArticle(
        id: id,
        subscriptionId: subscriptionId,
        feedTitle: feedTitle ?? this.feedTitle,
        folderId: clearFolderId ? null : (folderId ?? this.folderId),
        title: title ?? this.title,
        url: url ?? this.url,
        canonicalUrl: canonicalUrl ?? this.canonicalUrl,
        guid: guid ?? this.guid,
        author: author ?? this.author,
        normalizedAuthors: normalizedAuthors ?? this.normalizedAuthors,
        publishedAt: publishedAt ?? this.publishedAt,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        summaryPreview: summaryPreview ?? this.summaryPreview,
        blocks: blocks ?? this.blocks,
        contentStatus: contentStatus ?? this.contentStatus,
        statusReason:
            clearStatusReason ? null : (statusReason ?? this.statusReason),
        isRead: isRead ?? this.isRead,
        isStarred: isStarred ?? this.isStarred,
        isHidden: isHidden ?? this.isHidden,
        isPrioritized: isPrioritized ?? this.isPrioritized,
        isSavedToLibrary: isSavedToLibrary ?? this.isSavedToLibrary,
        readingOffset: readingOffset ?? this.readingOffset,
        readingScrollFraction:
            readingScrollFraction ?? this.readingScrollFraction,
        narrationOffset: narrationOffset ?? this.narrationOffset,
        matchedRuleIds: matchedRuleIds ?? this.matchedRuleIds,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'subscriptionId': subscriptionId,
        'feedTitle': feedTitle,
        'folderId': folderId,
        'title': title,
        'url': url,
        'canonicalUrl': canonicalUrl,
        'guid': guid,
        'author': author,
        'normalizedAuthors': normalizedAuthors,
        'publishedAt': publishedAt?.toUtc().toIso8601String(),
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
        'summaryPreview': summaryPreview,
        'blocks': [for (final block in blocks) block.toJson()],
        'contentStatus': contentStatus.name,
        'statusReason': statusReason,
        'isRead': isRead,
        'isStarred': isStarred,
        'isHidden': isHidden,
        'isPrioritized': isPrioritized,
        'isSavedToLibrary': isSavedToLibrary,
        'readingOffset': readingOffset,
        'readingScrollFraction': readingScrollFraction,
        'narrationOffset': narrationOffset,
        'matchedRuleIds': matchedRuleIds,
      };

  static RssArticle fromJson(Map<String, Object?> json) => RssArticle(
        id: json['id'] as String? ?? '',
        subscriptionId: json['subscriptionId'] as String? ?? '',
        feedTitle: json['feedTitle'] as String? ?? '',
        folderId: json['folderId'] as String?,
        title: json['title'] as String? ?? 'Untitled Article',
        url: json['url'] as String? ?? '',
        canonicalUrl:
            json['canonicalUrl'] as String? ?? (json['url'] as String? ?? ''),
        guid: json['guid'] as String?,
        author: json['author'] as String?,
        normalizedAuthors:
            (json['normalizedAuthors'] as List<Object?>? ?? const [])
                .whereType<String>()
                .toList(growable: false),
        publishedAt: json['publishedAt'] is String
            ? DateTime.tryParse(json['publishedAt'] as String)?.toUtc()
            : null,
        fetchedAt: DateTime.tryParse(json['fetchedAt'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        summaryPreview: json['summaryPreview'] as String? ?? '',
        blocks: [
          for (final item in json['blocks'] as List<Object?>? ?? const [])
            if (item is Map)
              ArticleBlock.fromJson(Map<String, dynamic>.from(item)),
        ],
        contentStatus:
            ArticleContentStatus.fromName(json['contentStatus'] as String?),
        statusReason: json['statusReason'] as String?,
        isRead: json['isRead'] as bool? ?? false,
        isStarred: json['isStarred'] as bool? ?? false,
        isHidden: json['isHidden'] as bool? ?? false,
        isPrioritized: json['isPrioritized'] as bool? ?? false,
        isSavedToLibrary: json['isSavedToLibrary'] as bool? ?? false,
        readingOffset: (json['readingOffset'] as num?)?.toInt() ?? 0,
        readingScrollFraction:
            (json['readingScrollFraction'] as num?)?.toDouble() ?? 0.0,
        narrationOffset: (json['narrationOffset'] as num?)?.toInt() ?? 0,
        matchedRuleIds: (json['matchedRuleIds'] as List<Object?>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
      );
}

String generateRssId(String prefix, String key) {
  final digest = sha256
      .convert(utf8.encode(key.trim().toLowerCase()))
      .toString()
      .substring(0, 16);
  return '${prefix}_$digest';
}
