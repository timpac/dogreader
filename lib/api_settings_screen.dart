import 'dart:async';

import 'package:flutter/material.dart';

import 'byok_tts.dart';
import 'offline_narration.dart';

/// API keys and on-device voice setup screen for the standalone Play Store build.
class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({
    super.key,
    required this.credentials,
    required this.ttsClient,
    this.offlineNarration,
  });

  final ByokCredentialStore credentials;
  final ByokTtsClient ttsClient;
  final OfflineNarration? offlineNarration;

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  late final TextEditingController _googleKey = TextEditingController();
  late final TextEditingController _azureKey = TextEditingController();
  late final TextEditingController _azureRegion = TextEditingController();
  late final TextEditingController _speechifyKey = TextEditingController();

  bool _showGoogle = false;
  bool _showAzure = false;
  bool _showSpeechify = false;
  bool _loading = true;
  final Map<String, String?> _messages = {};
  final Set<String> _testing = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await widget.credentials.load();
    _googleKey.text = widget.credentials.googleApiKey;
    _azureKey.text = widget.credentials.azureSpeechKey;
    _azureRegion.text = widget.credentials.azureSpeechRegion;
    _speechifyKey.text = widget.credentials.speechifyApiKey;
    if (widget.offlineNarration != null) {
      unawaited(widget.offlineNarration!.initialize().catchError((Object _) {}));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _googleKey.dispose();
    _azureKey.dispose();
    _azureRegion.dispose();
    _speechifyKey.dispose();
    super.dispose();
  }

  Future<void> _saveGoogle() async {
    await widget.credentials.setGoogleApiKey(_googleKey.text);
    if (!mounted) return;
    setState(() {
      _messages['google'] = widget.credentials.hasGoogleKey
          ? 'Google Cloud API key saved.'
          : 'Google Cloud API key cleared.';
    });
  }

  Future<void> _saveAzure() async {
    try {
      await widget.credentials.setAzureCredentials(
        key: _azureKey.text,
        region: _azureRegion.text,
      );
      if (!mounted) return;
      setState(() {
        _messages['azure'] = widget.credentials.hasAzureCredentials
            ? 'Azure Speech credentials saved.'
            : 'Azure Speech credentials cleared.';
      });
    } on ByokTtsException catch (e) {
      if (mounted) setState(() => _messages['azure'] = e.message);
    }
  }

  Future<void> _saveSpeechify() async {
    await widget.credentials.setSpeechifyApiKey(_speechifyKey.text);
    if (!mounted) return;
    setState(() {
      _messages['speechify'] = widget.credentials.hasSpeechifyKey
          ? 'Speechify API key saved.'
          : 'Speechify API key cleared.';
    });
  }

  Future<void> _testProvider(String engine) async {
    if (_testing.contains(engine)) return;
    if (engine == 'google') await _saveGoogle();
    if (engine == 'azure') await _saveAzure();
    if (engine == 'speechify') await _saveSpeechify();
    if (!widget.credentials.isConfigured(engine)) {
      if (mounted) {
        setState(
          () => _messages[engine] = widget.credentials.missingConfigMessage(
            engine,
          ),
        );
      }
      return;
    }
    setState(() {
      _testing.add(engine);
      _messages[engine] = 'Testing connection…';
    });
    try {
      final result = await widget.ttsClient.testConnection(engine);
      if (mounted) setState(() => _messages[engine] = result);
    } catch (e) {
      if (mounted) setState(() => _messages[engine] = '$e');
    } finally {
      if (mounted) setState(() => _testing.remove(engine));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('API keys & voices')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: scheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lock_outline, size: 20, color: scheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Your API keys are encrypted on this phone using Android Keystore and are sent only directly to the provider you choose. On-device Kokoro requires no API key.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildKokoroCard(context),
                const SizedBox(height: 16),
                _buildGoogleCard(context),
                const SizedBox(height: 16),
                _buildAzureCard(context),
                const SizedBox(height: 16),
                _buildSpeechifyCard(context),
              ],
            ),
    );
  }

  Widget _buildKokoroCard(BuildContext context) {
    final offline = widget.offlineNarration;
    if (offline == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.offline_bolt_outlined),
          title: Text('Kokoro (On-Device)'),
          subtitle: Text('Free offline narration built into Dogreader.'),
        ),
      );
    }
    return ListenableBuilder(
      listenable: offline,
      builder: (context, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    offline.ready
                        ? Icons.check_circle_outline
                        : Icons.download_for_offline_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Kokoro (On-Device)',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Chip(
                    label: Text(offline.ready ? 'Ready' : 'Download needed'),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                offline.ready
                    ? 'On-device Kokoro model and Misaki English frontend are installed. Generates chapters and articles offline with no API key.'
                    : 'One-time download (372 MB) enables free, private, offline narration for books and articles.',
              ),
              if (offline.status.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  offline.status,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (!offline.ready) ...[
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: offline.busy
                      ? null
                      : () => unawaited(offline.install()),
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(
                    offline.installing
                        ? 'Downloading offline files…'
                        : 'Download Kokoro model (372 MB)',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGoogleCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Google Cloud Chirp HD',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (widget.credentials.hasGoogleKey)
                const Chip(
                  label: Text('Configured'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Enable the Cloud Text-to-Speech API in Google Cloud Console and paste your API key. Billed directly to your Google Cloud account (1M Chirp HD chars/month free tier).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('google_api_key_field'),
            controller: _googleKey,
            obscureText: !_showGoogle,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Google Cloud API key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _showGoogle = !_showGoogle),
                icon: Icon(
                  _showGoogle ? Icons.visibility_off : Icons.visibility,
                ),
              ),
            ),
          ),
          if (_messages['google'] != null) ...[
            const SizedBox(height: 8),
            Text(
              _messages['google']!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('save_google_key_button'),
                onPressed: _saveGoogle,
                child: const Text('Save'),
              ),
              OutlinedButton(
                key: const Key('test_google_key_button'),
                onPressed: _testing.contains('google')
                    ? null
                    : () => _testProvider('google'),
                child: const Text('Test key'),
              ),
              if (widget.credentials.hasGoogleKey)
                TextButton(
                  onPressed: () async {
                    _googleKey.clear();
                    await _saveGoogle();
                  },
                  child: const Text('Clear'),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _buildAzureCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Azure AI Speech',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (widget.credentials.hasAzureCredentials)
                const Chip(
                  label: Text('Configured'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Create an Azure Speech resource (F0 free tier includes 500k Neural chars/month) and enter your Speech key and region.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('azure_speech_key_field'),
            controller: _azureKey,
            obscureText: !_showAzure,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Azure Speech key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _showAzure = !_showAzure),
                icon: Icon(
                  _showAzure ? Icons.visibility_off : Icons.visibility,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('azure_speech_region_field'),
            controller: _azureRegion,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Azure region',
              hintText: 'eastus',
              border: OutlineInputBorder(),
            ),
          ),
          if (_messages['azure'] != null) ...[
            const SizedBox(height: 8),
            Text(
              _messages['azure']!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('save_azure_key_button'),
                onPressed: _saveAzure,
                child: const Text('Save'),
              ),
              OutlinedButton(
                key: const Key('test_azure_key_button'),
                onPressed: _testing.contains('azure')
                    ? null
                    : () => _testProvider('azure'),
                child: const Text('Test key'),
              ),
              if (widget.credentials.hasAzureCredentials)
                TextButton(
                  onPressed: () async {
                    _azureKey.clear();
                    _azureRegion.clear();
                    await _saveAzure();
                  },
                  child: const Text('Clear'),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _buildSpeechifyCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Speechify',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (widget.credentials.hasSpeechifyKey)
                const Chip(
                  label: Text('Configured'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Paste your Speechify API key from console.sws.speechify.com to narrate chapters and articles directly with Speechify voices.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('speechify_api_key_field'),
            controller: _speechifyKey,
            obscureText: !_showSpeechify,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Speechify API key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                onPressed: () =>
                    setState(() => _showSpeechify = !_showSpeechify),
                icon: Icon(
                  _showSpeechify ? Icons.visibility_off : Icons.visibility,
                ),
              ),
            ),
          ),
          if (_messages['speechify'] != null) ...[
            const SizedBox(height: 8),
            Text(
              _messages['speechify']!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('save_speechify_key_button'),
                onPressed: _saveSpeechify,
                child: const Text('Save'),
              ),
              OutlinedButton(
                key: const Key('test_speechify_key_button'),
                onPressed: _testing.contains('speechify')
                    ? null
                    : () => _testProvider('speechify'),
                child: const Text('Test key'),
              ),
              if (widget.credentials.hasSpeechifyKey)
                TextButton(
                  onPressed: () async {
                    _speechifyKey.clear();
                    await _saveSpeechify();
                  },
                  child: const Text('Clear'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
