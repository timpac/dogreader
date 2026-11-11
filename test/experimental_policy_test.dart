import 'dart:io';

import 'package:audiobook_app/app_identity.dart';
import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/article_summary.dart';
import 'package:audiobook_app/narration_preview.dart';
import 'package:flutter_test/flutter_test.dart';

class NoNetwork extends HttpOverrides {
  int clients = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    throw StateError('A disabled operation created an HTTP client');
  }
}

void main() {
  test('Dart identity follows the Android experimental build switch', () {
    expect(
      dogreaderAppName,
      dogreaderExperimental ? 'Dog Reader 2.0' : 'Dogreader',
    );
    expect(
      dogreaderApplicationId,
      dogreaderExperimental
          ? 'com.example.audiobook_app.experimental'
          : 'com.example.audiobook_app',
    );
    expect(narrationNotificationChannel, '$dogreaderApplicationId.audio');
  });

  test(
    'experimental consent is chapter-local, consumed once and never restored',
    () {
      if (!dogreaderExperimental) return;
      final consent = ChapterGenerationConsent();
      expect(consent.take(0), isFalse);
      consent.approve(0);
      expect(consent.take(1), isFalse);
      expect(consent.take(0), isTrue);
      expect(consent.take(0), isFalse);
      consent.approve(0);
      consent.clear();
      expect(consent.take(0), isFalse);
      expect(ChapterGenerationConsent().take(0), isFalse);
      expect(
        () => requireNarrationRequestConsent(
          'POST',
          '/dogreader/books',
          approved: true,
        ),
        throwsStateError,
      );
      requireNarrationRequestConsent('POST', '/dogreader/jobs', approved: true);
      requireNarrationRequestConsent(
        'GET',
        '/dogreader/jobs/existing',
        approved: false,
      );
    },
  );

  test(
    'experimental unapproved submissions and summaries create no HTTP client',
    () async {
      if (!dogreaderExperimental) return;
      final network = NoNetwork();
      await HttpOverrides.runWithHttpOverrides(() async {
        await expectLater(
          narrationRequest(
            'https://example.org',
            'fake',
            'POST',
            '/dogreader/jobs',
            {'text': 'Unapproved retry'},
          ),
          throwsStateError,
        );
        await expectLater(
          narrationRequest(
            'https://example.org',
            'fake',
            'POST',
            '/dogreader/books',
            {},
            true,
          ),
          throwsStateError,
        );
        await expectLater(
          ArticleSummaryClient(Directory('/unused'), enabled: true).estimate(
            ImportedArticle(
              title: 'Article',
              sourceUrl: 'https://example.org',
              blocks: const [ArticleBlock('Immutable source')],
            ),
            SummaryDepth.brief,
          ),
          throwsA(isA<ArticleImportException>()),
        );
      }, network);
      expect(network.clients, 0);
      expect(articleSummariesEnabled, isFalse);
    },
  );
}
