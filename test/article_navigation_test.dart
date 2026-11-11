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
  int calls = 0;
  @override
  Future<ImportedArticle> fetch(String url) async {
    calls++;
    return fixture();
  }
}

void main() {
  testWidgets(
    'shared prefill and pasted URL use the same deduplicating import pipeline',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('article-entry-'),
      ))!;
      final fetcher = SingleArticleFetcher();
      final library = ArticleLibrary(Future.value(root), fetcher: fetcher);
      Future<void> settleImport() async {
        for (
          var i = 0;
          i < 50 &&
              library.jobs.any(
                (j) => j.status == 'Waiting' || j.status == 'Importing',
              );
          i++
        ) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        expect(library.jobs.single.status, 'Saved');
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ArticleImportScreen(
              initialUrl: 'https://example.org/trial?utm_source=chrome',
              library: library,
              openArticle: (_, _) {},
            ),
          ),
        );
        await tester.tap(find.text('Import article'));
        await settleImport();
        await tester.enterText(
          find.byType(TextField),
          'https://example.org/trial#paragraph',
        );
        await tester.tap(find.text('Import article'));
        await settleImport();
        expect(fetcher.calls, 1);
        expect(library.jobs.length, 1);
        expect(library.articles.single.text, fixture().text);
        expect(
          (await tester.runAsync(() async => (await library.store).load()))!
              .length,
          1,
        );
        await tester.pumpWidget(const SizedBox());
      } finally {
        library.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'library routes cold and idle warm shares to a prefilled import screen',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        ArticleShare.channel,
        (_) async => ['https://example.org/cold'],
      );
      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await tester.pumpAndSettle();
      expect(find.byType(ArticleImportScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://example.org/cold',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      await messenger.handlePlatformMessage(
        ArticleShare.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall(
            'sharedText',
            'From Chrome https://example.org/warm',
          ),
        ),
        (_) {},
      );
      // A method-channel callback must wake an idle UI, not wait for a tap/reflow.
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(ArticleImportScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://example.org/warm',
      );
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(ArticleShare.channel, null);
    },
  );
}
