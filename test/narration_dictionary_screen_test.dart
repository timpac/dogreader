import 'package:audiobook_app/narration_dictionary.dart';
import 'package:audiobook_app/narration_dictionary_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryDictionary extends NarrationDictionary {
  @override
  Future<void> load() async {}
  @override
  Future<void> setRules(String? bookId, List<NarrationRule> value) async {
    if (bookId == null) {
      global = List.of(value);
    } else {
      books[bookId] = List.of(value);
    }
    notifyListeners();
  }

  @override
  Future<void> setIgnoreSeparators(bool value) async {
    ignoreSeparators = value;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'editor previews unsaved pronunciation, saves, overrides, disables and deletes',
    (tester) async {
      final dictionary = _MemoryDictionary();
      addTearDown(dictionary.dispose);
      final previews = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NarrationDictionaryScreen(
            dictionary: dictionary,
            bookTitles: const {'book': 'Book'},
            previewLabel: 'Kokoro • Lewis',
            onPreview: (text, _) async {
              previews.add(text);
            },
            onStopPreview: () async {},
          ),
        ),
      );
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add rule'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Original Text'),
        'Cicero',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Replacement Text'),
        'SISS er oh',
      );
      await tester.ensureVisible(find.text('Preview pronunciation'));
      await tester.tap(find.text('Preview pronunciation'));
      await tester.pumpAndSettle();
      expect(previews, ['SISS er oh']);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(dictionary.rules(null), isEmpty);
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(dictionary.rules(null).single.replacement, 'SISS er oh');
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Existing audio is unchanged'),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This Book: Book').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add rule'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Original Text'),
        'Cicero',
      );
      await tester.tap(find.text('Silence / Do Not Narrate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(dictionary.rules('book').single.silence, isTrue);
      await tester.tap(find.byKey(const ValueKey('enable-Cicero')));
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(dictionary.rules('book').single.enabled, isFalse);
      await tester.tap(find.text('Delete'));
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(dictionary.rules('book'), isEmpty);
      expect(dictionary.rules(null).single.replacement, 'SISS er oh');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
