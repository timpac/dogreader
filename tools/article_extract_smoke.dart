// Extract a previously downloaded small HTML page. No network or AI calls.
import 'dart:io';

import 'package:audiobook_app/article_import.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tools/article_extract_smoke.dart HTML_FILE SOURCE_URL',
    );
    exitCode = 64;
    return;
  }
  final article = extractArticle(
    File(args[0]).readAsStringSync(),
    articleUrl(args[1]),
  );
  stdout.writeln(
    '${article.title}: ${article.blocks.length} blocks, ${article.text.length} characters',
  );
}
