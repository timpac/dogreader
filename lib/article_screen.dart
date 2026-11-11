import 'package:flutter/material.dart';

import 'article_import.dart';
import 'article_library.dart';

typedef OpenArticle = void Function(ImportedArticle article, bool narration);

class ArticleImportScreen extends StatefulWidget {
  const ArticleImportScreen({
    super.key,
    required this.library,
    required this.openArticle,
    this.initialUrl,
  });
  final ArticleLibrary library;
  final OpenArticle openArticle;
  final String? initialUrl;
  @override
  State<ArticleImportScreen> createState() => _ArticleImportScreenState();
}

class _ArticleImportScreenState extends State<ArticleImportScreen> {
  late final TextEditingController url = TextEditingController(
    text: widget.initialUrl,
  );
  bool summary = false;
  String? error;
  @override
  void dispose() {
    url.dispose();
    super.dispose();
  }

  void enqueue() {
    try {
      final job = widget.library.enqueue(url.text);
      setState(() {
        error = null;
        url.clear();
      });
      if (summary) {
        widget.library.settled.then((_) {
          if (mounted && job.article != null) _details(job.article!);
        });
      }
    } on ArticleImportException catch (e) {
      setState(() => error = e.message);
    }
  }

  void _details(ImportedArticle article) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ArticleDetailScreen(
        article: article,
        library: widget.library,
        openArticle: widget.openArticle,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Import a web article')),
    body: AnimatedBuilder(
      animation: widget.library,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(22),
        children: [
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onSubmitted: (_) => enqueue(),
            decoration: InputDecoration(
              labelText: 'Article URL',
              hintText: 'https://…',
              errorText: error,
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Read original')),
              ButtonSegment(value: true, label: Text('AI summary')),
            ],
            selected: {summary},
            onSelectionChanged: (value) =>
                setState(() => summary = value.single),
          ),
          const SizedBox(height: 12),
          Text(
            summary
                ? 'Save the original first, then choose summary depth and review usage before generating.'
                : 'Save the main article text for offline reading. Importing does not use paid AI.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: enqueue,
            icon: const Icon(Icons.add_link),
            label: const Text('Import article'),
          ),
          const SizedBox(height: 16),
          const Text(
            'Articles import one at a time. You can add another URL while an import is running.',
          ),
          for (final job in widget.library.jobs.reversed)
            Card(
              child: ListTile(
                title: Text(
                  job.article?.title ?? job.url,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(job.error ?? job.status),
                trailing: job.status == 'Importing'
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: job.article == null
                    ? null
                    : () => _details(job.article!),
              ),
            ),
        ],
      ),
    ),
  );
}

class ArticleDetailScreen extends StatefulWidget {
  const ArticleDetailScreen({
    super.key,
    required this.article,
    required this.library,
    required this.openArticle,
  });
  final ImportedArticle article;
  final ArticleLibrary library;
  final OpenArticle openArticle;
  @override
  State<ArticleDetailScreen> createState() => _ArticleDetailScreenState();
}

class _ArticleDetailScreenState extends State<ArticleDetailScreen> {
  SummaryDepth depth = SummaryDepth.standard;
  bool busy = false;
  String? notice;
  Map<String, dynamic>? estimate;
  String cost(Map<String, dynamic>? value) {
    final amount = value?['estimatedCostUsd'];
    return amount is num
        ? 'Estimated AI cost: US\$${amount.toStringAsFixed(5)}'
        : 'AI cost unavailable. Your configured cloud provider may charge for this request.';
  }

  Future<void> review() async {
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      final result = await widget.library.estimate(widget.article, depth);
      if (mounted) setState(() => estimate = result);
    } catch (e) {
      if (mounted) setState(() => notice = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> generate() async {
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      final result = await widget.library.summarize(widget.article, depth);
      if (mounted) widget.openArticle(result, false);
    } catch (e) {
      if (mounted) setState(() => notice = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    final original = article.depth == null
        ? article
        : widget.library.articles
              .where((a) => a.id == article.originalId)
              .firstOrNull;
    final saved = widget.library.savedSummary(article, depth);
    return Scaffold(
      appBar: AppBar(title: const Text('Article')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Text(article.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          if (article.author != null) Text('By ${article.author}'),
          if (article.published != null)
            Text('Published: ${article.published}'),
          SelectableText(article.sourceUrl),
          const SizedBox(height: 12),
          if (article.depth != null) ...[
            Text(
              'AI summary · ${article.depth!.label}. Check important details against the original.',
            ),
            if (article.usage?['costUsd'] is num)
              Text(
                'AI usage: US\$${(article.usage!['costUsd'] as num).toStringAsFixed(5)}',
              ),
          ],
          FilledButton(
            onPressed: () => widget.openArticle(article, false),
            child: Text(
              article.depth == null ? 'Read original' : 'Read summary',
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => widget.openArticle(article, true),
            icon: const Icon(Icons.record_voice_over),
            label: const Text('Generate / listen to narration'),
          ),
          if (article.depth != null && original != null)
            TextButton(
              onPressed: () => widget.openArticle(original, false),
              child: const Text('Read original article'),
            ),
          if (article.depth == null) ...[
            const Divider(height: 32),
            Text('AI summary', style: Theme.of(context).textTheme.titleLarge),
            const Text(
              'Choose how much detail to keep. AI summaries may contain errors; the original remains available.',
            ),
            const SizedBox(height: 12),
            Text('${depth.label}: ${depth.description}'),
            Slider(
              value: depth.index.toDouble(),
              min: 0,
              max: 2,
              divisions: 2,
              label: depth.label,
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      depth = SummaryDepth.values[value.round()];
                      estimate = null;
                      notice = null;
                    }),
            ),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text('Brief'), Text('Standard'), Text('Detailed')],
            ),
            const SizedBox(height: 16),
            if (saved != null) ...[
              const Text(
                'Saved summary available offline. No new AI request needed.',
              ),
              FilledButton(
                onPressed: () => widget.openArticle(saved, false),
                child: const Text('Read saved summary'),
              ),
              OutlinedButton(
                onPressed: () => widget.openArticle(saved, true),
                child: const Text('Narrate saved summary'),
              ),
            ] else ...[
              if (estimate != null) Text(cost(estimate)),
              FilledButton(
                onPressed: busy
                    ? null
                    : estimate == null
                    ? review
                    : generate,
                child: Text(
                  busy
                      ? 'Please wait…'
                      : estimate == null
                      ? 'Review AI usage'
                      : 'Generate ${depth.label.toLowerCase()} summary',
                ),
              ),
            ],
            if (notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(notice!),
              ),
          ],
        ],
      ),
    );
  }
}
