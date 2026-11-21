import 'dart:io';

import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/article_library.dart';
import 'package:audiobook_app/article_screen.dart';
import 'package:audiobook_app/article_share.dart';
import 'package:audiobook_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'article_import_test.dart' show fixture;

class SingleArticleFetcher extends ArticleFetcher {
  final calls = <String>[];
  @override
  Future<ImportedArticle> fetch(String url) async {
    calls.add(url);
    if (url.endsWith('/restricted')) {
      throw const ArticleAccessException('This article requires sign-in.');
    }
    return fixture();
  }
}

Future<void> settleImports(WidgetTester tester, ArticleLibrary library) async {
  await tester.pump();
  for (
    var i = 0;
    i < 50 &&
        library.jobs.any(
          (j) => j.status == 'Waiting' || j.status == 'Importing',
        );
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    library.jobs.where((j) => j.status == 'Waiting' || j.status == 'Importing'),
    isEmpty,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('manual paste saves an offline original and reuses it', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('article-entry-'),
    ))!;
    final fetcher = SingleArticleFetcher();
    final library = ArticleLibrary(Future.value(root), fetcher: fetcher);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return {
          'text':
              'A careful trial\nhttps://example.org/trial?utm_source=chrome',
        };
      }
      return null;
    });
    final opened = <(ImportedArticle, bool)>[];

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ArticleImportScreen(
            library: library,
            openArticle: (article, narration) =>
                opened.add((article, narration)),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Paste article URL'));
      await tester.pump();
      expect(
          find.text('https://example.org/trial'),
        findsOneWidget,
      );
      expect(fetcher.calls, isEmpty);
      await tester.tap(find.text('Import article'));
      await settleImports(tester, library);

      await tester.enterText(
        find.byType(TextField),
        'https://example.org/trial#paragraph',
      );
      await tester.tap(find.text('Import article'));
      await settleImports(tester, library);
      expect(fetcher.calls, ['https://example.org/trial']);
      expect(library.jobs.single.status, 'Saved');
      final saved = library.articles.single;
      expect(saved.toJson(), fixture().toJson());
      final restored = (await tester.runAsync(
        () async => (await library.store).load(),
      ))!;
      expect(restored.single.toJson(), saved.toJson());

      final read = find.widgetWithText(TextButton, 'Read');
      await tester.ensureVisible(read);
      await tester.tap(read);
      expect(opened, [(saved, false)]);
    } finally {
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      library.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });

  testWidgets('cold, warm and reattached shares import automatically', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('article-share-'),
    ))!;
    final fetcher = SingleArticleFetcher();
    final library = ArticleLibrary(Future.value(root), fetcher: fetcher);
    final messenger = tester.binding.defaultBinaryMessenger;
    final pending = ['A careful trial\nhttps://example.org/trial'];
    messenger.setMockMethodCallHandler(ArticleShare.channel, (_) async {
      final batch = pending.toList();
      pending.clear();
      return batch;
    });
    Future<void> share(String text) async {
      await messenger.handlePlatformMessage(
        ArticleShare.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('sharedText', text),
        ),
        (_) {},
      );
    }

    try {
      await tester.pumpWidget(
        MaterialApp(home: LibraryScreen(articleLibrary: library)),
      );
      await settleImports(tester, library);
      expect(find.byType(ArticleImportScreen), findsOneWidget);
      expect(library.jobs.single.status, 'Saved');

      await share('From Chrome (https://example.org/trial?utm_source=chrome).');
      await settleImports(tester, library);
      expect(library.jobs.length, 1);
      expect(fetcher.calls, ['https://example.org/trial']);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ArticleImportScreen), findsNothing);
      expect(
        find.widgetWithText(OutlinedButton, 'Import a web article'),
        findsOneWidget,
      );

      await share('Text without a web address');
      await tester.pumpAndSettle();
      expect(find.byType(ArticleImportScreen), findsNothing);
      expect(find.textContaining('Share a public article URL'), findsOneWidget);

      await share('https://example.org/restricted');
      await settleImports(tester, library);
      expect(find.byType(ArticleImportScreen), findsOneWidget);
      expect(find.text('This article requires sign-in.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      expect(library.articles.length, 1);
      expect(fetcher.calls, [
        'https://example.org/trial',
        'https://example.org/restricted',
      ]);

      await tester.pageBack();
      await tester.pumpAndSettle();
      pending.add('https://example.org/trial');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settleImports(tester, library);
      expect(pending, isEmpty);
      expect(find.byType(ArticleImportScreen), findsOneWidget);
      expect(library.articles.length, 1);
      expect(fetcher.calls.length, 2);
    } finally {
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(ArticleShare.channel, null);
      library.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
