import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/freepress_login.dart';
import 'package:audiobook_app/app_identity.dart';
import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/article_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String capture({
  String url = 'https://www.thefp.com/p/fixture?token=discarded',
}) => jsonEncode({
  'url': url,
  'title': 'A complete essay',
  'blocks': [
    {
      'text': List.filled(120, 'Readable article words.').join(' '),
      'kind': 'paragraph',
    },
    {'text': 'The actual ending of this essay.', 'kind': 'paragraph'},
  ],
});

class MemoryArticleLibrary extends ArticleLibrary {
  MemoryArticleLibrary(super.documents);
  @override
  Future<void> load() async {}
  @override
  Future<ImportedArticle> saveDeviceArticle(ImportedArticle article) async {
    articles.add(article);
    return article;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dogreader/freepress');
  late Directory root;
  late ArticleLibrary library;
  final calls = <MethodCall>[];
  final opened = <ImportedArticle>[];

  setUp(() {
    root = Directory('/unused-freepress-widget-fixture');
    library = MemoryArticleLibrary(Future.value(root));
    calls.clear();
    opened.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return capture();
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    library.dispose();
  });

  Widget tile({String? url}) => MaterialApp(
    home: Scaffold(
      body: FreePressLoginTile(
        library: library,
        initialUrl: url,
        onOpenArticle: (article, _) => opened.add(article),
      ),
    ),
  );

  test(
    'canonical article URL never includes authentication queries or fragments',
    () {
      expect(
        freePressArticleUrl(
          'https://thefp.com/p/example/?token=secret#session',
        ),
        'https://www.thefp.com/p/example',
      );
      for (final url in [
        'https://substack.com/sign-in?token=secret',
        'https://www.thefp.com/account/login?token=secret',
        'http://www.thefp.com/p/example',
        'https://www.thefp.com.evil.test/p/example',
        'https://name@www.thefp.com/p/example',
      ]) {
        expect(freePressArticleUrl(url), isNull);
      }
    },
  );

  test('captures are bounded, article-only and distinct from existing preview identities', () {
    final article = parseFreePressCapture(capture());
    final preview = ImportedArticle(
      title: 'Preview',
      sourceUrl: article.sourceUrl,
      blocks: const [ArticleBlock('Preview only')],
    );
    expect(article.localRevision, isTrue);
    expect(article.id, isNot(preview.id));
    expect(article.id.length, preview.id.length);
    expect(article.sourceUrl, 'https://www.thefp.com/p/fixture');
    expect(article.sourceUrl, isNot(contains('token')));
    expect(ImportedArticle.fromJson(article.toJson()).id, article.id);
    expect(preview.toJson().containsKey('localRevision'), isFalse);
    final polluted = jsonDecode(capture()) as Map<String, dynamic>;
    polluted['cookies'] = 'not allowed';
    expect(
      () => parseFreePressCapture(jsonEncode(polluted)),
      throwsA(isA<ArticleImportException>()),
    );
    expect(
      () => parseFreePressCapture(
        '{"title":"Login","url":"https://www.thefp.com/account/login","blocks":[]}',
      ),
      throwsA(isA<ArticleImportException>()),
    );
  });

  test('saving full text preserves old article bytes, progress, audio and subscriptions', () async {
    root = await Directory.systemTemp.createTemp('freepress-preservation-');
    library.dispose();
    library = ArticleLibrary(Future.value(root));
    final full = parseFreePressCapture(capture());
    final preview = ImportedArticle(
      title: 'Preview',
      sourceUrl: full.sourceUrl,
      blocks: const [ArticleBlock('Original preview')],
    );
    final store = await library.store;
    await store.save(preview);
    final fixtures = <String, String>{
      'reading_state.json': 'saved position 123',
      'rss/subscriptions.json': 'existing feeds',
      'audio/old.mp3': 'existing audio',
    };
    for (final entry in fixtures.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final oldPath = File('${store.directory.path}/${preview.id}.json');
    final oldBytes = await oldPath.readAsBytes();
    final saves = await Future.wait([
      library.saveDeviceArticle(full),
      library.saveDeviceArticle(full),
    ]);
    expect(saves[0].id, saves[1].id);
    expect(await oldPath.readAsBytes(), oldBytes);
    for (final entry in fixtures.entries) {
      expect(
        await File('${root.path}/${entry.key}').readAsString(),
        entry.value,
      );
    }
    final reloaded = ArticleLibrary(Future.value(root));
    await reloaded.load();
    expect(reloaded.articles.length, 2);
    expect(reloaded.deviceArticleForUrl(full.sourceUrl)?.text, full.text);
    expect(
      reloaded
          .deviceArticleForUrl(
            '${full.sourceUrl}?publication_id=12&utm_source=rss',
          )
          ?.id,
      full.id,
    );
    expect(
      reloaded.articles.singleWhere((a) => a.id == preview.id).text,
      preview.text,
    );
    reloaded.dispose();
    await root.delete(recursive: true);
  });

  if (!dogreaderExperimental) {
    testWidgets('original app has no Free Press entry', (tester) async {
      await tester.pumpWidget(tile());
      expect(find.byType(ListTile), findsNothing);
      expect(calls, isEmpty);
    });
    return;
  }

  testWidgets(
    'capture saves locally and immediately opens the ordinary reader',
    (tester) async {
      library.dispose();
      library = MemoryArticleLibrary(Future.value(root));
      await tester.pumpWidget(
        tile(url: 'https://www.thefp.com/p/fixture?token=discarded'),
      );
      await tester.tap(find.text('The Free Press: sign in and import'));
      await tester.pumpAndSettle();
      expect(calls.single.method, 'openArticle');
      expect(calls.single.arguments, {
        'url': 'https://www.thefp.com/p/fixture',
      });
      expect(opened.single.id, library.articles.single.id);
      expect(opened.single.localRevision, isTrue);
      // Subsequent reading is offline, with no further native browser call.
      await tester.tap(find.text('The Free Press: sign in and import'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      expect(opened.length, 2);
    },
  );

  testWidgets(
    'cancel and native errors do not save anything or reveal details',
    (tester) async {
      library.dispose();
      library = MemoryArticleLibrary(Future.value(root));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      await tester.pumpWidget(tile());
      await tester.tap(find.text('The Free Press: sign in and import'));
      await tester.pumpAndSettle();
      expect(library.articles, isEmpty);
      expect(opened, isEmpty);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'failed', message: 'private detail');
          });
      await tester.tap(find.text('The Free Press: sign in and import'));
      await tester.pumpAndSettle();
      expect(find.textContaining('private detail'), findsNothing);
      expect(
        find.text(
          'The article importer could not open or save this article. Please try again.',
        ),
        findsOneWidget,
      );
      expect(library.articles, isEmpty);
    },
  );
}
