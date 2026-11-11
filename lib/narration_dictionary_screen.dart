import 'package:flutter/material.dart';

import 'narration_dictionary.dart';
import 'reader_content.dart';

typedef DictionaryPreview = Future<void> Function(
  String text,
  bool Function() isCurrent,
);

class NarrationDictionaryScreen extends StatefulWidget {
  final NarrationDictionary dictionary;
  final Map<String, String> bookTitles;
  final String? initialBookId;
  final DictionaryPreview onPreview;
  final Future<void> Function() onStopPreview;
  final String previewLabel;
  const NarrationDictionaryScreen({
    super.key,
    required this.dictionary,
    this.bookTitles = const {},
    this.initialBookId,
    required this.onPreview,
    required this.onStopPreview,
    required this.previewLabel,
  });

  @override
  State<NarrationDictionaryScreen> createState() =>
      _NarrationDictionaryScreenState();
}

class _NarrationDictionaryScreenState extends State<NarrationDictionaryScreen> {
  String? bookId;
  bool loading = true;
  bool previewing = false;
  int previewSequence = 0;
  String? notice;
  final sample = TextEditingController(text: 'Cicero spoke to the crowd.');
  NarrationDictionary get dictionary => widget.dictionary;

  @override
  void initState() {
    super.initState();
    bookId = widget.initialBookId;
    dictionary.load().then((_) {
      if (mounted) setState(() => loading = false);
    });
  }

  Future<bool> save(Future<void> action) async {
    try {
      await action;
      if (mounted) {
        setState(
          () => notice = 'Saved. Existing audio is unchanged; regenerate affected chapters to apply changes.',
        );
      }
      return true;
    } catch (_) {
      if (mounted) {
        setState(
          () => notice =
              'Could not save dictionary. Please try again before leaving.',
        );
      }
      return false;
    }
  }

  Future<void> preview(String text) async {
    final sequence = ++previewSequence;
    if (text.trim().isEmpty) {
      setState(() => notice = 'This sample is silent (Do Not Narrate).');
      return;
    }
    setState(() {
      previewing = true;
      notice = 'Preparing a short preview…';
    });
    try {
      await widget.onPreview(
        text,
        () => mounted && sequence == previewSequence,
      );
      if (mounted && sequence == previewSequence) {
        setState(() => notice = 'Preview: ${widget.previewLabel}');
      }
    } catch (e) {
      if (mounted && sequence == previewSequence) {
        setState(() => notice = 'Preview unavailable: $e');
      }
    } finally {
      if (mounted && sequence == previewSequence) {
        setState(() => previewing = false);
      }
    }
  }

  Future<void> stopPreview() async {
    previewSequence++;
    await widget.onStopPreview();
    if (mounted) setState(() => previewing = false);
  }

  Future<void> edit([int? index]) async {
    final rules = dictionary.rules(bookId);
    final result = await showDialog<NarrationRule>(
      context: context,
      builder: (_) => _RuleEditor(
        rule: index == null ? null : rules[index],
        originals: {
          for (final entry in rules.indexed)
            if (entry.$1 != index) entry.$2.original,
        },
        onPreview: (draft) async {
          final text = NarrationDictionaryConfig(rules: [draft])
              .transform(ReaderChapter('', draft.original, const []))
              .text;
          await preview(text);
          return notice ?? '';
        },
      ),
    );
    await stopPreview();
    if (result == null || !mounted) return;
    final updated = List<NarrationRule>.of(rules);
    if (index == null) {
      updated.add(result);
    } else {
      updated[index] = result;
    }
    await save(dictionary.setRules(bookId, updated));
  }

  @override
  void dispose() {
    previewSequence++;
    widget.onStopPreview();
    sample.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rules = dictionary.rules(bookId);
    return Scaffold(
      appBar: AppBar(title: const Text('Narration Dictionary')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<String>(
                  initialValue: bookId ?? '',
                  decoration: const InputDecoration(
                    labelText: 'Global / This Book',
                  ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Global')),
                    for (final book in widget.bookTitles.entries)
                      DropdownMenuItem(
                        value: book.key,
                        child: Text(
                          'This Book: ${book.value}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  isExpanded: true,
                  onChanged: (value) =>
                      setState(() => bookId = value == '' ? null : value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Ignore common decorative separators'),
                  subtitle: const Text(
                    'Global setting. Silences standalone ***, ⁂ and common ornaments. They remain visible while reading.',
                  ),
                  value: dictionary.ignoreSeparators,
                  onChanged: (value) =>
                      save(dictionary.setIgnoreSeparators(value)),
                ),
                const Text(
                  'Dictionary changes apply to new narration. Existing audio stays intact until you explicitly regenerate affected chapters.',
                ),
                if (notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(notice!),
                  ),
                for (final entry in rules.indexed)
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          title: Text(entry.$2.original),
                          subtitle: Text(
                            entry.$2.silence
                                ? 'Do Not Narrate'
                                : entry.$2.replacement,
                          ),
                          onTap: () => edit(entry.$1),
                          trailing: Switch(
                            value: entry.$2.enabled,
                            key: ValueKey('enable-${entry.$2.original}'),
                            onChanged: (value) {
                              final updated = List<NarrationRule>.of(rules);
                              final r = entry.$2;
                              updated[entry.$1] = NarrationRule(
                                r.original,
                                r.replacement,
                                silence: r.silence,
                                enabled: value,
                              );
                              save(dictionary.setRules(bookId, updated));
                            },
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => edit(entry.$1),
                              child: const Text('Edit'),
                            ),
                            TextButton(
                              onPressed: () {
                                final updated = List<NarrationRule>.of(rules)
                                  ..removeAt(entry.$1);
                                save(dictionary.setRules(bookId, updated));
                              },
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                FilledButton.icon(
                  onPressed: () => edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add rule'),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: sample,
                  maxLength: 160,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Short preview sample',
                  ),
                ),
                Text(widget.previewLabel),
                TextButton.icon(
                  icon: Icon(previewing ? Icons.stop : Icons.volume_up),
                  label: Text(previewing ? 'Stop preview' : 'Preview sample'),
                  onPressed: previewing
                      ? stopPreview
                      : () {
                          // Samples are plain text, never interpreted as publisher markup.
                          final transformed = dictionary
                              .effective(bookId)
                              .transform(
                                ReaderChapter('', sample.text, const []),
                              );
                          preview(transformed.text);
                        },
                ),
              ],
            ),
    );
  }
}

/// Own the controllers for exactly the dialog's mounted lifetime, including its
/// outgoing route animation. Previewing never saves or discards the draft.
class _RuleEditor extends StatefulWidget {
  final NarrationRule? rule;
  final Set<String> originals;
  final Future<String> Function(NarrationRule rule) onPreview;
  const _RuleEditor({
    this.rule,
    required this.originals,
    required this.onPreview,
  });
  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final original = TextEditingController(
    text: widget.rule?.original ?? '',
  );
  late final replacement = TextEditingController(
    text: widget.rule?.replacement ?? '',
  );
  late bool silence = widget.rule?.silence ?? false;
  late bool enabled = widget.rule?.enabled ?? true;
  bool previewing = false;
  String? notice;
  final form = GlobalKey<FormState>();
  NarrationRule get draft => NarrationRule(
    original.text,
    replacement.text,
    silence: silence,
    enabled: enabled,
  );

  @override
  void dispose() {
    original.dispose();
    replacement.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.rule == null ? 'Add rule' : 'Edit rule'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: original,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Original Text'),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Enter original text';
                }
                if (widget.originals.contains(value)) {
                  return 'A rule for this text already exists';
                }
                return null;
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Silence / Do Not Narrate'),
              value: silence,
              onChanged: (value) => setState(() => silence = value),
            ),
            if (!silence)
              TextFormField(
                controller: replacement,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Replacement Text',
                ),
                validator: (value) =>
                    !silence && (value == null || value.trim().isEmpty)
                    ? 'Enter replacement text or select Silence'
                    : null,
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable rule'),
              value: enabled,
              onChanged: (value) => setState(() => enabled = value),
            ),
            const Text(
              'Matching is literal and case-sensitive, at word edges. Per-book rules override Global, even when disabled.',
            ),
            if (notice != null) Text(notice!),
            TextButton.icon(
              icon: Icon(previewing ? Icons.stop : Icons.volume_up),
              label: Text(
                previewing ? 'Preparing preview…' : 'Preview pronunciation',
              ),
              onPressed: previewing
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      setState(() {
                        previewing = true;
                        notice = null;
                      });
                      final message = await widget.onPreview(draft);
                      if (mounted) {
                        setState(() {
                          previewing = false;
                          notice = message;
                        });
                      }
                    },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) Navigator.pop(context, draft);
        },
        child: const Text('Save'),
      ),
    ],
  );
}
