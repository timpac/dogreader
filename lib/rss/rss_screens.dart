import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../article_import.dart';
import '../article_library.dart';
import 'rss_authors.dart';
import 'rss_controller.dart';
import 'rss_models.dart';
import 'rss_rules.dart';
import 'rss_shelf.dart';

typedef OpenRssImportedArticle = void Function(
  ImportedArticle article,
  bool narration,
);

/// Main RSS Reader screen showing articles organized around feeds, folders,
/// and followed writers.
class RssHomeScreen extends StatefulWidget {
  const RssHomeScreen({
    super.key,
    required this.controller,
    required this.articleLibrary,
    required this.onOpenArticle,
    this.initialMode = RssArticleFilterMode.all,
    this.initialSubscriptionId,
    this.initialFolderId,
    this.initialAuthorId,
  });

  final RssLibraryController controller;
  final ArticleLibrary articleLibrary;
  final OpenRssImportedArticle onOpenArticle;
  final RssArticleFilterMode initialMode;
  final String? initialSubscriptionId;
  final String? initialFolderId;
  final String? initialAuthorId;

  @override
  State<RssHomeScreen> createState() => _RssHomeScreenState();
}

class _RssHomeScreenState extends State<RssHomeScreen> {
  late RssArticleFilterMode _mode;
  String? _subscriptionId;
  String? _folderId;
  String? _authorId;
  String _searchQuery = '';
  bool _searching = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _subscriptionId = widget.initialSubscriptionId;
    _folderId = widget.initialFolderId;
    _authorId = widget.initialAuthorId;
    // Sensibly throttled refresh on opening the RSS area (15-min cooldown per feed)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.refreshAll(force: false).catchError((Object _) {});
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearScopeFilters() {
    setState(() {
      _subscriptionId = null;
      _folderId = null;
      _authorId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final articles = widget.controller.queryArticles(
          mode: _mode,
          subscriptionId: _subscriptionId,
          folderId: _folderId,
          authorId: _authorId,
          searchQuery: _searchQuery,
        );

        final activeSub = _subscriptionId != null
            ? widget.controller.subscriptionById(_subscriptionId!)
            : null;
        final activeFolder = _folderId != null
            ? widget.controller.folderById(_folderId!)
            : null;
        final activeAuthor = _authorId != null
            ? widget.controller.followedAuthors
                .where((a) => a.id == _authorId)
                .firstOrNull
            : null;

        final scopeTitle = activeAuthor != null
            ? 'Writer: ${activeAuthor.name}'
            : activeFolder != null
                ? 'Folder: ${activeFolder.name}'
                : activeSub != null
                    ? activeSub.displayTitle
                    : 'RSS Reader';

        return Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search articles, authors, or feeds…',
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  )
                : Row(
                    children: [
                      const Icon(
                        Icons.rss_feed_rounded,
                        color: kTraditionalRssOrange,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          scopeTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
            actions: [
              IconButton(
                tooltip: _searching ? 'Close search' : 'Search articles',
                icon: Icon(_searching ? Icons.close : Icons.search),
                onPressed: () {
                  setState(() {
                    _searching = !_searching;
                    if (!_searching) {
                      _searchController.clear();
                      _searchQuery = '';
                    }
                  });
                },
              ),
              IconButton(
                key: const Key('rss_refresh_all_button'),
                tooltip: 'Refresh feeds',
                icon: widget.controller.isRefreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
                onPressed: widget.controller.isRefreshing
                    ? null
                    : () => widget.controller.refreshAll(force: true),
              ),
              PopupMenuButton<String>(
                tooltip: 'RSS tools & organization',
                onSelected: (value) async {
                  switch (value) {
                    case 'mark_all_read':
                      await widget.controller.markAllRead(
                        subscriptionId: _subscriptionId,
                        folderId: _folderId,
                        authorId: _authorId,
                      );
                    case 'subscriptions':
                      if (!context.mounted) return;
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => RssSubscriptionsAndOpmlScreen(
                            controller: widget.controller,
                          ),
                        ),
                      );
                    case 'authors':
                      if (!context.mounted) return;
                      final pickedAuthorId = await Navigator.push<String>(
                        context,
                        MaterialPageRoute<String>(
                          builder: (_) => RssAuthorsScreen(
                            controller: widget.controller,
                          ),
                        ),
                      );
                      if (pickedAuthorId != null && mounted) {
                        setState(() {
                          _authorId = pickedAuthorId;
                          _subscriptionId = null;
                          _folderId = null;
                        });
                      }
                    case 'rules':
                      if (!context.mounted) return;
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => RssRulesScreen(
                            controller: widget.controller,
                          ),
                        ),
                      );
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'subscriptions',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.rss_feed_rounded),
                      title: Text('Subscriptions, Folders & OPML'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'authors',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.person_search_outlined),
                      title: Text('Favorite Writers'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rules',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.auto_fix_high_outlined),
                      title: Text('Natural-Language Feed Rules'),
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'mark_all_read',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.done_all_rounded),
                      title: Text('Mark visible articles read'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildFilterBar(
                context,
                activeSub: activeSub,
                activeFolder: activeFolder,
                activeAuthor: activeAuthor,
              ),
              const Divider(height: 1),
              Expanded(
                child: articles.isEmpty
                    ? _buildEmptyState(context)
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        itemCount: articles.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final article = articles[index];
                          return _RssArticleListCard(
                            article: article,
                            onTap: () => _openArticleReader(
                              context,
                              articles,
                              index,
                            ),
                            onToggleRead: () => widget.controller
                                .markRead(article.id, !article.isRead),
                            onToggleStar: () =>
                                widget.controller.toggleStarred(article.id),
                            onListen: () {
                              widget.controller.markRead(article.id, true);
                              widget.onOpenArticle(
                                article.toImportedArticle(),
                                true,
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            key: const Key('rss_add_feed_fab'),
            backgroundColor: kTraditionalRssOrange,
            foregroundColor: Colors.white,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => RssSubscriptionsAndOpmlScreen(
                  controller: widget.controller,
                ),
              ),
            ),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Manage Feeds'),
          ),
        );
      },
    );
  }

  Widget _buildFilterBar(
    BuildContext context, {
    required RssSubscription? activeSub,
    required RssFolder? activeFolder,
    required FollowedAuthor? activeAuthor,
  }) {
    final c = widget.controller;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final mode in RssArticleFilterMode.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      selected: _mode == mode,
                      label: Text(_modeLabel(mode, c)),
                      onSelected: (_) => setState(() => _mode = mode),
                    ),
                  ),
                const SizedBox(width: 4),
                ActionChip(
                  avatar: const Icon(Icons.person_outline_rounded, size: 16),
                  label: const Text('Writers'),
                  onPressed: () async {
                    final picked = await Navigator.push<String>(
                      context,
                      MaterialPageRoute<String>(
                        builder: (_) => RssAuthorsScreen(controller: c),
                      ),
                    );
                    if (picked != null && mounted) {
                      setState(() {
                        _authorId = picked;
                        _subscriptionId = null;
                        _folderId = null;
                      });
                    }
                  },
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.auto_fix_high_outlined, size: 16),
                  label: Text('Rules (${c.rules.where((r) => r.enabled).length})'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => RssRulesScreen(controller: c),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (c.followedAuthors.isNotEmpty ||
              c.folders.isNotEmpty ||
              c.subscriptions.isNotEmpty) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (activeSub != null ||
                      activeFolder != null ||
                      activeAuthor != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        selected: true,
                        label: Text(
                          activeAuthor != null
                              ? 'Writer: ${activeAuthor.name}'
                              : activeFolder != null
                                  ? 'Folder: ${activeFolder.name}'
                                  : 'Feed: ${activeSub!.displayTitle}',
                        ),
                        onDeleted: _clearScopeFilters,
                      ),
                    ),
                  for (final author in c.followedAuthors)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        selected: _authorId == author.id,
                        avatar: const Icon(Icons.person, size: 15),
                        label: Text(
                          '${author.name} (${c.unreadCountForAuthor(author)})',
                        ),
                        onSelected: (selected) => setState(() {
                          _authorId = selected ? author.id : null;
                          if (selected) {
                            _subscriptionId = null;
                            _folderId = null;
                          }
                        }),
                      ),
                    ),
                  for (final folder in c.folders)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        selected: _folderId == folder.id,
                        avatar: const Icon(Icons.folder_outlined, size: 15),
                        label: Text(
                          '${folder.name} (${c.unreadCountForFolder(folder.id)})',
                        ),
                        onSelected: (selected) => setState(() {
                          _folderId = selected ? folder.id : null;
                          if (selected) {
                            _subscriptionId = null;
                            _authorId = null;
                          }
                        }),
                      ),
                    ),
                  for (final sub in c.subscriptions)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        selected: _subscriptionId == sub.id,
                        avatar: const Icon(Icons.rss_feed_rounded, size: 15),
                        label: Text(
                          '${sub.displayTitle} (${c.unreadCountForSubscription(sub.id)})',
                        ),
                        onSelected: (selected) => setState(() {
                          _subscriptionId = selected ? sub.id : null;
                          if (selected) {
                            _folderId = null;
                            _authorId = null;
                          }
                        }),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _modeLabel(RssArticleFilterMode mode, RssLibraryController c) {
    return switch (mode) {
      RssArticleFilterMode.all =>
        'All (${c.allArticles.where((a) => !a.isHidden).length})',
      RssArticleFilterMode.unread => 'Unread (${c.totalUnreadCount})',
      RssArticleFilterMode.starred => 'Starred (${c.starredCount})',
      RssArticleFilterMode.savedToLibrary =>
        'In Books (${c.librarySavedArticles.length})',
    };
  }

  Widget _buildEmptyState(BuildContext context) {
    final hasSubs = widget.controller.subscriptions.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: kTraditionalRssOrange.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.rss_feed_rounded,
                size: 36,
                color: kTraditionalRssOrange,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              hasSubs ? 'No matching articles' : 'Your RSS shelf is ready',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              hasSubs
                  ? 'Try switching from Unread to All Articles, clearing filters, or refreshing your feeds.'
                  : 'Subscribe to publications, import an OPML file, or follow favorite writers like Ross Douthat, Coleman Hughes, and Douglas Murray.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                if (!hasSubs)
                  FilledButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => RssSubscriptionsAndOpmlScreen(
                          controller: widget.controller,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add Feed or Import OPML'),
                  ),
                if (hasSubs && _mode == RssArticleFilterMode.unread)
                  OutlinedButton(
                    onPressed: () =>
                        setState(() => _mode = RssArticleFilterMode.all),
                    child: const Text('Show All Articles'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => RssAuthorsScreen(
                        controller: widget.controller,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Follow Writers'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openArticleReader(
    BuildContext context,
    List<RssArticle> currentList,
    int initialIndex,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RssArticleReadingScreen(
          controller: widget.controller,
          articleLibrary: widget.articleLibrary,
          initialArticleId: currentList[initialIndex].id,
          orderedArticleIds: currentList.map((a) => a.id).toList(growable: false),
          onOpenArticle: widget.onOpenArticle,
        ),
      ),
    );
  }
}

class _RssArticleListCard extends StatelessWidget {
  const _RssArticleListCard({
    required this.article,
    required this.onTap,
    required this.onToggleRead,
    required this.onToggleStar,
    required this.onListen,
  });

  final RssArticle article;
  final VoidCallback onTap;
  final VoidCallback onToggleRead;
  final VoidCallback onToggleStar;
  final VoidCallback onListen;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dateText = _formatDate(article.publishedAt ?? article.fetchedAt);

    return Card(
      key: Key('rss_article_card_${article.id}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: !article.isRead
              ? kTraditionalRssOrange.withValues(alpha: 0.4)
              : colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (!article.isRead)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: const BoxDecoration(
                        color: kTraditionalRssOrange,
                        shape: BoxShape.circle,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      '${article.feedTitle} • ${article.displayAuthor}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    dateText,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                article.title,
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight:
                      article.isRead ? FontWeight.w500 : FontWeight.w700,
                  height: 1.3,
                ),
              ),
              if (article.summaryPreview.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  article.summaryPreview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.4,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  _ContentStatusChip(status: article.contentStatus),
                  if (article.isPrioritized) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Favorite Writer',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: article.isRead ? 'Mark unread' : 'Mark read',
                    icon: Icon(
                      article.isRead
                          ? Icons.mark_email_read_outlined
                          : Icons.mark_email_unread_rounded,
                      size: 20,
                    ),
                    onPressed: onToggleRead,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: article.isStarred ? 'Unstar' : 'Star article',
                    icon: Icon(
                      article.isStarred
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: article.isStarred ? Colors.amber : null,
                      size: 21,
                    ),
                    onPressed: onToggleStar,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Listen to article narration',
                    icon: const Icon(Icons.headphones_rounded, size: 20),
                    onPressed: onListen,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContentStatusChip extends StatelessWidget {
  const _ContentStatusChip({required this.status});
  final ArticleContentStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, IconData icon) = switch (status) {
      ArticleContentStatus.full => (
          Colors.green.withValues(alpha: 0.14),
          Colors.green.shade800,
          Icons.check_circle_outline_rounded,
        ),
      ArticleContentStatus.previewOnly => (
          Colors.blue.withValues(alpha: 0.14),
          Colors.blue.shade800,
          Icons.short_text_rounded,
        ),
      ArticleContentStatus.subscriberOnly => (
          Colors.orange.withValues(alpha: 0.16),
          Colors.deepOrange.shade800,
          Icons.lock_outline_rounded,
        ),
      ArticleContentStatus.extractionFailed => (
          Colors.red.withValues(alpha: 0.14),
          Colors.red.shade800,
          Icons.error_outline_rounded,
        ),
      ArticleContentStatus.unavailable => (
          Colors.grey.withValues(alpha: 0.2),
          Colors.grey.shade800,
          Icons.cloud_off_rounded,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.5, color: fg),
          const SizedBox(width: 4),
          Text(
            status.badgeLabel,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Distraction-Free Article Reading View
// =============================================================================

class RssArticleReadingScreen extends StatefulWidget {
  const RssArticleReadingScreen({
    super.key,
    required this.controller,
    required this.articleLibrary,
    required this.initialArticleId,
    required this.orderedArticleIds,
    required this.onOpenArticle,
  });

  final RssLibraryController controller;
  final ArticleLibrary articleLibrary;
  final String initialArticleId;
  final List<String> orderedArticleIds;
  final OpenRssImportedArticle onOpenArticle;

  @override
  State<RssArticleReadingScreen> createState() =>
      _RssArticleReadingScreenState();
}

class _RssArticleReadingScreenState extends State<RssArticleReadingScreen> with WidgetsBindingObserver {
  Timer? _positionTimer;
  double? _pendingFraction;
  late String _currentArticleId;
  final ScrollController _scrollController = ScrollController();
  double _fontSize = 19.0;
  double _lineHeight = 1.6;
  bool _serifFont = true;
  bool _restoredScroll = false;
  SummaryDepth _selectedSummaryDepth = SummaryDepth.standard;
  bool _isGeneratingSummary = false;
  String? _summaryError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentArticleId = widget.initialArticleId;
    _scrollController.addListener(_onScroll);
    widget.articleLibrary.addListener(_onLibraryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onEnterArticle());
  }

  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushPosition();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    widget.articleLibrary.removeListener(_onLibraryChanged);
    super.dispose();
  }

  Future<void> _generateSummary(RssArticle article, {bool force = false}) async {
    setState(() {
      _isGeneratingSummary = true;
      _summaryError = null;
    });
    try {
      final imported = article.toImportedArticle();
      await widget.articleLibrary.summarize(
        imported,
        _selectedSummaryDepth,
        forceRegenerate: force,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _summaryError =
              e is ArticleImportException ? e.message : e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingSummary = false;
        });
      }
    }
  }

  String _depthDescription(SummaryDepth depth) {
    switch (depth) {
      case SummaryDepth.brief:
        return 'Brief summary (approx. 3–5 sentences) capturing the main thesis and most important conclusions.';
      case SummaryDepth.standard:
        return 'Standard summary (approx. 200–350 words) covering main arguments, evidence, and conclusions with nuance.';
      case SummaryDepth.detailed:
        return 'Detailed summary (approx. 500–800 words) with thorough coverage of arguments, evidence, and counterarguments.';
    }
  }

  Future<void> _onEnterArticle() async {
    final article = widget.controller.articleById(_currentArticleId);
    if (article == null) return;
    await widget.controller.markRead(article.id, true);

    // Restore saved reading scroll position if available
    if (!_restoredScroll &&
        article.readingScrollFraction > 0 &&
        _scrollController.hasClients) {
      final maxExtent = _scrollController.position.maxScrollExtent;
      if (maxExtent > 0) {
        _scrollController.jumpTo(
          (maxExtent * article.readingScrollFraction).clamp(0.0, maxExtent),
        );
      }
      _restoredScroll = true;
    }

    // Automatically upgrade preview-only articles to full text
    if (article.contentStatus == ArticleContentStatus.previewOnly) {
      await widget.controller.ensureFullText(article.id);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final extent = _scrollController.position.maxScrollExtent;
    if (extent <= 0) return;
    _pendingFraction = (_scrollController.offset / extent).clamp(0.0, 1.0).toDouble();
    _positionTimer?.cancel();
    _positionTimer = Timer(const Duration(milliseconds: 300), _flushPosition);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _flushPosition();
  }

  void _flushPosition() {
    _positionTimer?.cancel();
    final fraction = _pendingFraction;
    _pendingFraction = null;
    if (fraction == null) return;
    final article = widget.controller.articleById(_currentArticleId);
    if (article == null) return;
    final totalChars = article.chapter.text.length;
    final charOffset = (totalChars * fraction).round();
    widget.controller.saveReadingPosition(
      article.id,
      readingOffset: charOffset,
      scrollFraction: fraction,
    );
  }

  void _navigateToNextArticle() {
    final currentIndex = widget.orderedArticleIds.indexOf(_currentArticleId);
    if (currentIndex < 0 ||
        currentIndex + 1 >= widget.orderedArticleIds.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reached the end of the current article list.')),
      );
      return;
    }
    _flushPosition();
    setState(() {
      _currentArticleId = widget.orderedArticleIds[currentIndex + 1];
      _restoredScroll = false;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
      _positionTimer?.cancel();
      _pendingFraction = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _onEnterArticle());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final article = widget.controller.articleById(_currentArticleId);
        if (article == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Article')),
            body: const Center(child: Text('Article is no longer available.')),
          );
        }

        final isExtracting =
            widget.controller.isExtractingArticle(article.id);
        final currentIndex =
            widget.orderedArticleIds.indexOf(_currentArticleId);
        final hasNext = currentIndex >= 0 &&
            currentIndex + 1 < widget.orderedArticleIds.length;

        return Scaffold(
          appBar: AppBar(
            title: Text(
              article.feedTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: article.isRead ? 'Mark as unread' : 'Mark as read',
                icon: Icon(
                  article.isRead
                      ? Icons.mark_email_read_outlined
                      : Icons.mark_email_unread_rounded,
                ),
                onPressed: () =>
                    widget.controller.markRead(article.id, !article.isRead),
              ),
              IconButton(
                tooltip: article.isStarred ? 'Unstar' : 'Star article',
                icon: Icon(
                  article.isStarred
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: article.isStarred ? Colors.amber : null,
                ),
                onPressed: () => widget.controller.toggleStarred(article.id),
              ),
              IconButton(
                tooltip: 'Typography settings',
                icon: const Icon(Icons.format_size_rounded),
                onPressed: () => _showTypographySheet(context),
              ),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'extract_full':
                      await widget.controller.ensureFullText(
                        article.id,
                        forceRetry: true,
                      );
                    case 'save_to_books':
                      final nextSaved = !article.isSavedToLibrary;
                      await widget.controller
                          .setSavedToLibrary(article.id, nextSaved);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            nextSaved
                                ? 'Saved article to your EPUB book library.'
                                : 'Removed article from your EPUB book library.',
                          ),
                        ),
                      );
                    case 'open_paginated':
                      widget.onOpenArticle(article.toImportedArticle(), false);
                    case 'copy_url':
                      await Clipboard.setData(ClipboardData(text: article.url));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Original article URL copied to clipboard.'),
                        ),
                      );
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'extract_full',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.downloading_rounded),
                      title: Text('Extract full text from webpage'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'save_to_books',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        article.isSavedToLibrary
                            ? Icons.bookmark_remove_outlined
                            : Icons.library_add_outlined,
                      ),
                      title: Text(
                        article.isSavedToLibrary
                            ? 'Remove from Book Library'
                            : 'Save to Book Library',
                      ),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'open_paginated',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.menu_book_rounded),
                      title: Text('Open in Paginated Book Reader'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'copy_url',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.link_rounded),
                      title: Text('Copy original webpage URL'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 36),
            children: [
              // Metadata Header
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _ContentStatusChip(status: article.contentStatus),
                  Text(
                    '${article.displayAuthor} • ${_formatDate(article.publishedAt ?? article.fetchedAt)} • ${article.wordCount} words',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(
                article.title,
                style: TextStyle(
                  fontSize: _fontSize + 7,
                  fontWeight: FontWeight.w700,
                  fontFamily: _serifFont ? 'serif' : null,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 14),

              // Diagnostic Banner when content is not full
              if (isExtracting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: LinearProgressIndicator(),
                ),
              if (article.contentStatus.showsDiagnosticBanner)
                _buildDiagnosticBanner(context, article, isExtracting),

              // On-Demand AI Summary Section (directly below title/metadata, before article body)
              _buildSummaryCard(context, article),
              const SizedBox(height: 20),

              // Article Body Blocks
              if (article.blocks.isEmpty && article.summaryPreview.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: SelectableText(
                    article.summaryPreview,
                    style: _bodyStyle(context),
                  ),
                ),
              for (final block in article.blocks)
                _buildArticleBlock(context, block),

              const SizedBox(height: 16),
              // Original Source Footer
              Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Original Webpage',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        article.url,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: article.url),
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Original webpage URL copied to clipboard.',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('Copy Original URL'),
                          ),
                          OutlinedButton.icon(
                            onPressed: isExtracting
                                ? null
                                : () => widget.controller.ensureFullText(
                                      article.id,
                                      forceRetry: true,
                                    ),
                            icon: const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text('Retry Full-Text Extraction'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: Row(
                children: [
                  FilledButton.icon(
                    key: const Key('rss_article_narrate_button'),
                    onPressed: () {
                      widget.onOpenArticle(article.toImportedArticle(), true);
                    },
                    icon: const Icon(Icons.headphones_rounded),
                    label: const Text('Listen / Narrate'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () {
                      widget.onOpenArticle(article.toImportedArticle(), false);
                    },
                    icon: const Icon(Icons.menu_book_rounded, size: 18),
                    label: const Text('Book View'),
                  ),
                  const Spacer(),
                  if (hasNext)
                    FilledButton.tonalIcon(
                      key: const Key('rss_next_article_button'),
                      onPressed: _navigateToNextArticle,
                      icon: const Icon(Icons.skip_next_rounded),
                      label: const Text('Next'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDiagnosticBanner(
    BuildContext context,
    RssArticle article,
    bool isExtracting,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('rss_content_status_banner'),
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                article.contentStatus == ArticleContentStatus.subscriberOnly
                    ? Icons.lock_outline_rounded
                    : Icons.info_outline_rounded,
                size: 18,
                color: colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  article.contentStatus.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            article.statusReason ??
                'Full article text was not included in the feed.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (article.contentStatus != ArticleContentStatus.subscriberOnly)
                FilledButton.tonalIcon(
                  onPressed: isExtracting
                      ? null
                      : () => widget.controller.ensureFullText(
                            article.id,
                            forceRetry: true,
                          ),
                  icon: const Icon(Icons.article_outlined, size: 16),
                  label: const Text('Extract Full Text'),
                ),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: article.url));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Original webpage link copied — open in your browser to view the publisher page.',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('Copy Original Webpage Link'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildArticleBlock(BuildContext context, ArticleBlock block) {
    final baseStyle = _bodyStyle(context);
    if (block.kind == 'break') {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Divider(),
      );
    }
    if (block.heading) {
      return Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 10),
        child: SelectableText.rich(
          _buildRichSpan(
            context,
            block,
            baseStyle.copyWith(
              fontSize: _fontSize + 4.0,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
        ),
      );
    }
    switch (block.kind) {
      case 'quote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: const EdgeInsets.only(left: 14, top: 6, bottom: 6),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(
                color: kTraditionalRssOrange,
                width: 3.5,
              ),
            ),
          ),
          child: SelectableText.rich(
            _buildRichSpan(
              context,
              block,
              baseStyle.copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        );
      case 'list':
        return Padding(
          padding: const EdgeInsets.only(left: 10, bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('•  ', style: baseStyle.copyWith(fontWeight: FontWeight.w700)),
              Expanded(
                child: SelectableText.rich(
                  _buildRichSpan(context, block, baseStyle),
                ),
              ),
            ],
          ),
        );
      case 'caption':
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: SelectableText.rich(
            _buildRichSpan(
              context,
              block,
              baseStyle.copyWith(
                fontSize: _fontSize - 3,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SelectableText.rich(
            _buildRichSpan(context, block, baseStyle),
          ),
        );
    }
  }

  TextSpan _buildRichSpan(
    BuildContext context,
    ArticleBlock block,
    TextStyle baseStyle,
  ) {
    final text = block.text;
    if (block.spans.isEmpty) {
      return TextSpan(text: text, style: baseStyle);
    }
    final children = <InlineSpan>[];
    for (var i = 0; i < text.length;) {
      var nextBoundary = text.length;
      var bold = false;
      var italic = false;
      String? href;
      for (final span in block.spans) {
        if (span.start <= i && span.end > i) {
          bold |= span.bold;
          italic |= span.italic;
          href ??= span.url;
          if (span.end < nextBoundary) nextBoundary = span.end;
        } else if (span.start > i && span.start < nextBoundary) {
          nextBoundary = span.start;
        }
      }
      final segment = text.substring(i, nextBoundary.clamp(i, text.length));
      children.add(
        TextSpan(
          text: segment,
          style: baseStyle.copyWith(
            fontWeight: bold ? FontWeight.w700 : baseStyle.fontWeight,
            fontStyle: italic ? FontStyle.italic : baseStyle.fontStyle,
            color: href != null
                ? Theme.of(context).colorScheme.primary
                : baseStyle.color,
            decoration: href != null ? TextDecoration.underline : null,
          ),
        ),
      );
      i = nextBoundary <= i ? i + 1 : nextBoundary;
    }
    return TextSpan(children: children);
  }

  TextStyle _bodyStyle(BuildContext context) => TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        fontFamily: _serifFont ? 'serif' : null,
        color: Theme.of(context).colorScheme.onSurface,
      );

  Widget _buildSummaryCard(BuildContext context, RssArticle article) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final imported = article.toImportedArticle();
    final cachedSummary = widget.articleLibrary.savedSummary(
      imported,
      _selectedSummaryDepth,
    );
    final isExtracting = widget.controller.isExtractingArticle(article.id);
    final isPaywalled =
        article.contentStatus == ArticleContentStatus.subscriberOnly;
    final isUnavailable =
        article.contentStatus == ArticleContentStatus.unavailable;
    final isExtractionFailed =
        article.contentStatus == ArticleContentStatus.extractionFailed;
    final isPreviewOnly =
        article.contentStatus == ArticleContentStatus.previewOnly &&
            article.blocks.isEmpty;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.summarize_outlined, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'On-Demand AI Article Summary',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'AI Summary',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<SummaryDepth>(
              key: ValueKey('rss-summary-depth-$_selectedSummaryDepth'),
              initialValue: _selectedSummaryDepth,
              decoration: const InputDecoration(
                labelText: 'Summary depth',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                for (final d in SummaryDepth.values)
                  DropdownMenuItem(
                    value: d,
                    child: Text(d.label),
                  ),
              ],
              onChanged: _isGeneratingSummary
                  ? null
                  : (s) => setState(() {
                        if (s != null) {
                          _selectedSummaryDepth = s;
                          _summaryError = null;
                        }
                      }),
            ),
            const SizedBox(height: 12),
            if (isPaywalled) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 18, color: colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Summaries are disabled for subscriber-only articles because DogReader never summarizes unextracted paywalled content.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ] else if (isUnavailable) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.link_off_rounded,
                      size: 18, color: colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Summaries are disabled because this article is unavailable.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ] else if (isExtractionFailed) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Full-text extraction from the webpage failed. DogReader only summarizes legitimately available, complete article text.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: isExtracting
                    ? null
                    : () => widget.controller
                        .ensureFullText(article.id, forceRetry: true),
                icon: isExtracting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 16),
                label: Text(
                  isExtracting
                      ? 'Extracting full text…'
                      : 'Retry Full-Text Extraction',
                ),
              ),
            ] else if (isPreviewOnly) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.short_text_rounded,
                      size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Only a preview or excerpt is available. DogReader never summarizes truncated previews as though they were complete articles.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: isExtracting
                    ? null
                    : () => widget.controller
                        .ensureFullText(article.id, forceRetry: true),
                icon: isExtracting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded, size: 16),
                label: Text(
                  isExtracting
                      ? 'Extracting full text…'
                      : 'Extract Full Text',
                ),
              ),
            ] else if (cachedSummary != null) ...[
              Text(
                'Cached ${cachedSummary.depth?.label ?? ''} AI Summary (distinct from original article):',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                cachedSummary.text,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () =>
                        widget.onOpenArticle(cachedSummary, false),
                    icon: const Icon(Icons.visibility_outlined, size: 16),
                    label: const Text('Read Summary'),
                  ),
                  FilledButton.icon(
                    onPressed: () =>
                        widget.onOpenArticle(cachedSummary, true),
                    icon: const Icon(Icons.headphones_rounded, size: 16),
                    label: const Text('Listen to Summary'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isGeneratingSummary
                        ? null
                        : () => _generateSummary(article, force: true),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Regenerate Summary'),
                  ),
                ],
              ),
              if (_isGeneratingSummary) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                Text(
                  'Regenerating ${_selectedSummaryDepth.label.toLowerCase()} summary…',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ] else if (_isGeneratingSummary) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                'Generating ${_selectedSummaryDepth.label.toLowerCase()} summary with Gemini Flash…',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.primary,
                ),
              ),
            ] else if (_summaryError != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _summaryError!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: () => _generateSummary(article),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry'),
              ),
            ] else ...[
              Text(
                _depthDescription(_selectedSummaryDepth),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _generateSummary(article),
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: Text(
                  'Generate ${_selectedSummaryDepth.label} Summary',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showTypographySheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Reading Appearance',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Text('Font size'),
                  Expanded(
                    child: Slider(
                      value: _fontSize,
                      min: 15,
                      max: 26,
                      divisions: 11,
                      label: _fontSize.round().toString(),
                      onChanged: (v) {
                        setSheetState(() => _fontSize = v);
                        setState(() => _fontSize = v);
                      },
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text('Line spacing'),
                  Expanded(
                    child: Slider(
                      value: _lineHeight,
                      min: 1.3,
                      max: 2.0,
                      divisions: 7,
                      label: _lineHeight.toStringAsFixed(1),
                      onChanged: (v) {
                        setSheetState(() => _lineHeight = v);
                        setState(() => _lineHeight = v);
                      },
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Serif book typeface'),
                value: _serifFont,
                onChanged: (v) {
                  setSheetState(() => _serifFont = v);
                  setState(() => _serifFont = v);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Subscriptions, Folders & OPML Import/Export Screen
// =============================================================================

class RssSubscriptionsAndOpmlScreen extends StatefulWidget {
  const RssSubscriptionsAndOpmlScreen({super.key, required this.controller});
  final RssLibraryController controller;

  @override
  State<RssSubscriptionsAndOpmlScreen> createState() =>
      _RssSubscriptionsAndOpmlScreenState();
}

class _RssSubscriptionsAndOpmlScreenState
    extends State<RssSubscriptionsAndOpmlScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _customTitleController = TextEditingController();
  String? _selectedFolderId;
  bool _subscribing = false;
  String? _errorText;

  @override
  void dispose() {
    _urlController.dispose();
    _customTitleController.dispose();
    super.dispose();
  }

  Future<void> _addFeed() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _subscribing = true;
      _errorText = null;
    });
    try {
      final sub = await widget.controller.addSubscriptionByUrl(
        url,
        folderId: _selectedFolderId,
        customTitle: _customTitleController.text.trim(),
      );
      _urlController.clear();
      _customTitleController.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Subscribed to ${sub.displayTitle}')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorText = error.toString());
    } finally {
      if (mounted) setState(() => _subscribing = false);
    }
  }

  Future<void> _pickAndImportOpmlFile() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['opml', 'xml'],
      );
      if (picked == null || picked.path == null) return;
      final xmlText = await File(picked.path!).readAsString();
      if (!mounted) return;
      await _runOpmlImport(xmlText);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import OPML file: $error')),
      );
    }
  }

  Future<void> _showPasteOpmlDialog() async {
    final pasteController = TextEditingController();
    final xml = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import OPML XML'),
        content: TextField(
          controller: pasteController,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Paste <opml>...</opml> XML content here…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, pasteController.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    pasteController.dispose();
    if (xml == null || xml.trim().isEmpty) return;
    await _runOpmlImport(xml);
  }

  Future<void> _runOpmlImport(String xmlText) async {
    try {
      final summary = await widget.controller.importOpml(
        xmlText,
        refreshAfterImport: true,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('OPML Import Complete'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Added subscriptions: ${summary.addedSubscriptions.length}'),
                Text('Created folders: ${summary.addedFolders.length}'),
                Text('Skipped duplicates: ${summary.skippedDuplicates.length}'),
                Text('Failed entries: ${summary.failures.length}'),
                if (summary.failures.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Failed Imports:',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  for (final f in summary.failures)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '• ${f.titleOrContext}: ${f.reason}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('OPML import failed: $error')),
      );
    }
  }

  Future<void> _showExportOpmlDialog() async {
    final opmlXml = widget.controller.exportOpml();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export Subscriptions to OPML'),
        content: SizedBox(
          width: 480,
          child: SelectableText(
            opmlXml,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: opmlXml));
              if (!context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('OPML copied to clipboard.')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy OPML'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateFolderDialog() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            hintText: 'e.g. Commentary, Technology, Substack',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await widget.controller.createFolder(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Subscriptions, Folders & OPML'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              // Add Subscription Card
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Subscribe to RSS / Atom Feed or Website',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('rss_add_feed_url_input'),
                        controller: _urlController,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Feed URL or Website URL',
                          hintText: 'https://www.thefp.com or https://.../feed',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _customTitleController,
                              decoration: const InputDecoration(
                                labelText: 'Custom name (optional)',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonFormField<String?>(
                              initialValue: _selectedFolderId,
                              decoration: const InputDecoration(
                                labelText: 'Folder',
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('No folder'),
                                ),
                                for (final f in c.folders)
                                  DropdownMenuItem<String?>(
                                    value: f.id,
                                    child: Text(f.name),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _selectedFolderId = v),
                            ),
                          ),
                        ],
                      ),
                      if (_errorText != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _errorText!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        key: const Key('rss_subscribe_submit_button'),
                        onPressed: _subscribing ? null : _addFeed,
                        icon: _subscribing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.rss_feed_rounded),
                        label: Text(
                          _subscribing ? 'Discovering feed…' : 'Subscribe',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // OPML Import / Export Bar
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'OPML Import & Export',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Migrate subscriptions and folder hierarchies between RSS readers.',
                        style: TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _pickAndImportOpmlFile,
                            icon: const Icon(Icons.upload_file_outlined, size: 18),
                            label: const Text('Import OPML File'),
                          ),
                          OutlinedButton.icon(
                            key: const Key('rss_paste_opml_button'),
                            onPressed: _showPasteOpmlDialog,
                            icon: const Icon(Icons.paste_rounded, size: 18),
                            label: const Text('Paste OPML XML'),
                          ),
                          OutlinedButton.icon(
                            key: const Key('rss_export_opml_button'),
                            onPressed: _showExportOpmlDialog,
                            icon: const Icon(Icons.download_outlined, size: 18),
                            label: const Text('Export OPML'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Folders Section
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Folders',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('rss_new_folder_button'),
                    onPressed: _showCreateFolderDialog,
                    icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                    label: const Text('New Folder'),
                  ),
                ],
              ),
              if (c.folders.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No folders created yet.'),
                ),
              for (final folder in c.folders)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.folder_outlined,
                    color: kTraditionalRssOrange,
                  ),
                  title: Text(folder.name),
                  subtitle: Text(
                    '${c.unreadCountForFolder(folder.id)} unread articles',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Rename folder',
                        icon: const Icon(Icons.edit_outlined, size: 19),
                        onPressed: () => _renameFolderDialog(folder),
                      ),
                      IconButton(
                        tooltip: 'Delete folder',
                        icon: const Icon(Icons.delete_outline, size: 19),
                        onPressed: () => c.deleteFolder(folder.id),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 24),

              // Subscriptions List
              Text(
                'Subscriptions (${c.subscriptions.length})',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (c.subscriptions.isEmpty)
                const Text('No active feed subscriptions.'),
              for (final sub in c.subscriptions)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: const Icon(
                      Icons.rss_feed_rounded,
                      color: kTraditionalRssOrange,
                    ),
                    title: Text(
                      sub.displayTitle,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sub.feedUrl, style: const TextStyle(fontSize: 12)),
                        if (sub.folderId != null)
                          Text(
                            'Folder: ${c.folderById(sub.folderId!)?.name ?? 'None'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        if (sub.lastError != null)
                          Text(
                            'Last refresh issue: ${sub.lastError}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        switch (action) {
                          case 'refresh':
                            c.refreshSubscription(sub.id, force: true);
                          case 'rename':
                            _renameSubDialog(sub);
                          case 'move':
                            _moveSubFolderDialog(sub);
                          case 'delete':
                            c.deleteSubscription(sub.id);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'refresh',
                          child: Text('Refresh feed'),
                        ),
                        PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename feed'),
                        ),
                        PopupMenuItem(
                          value: 'move',
                          child: Text('Move to folder…'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete subscription'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _renameFolderDialog(RssFolder folder) async {
    final tc = TextEditingController(text: folder.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Folder'),
        content: TextField(controller: tc, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, tc.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    tc.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await widget.controller.renameFolder(folder.id, name);
    }
  }

  Future<void> _renameSubDialog(RssSubscription sub) async {
    final tc = TextEditingController(text: sub.displayTitle);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Feed'),
        content: TextField(controller: tc, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, tc.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    tc.dispose();
    if (name != null) {
      await widget.controller.renameSubscription(sub.id, name);
    }
  }

  Future<void> _moveSubFolderDialog(RssSubscription sub) async {
    final picked = await showDialog<String?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Move "${sub.displayTitle}" to Folder'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, '__none__'),
            child: const Text('No folder (Top level)'),
          ),
          for (final folder in widget.controller.folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, folder.id),
              child: Text(folder.name),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await widget.controller.moveSubscriptionToFolder(
      sub.id,
      picked == '__none__' ? null : picked,
    );
  }
}

// =============================================================================
// Authors-First Organization Screen
// =============================================================================

class RssAuthorsScreen extends StatefulWidget {
  const RssAuthorsScreen({super.key, required this.controller});
  final RssLibraryController controller;

  @override
  State<RssAuthorsScreen> createState() => _RssAuthorsScreenState();
}

class _RssAuthorsScreenState extends State<RssAuthorsScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _aliasesController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _aliasesController.dispose();
    super.dispose();
  }

  Future<void> _followCustomAuthor() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final aliases = _aliasesController.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    await widget.controller.followAuthor(name, aliases: aliases);
    _nameController.clear();
    _aliasesController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        return Scaffold(
          appBar: AppBar(title: const Text('Favorite Writers & Authors')),
          body: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const Text(
                'Follow individual writers across publications (such as The Free Press, Substack, and syndicate columns). Articles by favorite writers are prioritized automatically.',
                style: TextStyle(fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 14),
              const Text(
                'Suggested Writers (One-Tap Follow)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final suggested in RssAuthors.suggestedAuthors)
                    ActionChip(
                      avatar: const Icon(Icons.person_add_alt_1_outlined, size: 16),
                      label: Text(suggested.name),
                      onPressed: () => c.followAuthor(
                        suggested.name,
                        aliases: suggested.aliases,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Follow Writer by Name',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('rss_follow_author_input'),
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Writer name',
                          hintText: 'e.g. Ross Douthat, Coleman Hughes, Douglas Murray',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _aliasesController,
                        decoration: const InputDecoration(
                          labelText: 'Byline variations / aliases (comma-separated, optional)',
                          hintText: 'e.g. R. Douthat, Ross G. Douthat',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        key: const Key('rss_follow_author_submit'),
                        onPressed: _followCustomAuthor,
                        icon: const Icon(Icons.person_add_rounded),
                        label: const Text('Follow Writer'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Followed Writers (${c.followedAuthors.length})',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (c.followedAuthors.isEmpty)
                const Text('No writers followed yet.'),
              for (final author in c.followedAuthors)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          kTraditionalRssOrange.withValues(alpha: 0.16),
                      child: const Icon(
                        Icons.person_rounded,
                        color: kTraditionalRssOrange,
                      ),
                    ),
                    title: Text(
                      author.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${c.unreadCountForAuthor(author)} unread articles'
                      '${author.aliases.isNotEmpty ? ' • Matches: ${author.aliases.join(", ")}' : ''}',
                    ),
                    onTap: () => Navigator.pop(context, author.id),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: author.favorite
                              ? 'Prioritized favorite writer'
                              : 'Mark as favorite writer',
                          icon: Icon(
                            author.favorite
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            color: author.favorite ? Colors.amber : null,
                          ),
                          onPressed: () => c.toggleAuthorFavorite(author.id),
                        ),
                        IconButton(
                          tooltip: 'Remove writer',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => c.unfollowAuthor(author.id),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// Natural-Language Feed Rules Screen
// =============================================================================

class RssRulesScreen extends StatefulWidget {
  const RssRulesScreen({super.key, required this.controller});
  final RssLibraryController controller;

  @override
  State<RssRulesScreen> createState() => _RssRulesScreenState();
}

class _RssRulesScreenState extends State<RssRulesScreen> {
  final TextEditingController _promptController = TextEditingController();
  RuleTranslationResult? _previewResult;
  String? _feedbackError;

  static const List<String> _examplePrompts = [
    'Show me articles by Ross Douthat',
    'Prioritize articles from favorite writers',
    'Automatically star articles matching AI',
    'Put articles about AI into Technology',
    'Hide articles from Guest Contributor',
  ];

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  void _updatePreview(String text) {
    setState(() {
      _feedbackError = null;
      if (text.trim().isEmpty) {
        _previewResult = null;
      } else {
        _previewResult = RssRulesEngine.translateNaturalLanguageRule(
          text,
          existingFolders: widget.controller.folders,
        );
      }
    });
  }

  Future<void> _submitRule() async {
    final text = _promptController.text.trim();
    if (text.isEmpty) return;
    final res = await widget.controller.addRuleFromNaturalLanguage(text);
    if (!mounted) return;
    if (!res.isSupported) {
      setState(() => _feedbackError = res.errorMessage);
      return;
    }
    _promptController.clear();
    setState(() {
      _previewResult = null;
      _feedbackError = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Rule added: ${res.rule!.explicitDescription}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        return Scaffold(
          appBar: AppBar(title: const Text('Natural-Language Feed Rules')),
          body: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const Text(
                'Write rules in plain English. DogReader translates them into explicit, inspectable, deterministic local rules—no recurring AI calls required.',
                style: TextStyle(fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final example in _examplePrompts)
                    ActionChip(
                      label: Text(example, style: const TextStyle(fontSize: 12)),
                      onPressed: () {
                        _promptController.text = example;
                        _updatePreview(example);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        key: const Key('rss_nl_rule_input'),
                        controller: _promptController,
                        onChanged: _updatePreview,
                        decoration: const InputDecoration(
                          labelText: 'Describe a rule in plain English',
                          hintText: 'e.g. Automatically star articles matching AI',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_previewResult != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _previewResult!.isSupported
                                ? Colors.green.withValues(alpha: 0.12)
                                : Colors.orange.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _previewResult!.isSupported
                                ? 'Translated Rule: ${_previewResult!.rule!.explicitDescription}'
                                : _previewResult!.errorMessage ??
                                    'Unsupported rule.',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      if (_feedbackError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _feedbackError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        key: const Key('rss_add_rule_button'),
                        onPressed: _submitRule,
                        icon: const Icon(Icons.auto_fix_high_rounded),
                        label: const Text('Save Deterministic Rule'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Active & Saved Rules (${c.rules.length})',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (c.rules.isEmpty)
                const Text('No feed rules configured.'),
              for (final rule in c.rules)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: Switch(
                      value: rule.enabled,
                      onChanged: (v) => c.toggleRuleEnabled(rule.id, v),
                    ),
                    title: Text(
                      '"${rule.naturalLanguagePrompt}"',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(rule.explicitDescription),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Edit rule',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _editRuleDialog(rule),
                        ),
                        IconButton(
                          tooltip: 'Delete rule',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => c.deleteRule(rule.id),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editRuleDialog(FeedRule rule) async {
    final patternController = TextEditingController(text: rule.pattern);
    var cond = rule.conditionType;
    var act = rule.actionType;
    final saved = await showDialog<FeedRule>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit Rule Definition'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<RuleConditionType>(
                initialValue: cond,
                decoration: const InputDecoration(labelText: 'Condition'),
                items: [
                  for (final item in RuleConditionType.values)
                    DropdownMenuItem(value: item, child: Text(item.label)),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => cond = v);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: patternController,
                decoration: const InputDecoration(
                  labelText: 'Match pattern (author / topic / publication)',
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<RuleActionType>(
                initialValue: act,
                decoration: const InputDecoration(labelText: 'Action'),
                items: [
                  for (final item in RuleActionType.values)
                    DropdownMenuItem(value: item, child: Text(item.label)),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => act = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                rule.copyWith(
                  conditionType: cond,
                  pattern: patternController.text.trim(),
                  actionType: act,
                ),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    patternController.dispose();
    if (saved != null) {
      await widget.controller.updateRule(saved);
    }
  }
}

String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}
