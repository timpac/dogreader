import 'package:audiobook_app/narration_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old preferences retain Google and migrate cloud Kokoro to on-device Kokoro', () {
    expect(NarrationPreference.fromJson(const {}).engine, 'kokoro_offline');
    final preference = NarrationPreference.fromJson({'narrator': 'en-US-Chirp3-HD-Charon'});
    expect(NarrationPreference.fromJson({'narrator': 'en-GB-Wavenet-B'}).voice, 'en-GB-Wavenet-B');
    expect(preference.engine, 'google');
    expect(preference.voice, 'en-US-Chirp3-HD-Charon');
    final restored = NarrationPreference.fromJson({'engine': 'kokoro', 'narrator': 'bm_lewis'});
    expect(restored.toJson(), {'engine': 'kokoro_offline', 'voice': 'af_heart'});
  });

  test('recording attribution uses stored engine and preserves model settings', () {
    expect(recordingLabel({'status': 'ready'}), 'Recording • engine and voice not recorded');
    expect(recordingLabel({'voice': 'en-US-Chirp3-HD-Kore'}), 'Google Chirp • Kore');
    expect(recordingLabel({'engine': 'kokoro', 'voice': 'bm_daniel'}), 'Kokoro • Daniel');
    expect(recordingLabel({'engine': 'speechify', 'voice': 'george'}), 'Speechify • George');
    expect(recordingMetadata({'status': 'ready', 'engine': 'kokoro', 'voice': 'bm_fable',
      'model_version': 'v1', 'settings': {'speed': 1}}), {
        'engine': 'kokoro', 'voice': 'bm_fable', 'model_version': 'v1', 'settings': {'speed': 1},
      });
  });

  testWidgets('selector shows voices for on-device Kokoro, Google Chirp, Azure Neural, and Speechify', (tester) async {
    var preference = const NarrationPreference('google', 'en-US-Chirp3-HD-Achernar');
    var previews = 0;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(builder: (context, setState) => Scaffold(
      body: NarrationControls(preference: preference,
        onChanged: (value) => setState(() => preference = value), onPreview: () => previews++),
    ))));

    await tester.tap(find.text('Preview voice'));
    expect(previews, 1);

    // Switch to Kokoro (On-Device) via the engine dropdown.
    await tester.tap(find.text('Google Chirp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kokoro (On-Device)').last);
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
      'Kokoro (On-Device) • Emma (UK Female)',
    );

    // Switch to Azure Neural and verify curated F0-eligible voices.
    await tester.tap(find.text('Kokoro (On-Device)'));
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

    // Switch to Speechify and verify voices.
    await tester.tap(find.text('Azure Neural'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speechify').last);
    await tester.pumpAndSettle();
    expect(preference.engine, 'speechify');
    expect(preference.voice, 'george');
  });

  test('Azure and Speechify preferences round-trip and fall back on voice mismatch', () {
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
    expect(
      NarrationPreference.fromJson({
        'engine': 'speechify',
        'voice': 'carly',
      }).toJson(),
      {'engine': 'speechify', 'voice': 'carly'},
    );
  });
}
