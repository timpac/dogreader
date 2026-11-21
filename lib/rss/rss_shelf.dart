import 'package:flutter/material.dart';

import 'rss_controller.dart';
import 'rss_models.dart';

const Color kTraditionalRssOrange = Color(0xFFF26522);

/// Compact, collapsible RSS shelf displayed near the top of the main library,
/// above the EPUB books.
///
/// Collapsed by default so it never clutters the book library. Displays the
/// recognizable traditional orange RSS icon, unread count badge, one-tap entry
/// into the RSS reader, and expands to show followed authors, folders, and feeds.
class RssLibraryShelf extends StatelessWidget {
  const RssLibraryShelf({
    super.key,
    required this.controller,
    required this.onOpenRssHome,
    required this.onOpenAddFeed,
    required this.onOpenAuthors,
    required this.onOpenRules,
    required this.onOpenOpml,
  });

  final RssLibraryController controller;
  final void Function({
    RssArticleFilterMode? initialMode,
    String? subscriptionId,
    String? folderId,
    String? authorId,
  }) onOpenRssHome;
  final VoidCallback onOpenAddFeed;
  final VoidCallback onOpenAuthors;
  final VoidCallback onOpenRules;
  final VoidCallback onOpenOpml;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final unreadCount = controller.totalUnreadCount;
        final expanded = controller.shelfExpanded;
        final subCount = controller.subscriptions.length;
        final authorCount = controller.followedAuthors.length;
        final colorScheme = Theme.of(context).colorScheme;

        return Card(
          key: const Key('rss_library_shelf'),
          margin: const EdgeInsets.only(bottom: 18),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: unreadCount > 0
                  ? kTraditionalRssOrange.withValues(alpha: 0.45)
                  : colorScheme.outlineVariant,
            ),
          ),
          color: colorScheme.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                key: const Key('rss_shelf_open_tap'),
                borderRadius: BorderRadius.circular(18),
                onTap: () => onOpenRssHome(
                  initialMode: unreadCount > 0
                      ? RssArticleFilterMode.unread
                      : RssArticleFilterMode.all,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: kTraditionalRssOrange,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.rss_feed_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Flexible(
                                  child: Text(
                                    'RSS Feeds & Writers',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                if (unreadCount > 0) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    key: const Key('rss_shelf_unread_badge'),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: kTraditionalRssOrange,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '$unreadCount unread',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subCount == 0
                                  ? 'Tap to subscribe to feeds, follow writers, or import OPML'
                                  : '$subCount ${subCount == 1 ? 'feed' : 'feeds'}'
                                      '${authorCount > 0 ? ' • $authorCount followed ${authorCount == 1 ? 'writer' : 'writers'}' : ''}'
                                      '${controller.starredCount > 0 ? ' • ${controller.starredCount} starred' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('rss_shelf_expand_button'),
                        tooltip: expanded ? 'Collapse RSS shelf' : 'Expand RSS shelf',
                        icon: Icon(
                          expanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                        ),
                        onPressed: () =>
                            controller.setShelfExpanded(!expanded),
                      ),
                    ],
                  ),
                ),
              ),
              if (expanded) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ActionChip(
                            avatar: const Icon(
                              Icons.mark_email_unread_outlined,
                              size: 16,
                            ),
                            label: Text('Unread ($unreadCount)'),
                            onPressed: () => onOpenRssHome(
                              initialMode: RssArticleFilterMode.unread,
                            ),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.article_outlined, size: 16),
                            label: Text(
                              'All (${controller.allArticles.where((a) => !a.isHidden).length})',
                            ),
                            onPressed: () => onOpenRssHome(
                              initialMode: RssArticleFilterMode.all,
                            ),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.star_outline_rounded, size: 16),
                            label: Text('Starred (${controller.starredCount})'),
                            onPressed: () => onOpenRssHome(
                              initialMode: RssArticleFilterMode.starred,
                            ),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.person_search_outlined, size: 16),
                            label: const Text('Writers'),
                            onPressed: onOpenAuthors,
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.auto_fix_high_outlined, size: 16),
                            label: Text('Rules (${controller.rules.length})'),
                            onPressed: onOpenRules,
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('Add Feed / OPML'),
                            onPressed: onOpenOpml,
                          ),
                        ],
                      ),
                      if (controller.followedAuthors.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          'FAVORITE WRITERS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final author in controller.followedAuthors)
                              _buildShelfPill(
                                context,
                                icon: Icons.person_outline_rounded,
                                label: author.name,
                                unread: controller.unreadCountForAuthor(author),
                                onTap: () => onOpenRssHome(
                                  initialMode: RssArticleFilterMode.all,
                                  authorId: author.id,
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (controller.folders.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          'FOLDERS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        for (final folder in controller.folders)
                          _buildFolderRow(context, folder),
                      ],
                      if (controller.subscriptions
                          .where((s) => s.folderId == null)
                          .isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'FEEDS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        for (final sub in controller.subscriptions
                            .where((s) => s.folderId == null))
                          _buildSubscriptionTile(context, sub),
                      ],
                      if (controller.subscriptions.isEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: onOpenAddFeed,
                              icon: const Icon(Icons.rss_feed_rounded, size: 18),
                              label: const Text('Add RSS Feed'),
                            ),
                            OutlinedButton.icon(
                              onPressed: onOpenOpml,
                              icon: const Icon(Icons.upload_file_outlined, size: 18),
                              label: const Text('Import OPML'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildFolderRow(BuildContext context, RssFolder folder) {
    final unread = controller.unreadCountForFolder(folder.id);
    final subsInFolder = controller.subscriptions
        .where((s) => s.folderId == folder.id)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onOpenRssHome(
            initialMode: RssArticleFilterMode.all,
            folderId: folder.id,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => controller.toggleFolderCollapsed(folder.id),
                  child: Icon(
                    folder.collapsed
                        ? Icons.folder_outlined
                        : Icons.folder_open_rounded,
                    size: 18,
                    color: kTraditionalRssOrange,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    folder.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ),
                if (unread > 0)
                  _buildUnreadCountBadge(unread),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                    folder.collapsed
                        ? Icons.chevron_right_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                  ),
                  onPressed: () => controller.toggleFolderCollapsed(folder.id),
                ),
              ],
            ),
          ),
        ),
        if (!folder.collapsed)
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: Column(
              children: [
                for (final sub in subsInFolder)
                  _buildSubscriptionTile(context, sub),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSubscriptionTile(BuildContext context, RssSubscription sub) {
    final unread = controller.unreadCountForSubscription(sub.id);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onOpenRssHome(
        initialMode: RssArticleFilterMode.all,
        subscriptionId: sub.id,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Row(
          children: [
            const Icon(
              Icons.rss_feed_rounded,
              size: 15,
              color: kTraditionalRssOrange,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                sub.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (sub.lastError != null)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 15,
                  color: Colors.amber,
                ),
              ),
            if (unread > 0) _buildUnreadCountBadge(unread),
          ],
        ),
      ),
    );
  }

  Widget _buildShelfPill(
    BuildContext context, {
    required IconData icon,
    required String label,
    required int unread,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: kTraditionalRssOrange),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            if (unread > 0) ...[
              const SizedBox(width: 6),
              _buildUnreadCountBadge(unread),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUnreadCountBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: kTraditionalRssOrange.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          color: kTraditionalRssOrange,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
