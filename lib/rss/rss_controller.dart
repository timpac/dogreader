import 'dart:io';

import 'package:flutter/foundation.dart';

import '../article_import.dart';
import 'rss_authors.dart';
import 'rss_extractor.dart';
import 'rss_models.dart';
import 'rss_opml.dart';
import 'rss_parser.dart';
import 'rss_rules.dart';
import 'rss_store.dart';

class DuplicateSubscriptionException implements Exception {
  const DuplicateSubscriptionException(this.existing);
  final RssSubscription existing;

  @override
  String toString() =>
      'Already subscribed to "${existing.displayTitle}" (${existing.feedUrl}).';
}

class OpmlImportSummary {
  const OpmlImportSummary({
    required this.addedSubscriptions,
    required this.addedFolders,
    required this.skippedDuplicates,
    required this.failures,
  });

  final List<RssSubscription> addedSubscriptions;
  final List<RssFolder> addedFolders;
  final List<String> skippedDuplicates;
  final List<OpmlFailure> failures;
}

enum RssArticleFilterMode {
  all('All Articles'),
  unread('Unread'),
  starred('Starred'),
  savedToLibrary('Saved to Books');

  const RssArticleFilterMode(this.label);
  final String label;
}

/// Central controller for DogReader 2.0's RSS reading, organization, rules,
/// offline caching, and narration integration.
class RssLibraryController extends ChangeNotifier {
  RssLibraryController(
    Future<Directory> rootDirectory, {
    RssExtractor? extractor,
    RssDocumentLoader? documentLoader,
    DateTime Function()? clock,
  })  : _store = RssStore(rootDirectory),
        _extractor =
            extractor ?? RssExtractor(documentLoader: documentLoader),
        _clock = clock ?? DateTime.now;

  final RssStore _store;
  final RssExtractor _extractor;
  final DateTime Function() _clock;

  bool _loaded = false;
  bool _refreshing = false;
  bool _shelfExpanded = false;
  final Set<String> _extractingArticleIds = <String>{};

  final List<RssFolder> _folders = <RssFolder>[];
  final List<RssSubscription> _subscriptions = <RssSubscription>[];
  final List<FollowedAuthor> _followedAuthors = <FollowedAuthor>[];
  final List<FeedRule> _rules = <FeedRule>[];
  final Map<String, RssArticle> _articlesById = <String, RssArticle>{};

  bool get isLoaded => _loaded;
  bool get isRefreshing => _refreshing;
  bool get shelfExpanded => _shelfExpanded;

  List<RssFolder> get folders => List.unmodifiable(_folders);
  List<RssSubscription> get subscriptions => List.unmodifiable(_subscriptions);
  List<FollowedAuthor> get followedAuthors => List.unmodifiable(_followedAuthors);
  List<FeedRule> get rules => List.unmodifiable(_rules);

  List<RssArticle> get allArticles {
    final list = _articlesById.values.toList(growable: false);
    list.sort(_compareArticles);
    return list;
  }

  /// Articles explicitly saved by the user to appear in the main EPUB/book library.
  List<RssArticle> get librarySavedArticles => allArticles
      .where((a) => a.isSavedToLibrary)
      .toList(growable: false);

  bool isExtractingArticle(String articleId) =>
      _extractingArticleIds.contains(articleId);

  int get totalUnreadCount => _articlesById.values
      .where((a) => !a.isHidden && !a.isRead)
      .length;

  int get starredCount => _articlesById.values
      .where((a) => a.isStarred)
      .length;

  int unreadCountForSubscription(String subscriptionId) => _articlesById.values
      .where((a) =>
          !a.isHidden && !a.isRead && a.subscriptionId == subscriptionId)
      .length;

  int unreadCountForFolder(String folderId) {
    final subIdsInFolder = _subscriptions
        .where((s) => s.folderId == folderId)
        .map((s) => s.id)
        .toSet();
    return _articlesById.values
        .where((a) =>
            !a.isHidden &&
            !a.isRead &&
            (a.folderId == folderId ||
                (a.folderId == null && subIdsInFolder.contains(a.subscriptionId))))
        .length;
  }

  int unreadCountForAuthor(FollowedAuthor author) => _articlesById.values
      .where((a) =>
          !a.isHidden &&
          !a.isRead &&
          RssAuthors.articleMatchesAuthor(a, author))
      .length;

  RssArticle? articleById(String id) => _articlesById[id];

  RssSubscription? subscriptionById(String id) =>
      _subscriptions.where((s) => s.id == id).firstOrNull;

  RssFolder? folderById(String id) =>
      _folders.where((f) => f.id == id).firstOrNull;

  Future<void> load() async {
    final state = await _store.loadState();
    final loadedArticles = await _store.loadArticles();
    _shelfExpanded = state.shelfExpanded;
    _folders
      ..clear()
      ..addAll(state.folders);
    _subscriptions
      ..clear()
      ..addAll(state.subscriptions);
    _followedAuthors
      ..clear()
      ..addAll(state.followedAuthors);
    _rules
      ..clear()
      ..addAll(state.rules);
    _articlesById.clear();
    for (final article in loadedArticles) {
      _articlesById[article.id] = article;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setShelfExpanded(bool expanded) async {
    if (_shelfExpanded == expanded) return;
    _shelfExpanded = expanded;
    notifyListeners();
    await _persistState();
  }

  /// Queries articles with optional filter mode, folder, feed, author, rule, and search text.
  List<RssArticle> queryArticles({
    RssArticleFilterMode mode = RssArticleFilterMode.all,
    String? subscriptionId,
    String? folderId,
    String? authorId,
    String? authorQuery,
    String? ruleId,
    String? searchQuery,
    bool includeHidden = false,
  }) {
    final subIdsInFolder = folderId == null
        ? const <String>{}
        : _subscriptions
            .where((s) => s.folderId == folderId)
            .map((s) => s.id)
            .toSet();
    final selectedAuthor = authorId == null
        ? null
        : _followedAuthors.where((a) => a.id == authorId).firstOrNull;
    final selectedRule =
        ruleId == null ? null : _rules.where((r) => r.id == ruleId).firstOrNull;
    final cleanSearch = searchQuery?.trim().toLowerCase() ?? '';

    final filtered = <RssArticle>[];
    for (final article in _articlesById.values) {
      if (!includeHidden && article.isHidden && mode != RssArticleFilterMode.starred) {
        continue;
      }
      switch (mode) {
        case RssArticleFilterMode.all:
          break;
        case RssArticleFilterMode.unread:
          if (article.isRead) continue;
        case RssArticleFilterMode.starred:
          if (!article.isStarred) continue;
        case RssArticleFilterMode.savedToLibrary:
          if (!article.isSavedToLibrary) continue;
      }

      if (subscriptionId != null && article.subscriptionId != subscriptionId) {
        continue;
      }

      if (folderId != null) {
        final effectiveFolder = article.folderId;
        final belongsToFolder = effectiveFolder == folderId ||
            (effectiveFolder == null &&
                subIdsInFolder.contains(article.subscriptionId));
        if (!belongsToFolder) continue;
      }

      if (selectedAuthor != null &&
          !RssAuthors.articleMatchesAuthor(article, selectedAuthor)) {
        continue;
      }

      if (authorQuery != null &&
          authorQuery.trim().isNotEmpty &&
          !RssAuthors.articleMatchesAuthorQuery(article, authorQuery)) {
        continue;
      }

      if (selectedRule != null &&
          !RssRulesEngine.matchesCondition(
            article,
            selectedRule,
            followedAuthors: _followedAuthors,
          )) {
        continue;
      }

      if (cleanSearch.isNotEmpty) {
        final matchesTitle = article.title.toLowerCase().contains(cleanSearch);
        final matchesAuthor =
            (article.author ?? '').toLowerCase().contains(cleanSearch);
        final matchesFeed =
            article.feedTitle.toLowerCase().contains(cleanSearch);
        final matchesSummary =
            article.summaryPreview.toLowerCase().contains(cleanSearch);
        if (!matchesTitle && !matchesAuthor && !matchesFeed && !matchesSummary) {
          continue;
        }
      }

      filtered.add(article);
    }

    filtered.sort(_compareArticles);
    return filtered;
  }

  // ---------------------------------------------------------------------------
  // Folders Management
  // ---------------------------------------------------------------------------

  Future<RssFolder> createFolder(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) {
      throw const FormatException('Folder name cannot be empty.');
    }
    final existing = _folders
        .where((f) => f.name.toLowerCase() == clean.toLowerCase())
        .firstOrNull;
    if (existing != null) return existing;

    final folder = RssFolder(
      id: generateRssId('folder', clean),
      name: clean,
      sortOrder: _folders.length,
      createdAt: _clock().toUtc(),
    );
    _folders.add(folder);
    _reapplyAllRulesInMemory();
    notifyListeners();
    await _persistState();
    return folder;
  }

  Future<void> renameFolder(String folderId, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) return;
    final idx = _folders.indexWhere((f) => f.id == folderId);
    if (idx < 0) return;
    _folders[idx] = _folders[idx].copyWith(name: clean);
    notifyListeners();
    await _persistState();
  }

  Future<void> toggleFolderCollapsed(String folderId) async {
    final idx = _folders.indexWhere((f) => f.id == folderId);
    if (idx < 0) return;
    _folders[idx] =
        _folders[idx].copyWith(collapsed: !_folders[idx].collapsed);
    notifyListeners();
    await _persistState();
  }

  Future<void> deleteFolder(String folderId) async {
    _folders.removeWhere((f) => f.id == folderId);
    for (var i = 0; i < _subscriptions.length; i++) {
      if (_subscriptions[i].folderId == folderId) {
        _subscriptions[i] = _subscriptions[i].copyWith(clearFolderId: true);
      }
    }
    final updatedArticles = <RssArticle>[];
    for (final entry in _articlesById.entries) {
      if (entry.value.folderId == folderId) {
        final next = entry.value.copyWith(clearFolderId: true);
        _articlesById[entry.key] = next;
        updatedArticles.add(next);
      }
    }
    notifyListeners();
    await _persistState();
    if (updatedArticles.isNotEmpty) {
      await _store.saveArticlesBatch(updatedArticles);
    }
  }

  // ---------------------------------------------------------------------------
  // Subscriptions Management & Feed Discovery
  // ---------------------------------------------------------------------------

  RssSubscription? findDuplicateSubscription(String candidateFeedUrl) {
    final norm = RssOpml.normalizeFeedUrlKey(candidateFeedUrl);
    for (final sub in _subscriptions) {
      if (RssOpml.normalizeFeedUrlKey(sub.feedUrl) == norm) {
        return sub;
      }
    }
    return null;
  }

  /// Adds a feed subscription by direct feed URL or website URL (via automatic
  /// discovery), fetches initial articles, and saves state.
  Future<RssSubscription> addSubscriptionByUrl(
    String urlOrWebsite, {
    String? folderId,
    String? customTitle,
  }) async {
    final preDup = findDuplicateSubscription(urlOrWebsite);
    if (preDup != null) {
      throw DuplicateSubscriptionException(preDup);
    }

    final parsedFeed = await _extractor.fetchAndDiscoverFeed(urlOrWebsite);
    final postDup = findDuplicateSubscription(parsedFeed.feedUrl);
    if (postDup != null) {
      throw DuplicateSubscriptionException(postDup);
    }

    final now = _clock().toUtc();
    final sub = RssSubscription(
      id: generateRssId(
        'sub',
        RssOpml.normalizeFeedUrlKey(parsedFeed.feedUrl),
      ),
      feedUrl: parsedFeed.feedUrl,
      siteUrl: parsedFeed.siteUrl,
      title: parsedFeed.title,
      customTitle: customTitle?.trim().isNotEmpty == true
          ? customTitle!.trim()
          : null,
      description: parsedFeed.description,
      folderId: folderId,
      lastRefreshedAt: now,
      createdAt: now,
    );

    _subscriptions.add(sub);
    final changedArticles = _ingestParsedEntries(sub, parsedFeed.entries, now);
    notifyListeners();
    await _persistState();
    await _store.saveArticlesBatch(changedArticles);
    return sub;
  }

  /// Registers a feed XML string directly (used for offline OPML tests or local fixtures).
  Future<RssSubscription> addSubscriptionFromXml({
    required String feedUrl,
    required String xmlText,
    String? folderId,
    String? customTitle,
  }) async {
    final dup = findDuplicateSubscription(feedUrl);
    if (dup != null) {
      throw DuplicateSubscriptionException(dup);
    }
    final uri = articleUrl(feedUrl);
    final parsed = RssParser.parseFeedXml(xmlText, feedUrl: uri);
    final now = _clock().toUtc();
    final sub = RssSubscription(
      id: generateRssId('sub', RssOpml.normalizeFeedUrlKey(parsed.feedUrl)),
      feedUrl: parsed.feedUrl,
      siteUrl: parsed.siteUrl,
      title: parsed.title,
      customTitle:
          customTitle?.trim().isNotEmpty == true ? customTitle!.trim() : null,
      description: parsed.description,
      folderId: folderId,
      lastRefreshedAt: now,
      createdAt: now,
    );
    _subscriptions.add(sub);
    final changed = _ingestParsedEntries(sub, parsed.entries, now);
    notifyListeners();
    await _persistState();
    await _store.saveArticlesBatch(changed);
    return sub;
  }

  Future<void> renameSubscription(
    String subscriptionId,
    String newCustomTitle,
  ) async {
    final idx = _subscriptions.indexWhere((s) => s.id == subscriptionId);
    if (idx < 0) return;
    final clean = newCustomTitle.trim();
    _subscriptions[idx] = _subscriptions[idx].copyWith(
      customTitle: clean.isEmpty ? null : clean,
      clearCustomTitle: clean.isEmpty,
    );
    final displayTitle = _subscriptions[idx].displayTitle;
    final updated = <RssArticle>[];
    for (final entry in _articlesById.entries) {
      if (entry.value.subscriptionId == subscriptionId) {
        final next = entry.value.copyWith(feedTitle: displayTitle);
        _articlesById[entry.key] = next;
        updated.add(next);
      }
    }
    notifyListeners();
    await _persistState();
    if (updated.isNotEmpty) {
      await _store.saveArticlesBatch(updated);
    }
  }

  Future<void> moveSubscriptionToFolder(
    String subscriptionId,
    String? folderId,
  ) async {
    final idx = _subscriptions.indexWhere((s) => s.id == subscriptionId);
    if (idx < 0) return;
    _subscriptions[idx] = _subscriptions[idx].copyWith(
      folderId: folderId,
      clearFolderId: folderId == null,
    );
    notifyListeners();
    await _persistState();
  }

  Future<void> deleteSubscription(
    String subscriptionId, {
    bool keepStarredAndSaved = true,
  }) async {
    _subscriptions.removeWhere((s) => s.id == subscriptionId);
    final toDelete = <String>[];
    for (final article in _articlesById.values) {
      if (article.subscriptionId == subscriptionId) {
        if (keepStarredAndSaved &&
            (article.isStarred || article.isSavedToLibrary)) {
          continue;
        }
        toDelete.add(article.id);
      }
    }
    for (final id in toDelete) {
      _articlesById.remove(id);
    }
    notifyListeners();
    await _persistState();
    for (final id in toDelete) {
      await _store.deleteArticle(id);
    }
  }

  // ---------------------------------------------------------------------------
  // Refreshing Feeds (with sensible throttling)
  // ---------------------------------------------------------------------------

  Future<void> refreshSubscription(
    String subscriptionId, {
    bool force = true,
    Duration minInterval = const Duration(minutes: 15),
  }) async {
    final idx = _subscriptions.indexWhere((s) => s.id == subscriptionId);
    if (idx < 0) return;
    final sub = _subscriptions[idx];
    final now = _clock().toUtc();
    if (!force &&
        sub.lastRefreshedAt != null &&
        now.difference(sub.lastRefreshedAt!) < minInterval) {
      return;
    }

    try {
      final parsed = await _extractor.fetchAndDiscoverFeed(sub.feedUrl);
      final updatedSub = sub.copyWith(
        title: parsed.title.isNotEmpty ? parsed.title : sub.title,
        siteUrl: parsed.siteUrl ?? sub.siteUrl,
        description: parsed.description ?? sub.description,
        lastRefreshedAt: now,
        clearLastError: true,
      );
      final currentIdx =
          _subscriptions.indexWhere((s) => s.id == subscriptionId);
      if (currentIdx >= 0) {
        _subscriptions[currentIdx] = updatedSub;
      }
      final changed = _ingestParsedEntries(updatedSub, parsed.entries, now);
      notifyListeners();
      await _persistState();
      await _store.saveArticlesBatch(changed);
    } catch (error) {
      final currentIdx =
          _subscriptions.indexWhere((s) => s.id == subscriptionId);
      if (currentIdx >= 0) {
        _subscriptions[currentIdx] = _subscriptions[currentIdx].copyWith(
          lastRefreshedAt: now,
          lastError: error.toString(),
        );
      }
      notifyListeners();
      await _persistState();
    }
  }

  Future<void> refreshAll({
    bool force = false,
    Duration minInterval = const Duration(minutes: 15),
  }) async {
    if (_refreshing || _subscriptions.isEmpty) return;
    _refreshing = true;
    notifyListeners();
    try {
      final ids = _subscriptions.map((s) => s.id).toList(growable: false);
      for (final id in ids) {
        await refreshSubscription(id, force: force, minInterval: minInterval);
      }
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // OPML Import & Export
  // ---------------------------------------------------------------------------

  Future<OpmlImportSummary> importOpml(
    String xmlText, {
    bool refreshAfterImport = false,
  }) async {
    final existingUrls = _subscriptions.map((s) => s.feedUrl).toSet();
    final parsed = RssOpml.parseOpml(
      xmlText,
      existingFeedUrls: existingUrls,
    );

    final addedFolders = <RssFolder>[];
    final folderByName = <String, RssFolder>{
      for (final f in _folders) f.name.toLowerCase(): f,
    };
    final now = _clock().toUtc();

    for (final folderName in parsed.folderNames) {
      final key = folderName.toLowerCase();
      if (!folderByName.containsKey(key)) {
        final created = RssFolder(
          id: generateRssId('folder', folderName),
          name: folderName,
          sortOrder: _folders.length,
          createdAt: now,
        );
        _folders.add(created);
        folderByName[key] = created;
        addedFolders.add(created);
      }
    }

    final addedSubs = <RssSubscription>[];
    for (final item in parsed.feeds) {
      final folder = item.folderName != null
          ? folderByName[item.folderName!.toLowerCase()]
          : null;
      final sub = RssSubscription(
        id: generateRssId('sub', RssOpml.normalizeFeedUrlKey(item.feedUrl)),
        feedUrl: item.feedUrl,
        siteUrl: item.siteUrl,
        title: item.title,
        folderId: folder?.id,
        createdAt: now,
      );
      _subscriptions.add(sub);
      addedSubs.add(sub);
    }

    notifyListeners();
    await _persistState();

    if (refreshAfterImport && addedSubs.isNotEmpty) {
      // Refresh in background without blocking the OPML import return.
      refreshAll(force: true).catchError((Object _) {});
    }

    return OpmlImportSummary(
      addedSubscriptions: addedSubs,
      addedFolders: addedFolders,
      skippedDuplicates: parsed.skippedDuplicates,
      failures: parsed.failures,
    );
  }

  String exportOpml() => RssOpml.exportOpml(
        folders: _folders,
        subscriptions: _subscriptions,
        exportedAt: _clock().toUtc(),
      );

  // ---------------------------------------------------------------------------
  // Full-Text Webpage Extraction & Status Classification
  // ---------------------------------------------------------------------------

  /// Extracts full article content from the original webpage when the feed entry
  /// is `previewOnly` or when [forceRetry] is true.
  Future<RssArticle?> ensureFullText(
    String articleId, {
    bool forceRetry = false,
  }) async {
    final existing = _articlesById[articleId];
    if (existing == null) return null;
    if (!forceRetry && existing.contentStatus == ArticleContentStatus.full) {
      return existing;
    }
    if (!forceRetry &&
        existing.contentStatus == ArticleContentStatus.subscriberOnly) {
      return existing;
    }
    if (_extractingArticleIds.contains(articleId)) {
      return existing;
    }

    _extractingArticleIds.add(articleId);
    notifyListeners();
    try {
      final upgraded = await _extractor.extractFullArticle(existing);
      final folderNameToId = {
        for (final f in _folders) f.name.toLowerCase(): f.id,
      };
      final withRules = RssRulesEngine.applyRulesToArticle(
        upgraded,
        rules: _rules,
        followedAuthors: _followedAuthors,
        folderNameToId: folderNameToId,
      );
      _articlesById[articleId] = withRules;
      notifyListeners();
      await _store.saveArticle(withRules);
      return withRules;
    } finally {
      _extractingArticleIds.remove(articleId);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Read/Unread, Starred, Saved to Library, & Reading Progress
  // ---------------------------------------------------------------------------

  Future<void> markRead(String articleId, bool isRead) async {
    final existing = _articlesById[articleId];
    if (existing == null || existing.isRead == isRead) return;
    final updated = existing.copyWith(isRead: isRead);
    _articlesById[articleId] = updated;
    notifyListeners();
    await _store.saveArticle(updated);
  }

  Future<void> markAllRead({
    String? subscriptionId,
    String? folderId,
    String? authorId,
  }) async {
    final targetArticles = queryArticles(
      mode: RssArticleFilterMode.unread,
      subscriptionId: subscriptionId,
      folderId: folderId,
      authorId: authorId,
    );
    if (targetArticles.isEmpty) return;
    final updated = <RssArticle>[];
    for (final article in targetArticles) {
      final next = article.copyWith(isRead: true);
      _articlesById[article.id] = next;
      updated.add(next);
    }
    notifyListeners();
    await _store.saveArticlesBatch(updated);
  }

  Future<void> toggleStarred(String articleId) async {
    final existing = _articlesById[articleId];
    if (existing == null) return;
    final updated = existing.copyWith(isStarred: !existing.isStarred);
    _articlesById[articleId] = updated;
    notifyListeners();
    await _store.saveArticle(updated);
  }

  Future<void> setSavedToLibrary(String articleId, bool saved) async {
    final existing = _articlesById[articleId];
    if (existing == null || existing.isSavedToLibrary == saved) return;
    final updated = existing.copyWith(isSavedToLibrary: saved);
    _articlesById[articleId] = updated;
    notifyListeners();
    await _store.saveArticle(updated);
  }

  Future<void> saveReadingPosition(
    String articleId, {
    int? readingOffset,
    double? scrollFraction,
    int? narrationOffset,
  }) async {
    final existing = _articlesById[articleId];
    if (existing == null) return;
    final updated = existing.copyWith(
      readingOffset: readingOffset ?? existing.readingOffset,
      readingScrollFraction:
          scrollFraction ?? existing.readingScrollFraction,
      narrationOffset: narrationOffset ?? existing.narrationOffset,
    );
    _articlesById[articleId] = updated;
    notifyListeners();
    await _store.saveArticle(updated);
  }

  // ---------------------------------------------------------------------------
  // Authors-First Organization
  // ---------------------------------------------------------------------------

  Future<FollowedAuthor> followAuthor(
    String name, {
    List<String> aliases = const [],
    bool favorite = true,
    bool autoNarrateEligible = false,
  }) async {
    final candidate = RssAuthors.createFollowedAuthor(
      name,
      aliases: aliases,
      favorite: favorite,
      autoNarrateEligible: autoNarrateEligible,
    );
    final existingIdx = _followedAuthors
        .indexWhere((a) => a.normalizedName == candidate.normalizedName);
    if (existingIdx >= 0) {
      final mergedAliases = <String>{
        ..._followedAuthors[existingIdx].aliases,
        ...candidate.aliases,
      }.toList(growable: false);
      final updated = _followedAuthors[existingIdx].copyWith(
        aliases: mergedAliases,
        favorite: favorite,
        autoNarrateEligible: autoNarrateEligible,
      );
      _followedAuthors[existingIdx] = updated;
      await _reapplyAllRulesAndPersist();
      return updated;
    }
    _followedAuthors.add(candidate);
    await _reapplyAllRulesAndPersist();
    return candidate;
  }

  Future<void> toggleAuthorFavorite(String authorId) async {
    final idx = _followedAuthors.indexWhere((a) => a.id == authorId);
    if (idx < 0) return;
    _followedAuthors[idx] = _followedAuthors[idx].copyWith(
      favorite: !_followedAuthors[idx].favorite,
    );
    await _reapplyAllRulesAndPersist();
  }

  Future<void> toggleAuthorAutoNarrateEligible(String authorId) async {
    final idx = _followedAuthors.indexWhere((a) => a.id == authorId);
    if (idx < 0) return;
    _followedAuthors[idx] = _followedAuthors[idx].copyWith(
      autoNarrateEligible: !_followedAuthors[idx].autoNarrateEligible,
    );
    notifyListeners();
    await _persistState();
  }

  Future<void> unfollowAuthor(String authorId) async {
    _followedAuthors.removeWhere((a) => a.id == authorId);
    await _reapplyAllRulesAndPersist();
  }

  // ---------------------------------------------------------------------------
  // Natural-Language Feed Rules
  // ---------------------------------------------------------------------------

  Future<RuleTranslationResult> addRuleFromNaturalLanguage(
    String prompt,
  ) async {
    final result = RssRulesEngine.translateNaturalLanguageRule(
      prompt,
      existingFolders: _folders,
      now: _clock().toUtc(),
    );
    if (!result.isSupported || result.rule == null) {
      return result;
    }

    var rule = result.rule!;
    // If the rule assigns a folder that doesn't exist yet, create that folder automatically!
    if (rule.actionType == RuleActionType.assignFolder &&
        rule.targetFolderName != null &&
        rule.targetFolderId == null) {
      final folder = await createFolder(rule.targetFolderName!);
      rule = rule.copyWith(
        targetFolderName: folder.name,
        targetFolderId: folder.id,
      );
    }

    final existingIdx = _rules.indexWhere((r) => r.id == rule.id);
    if (existingIdx >= 0) {
      _rules[existingIdx] = rule;
    } else {
      _rules.add(rule);
    }
    await _reapplyAllRulesAndPersist();
    return RuleTranslationResult.success(rule);
  }

  Future<void> updateRule(FeedRule updatedRule) async {
    final idx = _rules.indexWhere((r) => r.id == updatedRule.id);
    if (idx < 0) {
      _rules.add(updatedRule);
    } else {
      _rules[idx] = updatedRule;
    }
    await _reapplyAllRulesAndPersist();
  }

  Future<void> toggleRuleEnabled(String ruleId, bool enabled) async {
    final idx = _rules.indexWhere((r) => r.id == ruleId);
    if (idx < 0) return;
    _rules[idx] = _rules[idx].copyWith(enabled: enabled);
    await _reapplyAllRulesAndPersist();
  }

  Future<void> deleteRule(String ruleId) async {
    _rules.removeWhere((r) => r.id == ruleId);
    await _reapplyAllRulesAndPersist();
  }

  // ---------------------------------------------------------------------------
  // Internal Ingestion & Rule Evaluation Helpers
  // ---------------------------------------------------------------------------

  List<RssArticle> _ingestParsedEntries(
    RssSubscription sub,
    List<ParsedFeedEntry> entries,
    DateTime now,
  ) {
    final folderNameToId = {
      for (final f in _folders) f.name.toLowerCase(): f.id,
    };
    final changed = <RssArticle>[];

    for (final entry in entries) {
      final existing = _articlesById[entry.id] ??
          _findDuplicateArticleByUrl(entry.canonicalUrl, entry.guid);

      if (existing != null) {
        // Preserve user state (isRead, isStarred, readingOffset, cached full blocks)
        final keepExistingBlocks =
            existing.contentStatus == ArticleContentStatus.full &&
                entry.contentStatus != ArticleContentStatus.full;
        final merged = existing.copyWith(
          feedTitle: sub.displayTitle,
          title: entry.title.isNotEmpty ? entry.title : existing.title,
          author: entry.author ?? existing.author,
          normalizedAuthors: entry.normalizedAuthors.isNotEmpty
              ? entry.normalizedAuthors
              : existing.normalizedAuthors,
          publishedAt: entry.publishedAt ?? existing.publishedAt,
          blocks: keepExistingBlocks ? existing.blocks : entry.blocks,
          contentStatus:
              keepExistingBlocks ? existing.contentStatus : entry.contentStatus,
          statusReason:
              keepExistingBlocks ? existing.statusReason : entry.statusReason,
        );
        final evaluated = RssRulesEngine.applyRulesToArticle(
          merged,
          rules: _rules,
          followedAuthors: _followedAuthors,
          folderNameToId: folderNameToId,
        );
        _articlesById[existing.id] = evaluated;
        changed.add(evaluated);
      } else {
        final fresh = RssArticle(
          id: entry.id,
          subscriptionId: sub.id,
          feedTitle: sub.displayTitle,
          folderId: sub.folderId,
          title: entry.title,
          url: entry.url,
          canonicalUrl: entry.canonicalUrl,
          guid: entry.guid,
          author: entry.author,
          normalizedAuthors: entry.normalizedAuthors,
          publishedAt: entry.publishedAt,
          fetchedAt: now,
          summaryPreview: entry.summaryPreview,
          blocks: entry.blocks,
          contentStatus: entry.contentStatus,
          statusReason: entry.statusReason,
        );
        final evaluated = RssRulesEngine.applyRulesToArticle(
          fresh,
          rules: _rules,
          followedAuthors: _followedAuthors,
          folderNameToId: folderNameToId,
        );
        _articlesById[fresh.id] = evaluated;
        changed.add(evaluated);
      }
    }
    return changed;
  }

  RssArticle? _findDuplicateArticleByUrl(String canonicalUrl, String? guid) {
    for (final article in _articlesById.values) {
      if (canonicalUrl.isNotEmpty && article.canonicalUrl == canonicalUrl) {
        return article;
      }
      if (guid != null && guid.isNotEmpty && article.guid == guid) {
        return article;
      }
    }
    return null;
  }

  List<RssArticle> _reapplyAllRulesInMemory() {
    final folderNameToId = {
      for (final f in _folders) f.name.toLowerCase(): f.id,
    };
    final changed = <RssArticle>[];
    for (final entry in _articlesById.entries.toList()) {
      final sub = subscriptionById(entry.value.subscriptionId);
      final baseArticle = entry.value.copyWith(
        folderId: sub?.folderId,
        clearFolderId: sub?.folderId == null,
      );
      final evaluated = RssRulesEngine.applyRulesToArticle(
        baseArticle,
        rules: _rules,
        followedAuthors: _followedAuthors,
        folderNameToId: folderNameToId,
      );
      _articlesById[entry.key] = evaluated;
      changed.add(evaluated);
    }
    return changed;
  }

  Future<void> _reapplyAllRulesAndPersist() async {
    final changed = _reapplyAllRulesInMemory();
    notifyListeners();
    await _persistState();
    if (changed.isNotEmpty) {
      await _store.saveArticlesBatch(changed);
    }
  }

  Future<void> _persistState() => _store.saveState(
        RssStateSnapshot(
          shelfExpanded: _shelfExpanded,
          folders: _folders,
          subscriptions: _subscriptions,
          followedAuthors: _followedAuthors,
          rules: _rules,
        ),
      );

  static int _compareArticles(RssArticle a, RssArticle b) {
    if (a.isPrioritized != b.isPrioritized) {
      return a.isPrioritized ? -1 : 1;
    }
    final aTime = a.publishedAt ?? a.fetchedAt;
    final bTime = b.publishedAt ?? b.fetchedAt;
    final cmp = bTime.compareTo(aTime);
    if (cmp != 0) return cmp;
    return b.id.compareTo(a.id);
  }
}
