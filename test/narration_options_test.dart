import 'package:audiobook_app/narration_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old preferences retain Google and the existing voice', () {
    final preference = NarrationPreference.fromJson({'narrator': 'en-US-Chirp3-HD-Charon'});
    expect(preference.engine, 'google');
    expect(preference.voice, 'en-US-Chirp3-HD-Charon');
    final restored = NarrationPreference.fromJson({'engine': 'kokoro', 'narrator': 'bm_lewis'});
    expect(restored.toJson(), {'engine': 'kokoro', 'voice': 'bm_lewis'});
    expect(NarrationPreference.fromJson({'engine': 'kokoro', 'narrator': 'en-US-Chirp3-HD-Puck'}).voice, 'bm_george');
  });

  test('recording attribution uses stored engine and preserves model settings', () {
    expect(recordingLabel({'status': 'ready'}), 'Recording • engine and voice not recorded');
    expect(recordingLabel({'voice': 'en-US-Chirp3-HD-Kore'}), 'Google Chirp • Kore');
    expect(recordingLabel({'engine': 'kokoro', 'voice': 'bm_daniel'}), 'Kokoro • Daniel');
    expect(recordingMetadata({'status': 'ready', 'engine': 'kokoro', 'voice': 'bm_fable',
      'model_version': 'v1', 'settings': {'speed': 1}}), {
        'engine': 'kokoro', 'voice': 'bm_fable', 'model_version': 'v1', 'settings': {'speed': 1},
      });
  });

  testWidgets('selector shows voices for the selected engine and offers a preview', (tester) async {
    var preference = const NarrationPreference('google', 'en-US-Chirp3-HD-Achernar');
    var previews = 0;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(builder: (context, setState) => Scaffold(
      body: NarrationControls(preference: preference,
        onChanged: (value) => setState(() => preference = value), onPreview: () => previews++),
    ))));
    await tester.tap(find.text('Google Chirp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kokoro').last);
    await tester.pumpAndSettle();
    expect(preference.engine, 'kokoro');
    expect(preference.voice, 'bm_george');
    expect(find.text('Achernar'), findsNothing);
    await tester.tap(find.text('George'));
    await tester.pumpAndSettle();
    for (final voice in ['George', 'Fable', 'Daniel', 'Lewis']) {
      expect(find.text(voice), findsWidgets);
    }
    await tester.tap(find.text('Lewis').last);
    await tester.pumpAndSettle();
    expect(preference.voice, 'bm_lewis');
    await tester.tap(find.text('Preview voice'));
    expect(previews, 1);
  });
}
