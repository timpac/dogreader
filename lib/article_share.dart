import 'package:flutter/services.dart';

import 'article_import.dart';

/// A separate channel keeps media-session ownership and commands untouched.
class ArticleShare {
  static const channel = MethodChannel('dogreader/article_share');
  static Future<void> listen(void Function(String) onText) async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText' && call.arguments is String) {
        onText(call.arguments as String);
      }
    });
    await takePending(onText);
  }

  static Future<void> takePending(void Function(String) onText) async {
    try {
      final initial = await channel.invokeListMethod<String>(
        'takePendingTexts',
      );
      for (final text in initial ?? <String>[]) {
        onText(text);
      }
    } on MissingPluginException {
      /* Non-Android test/desktop host. */
    }
  }

  static void stop() => channel.setMethodCallHandler(null);
}

final _webUrls = RegExp(
  r'''(?:^|[\s<("'\[“‘])(https?://[^\s<>"“”‘’\u0000-\u001f]+)''',
  caseSensitive: false,
);

String? sharedArticleUrl(String text) {
  final input = text.trim();
  for (final match in _webUrls.allMatches(input)) {
    var candidate = match[1]!;
    final prefix = match[0]![0];
    final startsLine =
        match[0] == candidate || prefix == '\n' || prefix == '\r';
    final endsLine =
        match.end == input.length || '\n\r'.contains(input[match.end]);
    // Strip punctuation from prose links, preserving URLs on their own line and
    // balanced parentheses inside paths such as Wikipedia article titles.
    if (!startsLine || !endsLine) {
      var end = candidate.length;
      while (end > 0 && ".,;!?'".contains(candidate[end - 1])) {
        end--;
      }
      if (prefix == '[' && end > 0 && candidate[end - 1] == ']') end--;
      if (end > 0 && candidate[end - 1] == ')') {
        var extraClosers =
            ')'.allMatches(candidate).length - '('.allMatches(candidate).length;
        while (extraClosers > 0 && candidate[end - 1] == ')') {
          end--;
          extraClosers--;
        }
      }
      candidate = candidate.substring(0, end);
    }
    try {
      return normalizedArticleUrl(articleUrl(candidate));
    } on ArticleImportException {
      // A share payload may contain other links before the public article URL.
    } on FormatException {
      // The candidate may contain invalid query encoding.
    }
  }
  return null;
}
