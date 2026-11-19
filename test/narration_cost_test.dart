import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/narration_cost.dart';
import 'package:audiobook_app/narration_delivery.dart';
import 'package:audiobook_app/narration_options.dart';
import 'package:audiobook_app/reader_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late DateTime now;
  late NarrationCostTracker tracker;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('narration-cost-test-');
    now = DateTime.utc(2026, 11, 19);
    tracker = NarrationCostTracker(
      usageFile: () async => File('${root.path}/narration_cost.json'),
      clock: () => now,
    );
    await tracker.load();
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    '1M free characters + \$10 Google Pro credit covers 1,333,333 Chirp 3 HD characters before charges',
    () async {
      final initial = tracker.estimate();
      expect(initial.monthKey, '2026-11');
      expect(initial.freeCharacterLimit, 1000000);
      expect(initial.monthlyCreditLimitUsd, 10.0);
      expect(initial.creditCharacterAllowance, 333333);
      expect(initial.totalCoveredGoogleCharacters, 1333333);
      expect(initial.coveredCharactersRemaining, 1333333);
      expect(initial.shouldSwitchToKokoro, isFalse);

      // Record 900,000 characters within the 1M free tier.
      expect(
        await tracker.recordSubmission(
          jobId: 'job-free-1',
          engine: 'google',
          voice: 'en-US-Chirp3-HD-Achernar',
          characters: 900000,
        ),
        isTrue,
      );
      // Duplicate jobId must not double-count characters.
      expect(
        await tracker.recordSubmission(
          jobId: 'job-free-1',
          engine: 'google',
          voice: 'en-US-Chirp3-HD-Achernar',
          characters: 900000,
        ),
        isFalse,
      );

      final afterFree = tracker.estimate(selectionCharacters: 250000);
      expect(afterFree.usedGoogleCharacters, 900000);
      expect(afterFree.freeCharactersRemaining, 100000);
      expect(afterFree.creditUsdRemaining, 10.0);
      // 250,000 selected: 100,000 covered by remaining free tier, 150,000 covered by $10 credit ($4.50).
      expect(afterFree.selectionCoveredByFreeCharacters, 100000);
      expect(afterFree.selectionCoveredByCreditCharacters, 150000);
      expect(afterFree.selectionUncoveredCharacters, 0);
      expect(afterFree.selectionCreditUsedUsd, closeTo(4.50, 0.001));
      expect(afterFree.selectionOutOfPocketUsd, 0.0);
      expect(afterFree.projectedCreditUsdRemaining, closeTo(5.50, 0.001));
      expect(afterFree.shouldSwitchToKokoro, isFalse);

      // Record another 400,000 characters -> 1,300,000 total used ($9.00 of $10.00 credit used).
      await tracker.recordSubmission(
        jobId: 'job-credit-2',
        engine: 'google',
        voice: 'en-US-Chirp3-HD-Achernar',
        characters: 400000,
      );
      final nearLimit = tracker.estimate(selectionCharacters: 50000);
      expect(nearLimit.usedGoogleCharacters, 1300000);
      expect(nearLimit.coveredCharactersRemaining, 33333);
      expect(nearLimit.creditUsdRemaining, closeTo(1.00, 0.001));
      // Selecting 50,000 characters now exceeds the remaining 33,333 covered characters by 16,667 ($0.50).
      expect(nearLimit.selectionExceedsAllowance, isTrue);
      expect(nearLimit.shouldSwitchToKokoro, isTrue);
      expect(nearLimit.selectionUncoveredCharacters, 16667);
      expect(nearLimit.selectionOutOfPocketUsd, closeTo(0.50, 0.01));

      // Switching the preference to Kokoro costs $0.00 and preserves the remaining Google allowance.
      final kokoroEstimate = tracker.estimate(
        preference: const NarrationPreference('kokoro', 'bm_george'),
        selectionCharacters: 50000,
      );
      expect(kokoroEstimate.selectionOutOfPocketUsd, 0.0);
      expect(kokoroEstimate.selectionCreditUsedUsd, 0.0);
      expect(kokoroEstimate.projectedCoveredCharactersRemaining, 33333);
    },
  );

  test(
    'monthly usage persists across restarts and rolls over cleanly in a new calendar month',
    () async {
      await tracker.recordSubmission(
        jobId: 'nov-job',
        engine: 'google',
        voice: 'en-US-Chirp3-HD-Achernar',
        characters: 1333333,
      );
      await tracker.recordSubmission(
        jobId: 'nov-kokoro',
        engine: 'kokoro',
        voice: 'bm_lewis',
        characters: 85000,
      );

      final reopened = NarrationCostTracker(
        usageFile: () async => File('${root.path}/narration_cost.json'),
        clock: () => now,
      );
      await reopened.load();
      expect(reopened.estimate().usedGoogleCharacters, 1333333);
      expect(reopened.estimate().usedKokoroCharacters, 85000);
      expect(reopened.estimate().allowanceExhausted, isTrue);
      expect(reopened.estimate().shouldSwitchToKokoro, isTrue);

      // Advance clock to December 2026: monthly allowance resets for the new billing month.
      now = DateTime.utc(2026, 12, 1);
      final december = reopened.estimate();
      expect(december.monthKey, '2026-12');
      expect(december.usedGoogleCharacters, 0);
      expect(december.coveredCharactersRemaining, 1333333);
      expect(december.shouldSwitchToKokoro, isFalse);
      // Historical November record remains intact.
      expect(reopened.estimate(monthKey: '2026-11').usedGoogleCharacters, 1333333);
    },
  );

  test(
    'NarrationDelivery automatically records submitted chapter characters once per job ID',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'id': 'a1b2c3d4e5f60123456789abcdef0123',
              'status': 'queued',
              'engine': 'google',
              'voice': 'en-US-Chirp3-HD-Achernar',
            }),
          );
          await req.response.close();
        });

        final chapterText = List.filled(250, 'Hello dog reader. ').join();
        final delivery = NarrationDelivery(
          documentsDirectory: () async => root,
          beforeReplace: (_, _) async {},
          clock: () => now,
          costTracker: tracker,
        );
        addTearDown(delivery.dispose);
        await delivery.load();
        delivery.host = 'http://127.0.0.1:${server.port}';
        delivery.token = 'secret';
        delivery.registerBookChapters('book-1', [
          ReaderChapter('Chapter 1', chapterText, const []),
        ]);
        delivery.books['book-1'] = {
          0: {
            'status': 'waiting',
            'engine': 'google',
            'voice': 'en-US-Chirp3-HD-Achernar',
          },
        };
        await delivery.submitWaitingJobs(bookId: 'book-1');

        expect(
          tracker.estimate().usedGoogleCharacters,
          chapterText.runes.length,
        );
        expect(
          delivery.books['book-1']![0]!['characters'],
          chapterText.runes.length,
        );
      }, _RealHttp());
    },
  );

  testWidgets(
    'NarrationCostBanner alerts when free tier + \$10 credit is exceeded and switches to Kokoro on tap',
    (tester) async {
      await tracker.setMonthUsage(googleCharacters: 1300000);
      var preference = const NarrationPreference(
        'google',
        'en-US-Chirp3-HD-Achernar',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: NarrationCostBanner(
                tracker: tracker,
                preference: preference,
                selectionCharacters: 50000,
                onSwitchToKokoro: (next) => setState(() => preference = next),
                onAdjustBudget: () =>
                    showNarrationBudgetDialog(context, tracker: tracker),
              ),
            ),
          ),
        ),
      );

      expect(
        find.textContaining('switch to Kokoro'),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey('switch-to-kokoro-button')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('switch-to-kokoro-button')));
      await tester.pumpAndSettle();
      expect(preference.engine, 'kokoro');
      expect(preference.voice, 'bm_george');
      expect(find.textContaining('\$0.00 API cost with Kokoro'), findsOneWidget);

      // Test adjusting usage via the budget dialog.
      await tester.tap(find.text('Usage / budget'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('budget-google-used-field')),
        '500000',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(tracker.estimate().usedGoogleCharacters, 500000);
      expect(tracker.estimate().coveredCharactersRemaining, 833333);
    },
  );
}

class _RealHttp extends HttpOverrides {}
