import 'package:flutter/services.dart';

/// A separate channel keeps media-session ownership and commands untouched.
class ArticleShare {
  static const channel = MethodChannel('dogreader/article_share');
  static Future<void> listen(void Function(String) onText) async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText' && call.arguments is String) {
        onText(call.arguments as String);
      }
    });
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

String? sharedArticleUrl(String text) =>
    RegExp(r'https?://[^\s<>"\u0000-\u001f]+').firstMatch(text)?.group(0);
