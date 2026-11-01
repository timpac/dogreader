import 'dart:io';
import 'package:audiobook_app/narration_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in [Brightness.dark, Brightness.light]) {
    testWidgets('narration controls in ${brightness.name} theme', (tester) async {
      tester.view.physicalSize = const Size(430, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sdk = Platform.environment['FLUTTER_ROOT'];
      if (sdk != null) {
        final font = File('$sdk/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
        if (font.existsSync()) {
          final loader = FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
          await loader.load();
        }
      }
      await tester.pumpWidget(MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB7A6F6), brightness: brightness)),
        home: Scaffold(appBar: AppBar(title: const Text('Generate narration')),
          body: Column(children: [
            const NarrationControls(preference: NarrationPreference('kokoro', 'bm_george'),
              onChanged: ignorePreference, onPreview: ignorePreview),
            const ListTile(title: Text('Chapter One'), subtitle: Text('Ready to listen • Kokoro • George'),
              leading: Icon(Icons.play_circle_fill)),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () {}, child: const Text('Download audio')),
              TextButton(onPressed: () {}, child: const Text('Regenerate narration')),
            ]),
            const Spacer(),
            FilledButton(onPressed: () {}, child: const Text('Generate narration (1)')),
            const SizedBox(height: 16),
          ]))));
      await tester.pumpAndSettle();
      await expectLater(find.byType(Scaffold), matchesGoldenFile('screenshots/kokoro-${brightness.name}.png'));
    }, tags: ['screenshots']);
  }
}

void ignorePreference(NarrationPreference value) {}
void ignorePreview() {}
