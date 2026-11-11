import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'article_import.dart';

/// Uses user-configured narration credentials read-only. No provider key in APK.
/// Additive backend contract is prepared in backend_proposal, pending coordination.
class ArticleSummaryClient {
  ArticleSummaryClient(this.documents);
  final Directory documents;
  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final settings = File('${documents.path}/dogreader_queue.json');
    if (!await settings.exists()) {
      throw const ArticleImportException(
        'Connect Dogreader Cloud in the narration screen before requesting summaries.',
      );
    }
    Map<String, dynamic> config;
    try {
      final value = jsonDecode(await settings.readAsString());
      if (value is! Map<String, dynamic>) throw const FormatException();
      config = value;
    } on FormatException {
      throw const ArticleImportException(
        'Cloud settings could not be read. Reconnect Dogreader Cloud in the narration screen.',
      );
    } on FileSystemException {
      throw const ArticleImportException(
        'Cloud settings could not be opened. Reconnect Dogreader Cloud in the narration screen.',
      );
    }
    final host = Uri.tryParse(config['host'] as String? ?? '');
    final token = config['token'] as String? ?? '';
    if (host == null ||
        host.scheme != 'https' ||
        host.host.isEmpty ||
        host.userInfo.isNotEmpty ||
        token.isEmpty) {
      throw const ArticleImportException(
        'Configure a valid HTTPS Dogreader Cloud connection in the narration screen.',
      );
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      return await (() async {
        final req = await client.postUrl(Uri.parse('${host.origin}$path'));
        req.followRedirects =
            false; // Never forward the access token to redirects.
        req.headers.set('X-Dogreader-Token', token);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(payload));
        final response = await req.close();
        if ({404, 405, 501}.contains(response.statusCode)) {
          throw const ArticleImportException(
            'AI summaries are not enabled on this server yet. The original article is saved and readable.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 1024 * 1024) {
            throw const ArticleImportException(
              'The summary server returned an oversized response.',
            );
          }
        }
        final result = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (response.statusCode >= 300) {
          throw ArticleImportException(
            result['error'] as String? ??
                'The summary server could not complete this request.',
          );
        }
        return result;
      })().timeout(const Duration(seconds: 100));
    } on TimeoutException {
      throw const ArticleImportException(
        'Summary request timed out. Retry to check the same request; Dogreader will not intentionally create a second summary charge.',
      );
    } on SocketException {
      throw const ArticleImportException(
        'Cannot reach the summary server. The original article remains saved.',
      );
    } on FormatException {
      throw const ArticleImportException(
        'The summary server returned an unsupported response.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> estimate(
    ImportedArticle article,
    SummaryDepth depth,
  ) => _request('/dogreader/article-summaries/estimate', {
    'text': article.text,
    'depth': depth.name,
  });

  Future<ImportedArticle> summarize(
    ImportedArticle article,
    SummaryDepth depth,
  ) async {
    final result = await _request('/dogreader/article-summaries', {
      'text': article.text,
      'depth': depth.name,
      'contentHash': article.contentHash,
    });
    final text = result['summary'] as String? ?? '';
    if (text.trim().length < 100 || text.length > 50000) {
      throw const ArticleImportException(
        'The server did not return a complete readable summary. The original article remains saved.',
      );
    }
    return ImportedArticle(
      title: article.title,
      sourceUrl: article.sourceUrl,
      author: article.author,
      published: article.published,
      depth: depth,
      originalId: article.id,
      usage: (result['usage'] as Map?)?.cast<String, dynamic>(),
      blocks: text
          .trim()
          .split(RegExp(r'\n\s*\n'))
          .where((p) => p.trim().isNotEmpty)
          .map((p) => ArticleBlock(p.trim()))
          .toList(),
    );
  }
}
