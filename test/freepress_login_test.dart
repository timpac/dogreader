import 'package:audiobook_app/freepress_login.dart';
import 'package:audiobook_app/app_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dogreader/freepress');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  if (!dogreaderExperimental) {
    testWidgets('original app has no Free Press entry', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: FreePressLoginTile())),
      );
      expect(find.byType(ListTile), findsNothing);
      expect(calls, isEmpty);
    });
    return;
  }

  testWidgets('opens native login check without URLs, credentials or session data',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FreePressLoginTile())),
    );
    expect(find.textContaining('Chrome login is separate'), findsOneWidget);
    await tester.tap(find.text('The Free Press: test sign-in'));
    await tester.pump();
    expect(calls.single.method, 'openLoginCheck');
    expect(calls.single.arguments, isNull);
  });

  testWidgets('native failure displays a generic message without logging details',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'failed', message: 'private detail');
        });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FreePressLoginTile())),
    );
    await tester.tap(find.text('The Free Press: test sign-in'));
    await tester.pumpAndSettle();
    expect(find.text('The device login check could not open.'), findsOneWidget);
    expect(find.textContaining('private detail'), findsNothing);
  });
}
