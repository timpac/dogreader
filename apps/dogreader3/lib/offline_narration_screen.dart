import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'offline_narration.dart';
import 'reader_content.dart';

class OfflineNarrationScreen extends StatefulWidget {
  const OfflineNarrationScreen({super.key, required this.controller, required this.bookId,
    required this.bookTitle, required this.chapters, required this.onPlay});
  final OfflineNarration controller;
  final String bookId, bookTitle;
  final List<ReaderChapter> chapters;
  final Future<void> Function(int) onPlay;
  @override
  State<OfflineNarrationScreen> createState() => _OfflineNarrationScreenState();
}

class _OfflineNarrationScreenState extends State<OfflineNarrationScreen> {
  int index = 0, sid = 3, threads = 2;
  bool starting = true;
  String? error;
  OfflineNarration get controller => widget.controller;
  Map<String, dynamic>? get recording {
    final item = controller.recordings['${widget.bookId}:$index'];
    return item is Map ? Map<String, dynamic>.from(item) : null;
  }
  @override
  void initState() { super.initState(); initialize(); }
  Future<void> initialize() async {
    try {
      await controller.initialize();
      final settings = File('${controller.root}/offline-settings.json');
      if (await settings.exists()) {
        final saved = jsonDecode(await settings.readAsString()) as Map;
        if (offlineVoices.containsKey(saved['sid'])) sid = saved['sid'] as int;
        if ([1, 2, 4].contains(saved['threads'])) threads = saved['threads'] as int;
      }
      final chapter = controller.job?['chapter'];
      if (chapter is Map && chapter['bookId'] == widget.bookId) {
        index = (chapter['chapterIndex'] as int).clamp(0, widget.chapters.length - 1);
      }
    } catch (e) { error = '$e'; }
    if (mounted) setState(() => starting = false);
  }

  Future<void> action(Future<void> Function() operation) async {
    if (mounted) setState(() { starting = true; error = null; });
    try { await operation(); } catch (e) { error = '$e'; }
    if (mounted) setState(() => starting = false);
  }

  Future<void> generate() async {
    if (recording != null) {
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('Generate another offline recording?'),
        content: const Text('The previous completed WAV remains available until the new chapter finishes. Cloud recordings are kept separately.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Generate'))]));
      if (accepted != true) return;
    }
    await action(() async {
      await File('${controller.root}/offline-settings.json').writeAsString(jsonEncode({'sid': sid, 'threads': threads}), flush: true);
      await controller.generate(bookId: widget.bookId, bookTitle: widget.bookTitle,
        index: index, chapter: widget.chapters[index], sid: sid, threads: threads);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: controller, builder: (context, _) {
    final busy = starting || controller.busy;
    final current = controller.job;
    final completed = current?['completedChunks'] as int? ?? 0;
    final total = current?['totalChunks'] as int? ?? 0;
    final chapter = current?['chapter'];
    final ownJob = chapter is Map && chapter['key'] == '${widget.bookId}:$index';
    final item = recording;
    return Scaffold(appBar: AppBar(title: const Text('Kokoro Offline')), body: ListView(
      padding: const EdgeInsets.all(20), children: [
        Text(widget.bookTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        const Text('FP32 • Misaki English • entirely on this device after installation. Cloud Chirp and cloud Kokoro remain available on the narration screen.'),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(key: ValueKey('chapter-$index'), initialValue: index, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Chapter'),
          items: [for (var i = 0; i < widget.chapters.length; i++) DropdownMenuItem(value: i,
            child: Text('${i + 1}. ${widget.chapters[i].title}', overflow: TextOverflow.ellipsis))],
          onChanged: busy ? null : (value) => setState(() => index = value!)),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(key: ValueKey('voice-$sid'), initialValue: sid, decoration: const InputDecoration(labelText: 'Offline voice'),
          items: [for (final voice in offlineVoices.entries) DropdownMenuItem(value: voice.key, child: Text(voice.value))],
          onChanged: busy ? null : (value) => setState(() => sid = value!)),
        DropdownButtonFormField<int>(key: ValueKey('threads-$threads'), initialValue: threads, decoration: const InputDecoration(labelText: 'CPU threads'),
          items: [for (final n in [1, 2, 4]) DropdownMenuItem(value: n, child: Text('$n'))],
          onChanged: busy ? null : (value) => setState(() => threads = value!)),
        const SizedBox(height: 16),
        Text(controller.ready ? 'Offline files installed.' : 'Optional download: FP32 349.9 MB + English frontend 22.2 MB. Allow 1.5 GB free during setup. Keep this screen open during installation.'),
        if (!controller.ready) OutlinedButton(onPressed: busy ? null : () => action(controller.install),
          child: const Text('Download offline files (372 MB)')),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: busy || !controller.ready ? null : generate,
          icon: const Icon(Icons.offline_bolt), label: const Text('Generate chapter offline')),
        if (controller.active) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: total > 0 ? completed / total : null),
          Text('$completed/$total chunks saved'),
          Text(chapter is Map ? '${chapter['bookTitle']} • ${chapter['chapterTitle']}' : ''),
          OutlinedButton(onPressed: () => action(controller.cancel), child: const Text('Cancel offline generation')),
        ],
        if (!busy && ownJob && current?['outcome'] != 'completed')
          OutlinedButton(onPressed: () => action(controller.resume), child: const Text('Retry saved chapter job')),
        const SizedBox(height: 12),
        SelectableText(controller.status),
        if (item != null) ...[
          const Divider(height: 32),
          Text('Completed • Kokoro Offline FP32 • ${item['voice']}'),
          Text('${((item['result'] as Map)['audioSeconds'] as num).toStringAsFixed(1)} seconds of audio'),
          FilledButton.icon(onPressed: starting ? null : () => action(() async {
            await controller.select(item);
            await widget.onPlay(index);
          }), icon: const Icon(Icons.play_arrow), label: const Text('Play completed chapter')),
          TextButton(onPressed: starting ? null : () => action(() => controller.export((item['result'] as Map)['path'] as String)),
            child: const Text('Save offline WAV')),
        ],
        if (current?['reportPath'] is String && !controller.active)
          TextButton(onPressed: starting ? null : () => action(() => controller.export(current!['reportPath'] as String)),
            child: const Text('Save generation diagnostics')),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        TextButton(onPressed: () => showLicensePage(context: context, applicationName: 'Dogreader 3.0'), child: const Text('Offline component licenses')),
        const SizedBox(height: 16),
        const Text('You can switch apps or lock the screen during generation. The progress notification offers Cancel. Android time quotas and battery restrictions still apply. Names are best-effort; unresolved input reports an error. Completed PCM chunks are retained for retry; no automatic restart.'),
      ]));
  });
}
