import 'dart:io';

import 'package:audiobook_app/rss/rss_authors.dart';
import 'package:audiobook_app/rss/rss_controller.dart';
import 'package:audiobook_app/rss/rss_extractor.dart';
import 'package:audiobook_app/rss/rss_models.dart';
import 'package:audiobook_app/rss/rss_opml.dart';
import 'package:audiobook_app/rss/rss_parser.dart';
import 'package:audiobook_app/rss/rss_rules.dart';
import 'package:audiobook_app/rss/rss_shelf.dart';
import 'package:audiobook_app/rss/rss_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _kSampleRss2Xml = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:content="http://purl.org/rss/1.0/modules/content/"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>The Free Press</title>
    <link>https://www.thefp.com</link>
    <description>Independent journalism and essays.</description>
    <item>
      <title>Why Cultural Pessimism Misses the Mark</title>
      <link>https://www.thefp.com/p/cultural-pessimism?utm_source=rss</link>
      <guid isPermaLink="false">fp-post-101</guid>
      <dc:creator>Ross G. Douthat</dc:creator>
      <pubDate>Mon, 16 Nov 2026 14:30:00 GMT</pubDate>
      <description>A short summary of the essay on cultural institutions.</description>
      <content:encoded><![CDATA[
        <h2>The State of Modern Institutions</h2>
        <p>Across the last decade, commentators have argued that institutional renewal is impossible in an era of digital fragmentation and hyper-partisan media incentives. Yet historical precedent suggests that periods of technological disruption routinely precede institutional reform.</p>
        <blockquote>Renewal rarely begins at the center; it begins in smaller communities of writers and readers who value serious argument.</blockquote>
        <p>Consider three concrete developments that point toward a healthier intellectual culture in the coming years:</p>
        <ul>
          <li>Independent publications allow individual writers to build direct relationships with long-form readers.</li>
          <li>Audio narration makes long essays accessible during commutes and daily walks.</li>
        </ul>
        <p>When readers deliberately curate a small collection of thoughtful voices rather than scrolling algorithmic feeds, the quality of public discourse improves substantially and durably.</p>
      ]]></content:encoded>
    </item>
    <item>
      <title>AI Governance and Open Science</title>
      <link>https://www.thefp.com/p/ai-governance-open-science</link>
      <guid isPermaLink="false">fp-post-102</guid>
      <dc:creator>Coleman Hughes</dc:creator>
      <pubDate>Tue, 17 Nov 2026 09:00:00 GMT</pubDate>
      <description><![CDATA[<p>This is only a brief teaser paragraph about AI policy. Continue reading...</p>]]></description>
    </item>
    <item>
      <title>Notes on European History (Subscriber Exclusive)</title>
      <link>https://www.thefp.com/p/notes-european-history</link>
      <guid isPermaLink="false">fp-post-103</guid>
      <dc:creator>Douglas Murray</dc:creator>
      <pubDate>Tue, 17 Nov 2026 11:00:00 GMT</pubDate>
      <description><![CDATA[<p>Opening preview paragraph. This post is for paid subscribers only.</p>]]></description>
    </item>
  </channel>
</rss>''';

const String _kSampleAtomXml = '''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Slow Thought Essays</title>
  <subtitle>Long-form analysis</subtitle>
  <link href="https://slowthought.example.com/" rel="alternate"/>
  <link href="https://slowthought.example.com/atom.xml" rel="self"/>
  <entry>
    <title>The Architecture of Calm Software</title>
    <link href="https://slowthought.example.com/posts/calm-software" rel="alternate"/>
    <id>tag:slowthought.example.com,2026:calm-software</id>
    <published>2026-11-15T18:00:00Z</published>
    <author>
      <name>Ross Douthat and Coleman Hughes</name>
    </author>
    <summary>Why calm, local-first software respects human attention.</summary>
    <content type="html"><![CDATA[
      <p>Software tools should serve the reader's deliberate habits rather than competing for constant notifications or engagement metrics. A good RSS and book reader stays quiet until opened.</p>
      <p>By combining structured feed organization with distraction-free typography and offline caching, a reader can follow a dozen favorite writers without algorithmic noise or endless scrolling.</p>
      <p>Local-first storage also guarantees that reading positions, starred essays, and downloaded narration remain available on an airplane or subway with zero network latency.</p>
    ]]></content>
  </entry>
</feed>''';

const String _kFullExtractedWebpageHtml = '''<!doctype html>
<html>
<head>
  <title>AI Governance and Open Science</title>
  <meta name="author" content="Coleman Hughes">
  <link rel="canonical" href="https://www.thefp.com/p/ai-governance-open-science">
</head>
<body>
  <article>
    <h1>AI Governance and Open Science</h1>
    <p>Open scientific inquiry has historically been the strongest safeguard against concentrated technological power. When researchers can inspect weights, benchmarks, and evaluation methodologies, flaws are discovered rapidly.</p>
    <p>Regulatory frameworks that criminalize open-weight research risk entrenching a small cartel of incumbent labs while doing little to prevent misuse by sophisticated state actors.</p>
    <p>A balanced approach focuses on rigorous evaluation standards, transparency around training compute, and clear liability for downstream harmful actions rather than licensing basic mathematics.</p>
  </article>
</body>
</html>''';

const String _kPaywalledWebpageHtml = '''<!doctype html>
<html>
<head>
  <title>Subscriber Deep Dive</title>
  <script type="application/ld+json">
  {"@context":"https://schema.org","@type":"NewsArticle","headline":"Subscriber Deep Dive","isAccessibleForFree":false}
  </script>
</head>
<body>
  <article>
    <p>Short public intro.</p>
    <div class="paywall">Subscribe to continue reading this article.</div>
  </article>
</body>
</html>''';

void main() {
  group('RSS 2.0, Atom Parsing, and Feed Discovery', () {
    test('parses RSS 2.0 channel metadata, entries, formatting, and content status', () {
      final feed = RssParser.parseFeedXml(
        _kSampleRss2Xml,
        feedUrl: Uri.parse('https://www.thefp.com/feed'),
      );

      expect(feed.title, 'The Free Press');
      expect(feed.siteUrl, 'https://www.thefp.com');
      expect(feed.entries.length, 3);

      final first = feed.entries[0];
      expect(first.title, 'Why Cultural Pessimism Misses the Mark');
      expect(first.canonicalUrl, 'https://www.thefp.com/p/cultural-pessimism');
      expect(first.author, 'Ross G. Douthat');
      expect(first.normalizedAuthors, contains('ross douthat'));
      expect(first.contentStatus, ArticleContentStatus.full);
      expect(first.blocks.any((b) => b.heading), isTrue);
      expect(first.blocks.any((b) => b.kind == 'quote'), isTrue);
      expect(first.blocks.any((b) => b.kind == 'list'), isTrue);

      final second = feed.entries[1];
      expect(second.title, 'AI Governance and Open Science');
      expect(second.contentStatus, ArticleContentStatus.previewOnly);
      expect(second.statusReason, isNotNull);

      final third = feed.entries[2];
      expect(third.contentStatus, ArticleContentStatus.subscriberOnly);
      expect(third.statusReason, contains('subscriber-only'));
    });

    test('parses Atom 1.0 feed and multi-author bylines', () {
      final feed = RssParser.parseFeedXml(
        _kSampleAtomXml,
        feedUrl: Uri.parse('https://slowthought.example.com/atom.xml'),
      );

      expect(feed.title, 'Slow Thought Essays');
      expect(feed.entries.length, 1);
      final entry = feed.entries.first;
      expect(entry.title, 'The Architecture of Calm Software');
      expect(entry.contentStatus, ArticleContentStatus.full);
      expect(
        entry.normalizedAuthors,
        containsAll(['ross douthat', 'coleman hughes']),
      );
    });

    test('discovers RSS and Atom feeds from website HTML and common paths', () {
      const html = '''
        <!doctype html>
        <html>
          <head>
            <link rel="alternate" type="application/rss+xml" title="Main RSS" href="/custom-rss.xml">
          </head>
          <body><h1>Publication Home</h1></body>
        </html>
      ''';
      final candidates = RssParser.discoverCandidateFeedUrls(
        Uri.parse('https://example.org/'),
        html: html,
      );
      expect(
        candidates.first.toString(),
        'https://example.org/custom-rss.xml',
      );
      expect(
        candidates.map((u) => u.toString()),
        contains('https://example.org/feed'),
      );
    });
  });

  group('OPML Import and Export', () {
    test('imports nested folder hierarchy, deduplicates feeds, reports invalid outlines, and exports OPML 2.0', () {
      const opml = '''<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>My Subscriptions</title></head>
  <body>
    <outline text="Commentary" title="Commentary">
      <outline type="rss" text="The Free Press" xmlUrl="https://www.thefp.com/feed" htmlUrl="https://www.thefp.com"/>
      <outline type="rss" text="Duplicate Free Press" xmlUrl="https://www.thefp.com/feed/" htmlUrl="https://www.thefp.com"/>
      <outline text="Columnists">
        <outline type="rss" text="Coleman Hughes" xmlUrl="https://colemanhughes.substack.com/feed"/>
      </outline>
    </outline>
    <outline type="rss" text="Broken Feed Missing URL" htmlUrl="https://broken.example.com"/>
    <outline type="rss" text="Bad Scheme" xmlUrl="ftp://invalid.example.com/rss"/>
  </body>
</opml>''';

      final parsed = RssOpml.parseOpml(opml);
      expect(parsed.folderNames, containsAll(['Commentary', 'Commentary / Columnists']));
      expect(parsed.feeds.length, 2);
      expect(parsed.skippedDuplicates, ['Duplicate Free Press']);
      expect(parsed.failures.length, 2);

      // Verify large OPML handling (120 feeds across 10 folders)
      final largeBuffer = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8"?><opml version="2.0"><body>',
      );
      for (var f = 0; f < 10; f++) {
        largeBuffer.write('<outline text="Folder $f">');
        for (var i = 0; i < 12; i++) {
          largeBuffer.write(
            '<outline type="rss" text="Feed ${f}_$i" xmlUrl="https://pub$f.example.com/feed$i.xml"/>',
          );
        }
        largeBuffer.write('</outline>');
      }
      largeBuffer.write('</body></opml>');

      final largeResult = RssOpml.parseOpml(largeBuffer.toString());
      expect(largeResult.folderNames.length, 10);
      expect(largeResult.feeds.length, 120);
      expect(largeResult.failures, isEmpty);
    });
  });

  group('Authors-First Normalization & Natural-Language Feed Rules', () {
    test('normalizes author name variations and matches followed writers', () {
      expect(RssAuthors.normalizeAuthorName('By Ross G. Douthat'), 'ross douthat');
      expect(
        RssAuthors.normalizeAuthorName('douthat@nytimes.com (Ross Douthat)'),
        'ross douthat',
      );

      final ross = RssAuthors.createFollowedAuthor('Ross Douthat');
      final feed = RssParser.parseFeedXml(
        _kSampleRss2Xml,
        feedUrl: Uri.parse('https://www.thefp.com/feed'),
      );
      final article = RssArticle(
        id: feed.entries.first.id,
        subscriptionId: 'sub_1',
        feedTitle: feed.title,
        title: feed.entries.first.title,
        url: feed.entries.first.url,
        canonicalUrl: feed.entries.first.canonicalUrl,
        author: 'R. Douthat',
        normalizedAuthors: RssAuthors.extractNormalizedAuthors('R. Douthat'),
        fetchedAt: DateTime.utc(2026, 11, 17),
        summaryPreview: feed.entries.first.summaryPreview,
        blocks: feed.entries.first.blocks,
        contentStatus: feed.entries.first.contentStatus,
      );

      expect(RssAuthors.articleMatchesAuthor(article, ross), isTrue);
    });

    test('translates plain-English prompts into explicit deterministic rules and rejects unsupported prompts', () {
      final showRoss = RssRulesEngine.translateNaturalLanguageRule(
        'Show me articles by Ross Douthat',
      );
      expect(showRoss.isSupported, isTrue);
      expect(showRoss.rule!.conditionType, RuleConditionType.author);
      expect(showRoss.rule!.pattern, 'Ross Douthat');
      expect(showRoss.rule!.actionType, RuleActionType.showOnly);

      final hideAuthor = RssRulesEngine.translateNaturalLanguageRule(
        'Hide articles from Guest Writer',
      );
      expect(hideAuthor.isSupported, isTrue);
      expect(hideAuthor.rule!.conditionType, RuleConditionType.author);
      expect(hideAuthor.rule!.actionType, RuleActionType.hide);

      final starAi = RssRulesEngine.translateNaturalLanguageRule(
        'Automatically star articles matching AI',
      );
      expect(starAi.isSupported, isTrue);
      expect(starAi.rule!.conditionType, RuleConditionType.topic);
      expect(starAi.rule!.pattern, 'AI');
      expect(starAi.rule!.actionType, RuleActionType.star);

      final folderAi = RssRulesEngine.translateNaturalLanguageRule(
        'Put articles about AI into Technology',
      );
      expect(folderAi.isSupported, isTrue);
      expect(folderAi.rule!.conditionType, RuleConditionType.topic);
      expect(folderAi.rule!.actionType, RuleActionType.assignFolder);
      expect(folderAi.rule!.targetFolderName, 'Technology');

      final prioritizeFav = RssRulesEngine.translateNaturalLanguageRule(
        'Prioritize articles from favorite writers',
      );
      expect(prioritizeFav.isSupported, isTrue);
      expect(
        prioritizeFav.rule!.conditionType,
        RuleConditionType.favoriteAuthors,
      );
      expect(prioritizeFav.rule!.actionType, RuleActionType.prioritize);

      final unsupportedPaywall = RssRulesEngine.translateNaturalLanguageRule(
        'Bypass paywalls on all articles',
      );
      expect(unsupportedPaywall.isSupported, isFalse);
      expect(unsupportedPaywall.errorMessage, contains('paywall'));
    });
  });

  group('RssLibraryController End-to-End Persistence, Full-Text Upgrade, and Narration Bridge', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dogreader2_rss_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('manages subscriptions, folders, duplicate detection, full-text 5-state classification, rules, and offline reload', () async {
      final routes = <String, RssHttpDocument>{
        'https://www.thefp.com': RssHttpDocument(
          finalUrl: Uri.parse('https://www.thefp.com'),
          body: '''<!doctype html><html><head>
            <link rel="alternate" type="application/rss+xml" href="https://www.thefp.com/feed">
          </head><body></body></html>''',
        ),
        'https://www.thefp.com/feed': RssHttpDocument(
          finalUrl: Uri.parse('https://www.thefp.com/feed'),
          body: _kSampleRss2Xml,
        ),
        'https://www.thefp.com/p/ai-governance-open-science': RssHttpDocument(
          finalUrl: Uri.parse('https://www.thefp.com/p/ai-governance-open-science'),
          body: _kFullExtractedWebpageHtml,
        ),
        'https://www.thefp.com/p/notes-european-history': RssHttpDocument(
          finalUrl: Uri.parse('https://www.thefp.com/p/notes-european-history'),
          body: _kPaywalledWebpageHtml,
        ),
      };

      Future<RssHttpDocument> fakeLoader(Uri uri, {bool preferFeed = false}) async {
        final key = uri.toString();
        if (key == 'https://www.thefp.com/p/missing-404') {
          throw RssHttpStatusException(404, uri);
        }
        final doc = routes[key];
        if (doc != null) return doc;
        throw RssHttpStatusException(404, uri);
      }

      final controller = RssLibraryController(
        Future.value(tempDir),
        documentLoader: fakeLoader,
        clock: () => DateTime.utc(2026, 11, 17, 12, 0),
      );
      await controller.load();

      // 1. Create folder & discover feed from website homepage URL
      final folder = await controller.createFolder('Commentary');
      final sub = await controller.addSubscriptionByUrl(
        'https://www.thefp.com',
        folderId: folder.id,
      );
      expect(sub.feedUrl, 'https://www.thefp.com/feed');
      expect(sub.displayTitle, 'The Free Press');
      expect(controller.totalUnreadCount, 3);
      expect(controller.unreadCountForFolder(folder.id), 3);

      // 2. Duplicate subscription detection
      expect(
        () => controller.addSubscriptionByUrl('https://www.thefp.com/feed/'),
        throwsA(isA<DuplicateSubscriptionException>()),
      );

      // 3. Follow author & apply natural-language rules
      final coleman = await controller.followAuthor('Coleman Hughes');
      expect(controller.unreadCountForAuthor(coleman), 1);

      final ruleResult = await controller.addRuleFromNaturalLanguage(
        'Automatically star articles matching AI',
      );
      expect(ruleResult.isSupported, isTrue);

      final aiArticle = controller.allArticles
          .firstWhere((a) => a.title.contains('AI Governance'));
      expect(aiArticle.isStarred, isTrue);
      expect(aiArticle.isPrioritized, isTrue);
      expect(aiArticle.contentStatus, ArticleContentStatus.previewOnly);

      // 4. Upgrade previewOnly article to full text from original webpage
      final upgraded = await controller.ensureFullText(aiArticle.id);
      expect(upgraded, isNotNull);
      expect(upgraded!.contentStatus, ArticleContentStatus.full);
      expect(upgraded.statusReason, isNull);
      expect(upgraded.wordCount, greaterThan(60));

      // 5. Subscriber-only article preserves subscriberOnly status and never bypasses paywall
      final subOnlyArticle = controller.allArticles
          .firstWhere((a) => a.title.contains('Subscriber Exclusive'));
      expect(subOnlyArticle.contentStatus, ArticleContentStatus.subscriberOnly);
      final retriedSubOnly = await controller.ensureFullText(
        subOnlyArticle.id,
        forceRetry: true,
      );
      expect(
        retriedSubOnly!.contentStatus,
        ArticleContentStatus.subscriberOnly,
      );

      // 6. Persist read status, reading scroll position, and book-library promotion
      await controller.markRead(aiArticle.id, true);
      await controller.saveReadingPosition(
        aiArticle.id,
        readingOffset: 120,
        scrollFraction: 0.45,
        narrationOffset: 80,
      );
      expect(controller.librarySavedArticles, isEmpty);
      await controller.setSavedToLibrary(aiArticle.id, true);
      expect(controller.librarySavedArticles.length, 1);

      // 7. Verify narration chapter generation
      final chapter = upgraded.chapter;
      expect(chapter.title, 'AI Governance and Open Science');
      expect(chapter.text, contains('Open scientific inquiry'));

      // 8. Reload from disk into a fresh controller instance (offline persistence)
      final reloaded = RssLibraryController(
        Future.value(tempDir),
        documentLoader: fakeLoader,
      );
      await reloaded.load();
      expect(reloaded.folders.length, 1);
      expect(reloaded.subscriptions.length, 1);
      expect(reloaded.followedAuthors.length, 1);
      expect(reloaded.rules.length, 1);
      expect(reloaded.totalUnreadCount, 2);

      final reloadedAi = reloaded.articleById(aiArticle.id)!;
      expect(reloadedAi.isRead, isTrue);
      expect(reloadedAi.isStarred, isTrue);
      expect(reloadedAi.isSavedToLibrary, isTrue);
      expect(reloadedAi.contentStatus, ArticleContentStatus.full);
      expect(reloadedAi.readingOffset, 120);
      expect(reloadedAi.readingScrollFraction, 0.45);
      expect(reloadedAi.narrationOffset, 80);

      // 9. Verify schema migration resilience
      final legacySnapshot = RssStateSnapshot.fromJson({
        'schemaVersion': 0,
        'shelfExpanded': true,
        'folders': const [],
        'subscriptions': const [],
      });
      expect(
        legacySnapshot.schemaVersion,
        RssStateSnapshot.currentSchemaVersion,
      );
      expect(legacySnapshot.shelfExpanded, isTrue);
    });
  });

  group('RssLibraryShelf Widget Integration', () {
    testWidgets('RssLibraryShelf renders collapsed by default with unread badge and expands cleanly', (tester) async {
      late Directory widgetTempDir;
      late RssLibraryController controller;
      await tester.runAsync(() async {
        widgetTempDir = await Directory.systemTemp.createTemp('dogreader2_shelf_');
        controller = RssLibraryController(Future.value(widgetTempDir));
        await controller.load();
        await controller.addSubscriptionFromXml(
          feedUrl: 'https://www.thefp.com/feed',
          xmlText: _kSampleRss2Xml,
        );
        await controller.followAuthor('Ross Douthat');
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          if (await widgetTempDir.exists()) {
            await widgetTempDir.delete(recursive: true);
          }
        });
      });

      var openedRss = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RssLibraryShelf(
              controller: controller,
              onOpenRssHome: ({initialMode, subscriptionId, folderId, authorId}) {
                openedRss = true;
              },
              onOpenAddFeed: () {},
              onOpenAuthors: () {},
              onOpenRules: () {},
              onOpenOpml: () {},
            ),
          ),
        ),
      );

      // Collapsed by default with unread badge
      expect(find.byKey(const Key('rss_library_shelf')), findsOneWidget);
      expect(find.byKey(const Key('rss_shelf_unread_badge')), findsOneWidget);
      expect(find.text('3 unread'), findsOneWidget);
      expect(find.text('FAVORITE WRITERS'), findsNothing);

      // Expand shelf
      await tester.runAsync(() async {
        await controller.setShelfExpanded(true);
      });
      await tester.pump();
      expect(find.text('FAVORITE WRITERS'), findsOneWidget);
      expect(find.text('Ross Douthat'), findsOneWidget);
      expect(find.text('The Free Press'), findsOneWidget);

      // One-tap open RSS reader
      await tester.tap(find.byKey(const Key('rss_shelf_open_tap')));
      await tester.pump();
      expect(openedRss, isTrue);
    });
  });
}
