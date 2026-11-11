import 'package:audiobook_app/article_screen.dart';
import 'package:audiobook_app/article_share.dart';
import 'package:audiobook_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
