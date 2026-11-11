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

  ArticleImportJob enqueue(String value) {
    final url = normalizedArticleUrl(articleUrl(value));
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
        var article = articles
            .where((a) => a.depth == null && a.sourceUrl == url)
            .firstOrNull;
        if (article == null) {
          final fetched = await fetcher.fetch(url);
          article = articles.where((a) => a.id == fetched.id).firstOrNull;
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
  ImportedArticle? savedSummary(ImportedArticle article, SummaryDepth depth) =>
      articles
          .where(
            (a) =>
                a.originalId == article.id &&
                a.depth == depth &&
                (a.originalContentHash == null ||
                    a.originalContentHash == article.contentHash),
          )
          .firstOrNull;
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
    SummaryDepth depth,
  ) {
    final saved = savedSummary(article, depth);
    if (saved != null) return Future.value(saved);
    if (!summariesEnabled) {
      return Future.error(
        const ArticleImportException(articleSummariesDisabledMessage),
      );
    }
    final key = '${article.id}:${article.contentHash}:${depth.name}';
    return _summaries.putIfAbsent(key, () async {
      try {
        final result = await ArticleSummaryClient(
          await documents,
          enabled: summariesEnabled,
        ).summarize(article, depth);
        await (await store).save(result);
        articles.add(result);
        notifyListeners();
        return result;
      } finally {
        _summaries.remove(key);
      }
    });
  }
}
