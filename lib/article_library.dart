import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'article_import.dart';
import 'article_summary.dart';

class ArticleImportJob {
  ArticleImportJob(this.url);
  final String url;
  String status = 'Waiting';
  ImportedArticle? article;
  String? error;
}

class ArticleLibrary extends ChangeNotifier {
  ArticleLibrary(
    this.documents, {
    ArticleFetcher? fetcher,
    this.summariesEnabled = articleSummariesEnabled,
  }) : fetcher = fetcher ?? ArticleFetcher();
  final Future<Directory> documents;
  final ArticleFetcher fetcher;
  final bool summariesEnabled;
  final List<ImportedArticle> articles = [];
  final List<ArticleImportJob> jobs = [];
  final Map<String, Future<ImportedArticle>> _summaries = {};
  Future<void> _pending = Future.value();
  bool _disposed = false;
  Future<void>? _loaded;
  Future<ArticleStore> get store async =>
      ArticleStore(Directory('${(await documents).path}/articles'));
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() => _loaded ??= (() async {
    articles.addAll(await (await store).load());
    notifyListeners();
  })();

  ImportedArticle? _savedArticle(Uri url) => articles.where((article) {
    if (article.depth != null) return false;
    return [article.sourceUrl, article.originalUrl].whereType<String>().any((
      savedUrl,
    ) {
      final saved = Uri.tryParse(savedUrl);
      if (saved == null) return false;
      try {
        return sameArticleUrl(saved, url);
      } on ArticleImportException {
        return false;
      } on FormatException {
        return false;
      }
    });
  }).firstOrNull;

  ArticleImportJob enqueue(String value) {
    final uri = articleUrl(value);
    final url = normalizedArticleUrl(uri);
    final existing = jobs
        .where((j) => j.url == url && j.error == null)
        .firstOrNull;
    if (existing != null) return existing;
    final job = ArticleImportJob(url);
    jobs.add(job);
    notifyListeners();
    _pending = _pending.catchError((Object _) {}).then((_) async {
      try {
        await load();
        job.status = 'Importing';
        notifyListeners();
        var article = _savedArticle(uri);
        if (article == null) {
          final fetched = await fetcher.fetch(url);
          article = _savedArticle(Uri.parse(fetched.sourceUrl));
          if (article == null) {
            await (await store).save(fetched);
            articles.add(fetched);
            article = fetched;
          }
        }
        job.article = article;
        job.status = 'Saved';
      } catch (error) {
        job.status = 'Could not import';
        job.error = error is ArticleImportException
            ? error.message
            : 'This article could not be imported or saved. Please try again.';
      }
      notifyListeners();
    });
    return job;
  }

  Future<void> get settled => _pending;
  ImportedArticle? savedSummary(ImportedArticle article, SummaryDepth depth) {
    final matches = articles
        .where(
          (a) =>
              a.originalId == article.id &&
              a.depth == depth &&
              (a.originalContentHash == null ||
                  a.originalContentHash == article.contentHash),
        )
        .toList();
    if (matches.isEmpty) return null;
    return matches.last;
  }

  Future<Map<String, dynamic>> estimate(
    ImportedArticle article,
    SummaryDepth depth,
  ) async {
    if (!summariesEnabled) {
      throw const ArticleImportException(articleSummariesDisabledMessage);
    }
    return ArticleSummaryClient(
      await documents,
      enabled: summariesEnabled,
    ).estimate(article, depth);
  }

  Future<ImportedArticle> summarize(
    ImportedArticle article,
    SummaryDepth depth, {
    bool forceRegenerate = false,
  }) {
    if (!forceRegenerate) {
      final saved = savedSummary(article, depth);
      if (saved != null) return Future.value(saved);
    }
    if (!summariesEnabled) {
      return Future.error(
        const ArticleImportException(articleSummariesDisabledMessage),
      );
    }
    final key =
        '${article.id}:${article.contentHash}:${depth.name}:${forceRegenerate ? DateTime.now().microsecondsSinceEpoch : ""}';
    return _summaries.putIfAbsent(key, () async {
      try {
        final result = await ArticleSummaryClient(
          await documents,
          enabled: summariesEnabled,
        ).summarize(article, depth);
        await (await store).save(result);
        articles.removeWhere(
          (a) =>
              a.originalId == article.id &&
              a.depth == depth &&
              (a.originalContentHash == null ||
                  a.originalContentHash == article.contentHash),
        );
        articles.add(result);
        notifyListeners();
        return result;
      } finally {
        _summaries.remove(key);
      }
    });
  }

  Future<ImportedArticle> regenerateSummary(
    ImportedArticle article,
    SummaryDepth depth,
  ) => summarize(article, depth, forceRegenerate: true);
}
