import 'dart:convert';

import 'package:audiobook_app/article_import.dart';
import 'package:audiobook_app/narration_dictionary.dart';
import 'package:audiobook_app/whole_book_preflight.dart';
import 'package:audiobook_app/whole_book_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'saved article Unicode, headings and scopes survive speech transforms',
    () {
      final article = ImportedArticle(
        title: 'Article',
        sourceUrl: 'https://example.org/immutable',
        blocks: const [
          ArticleBlock('😀 Cicero e\u0301', heading: true),
          ArticleBlock('***'),
          ArticleBlock('A meaningful* note. Cicero.'),
        ],
      );
      final saved = jsonEncode(article.toJson());
      final restored = ImportedArticle.fromJson(jsonDecode(saved));
      final chapter = restored.chapter;
      expect(chapter.text, article.text);
      expect(chapter.ranges.single.heading, isTrue);
      expect(chapter.ranges.single.end, article.blocks.first.text.length);
      final separator = chapter.narrationSeparators.single;
      expect(separator.start, article.blocks.first.text.length + 2);
      expect(chapter.text.substring(separator.start, separator.end), '***');

      final summary = ImportedArticle(
        title: article.title,
        sourceUrl: article.sourceUrl,
        originalId: article.id,
        originalContentHash: article.contentHash,
        depth: SummaryDepth.brief,
        blocks: const [ArticleBlock('Cicero summary.')],
      );
      final dictionary = NarrationDictionary();
      addTearDown(dictionary.dispose);
      dictionary.global = [const NarrationRule('Cicero', 'SEE')];
      dictionary.books[article.id] = [
        const NarrationRule('Cicero', 'KIK er oh'),
      ];
      final spoken = dictionary.effective(article.id).transform(chapter);
      expect(
        spoken.text,
        '😀 KIK er oh e\u0301\n\n\n\nA meaningful* note. KIK er oh.',
      );
      expect(spoken.offsets['sourceLength'], article.text.length);
      expect(spoken.offsets['spokenLength'], spoken.text.length);
      expect(
        dictionary.effective(summary.id).transform(summary.chapter).text,
        'SEE summary.',
      );
      expect(summary.id, isNot(article.id));
      expect(jsonEncode(restored.toJson()), saved);
      expect(restored.contentHash, article.contentHash);
      expect(narrationFraction(1, spoken.offsets), 1);
    },
  );

  test(
    'inactive planner consumes frozen speech and never invents reuse or price',
    () {
      final article = ImportedArticle(
        title: 'Article',
        sourceUrl: 'https://example.org/plan',
        blocks: [
          ArticleBlock(List.filled(20, '😀 Cicero').join(' ')),
          const ArticleBlock('***'),
        ],
      );
      final dictionary = NarrationDictionary();
      addTearDown(dictionary.dispose);
      dictionary.global = [const NarrationRule('Cicero', 'SEE')];
      final frozen = NarrationDictionaryConfig.fromJson(
        jsonDecode(jsonEncode(dictionary.effective(article.id).toJson())),
      );
      final spoken = frozen.transform(article.chapter);
      dictionary.global = [const NarrationRule('Cicero', 'changed')];
      final existing = <int, Map<String, dynamic>>{
        0: {'id': 'old-recording', 'status': 'ready'},
      };
      final saved = {
        for (final entry in existing.entries)
          entry.key: Map<String, dynamic>.from(entry.value),
      };
      final plan = WholeBookPreflight(
        chapters: [
          WholeBookChapter(
            index: 0,
            title: article.title,
            text: frozen.transform(article.chapter).text,
          ),
        ],
        settings: WholeBookSettings(
          engine: 'google',
          voice: 'voice',
          modelVersion: 'model',
          settings: {},
        ),
        existing: existing,
      );
      expect(plan.entries.single.disposition, WholeBookDisposition.generate);
      expect(plan.estimatedBillableCharacters, spoken.text.runes.length);
      expect(plan.estimatedBillableCharacters, isNot(spoken.text.length));
      expect(plan.estimatedTtsUsd, isNull);
      final progress = WholeBookProgress(plan: plan, serverJobs: existing);
      expect(progress.chapters.single.phase, WholeBookChapterPhase.pending);
      expect(existing, saved);
      expect(article.chapter.text, article.text);
    },
  );
}
