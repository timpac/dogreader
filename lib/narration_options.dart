import 'package:flutter/material.dart';

const narrationEngines = {'google': 'Google Chirp', 'kokoro': 'Kokoro'};
const narrationVoices = <String, Map<String, String>>{
  'google': {
    'en-US-Chirp3-HD-Achernar': 'Achernar',
    'en-US-Chirp3-HD-Charon': 'Charon',
    'en-US-Chirp3-HD-Kore': 'Kore',
    'en-US-Chirp3-HD-Puck': 'Puck',
    'en-GB-Wavenet-B': 'Oliver (Cheap)',
  },
  'kokoro': {
    'bm_george': 'George',
    'bm_fable': 'Fable',
    'bm_daniel': 'Daniel',
    'bm_lewis': 'Lewis',
  },
};

class NarrationPreference {
  final String engine;
  final String voice;
  const NarrationPreference(this.engine, this.voice);

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
  for (final key in ['engine', 'voice', 'model_version', 'settings'])
    if (response.containsKey(key)) key: response[key],
};

String recordingLabel(Map<String, dynamic>? job) {
  if (job?['id'] == null && job?['engine'] == null && job?['voice'] == null) {
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
        TextButton.icon(
          onPressed: onPreview,
          icon: Icon(previewing ? Icons.stop : Icons.volume_up),
          label: Text(previewing ? 'Stop preview' : 'Preview voice'),
        ),
      ],
    ),
  );
}
