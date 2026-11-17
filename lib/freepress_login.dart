import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_identity.dart';
import 'article_import.dart';
import 'article_library.dart';

typedef OpenFreePressArticle = void Function(
  ImportedArticle article,
  bool narration,
);

/// This intentionally discards every query/fragment, including any auth token.
String? freePressArticleUrl(String value) {
  final uri = Uri.tryParse(value);
  if (value.length > 8192 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443) ||
      !{'thefp.com', 'www.thefp.com'}.contains(uri.host.toLowerCase()) ||
      !RegExp(r'^/(?:p|cp)/[A-Za-z0-9_-]+/?$').hasMatch(uri.path)) {
    return null;
  }
  return 'https://www.thefp.com${uri.path.replaceFirst(RegExp(r'/$'), '')}';
}

/// The native side returns only rendered article blocks and a public URL. Reject
/// malformed captures rather than persisting raw browser data or error details.
ImportedArticle parseFreePressCapture(
  String payload, {
  String? author,
  String? published,
}) {
  const invalid = ArticleImportException(
    'The complete article could not be imported. Open the paid article and try again.',
  );
  if (payload.length > 220000) throw invalid;
  try {
    final value = jsonDecode(payload) as Map<String, dynamic>;
    if (value.keys.any((key) => !{'url', 'title', 'blocks'}.contains(key))) {
      throw invalid;
    }
    final url = freePressArticleUrl(value['url'] as String);
    final title = (value['title'] as String).trim();
    final rows = value['blocks'] as List;
    if (url == null ||
        title.isEmpty ||
        title.length > 500 ||
        rows.length > 1500) {
      throw invalid;
    }
    final blocks = <ArticleBlock>[];
    var size = 0;
    for (final row in rows) {
      final data = Map<String, dynamic>.from(row as Map);
      if (data.keys.any((key) => !{'text', 'kind'}.contains(key))) {
        throw invalid;
      }
      final text = (data['text'] as String).trim();
      final kind = data['kind'] as String;
      if (text.isEmpty ||
          !{'paragraph', 'heading', 'list', 'quote', 'break'}.contains(kind)) {
        throw invalid;
      }
      size += text.length;
      blocks.add(ArticleBlock(text, kind: kind, heading: kind == 'heading'));
    }
    if (size < 500 ||
        size > 180000 ||
        blocks.map((b) => b.text).join(' ').split(RegExp(r'\s+')).length <
            100) {
      throw invalid;
    }
    return ImportedArticle(
      title: '$title — Full article',
      sourceUrl: url,
      publication: 'The Free Press',
      author: author,
      published: published,
      blocks: blocks,
      localRevision: true,
    );
  } catch (_) {
    throw invalid;
  }
}

Future<void> openFreePressArticle(
  BuildContext context, {
  required ArticleLibrary library,
  required OpenFreePressArticle onOpenArticle,
  String? initialUrl,
  bool useSaved = true,
  String? author,
  String? published,
}) async {
  if (!dogreaderExperimental) return;
  try {
    final url = initialUrl == null ? null : freePressArticleUrl(initialUrl);
    if (initialUrl != null && url == null) {
      throw const ArticleImportException('Choose a Free Press article URL.');
    }
    await library.load();
    if (!context.mounted) return;
    if (url != null && useSaved) {
      final saved = library.deviceArticleForUrl(url);
      if (saved != null) {
        onOpenArticle(saved, false);
        return;
      }
    }
    final payload = await const MethodChannel('dogreader/freepress')
        .invokeMethod<String>('openArticle', url == null ? null : {'url': url});
    if (payload == null) return; // Closing or cancelling saves nothing.
    final article = await library.saveDeviceArticle(
      parseFreePressCapture(payload, author: author, published: published),
    );
    if (context.mounted) onOpenArticle(article, false);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is ArticleImportException ? error.message : 'The article importer could not open or save this article. Please try again.',
          ),
        ),
      );
    }
  }
}

class FreePressLoginTile extends StatelessWidget {
  const FreePressLoginTile({
    super.key,
    required this.library,
    required this.onOpenArticle,
    this.initialUrl,
  });
  final ArticleLibrary library;
  final OpenFreePressArticle onOpenArticle;
  final String? initialUrl;

  @override
  Widget build(BuildContext context) => dogreaderExperimental
      ? ListTile(
          leading: const Icon(Icons.article_outlined),
          title: const Text('The Free Press: sign in and import'),
          subtitle: const Text(
            'Use your subscription, then save full text to DogReader. '
            'Your login stays on this device. Chrome login is separate.',
          ),
          onTap: () => openFreePressArticle(
            context,
            library: library,
            onOpenArticle: onOpenArticle,
            initialUrl: freePressArticleUrl(initialUrl ?? ''),
          ),
        )
      : const SizedBox.shrink();
}
