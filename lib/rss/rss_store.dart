import 'dart:convert';
import 'dart:io';

import 'rss_models.dart';
import 'rss_rules.dart';

class RssStateSnapshot {
  const RssStateSnapshot({
    this.schemaVersion = currentSchemaVersion,
    this.shelfExpanded = false,
    this.folders = const [],
    this.subscriptions = const [],
    this.followedAuthors = const [],
    this.rules = const [],
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final bool shelfExpanded;
  final List<RssFolder> folders;
  final List<RssSubscription> subscriptions;
  final List<FollowedAuthor> followedAuthors;
  final List<FeedRule> rules;

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'shelfExpanded': shelfExpanded,
        'folders': [for (final f in folders) f.toJson()],
        'subscriptions': [for (final s in subscriptions) s.toJson()],
        'followedAuthors': [for (final a in followedAuthors) a.toJson()],
        'rules': [for (final r in rules) r.toJson()],
      };

  static RssStateSnapshot fromJson(Map<String, Object?> json) {
    final version = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    return RssStateSnapshot(
      schemaVersion: version < currentSchemaVersion ? currentSchemaVersion : version,
      shelfExpanded: json['shelfExpanded'] as bool? ?? false,
      folders: [
        for (final item in json['folders'] as List<Object?>? ?? const [])
          if (item is Map) RssFolder.fromJson(item.cast<String, Object?>()),
      ],
      subscriptions: [
        for (final item in json['subscriptions'] as List<Object?>? ?? const [])
          if (item is Map) RssSubscription.fromJson(item.cast<String, Object?>()),
      ],
      followedAuthors: [
        for (final item in json['followedAuthors'] as List<Object?>? ?? const [])
          if (item is Map) FollowedAuthor.fromJson(item.cast<String, Object?>()),
      ],
      rules: [
        for (final item in json['rules'] as List<Object?>? ?? const [])
          if (item is Map) FeedRule.fromJson(item.cast<String, Object?>()),
      ],
    );
  }
}

/// Durable, atomic local storage for RSS subscriptions, folders, followed
/// authors, natural-language rules, and cached offline articles.
class RssStore {
  RssStore(this._rootDirectory);

  final Future<Directory> _rootDirectory;
  Future<void> _writeQueue = Future<void>.value();

  Future<Directory> _rssDir() async {
    final root = await _rootDirectory;
    final dir = Directory('${root.path}/rss');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _articlesDir() async {
    final rss = await _rssDir();
    final dir = Directory('${rss.path}/articles');
    await dir.create(recursive: true);
    return dir;
  }

  Future<RssStateSnapshot> loadState() async {
    try {
      final rss = await _rssDir();
      final file = File('${rss.path}/state_v1.json');
      if (!await file.exists()) {
        return const RssStateSnapshot();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return RssStateSnapshot.fromJson(decoded.cast<String, Object?>());
      }
    } catch (_) {
      // Recover gracefully with empty state if state file is unreadable.
    }
    return const RssStateSnapshot();
  }

  Future<void> saveState(RssStateSnapshot snapshot) {
    final encoded = jsonEncode(snapshot.toJson());
    _writeQueue = _writeQueue.catchError((Object _) {}).then((_) async {
      final rss = await _rssDir();
      final target = File('${rss.path}/state_v1.json');
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(target.path);
    });
    return _writeQueue;
  }

  Future<List<RssArticle>> loadArticles() async {
    final dir = await _articlesDir();
    final loaded = <RssArticle>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = await entity.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final article = RssArticle.fromJson(decoded.cast<String, Object?>());
          if (article.id.isNotEmpty) {
            loaded.add(article);
          }
        }
      } catch (_) {
        // Ignore corrupted individual article files.
      }
    }
    loaded.sort(_compareArticles);
    return loaded;
  }

  Future<void> saveArticle(RssArticle article) {
    final safeId = _safeFileId(article.id);
    final encoded = jsonEncode(article.toJson());
    _writeQueue = _writeQueue.catchError((Object _) {}).then((_) async {
      final dir = await _articlesDir();
      final target = File('${dir.path}/$safeId.json');
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(target.path);
    });
    return _writeQueue;
  }

  Future<void> saveArticlesBatch(Iterable<RssArticle> articles) {
    final entries = <String, String>{
      for (final a in articles) _safeFileId(a.id): jsonEncode(a.toJson()),
    };
    if (entries.isEmpty) return Future<void>.value();
    _writeQueue = _writeQueue.catchError((Object _) {}).then((_) async {
      final dir = await _articlesDir();
      for (final entry in entries.entries) {
        final target = File('${dir.path}/${entry.key}.json');
        final tmp = File('${target.path}.tmp');
        await tmp.writeAsString(entry.value, flush: true);
        await tmp.rename(target.path);
      }
    });
    return _writeQueue;
  }

  Future<void> deleteArticle(String articleId) {
    final safeId = _safeFileId(articleId);
    _writeQueue = _writeQueue.catchError((Object _) {}).then((_) async {
      final dir = await _articlesDir();
      for (final suffix in const ['.json', '.json.tmp']) {
        final file = File('${dir.path}/$safeId$suffix');
        if (await file.exists()) await file.delete();
      }
    });
    return _writeQueue;
  }

  static String _safeFileId(String id) {
    final sanitized = id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? 'rss_item' : sanitized;
  }

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
