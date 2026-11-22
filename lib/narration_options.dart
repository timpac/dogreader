import 'package:flutter/material.dart';

const narrationEngines = {
  'google': 'Google Chirp',
  'azure': 'Azure Neural',
  'kokoro': 'Kokoro',
  'kokoro_offline': 'Kokoro (Offline)',
};
const narrationVoices = <String, Map<String, String>>{
  'google': {
    'en-US-Chirp3-HD-Achernar': 'Achernar',
    'en-US-Chirp3-HD-Charon': 'Charon',
    'en-US-Chirp3-HD-Kore': 'Kore',
    'en-US-Chirp3-HD-Puck': 'Puck',
    'en-GB-Wavenet-B': 'Oliver (Cheap)',
  },
  'azure': {
    'en-US-AndrewMultilingualNeural': 'Andrew (US)',
    'en-US-AvaMultilingualNeural': 'Ava (US)',
    'en-US-BrianMultilingualNeural': 'Brian (US)',
    'en-US-EmmaMultilingualNeural': 'Emma (US)',
    'en-GB-RyanNeural': 'Ryan (UK)',
    'en-GB-SoniaNeural': 'Sonia (UK)',
  },
  'kokoro': {
    'bm_george': 'George',
    'bm_fable': 'Fable',
    'bm_daniel': 'Daniel',
    'bm_lewis': 'Lewis',
  },
  'kokoro_offline': {
    'af_heart': 'Heart (US Female)',
    'am_michael': 'Michael (US Male)',
    'bf_emma': 'Emma (UK Female)',
  },
};

const offlineVoiceSids = <String, int>{
  'af_heart': 3,
  'am_michael': 16,
  'bf_emma': 21,
};

int offlineSidForVoice(String? voice) => offlineVoiceSids[voice] ?? 3;

String offlineVoiceIdForSid(int? sid) {
  for (final entry in offlineVoiceSids.entries) {
    if (entry.value == sid) return entry.key;
  }
  return 'af_heart';
}

class NarrationPreference {
  final String engine;
  final String voice;
  const NarrationPreference(this.engine, this.voice);

  bool get isOffline => engine == 'kokoro_offline';

  factory NarrationPreference.fromJson(Map<String, dynamic> data) {
    final engine = narrationEngines.containsKey(data['engine'])
        ? data['engine'] as String
        : 'google';
    final voices = narrationVoices[engine]!;
    final candidate = data['narrator'] ?? data['voice'];
    return NarrationPreference(
      engine,
      voices.containsKey(candidate) ? candidate as String : voices.keys.first,
    );
  }

  Map<String, dynamic> toJson() => {'engine': engine, 'voice': voice};
}

Map<String, dynamic> recordingMetadata(Map<String, dynamic> response) => {
  for (final key in ['engine', 'voice', 'model_version', 'settings', 'narration_dictionary', 'narration_offsets'])
    if (response.containsKey(key)) key: response[key],
};

String recordingLabel(Map<String, dynamic>? job) {
  if (job?['id'] == null &&
      job?['offlineJobId'] == null &&
      job?['engine'] == null &&
      job?['voice'] == null) {
    return 'Recording • engine and voice not recorded';
  }
  final engine = job?['engine'] as String? ?? 'google';
  final voice = job?['voice'] as String?;
  final name = voice == null ? 'voice not recorded' : narrationVoices[engine]?[voice] ?? voice;
  return '${narrationEngines[engine] ?? engine} • $name';
}

/// Uses inherited colors so the controls follow the app's current theme.
class NarrationControls extends StatelessWidget {
  final NarrationPreference preference;
  final ValueChanged<NarrationPreference> onChanged;
  final VoidCallback? onPreview;
  final bool previewing;
  const NarrationControls({
    super.key,
    required this.preference,
    required this.onChanged,
    required this.onPreview,
    this.previewing = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('engine-${preference.engine}'),
          initialValue: preference.engine,
          decoration: const InputDecoration(labelText: 'Narration engine', border: OutlineInputBorder()),
          items: narrationEngines.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: previewing ? null : (engine) {
            if (engine != null) { onChanged(NarrationPreference(engine, narrationVoices[engine]!.keys.first)); }
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey('voice-${preference.engine}-${preference.voice}'),
          initialValue: preference.voice,
          decoration: const InputDecoration(labelText: 'Narrator', border: OutlineInputBorder(), prefixIcon: Icon(Icons.record_voice_over)),
          items: narrationVoices[preference.engine]!.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: previewing ? null : (voice) {
            if (voice != null) { onChanged(NarrationPreference(preference.engine, voice)); }
          },
        ),
        if (preference.isOffline)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(
                  Icons.offline_bolt_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Runs on this device (Kokoro FP32 • Misaki English). No cloud account or billing required.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          TextButton.icon(
            onPressed: onPreview,
            icon: Icon(previewing ? Icons.stop : Icons.volume_up),
            label: Text(previewing ? 'Stop preview' : 'Preview voice'),
          ),
      ],
    ),
  );
}
