import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/app_theme.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/theme_preferences.dart';
import 'package:audiobook_app/reader_content.dart' show parseReaderChapter;

import 'light_theme_test.dart' show contrast;

// Keep disk I/O in the persistence tests; widget tests use Flutter's fake clock.
class MemoryPreferences extends ThemePreferences {
  ThemeMode _value = ThemeMode.light;
  final choices = <ThemeMode>[];

  @override
  ThemeMode get mode => _value;

  @override
  Future<void> setMode(ThemeMode mode) async {
    _value = mode;
    choices.add(mode);
    notifyListeners();
  }
}

Widget themedApp(ThemePreferences preferences, {Widget? home}) => AnimatedBuilder(
  animation: preferences,
  builder: (context, child) => MaterialApp(
    theme: dogreaderLightTheme(),
    darkTheme: dogreaderDarkTheme(),
    themeMode: preferences.mode,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.5)),
      child: child!,
    ),
    home: home ?? LibraryScreen(appearance: preferences),
  ),
);

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dogreader-appearance-');
    file = File('${directory.path}/appearance.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('missing, malformed, or unknown preferences default to light', () async {
    final preferences = ThemePreferences(preferencesFile: () async => file);
    addTearDown(preferences.dispose);
    await preferences.load();
    expect(preferences.mode, ThemeMode.light);
    for (final content in ['broken json', '[]', '{"theme":"unknown"}']) {
      await file.writeAsString(content);
      await preferences.load();
      expect(preferences.mode, ThemeMode.light);
    }
  });

  test('all three choices survive restart and rapid changes save the latest', () async {
    final preferences = ThemePreferences(preferencesFile: () async => file);
    final reopened = ThemePreferences(preferencesFile: () async => file);
    addTearDown(preferences.dispose);
    addTearDown(reopened.dispose);
    for (final mode in ThemeMode.values) {
      await preferences.setMode(mode);
      await reopened.load();
      expect(reopened.mode, mode);
    }
    await Future.wait([
      preferences.setMode(ThemeMode.light),
      preferences.setMode(ThemeMode.dark),
      preferences.setMode(ThemeMode.system),
    ]);
    await reopened.load();
    expect(reopened.mode, ThemeMode.system);
  });

  test('failed save is reported and does not block a subsequent save', () async {
    var fail = true;
    final preferences = ThemePreferences(preferencesFile: () async {
      if (fail) throw const FileSystemException('Unavailable');
      return file;
    });
    addTearDown(preferences.dispose);
    await expectLater(preferences.setMode(ThemeMode.dark), throwsA(isA<FileSystemException>()));
    expect(preferences.mode, ThemeMode.dark);
    fail = false;
    await preferences.setMode(ThemeMode.light);
    expect(await file.readAsString(), '{"theme":"light"}');
  });

  test('dark surfaces, text, buttons, and system bars remain readable', () {
    final theme = dogreaderDarkTheme();
    final scheme = theme.colorScheme;
    expect(theme.brightness, Brightness.dark);
    for (final surface in [scheme.surface, scheme.surfaceContainerLow]) {
      for (final foreground in [scheme.onSurface, scheme.onSurfaceVariant,
          scheme.primary, scheme.error]) {
        expect(contrast(foreground, surface), greaterThanOrEqualTo(4.5));
      }
    }
    final button = theme.filledButtonTheme.style!;
    expect(contrast(button.foregroundColor!.resolve({})!,
        button.backgroundColor!.resolve({})!), greaterThanOrEqualTo(4.5));
    expect(theme.appBarTheme.systemOverlayStyle!.statusBarIconBrightness, Brightness.light);
    expect(theme.appBarTheme.systemOverlayStyle!.systemNavigationBarIconBrightness, Brightness.light);
  });

  testWidgets('Settings switches all three modes without losing tab or library state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final preferences = MemoryPreferences();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(themedApp(preferences));
    await tester.pumpAndSettle();
    final libraryState = tester.state(find.byType(LibraryScreen));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    tester.binding.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.binding.platformDispatcher.clearPlatformBrightnessTestValue);
    for (final label in ['Dark', 'Light', 'Follow system']) {
      await tester.tap(find.byType(DropdownButton<ThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
      expect(tester.state(find.byType(LibraryScreen)), same(libraryState));
      final theme = Theme.of(tester.element(find.byType(DropdownButton<ThemeMode>)));
      expect(theme.brightness, label == 'Dark' ? Brightness.dark : Brightness.light);
      expect(tester.takeException(), isNull);
    }
    expect(preferences.choices, [ThemeMode.dark, ThemeMode.light, ThemeMode.system]);
    for (final brightness in [Brightness.dark, Brightness.light]) {
      tester.binding.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byType(DropdownButton<ThemeMode>))).brightness,
          brightness);
      expect(preferences.mode, ThemeMode.system);
    }
  });

  testWidgets('switching while reading preserves the route and page anchor', (tester) async {
    final preferences = MemoryPreferences();
    addTearDown(preferences.dispose);
    final chapter = parseReaderChapter('One', List.filled(80,
        '<p>Words with <em>emphasis</em> and <strong>bold</strong> text.</p>').join());
    final book = ImportedBook('Book', 'Author', [chapter], 'appearance-book', null);
    await tester.pumpWidget(themedApp(preferences));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => ReadingScreen(
      book: book, chapterIndex: 0, initialOffset: 0,
      onSave: (_, offset) async {},
    )));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(ReadingScreen));
    state.jumpToPage(3);
    await tester.pumpAndSettle();
    final anchor = state.currentOffset;
    final page = state.currentPage;
    final pages = List<String>.from(state.pages as List);
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      await preferences.setMode(mode);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ReadingScreen)), same(state));
      expect(state.currentOffset, anchor);
      expect(state.currentPage, page);
      expect(state.pages, pages);
      final span = state.styledPage(0, chapter.text.length) as TextSpan;
      final scheme = Theme.of(tester.element(find.byType(ReadingScreen))).colorScheme;
      expect(contrast(span.style!.color!, scheme.surface), greaterThanOrEqualTo(4.5));
      expect(span.toPlainText(), chapter.text);
      expect(tester.takeException(), isNull);
    }
    expect(navigator.canPop(), isTrue);
  });
}
