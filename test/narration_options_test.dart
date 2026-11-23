import 'package:audiobook_app/narration_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old preferences retain Google and the existing voice', () {
    final preference = NarrationPreference.fromJson({'narrator': 'en-US-Chirp3-HD-Charon'});
    expect(NarrationPreference.fromJson({'narrator': 'en-GB-Wavenet-B'}).voice, 'en-GB-Wavenet-B');
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

    // Switch from cloud Kokoro to Kokoro (Offline) via the standard engine dropdown.
    await tester.tap(find.text('Kokoro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kokoro (Offline)').last);
    await tester.pumpAndSettle();
    expect(preference.engine, 'kokoro_offline');
    expect(preference.isOffline, isTrue);
    expect(preference.voice, 'af_heart');
    expect(
      find.textContaining('Runs on this device (Kokoro FP32 • Misaki English)'),
      findsOneWidget,
    );
    expect(find.text('Preview voice'), findsNothing);

    // Open the Narrator dropdown and verify all local voices are listed.
    await tester.tap(find.text('Heart (US Female)'));
    await tester.pumpAndSettle();
    for (final voice in [
      'Heart (US Female)',
      'Michael (US Male)',
      'Emma (UK Female)',
    ]) {
      expect(find.text(voice), findsWidgets);
    }
    await tester.tap(find.text('Emma (UK Female)').last);
    await tester.pumpAndSettle();
    expect(preference.voice, 'bf_emma');
    expect(offlineSidForVoice(preference.voice), 21);
    expect(
      recordingLabel(preference.toJson()),
      'Kokoro (Offline) • Emma (UK Female)',
    );

    // Switch back to Google Chirp cloud narration.
    await tester.tap(find.text('Kokoro (Offline)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google Chirp').last);
    await tester.pumpAndSettle();
    // Switch to Azure Neural and verify curated F0-eligible voices.
    await tester.tap(find.text('Google Chirp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Azure Neural').last);
    await tester.pumpAndSettle();
    expect(preference.engine, 'azure');
    expect(preference.isOffline, isFalse);
    expect(preference.voice, 'en-US-AndrewMultilingualNeural');
    expect(find.text('Preview voice'), findsOneWidget);

    await tester.tap(find.text('Andrew (US)'));
    await tester.pumpAndSettle();
    for (final voice in [
      'Andrew (US)',
      'Ava (US)',
      'Brian (US)',
      'Emma (US)',
      'Ryan (UK)',
      'Sonia (UK)',
    ]) {
      expect(find.text(voice), findsWidgets);
    }
    await tester.tap(find.text('Ryan (UK)').last);
    await tester.pumpAndSettle();
    expect(preference.voice, 'en-GB-RyanNeural');
    expect(
      recordingLabel(preference.toJson()),
      'Azure Neural • Ryan (UK)',
    );
  });

  test('Azure preference round-trips and falls back to default Azure voice on mismatch', () {
    final restored = NarrationPreference.fromJson({
      'engine': 'azure',
      'voice': 'en-GB-SoniaNeural',
    });
    expect(restored.toJson(), {'engine': 'azure', 'voice': 'en-GB-SoniaNeural'});
    expect(
      NarrationPreference.fromJson({
        'engine': 'azure',
        'voice': 'en-US-Chirp3-HD-Puck',
      }).voice,
      'en-US-AndrewMultilingualNeural',
    );
  });
}
