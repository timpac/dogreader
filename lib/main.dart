import 'package:just_audio/just_audio.dart' as ja;
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:async';

import 'package:path_provider/path_provider.dart';

import 'package:epubx/epubx.dart' hide Image;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, rootBundle;
import 'package:google_fonts/google_fonts.dart';
import 'package:audio_service/audio_service.dart';

import 'dogreader_audio_handler.dart';
import 'book_progress.dart';
import 'media_diagnostics.dart';
import 'native_media_diagnostics.dart';
import 'app_theme.dart';
import 'theme_preferences.dart';
export 'app_theme.dart' show background, panel, accent;

import 'reader_content.dart';
export 'reader_content.dart' show ReaderChapter, StyledRange;
import 'narration_seek.dart';
import 'narration_files.dart';
import 'narration_delivery.dart';
import 'narration_presentation.dart';
import 'narration_storage.dart';
import 'narration_options.dart';
import 'narration_cost.dart';
import 'narration_dictionary.dart';
import 'narration_dictionary_screen.dart';
import 'byok_tts.dart';
import 'api_settings_screen.dart';
import 'article_import.dart';
import 'article_library.dart';
import 'article_screen.dart';
import 'article_share.dart';
import 'offline_narration.dart';
import 'kokoro/service_runner.dart';
import 'rss/rss_controller.dart';
import 'rss/rss_screens.dart';
import 'rss/rss_shelf.dart';

@pragma('vm:entry-point')
void generationMain() => unawaited(runGenerationService());

late final DogreaderAudioHandler audioHandler;
final byokCredentials = ByokCredentialStore();
ByokTtsClient byokTtsClient = ByokTtsClient(credentials: byokCredentials);
ByokNarrationRunner byokNarrationRunner = ByokNarrationRunner(
  client: byokTtsClient,
  documentsDirectory: getApplicationDocumentsDirectory,
  beforeReplace: (book, index) => audioHandler.unloadChapter(book, index),
  costTracker: narrationCostTracker,
);
final narrationDelivery = NarrationDelivery(
  documentsDirectory: getApplicationDocumentsDirectory,
  beforeReplace: (book, index) => audioHandler.unloadChapter(book, index),
  diagnosticSink: (fields) => audioHandler.diagnostics?.record(MediaDiagnosticEvent.narrationDelivery, fields),
);

OfflineNarration offlineNarration = OfflineNarration(
  beforeSelect: (book, index) async {
    try {
      await audioHandler.unloadChapter(book, index);
    } catch (_) {}
  },
  isChapterPlaying: (book, index) {
    try {
      return audioHandler.isChapterPlaying(book, index);
    } catch (_) {
      return false;
    }
  },
  onChapterStateChanged: (bookId, chapterIndex, jobState) async {
    await narrationDelivery.load();
    final bookJobs = narrationDelivery.books.putIfAbsent(bookId, () => {});
    bookJobs[chapterIndex] = {...?bookJobs[chapterIndex], ...jobState};
    await narrationDelivery.save();
  },
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    try {
      yield LicenseEntryWithLineBreaks(
        ['Kokoro Offline / Misaki'],
        '${await rootBundle.loadString('LICENSES.txt')}\n\n${await rootBundle.loadString('frontend-notices.txt')}',
      );
    } catch (_) {}
  });

  final diagnostics = MediaDiagnostics(directory: () async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/media_diagnostics');
  });
  diagnostics.record(MediaDiagnosticEvent.processStarted, {'build': dogreaderBuild});

  audioHandler = await AudioService.init(
    builder: () => DogreaderAudioHandler(diagnostics: diagnostics, progress: bookProgress),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.timpac.dogreader.audio',
      androidNotificationChannelName: 'Dogreader narration',
      // Keep the media service available for lock-screen/Bluetooth resume.
      androidStopForegroundOnPause: false,
    ),
  );

  audioHandler.observeLifecycle();
  await audioHandler.initializeAudioSession();
  unawaited(offlineNarration.initialize().catchError((Object _) {}));
  unawaited(NativeMediaDiagnostics.start(diagnostics));

  final appearance = ThemePreferences();
  await appearance.load();
  await byokCredentials.load();
  await narrationDictionary.load();
  await narrationCostTracker.load();
  runApp(NarrationPlaybackScope(
    handler: audioHandler, child: AudiobookApp(appearance: appearance),
  ));
}

/// Shared entry point for Settings and the book's narration queue.
Future<void> openNarrationDictionary(BuildContext context, {
  required Map<String, String> bookTitles, String? bookId,
  NarrationPreference? preference, String? host, String? token,
}) async {
  Map<String, dynamic> saved = {};
  if (preference == null) {
    try {
      final root = await getApplicationDocumentsDirectory();
      saved = jsonDecode(await File('${root.path}/dogreader_queue.json').readAsString()) as Map<String, dynamic>;
    } catch (_) {}
  }
  final selected = preference ?? NarrationPreference.fromJson(saved);
  if (!context.mounted) return;
  await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NarrationDictionaryScreen(
    dictionary: narrationDictionary, bookTitles: bookTitles, initialBookId: bookId,
    previewLabel: recordingLabel(selected.toJson()),
    onStopPreview: () => audioHandler.stopPreview(),
    onPreview: (sample, isCurrent) async {
      if (selected.isOffline) {
        throw StateError('Switch to a configured API voice (Google Chirp, Azure, or Speechify) to preview pronunciation snippets.');
      }
      final file = await byokTtsClient.synthesizePreview(
        preference: selected,
        sample: sample,
        isCurrent: isCurrent,
      );
      if (file != null && isCurrent()) await audioHandler.playPreview(file.path, 'Pronunciation preview');
    },
  )));
}

// Set by GitHub Actions at build time; visible on the library home screen.
const dogreaderBuild = String.fromEnvironment('DOGREADER_BUILD', defaultValue: 'DEV');

class AudiobookApp extends StatelessWidget {
  const AudiobookApp({super.key, required this.appearance});

  final ThemePreferences appearance;

  @override
  Widget build(BuildContext context) {
    final theme = dogreaderLightTheme();
    final darkTheme = dogreaderDarkTheme();
    return AnimatedBuilder(
      animation: appearance,
      builder: (context, child) => MaterialApp(
        title: 'Dogreader',
        debugShowCheckedModeBanner: false,
        theme: theme.copyWith(
          textTheme: GoogleFonts.urbanistTextTheme(theme.textTheme),
          primaryTextTheme: GoogleFonts.urbanistTextTheme(theme.primaryTextTheme),
        ),
        darkTheme: darkTheme.copyWith(
          textTheme: GoogleFonts.urbanistTextTheme(darkTheme.textTheme),
          primaryTextTheme: GoogleFonts.urbanistTextTheme(darkTheme.primaryTextTheme),
        ),
        themeMode: appearance.mode,
        home: LibraryScreen(appearance: appearance),
      ),
    );
  }
}

class ImportedBook {
  final String title;
  final String author;
  final List<ReaderChapter> chapters;
  final String id;
  final Uint8List? cover;
  const ImportedBook(
    this.title,
    this.author,
    this.chapters,
    this.id,
    this.cover,
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.appearance,
    this.progressStore,
    this.articleLibrary,
  });

  final BookProgress? progressStore;
  final ArticleLibrary? articleLibrary;

  final ThemePreferences? appearance;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with WidgetsBindingObserver {
  late final ArticleLibrary articles;
  late final RssLibraryController rss;
  bool _showingArticleImports = false;
  int selectedTab = 0;
  bool importing = false;
  final List<ImportedBook> books = [];
  BookProgress get progress => widget.progressStore ?? bookProgress;

  void sortBooks() {
    books.sort((a, b) {
      final recent = progress.lastOpened(b.id).compareTo(progress.lastOpened(a.id));
      if (recent != 0) return recent;
      return b.id.compareTo(a.id);
    });
  }

  void _progressChanged() {
    if (mounted) setState(sortBooks);
  }

  ImportedBook articleBook(ImportedArticle article) => ImportedBook(
    article.depth == null ? article.title : '${article.title} — ${article.depth!.label} summary',
    article.author ?? 'Unknown author', [article.chapter], article.id, null);

  void openArticle(ImportedArticle article, bool narration) {
    final book = articleBook(article);
    if (narration) {
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NarrationQueueScreen(
        book: book, onSave: (chapter, offset) => saveProgress(book.id, chapter, offset))));
    } else {
      openBook(book, articleText: true);
    }
  }

  void openRssHome({
    RssArticleFilterMode? initialMode,
    String? subscriptionId,
    String? folderId,
    String? authorId,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RssHomeScreen(
          controller: rss,
          articleLibrary: articles,
          onOpenArticle: openArticle,
          initialMode: initialMode ?? RssArticleFilterMode.all,
          initialSubscriptionId: subscriptionId,
          initialFolderId: folderId,
          initialAuthorId: authorId,
        ),
      ),
    );
  }

  void articleDetails(ImportedArticle article) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ArticleDetailScreen(
      article: article, library: articles, openArticle: openArticle)));
  }

  void openBook(ImportedBook book, {bool articleText = false}) {
    final article = articles.articles.where((a) => a.id == book.id).firstOrNull;
    if (!articleText && article != null) { articleDetails(article); return; }
    final rssArticle = rss.articleById(book.id);
    if (!articleText && rssArticle != null) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => RssArticleReadingScreen(
            controller: rss,
            articleLibrary: articles,
            initialArticleId: rssArticle.id,
            orderedArticleIds: [rssArticle.id],
            onOpenArticle: openArticle,
          ),
        ),
      );
      return;
    }
    setState(() {
      sortBooks();
    });
    progress.opened(book.id).catchError((Object _) {});

    final saved = progress.continuePosition(book.id);
    final chapter = (saved?['chapter'] ?? 0).clamp(0, book.chapters.length - 1);
    final offset = (saved?['offset'] ?? 0).clamp(
      0,
      book.chapters[chapter].text.length,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingScreen(
          continuous: articleText,
          book: book,
          chapterIndex: chapter,
          initialOffset: offset,
          onSave: (chapter, offset) => saveProgress(book.id, chapter, offset),
          progressStore: progress,
        ),
      ),
    );
  }

  void openChapters(ImportedBook book) {
    final article = articles.articles.where((a) => a.id == book.id).firstOrNull;
    if (article != null) { articleDetails(article); return; }
    final rssArticle = rss.articleById(book.id);
    if (rssArticle != null) {
      openArticle(rssArticle.toImportedArticle(), true);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChapterListScreen(
          book: book,
          saved: progress.continuePosition(book.id),
          progressStore: progress,
          onSave: (chapter, offset) => saveProgress(book.id, chapter, offset),
          chapterOffsets: const {},
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    progress.addListener(_progressChanged);
    narrationDelivery.chapterResolver = _resolveChapterForDelivery;
    narrationDelivery.start();
    articles =
        widget.articleLibrary ??
        ArticleLibrary(getApplicationDocumentsDirectory());
    articles.addListener(_articlesChanged);
    articles.load().catchError((Object _) {});
    rss = RssLibraryController(getApplicationDocumentsDirectory());
    rss.addListener(_articlesChanged);
    rss.load().catchError((Object _) {});
    loadLibrary();
    ArticleShare.listen(_receiveArticleShare).catchError((Object _) {});
  }

  Future<ReaderChapter?> _resolveChapterForDelivery(
    String bookId,
    int index,
  ) async {
    final loaded = books.where((b) => b.id == bookId).firstOrNull;
    if (loaded != null) {
      narrationDelivery.registerBookChapters(bookId, loaded.chapters);
      return index >= 0 && index < loaded.chapters.length
          ? loaded.chapters[index]
          : null;
    }
    final article = articles.articles.where((a) => a.id == bookId).firstOrNull;
    if (article != null) {
      final book = articleBook(article);
      narrationDelivery.registerBookChapters(bookId, book.chapters);
      return index == 0 ? book.chapters.first : null;
    }
    final rssArticle = rss.articleById(bookId);
    if (rssArticle != null) {
      final book = articleBook(rssArticle.toImportedArticle());
      narrationDelivery.registerBookChapters(bookId, book.chapters);
      return index == 0 ? book.chapters.first : null;
    }
    try {
      final file = File('${(await bookDirectory()).path}/$bookId.epub');
      if (await file.exists()) {
        final epub = await EpubReader.readBook(await file.readAsBytes());
        final chapters = <ReaderChapter>[];
        loadBookChapters(epub, chapters);
        if (chapters.isNotEmpty) {
          narrationDelivery.registerBookChapters(bookId, chapters);
          return index >= 0 && index < chapters.length ? chapters[index] : null;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    narrationDelivery.setActive(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      // An activity can reattach to the still-running audio service engine.
      unawaited(ArticleShare.takePending(_receiveArticleShare).catchError(
        (Object _) {},
      ));
    }
  }

  void _articlesChanged() {
    if (!mounted) return;
    setState(() {
      books.removeWhere(
        (b) => b.id.startsWith('article_') || b.id.startsWith('rss_article_'),
      );
      for (final article in articles.articles) {
        final book = articleBook(article);
        narrationDelivery.registerBookChapters(book.id, book.chapters);
        books.add(book);
      }
      for (final rssArticle in rss.librarySavedArticles) {
        final book = articleBook(rssArticle.toImportedArticle());
        narrationDelivery.registerBookChapters(book.id, book.chapters);
        books.add(book);
      }
      sortBooks();
    });
    unawaited(narrationDelivery.reconcile());
  }

  void _receiveArticleShare(String text) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final url = sharedArticleUrl(text);
      if (url == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Share a public article URL, or paste it in Import a web article.',
            ),
          ),
        );
        return;
      }
      articles.enqueue(url);
      unawaited(_openArticleImports());
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _openArticleImports() async {
    if (_showingArticleImports) return;
    _showingArticleImports = true;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ArticleImportScreen(
            library: articles,
            openArticle: openArticle,
          ),
        ),
      );
    } finally {
      _showingArticleImports = false;
    }
  }

  @override
  void dispose() {
    progress.removeListener(_progressChanged);
    ArticleShare.stop();
    articles.removeListener(_articlesChanged);
    rss.removeListener(_articlesChanged);
    WidgetsBinding.instance.removeObserver(this);
    narrationDelivery.setActive(false);
    if (widget.articleLibrary == null) articles.dispose();
    rss.dispose();
    super.dispose();
  }

  Future<Directory> bookDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/epubs');
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> loadLibrary() async {
    try {
      final directory = await bookDirectory();
      await progress.load();
      final restored = <ImportedBook>[];
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.epub')) continue;
        try {
          final epub = await EpubReader.readBook(await entity.readAsBytes());
          final chapters = <ReaderChapter>[];
          loadBookChapters(epub, chapters);
          if (chapters.isEmpty) continue;
          final title = (epub.Title ?? '').trim();
          final author = (epub.Author ?? '').trim();
          final bookId = entity.uri.pathSegments.last.replaceAll('.epub', '');
          narrationDelivery.registerBookChapters(bookId, chapters);
          restored.add(
            ImportedBook(
              title.isEmpty ? 'Untitled book' : title,
              author.isEmpty ? 'Unknown author' : author,
              chapters,
              bookId,
              extractCover(epub),
            ),
          );
        } catch (_) {
          /* Ignore unreadable files. */
        }
      }
      await articles.load();
      await rss.load();
      for (final article in articles.articles) {
        final book = articleBook(article);
        narrationDelivery.registerBookChapters(book.id, book.chapters);
      }
      for (final rssArticle in rss.librarySavedArticles) {
        final book = articleBook(rssArticle.toImportedArticle());
        narrationDelivery.registerBookChapters(book.id, book.chapters);
      }
      if (!mounted) return;
      setState(() {
        books.clear();
        books.addAll(restored);
        books.addAll(articles.articles.map(articleBook));
        books.addAll(
          rss.librarySavedArticles.map((a) => articleBook(a.toImportedArticle())),
        );
        sortBooks();
      });
      unawaited(narrationDelivery.reconcile());
    } catch (_) {
      /* Library remains usable even if restoration fails. */
    }
  }

  Future<void> saveProgress(String id, int chapter, int offset, {bool activate = true}) async {
    try {
      await progress.saveReading(id, chapter, offset, activate: activate);
    } catch (_) {
      // Keep the reader usable while retaining the last valid on-disk record.
    }
  }

  void showUpcoming(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is coming in a future version.')),
    );
  }

  ReaderChapter parseChapter(String title, String rawHtml) =>
      parseReaderChapter(title, rawHtml);

  Uint8List? extractCover(EpubBook epub) {
    try {
      final images = epub.Content?.Images;
      if (images == null || images.isEmpty) return null;
      final entries = images.entries.toList();
      entries.sort((a, b) {
        final ac = a.key.toLowerCase().contains('cover') ? 0 : 1;
        final bc = b.key.toLowerCase().contains('cover') ? 0 : 1;
        return ac.compareTo(bc);
      });
      for (final entry in entries) {
        if (!entry.key.toLowerCase().contains('cover')) continue;
        final dynamic image = entry.value;
        final dynamic content = image.Content;
        if (content is List<int>) return Uint8List.fromList(content);
      }
    } catch (_) {
      /* A missing or unusual cover is not fatal. */
    }
    return null;
  }

  void collectChapters(List<EpubChapter> source, List<ReaderChapter> output,
      Map<String, String> styleSheets) {
    for (final chapter in source) {
      final title = (chapter.Title ?? '').trim();
      final parsed = parseReaderChapter(
        title.isEmpty ? 'Section ${output.length + 1}' : title,
        chapter.HtmlContent ?? '',
        documentPath: chapter.ContentFileName ?? '',
        styleSheets: styleSheets,
      );
      if (parsed.text.isNotEmpty) output.add(parsed);
      collectChapters(chapter.SubChapters ?? [], output, styleSheets);
    }
  }

  void loadBookChapters(EpubBook epub, List<ReaderChapter> output) {
    final styleSheets = <String, String>{
      for (final entry in (epub.Content?.Css ?? {}).entries)
        entry.key: entry.value.Content ?? '',
    };
    collectChapters(epub.Chapters ?? [], output, styleSheets);
    if (output.isNotEmpty) return;

    final schema = epub.Schema;
    final package = schema?.Package;
    final spine = package?.Spine?.Items ?? [];
    final manifest = package?.Manifest?.Items ?? [];
    final htmlFiles = epub.Content?.Html ?? {};

    for (final itemRef in spine) {
      if (itemRef.IsLinear == false) continue;

      final id = itemRef.IdRef;
      if (id == null) continue;

      final matches = manifest.where((item) => item.Id == id);
      if (matches.isEmpty) continue;

      final href = matches.first.Href;
      if (href == null) continue;

      final normalized = Uri.decodeFull(href).split('#').first;
      final content =
          htmlFiles[normalized] ??
          htmlFiles.entries
              .where(
                (entry) =>
                    entry.key == normalized ||
                    entry.key.endsWith('/$normalized'),
              )
              .map((entry) => entry.value)
              .firstOrNull;

      final rawHtml = content?.Content;
      if (rawHtml == null || rawHtml.isEmpty) continue;

      final parsed = parseReaderChapter('Section ${output.length + 1}', rawHtml,
          documentPath: normalized, styleSheets: styleSheets);

      if (parsed.text.trim().isNotEmpty) {
        output.add(parsed);
      }
    }
  }

  Future<void> importBook() async {
    if (importing) return;
    setState(() => importing = true);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['epub'],
      );
      if (file == null) return;
      final bytes = file.path != null
          ? await File(file.path!).readAsBytes()
          : null;
      if (bytes == null) {
        throw Exception('Android did not provide access to this EPUB.');
      }

      final epub = await EpubReader.readBook(bytes);
      final chapters = <ReaderChapter>[];
      loadBookChapters(epub, chapters);

      if (chapters.isEmpty) {
        throw Exception('No readable chapters were found in this EPUB.');
      }

      final title = (epub.Title ?? '').trim();
      final author = (epub.Author ?? '').trim();
      final directory = await bookDirectory();
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      await File('${directory.path}/$id.epub').writeAsBytes(bytes);
      final imported = ImportedBook(
        title.isEmpty ? file.name : title,
        author.isEmpty ? 'Unknown author' : author,
        chapters,
        id,
        extractCover(epub),
      );
      if (!mounted) return;
      setState(() {
        books.add(imported);
        sortBooks();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Imported ${imported.title}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not import EPUB: $error')));
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _libraryPage(),
      _narrationLibraryPage(),
      _settingsPage(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.auto_stories_rounded, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            const Flexible(
              child: Text(
                'Dogreader',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 19),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Audio diagnostics',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
              builder: (_) => const AudioDiagnosticsScreen(),
            )),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                'BUILD $dogreaderBuild',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(child: pages[selectedTab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedTab,
        onDestinationSelected: (value) => setState(() => selectedTab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.queue_music_outlined),
            selectedIcon: Icon(Icons.queue_music),
            label: 'Queue',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _settingsPage() {
    final appearance = widget.appearance;
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.record_voice_over_outlined),
          title: const Text('Narration Dictionary'),
          subtitle: const Text('Pronunciations and Do Not Narrate rules'),
          onTap: () => openNarrationDictionary(context,
            bookTitles: {for (final b in books) b.id: b.title}),
        ),
        const SizedBox(height: 24),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('Choose how Dogreader looks.'),
                const SizedBox(height: 20),
                DropdownButton<ThemeMode>(
                  isExpanded: true,
                  value: appearance?.mode ?? ThemeMode.light,
                  items: const [
                    DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                    DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                    DropdownMenuItem(value: ThemeMode.system, child: Text('Follow system')),
                  ],
                  onChanged: appearance == null ? null : (selection) async {
                    if (selection == null) return;
                    try {
                      await appearance.setMode(selection);
                    } catch (_) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Appearance changed, but could not be saved. Please try again.'),
                      ));
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('API keys & voices'),
            subtitle: const Text('On-device Kokoro, Google Chirp HD, Azure Speech, Speechify'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ApiSettingsScreen(
                  credentials: byokCredentials,
                  ttsClient: byokTtsClient,
                  offlineNarration: offlineNarration,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        ListenableBuilder(
          listenable: narrationCostTracker,
          builder: (context, _) {
            final estimate = narrationCostTracker.estimate();
            final colors = Theme.of(context).colorScheme;
            return Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TTS Usage & Monthly Budget (${estimate.monthKey})',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      estimate.shouldSwitchToKokoro
                          ? 'Google 1M free tier + ${formatUsdAmount(estimate.monthlyCreditLimitUsd)} credit used up — switch to Kokoro (\$0.00).'
                          : 'Track your 1,000,000 free Google characters + ${formatUsdAmount(estimate.monthlyCreditLimitUsd)}/month Google Pro credit (${formatCharacterCount(estimate.totalCoveredGoogleCharacters)} covered Chirp 3 HD characters total) so you know when to switch to Kokoro.',
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: estimate.allowanceUsedFraction,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                      color: estimate.shouldSwitchToKokoro
                          ? colors.error
                          : colors.primary,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Covered Google Chirp allowance: ${formatCharacterCount(estimate.usedGoogleCharacters)} / ${formatCharacterCount(estimate.totalCoveredGoogleCharacters)} chars (${formatCharacterCount(estimate.coveredCharactersRemaining)} left)',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Free tier: ${formatCharacterCount(estimate.freeCharactersUsed)} / ${formatCharacterCount(estimate.freeCharacterLimit)} chars (${formatCharacterCount(estimate.freeCharactersRemaining)} left)',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Google Pro credit: ${formatUsdAmount(estimate.creditUsdUsed)} / ${formatUsdAmount(estimate.monthlyCreditLimitUsd)} used (${formatUsdAmount(estimate.creditUsdRemaining)} left • covers ${formatCharacterCount(estimate.creditCharacterAllowance)} Chirp chars)',
                    ),
                    if (estimate.outOfPocketUsdUsed > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Estimated out-of-pocket this month: ${formatUsdAmount(estimate.outOfPocketUsdUsed)}',
                        style: TextStyle(
                          color: colors.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: estimate.azureAllowanceUsedFraction,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                      color: estimate.azureAllowanceExhausted
                          ? colors.error
                          : colors.secondary,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Azure F0 free tier: ${formatCharacterCount(estimate.usedAzureCharacters)} / ${formatCharacterCount(estimate.azureFreeCharacterLimit)} chars (${formatCharacterCount(estimate.azureCharactersRemaining)} left • \$0.00)',
                    ),
                    if (estimate.usedKokoroCharacters > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Kokoro generated this month: ${formatCharacterCount(estimate.usedKokoroCharacters)} chars (\$0.00 API cost)',
                      ),
                    ],
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => showNarrationBudgetDialog(context),
                        icon: const Icon(Icons.tune, size: 18),
                        label: const Text('Adjust usage / budget'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _libraryPage() {
    final articleIds = articles.articles.map((article) => article.id).toSet();
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 22),
      children: [
        Text(
          'Your library',
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
            fontSize: 34,
            fontWeight: FontWeight.w600,
            fontFamily: 'serif',
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          "I'm not surprised you're reading that, because you're stupid.",
          style: TextStyle(
            fontSize: 15,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _openArticleImports,
          icon: const Icon(Icons.add_link),
          label: const Text('Import a web article'),
        ),
        const SizedBox(height: 10),
        RssLibraryShelf(
          controller: rss,
          onOpenRssHome: openRssHome,
          onOpenAddFeed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => RssSubscriptionsAndOpmlScreen(controller: rss),
            ),
          ),
          onOpenAuthors: () async {
            final authorId = await Navigator.push<String>(
              context,
              MaterialPageRoute<String>(
                builder: (_) => RssAuthorsScreen(controller: rss),
              ),
            );
            if (authorId != null && mounted) {
              openRssHome(
                initialMode: RssArticleFilterMode.all,
                authorId: authorId,
              );
            }
          },
          onOpenRules: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => RssRulesScreen(controller: rss),
            ),
          ),
          onOpenOpml: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => RssSubscriptionsAndOpmlScreen(controller: rss),
            ),
          ),
        ),
        if (articles.articles.isNotEmpty)
          Card(
            child: ExpansionTile(
              key: const PageStorageKey('saved-article-shelf'),
              leading: const Icon(Icons.article_outlined),
              title: const Text('Articles'),
              subtitle: Text('${articles.articles.length} saved'),
              children: [
                for (final article in articles.articles.reversed)
                  ListTile(
                    title: Text(article.title),
                    onTap: () => articleDetails(article),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Article options',
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'remove', child: Text('Remove article')),
                      ],
                      onSelected: (_) async {
                        try {
                          await articles.removeArticle(article);
                        } catch (_) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Could not remove this article.')),
                            );
                          }
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        if (books.isEmpty) _emptyLibrary(),
        for (final book in books.where((book) => !articleIds.contains(book.id)))
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: ListTile(
              contentPadding: const EdgeInsets.all(15),
              leading: SizedBox(
                width: 54,
                height: 76,
                child: book.cover == null
                    ? Icon(
                        Icons.menu_book_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 36,
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: Image.memory(
                          book.cover!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Icon(
                                Icons.menu_book_rounded,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ),
              ),
              title: Text(
                book.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${book.author}\n${book.chapters.length} sections',
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: 'Chapters and narration',
                icon: Icon(Icons.list_rounded, color: Theme.of(context).colorScheme.primary),
                onPressed: () => openChapters(book),
              ),
              onTap: () => openBook(book),
            ),
          ),
        if (books.isNotEmpty) const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: importing ? null : importBook,
          icon: importing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_rounded),
          label: Text(importing ? 'Importing…' : 'Import a book'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),

      ],
    );
  }

  Widget _emptyLibrary() {
    return Container(
      padding: const EdgeInsets.all(24),
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(Icons.menu_book_rounded, size: 62, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 20),
          const Text(
            'A new chapter begins',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            'Import an EPUB, browse its chapters, and start reading.',
            textAlign: TextAlign.center,
            style: TextStyle(
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _narrationLibraryPage() {
    if (books.isEmpty) {
      return _placeholderPage(
        Icons.queue_music_rounded,
        'Narration',
        'Import a book to generate or listen to narration.',
      );
    }
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Your books',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
        ),
        for (final book in books)
          ListTile(
            leading: Icon(Icons.headphones, color: Theme.of(context).colorScheme.primary),
            title: Text(book.title),
            subtitle: Text(book.author),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => NarrationQueueScreen(book: book,
                  onSave: (chapter, offset) => saveProgress(book.id, chapter, offset)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _placeholderPage(IconData icon, String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

typedef SavePosition = Future<void> Function(int chapter, int offset);

Future<void> openBookNarration(
  BuildContext context,
  ImportedBook book,
  SavePosition onSave, {
  int? chapter,
}) => Navigator.push<void>(context, MaterialPageRoute<void>(
  builder: (_) => NarrationQueueScreen(
    book: book, onSave: onSave, initialChapter: chapter,
  ),
));

Future<void> openChapterPlayer(
  BuildContext context,
  ImportedBook book,
  int chapter,
  SavePosition onSave, {
  bool playOnOpen = false,
}) => Navigator.push<void>(context, MaterialPageRoute<void>(
  builder: (_) => ChapterNarrationScreen(
    book: book, chapterIndex: chapter, onSave: onSave, playOnOpen: playOnOpen,
  ),
));

Future<void> runChapterAudioAction(
  BuildContext context,
  ImportedBook book,
  int index,
  SavePosition onSave,
  ChapterAudioAction action,
) async {
  try {
    switch (action) {
      case ChapterAudioAction.generate:
      case ChapterAudioAction.retryGeneration:
        await openBookNarration(context, book, onSave, chapter: index);
      case ChapterAudioAction.download:
      case ChapterAudioAction.retryDownload:
        if (!narrationDelivery.deliveryInFlight(book.id, index)) {
          await narrationDelivery.retryDownload(book.id, index);
        }
      case ChapterAudioAction.play:
      case ChapterAudioAction.pause:
        final handler = NarrationPlaybackScope.maybeOf(context);
        if (handler != null && handler.mediaItem.value?.id == '${book.id}:$index') {
          final playing = handler.playbackState.value.playing;
          if (action == ChapterAudioAction.pause && playing) {
            await handler.pause(origin: 'chapter narration controls');
          } else if (action == ChapterAudioAction.play && !playing) {
            await handler.play(origin: 'chapter narration controls');
          }
        } else if (action == ChapterAudioAction.play) {
          await openChapterPlayer(context, book, index, onSave, playOnOpen: true);
        }
    }
  } catch (_) {
    if (!context.mounted) return;
    final message = action == ChapterAudioAction.download ||
            action == ChapterAudioAction.retryDownload
        ? 'Download interrupted. Try again when connected.'
        : 'Could not open narration. Please try again.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Outer corner radius of the connected chapter card.
const double _chapterCardRadius = 24;

class ChapterListScreen extends StatefulWidget {
  final ImportedBook book;
  final Map<String, int>? saved;
  final SavePosition onSave;
  final Map<String, int> chapterOffsets;
  final BookProgress? progressStore;
  const ChapterListScreen({
    super.key,
    required this.book,
    required this.saved,
    required this.onSave,
    required this.chapterOffsets,
    this.progressStore,
  });

  @override
  State<ChapterListScreen> createState() => _ChapterListScreenState();
}

class _ChapterListScreenState extends State<ChapterListScreen> {
  ImportedBook get book => widget.book;
  SavePosition get onSave => widget.onSave;
  BookProgress? get progressStore => widget.progressStore;

  @override
  void initState() {
    super.initState();
    narrationDelivery.registerBookChapters(book.id, book.chapters);
  }

  @override
  void didUpdateWidget(covariant ChapterListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    narrationDelivery.registerBookChapters(book.id, book.chapters);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: progressStore ?? bookProgress,
    builder: (context, _) => BookNarrationStatus(
      bookId: book.id,
      delivery: narrationDelivery,
      builder: buildOverview,
    ),
  );

  final Set<int> _selected = {};
  bool _selecting = false;

  void _exitSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _toggle(int index) => setState(() {
    if (!_selected.add(index)) _selected.remove(index);
  });

  void _startSelection(int index) {
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _selecting = true;
      _selected.add(index);
    });
  }

  Future<void> _generate(Set<int> chapters) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: true,
      enableDrag: true,
      builder: (_) => NarrationQueueScreen(
        book: book,
        onSave: onSave,
        generationChapters: Set.unmodifiable(chapters),
      ),
    );
    if (!mounted || result == null) return;
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
  }

  Iterable<int> get _allChapters =>
      Iterable<int>.generate(book.chapters.length);

  Widget _selectionActions() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        Text('${_selected.length} selected'),
        TextButton(
          onPressed: _selected.length == book.chapters.length
              ? null
              : () => setState(() => _selected.addAll(_allChapters)),
          child: const Text('Select All'),
        ),
        TextButton(
          onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
          child: const Text('Clear'),
        ),
        TextButton(onPressed: _exitSelection, child: const Text('Cancel')),
      ],
    ),
  );

  Widget _narrationMenu() => MenuAnchor(
    menuChildren: [
      MenuItemButton(
        onPressed: () => setState(() => _selecting = true),
        child: const Text('Select chapters'),
      ),
      MenuItemButton(
        onPressed: () => _generate(_allChapters.toSet()),
        child: const Text('Generate entire book'),
      ),
      MenuItemButton(
        onPressed: () => openBookNarration(context, book, onSave),
        child: const Text('Narration settings'),
      ),
    ],
    builder: (context, controller, _) => TextButton.icon(
      onPressed: book.chapters.isEmpty
          ? null
          : () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
      icon: const Icon(Icons.expand_more),
      label: const Text('Narration'),
    ),
  );

  Widget buildOverview(
    BuildContext context,
    ChapterAudioPresentation Function(int) narration,
  ) {
    final saved = progressStore?.continuePosition(book.id) ?? widget.saved;
    final lastChapter = saved?['chapter'] ?? 0;
    final furthest = progressStore?.furthestChapter(book.id);
    final listening = progressStore?.listeningChapter(book.id);
    final hasChapters = book.chapters.isNotEmpty;
    final showResume = hasChapters && saved != null && !_selecting;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _exitSelection();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(book.title)),
        body: Column(
          children: [
            if (_selecting) _selectionActions() else _narrationMenu(),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        if (!_selecting &&
                            listening != null &&
                            listening >= 0 &&
                            listening < book.chapters.length)
                          TextButton.icon(
                            icon: Image.asset(
                              'assets/images/chapter_headphones.webp',
                              width: 22,
                              height: 22,
                              filterQuality: FilterQuality.high,
                              excludeFromSemantics: true,
                            ),
                            label: Text(
                              'Continue listening: ${book.chapters[listening].title}',
                            ),
                            onPressed: () => openChapterPlayer(
                              context,
                              book,
                              listening,
                              onSave,
                            ),
                          ),
                        if (!_selecting &&
                            hasChapters &&
                            furthest != null &&
                            furthest != lastChapter)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              'Furthest reached: ${book.chapters[furthest.clamp(0, book.chapters.length - 1)].title}',
                            ),
                          ),
                        if (showResume)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: Card(
                              child: ListTile(
                                leading: Icon(
                                  Icons.bookmark,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                title: const Text('Continue reading'),
                                subtitle: Text(
                                  book
                                      .chapters[lastChapter.clamp(
                                        0,
                                        book.chapters.length - 1,
                                      )]
                                      .title,
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => openChapter(
                                  context,
                                  lastChapter.clamp(
                                    0,
                                    book.chapters.length - 1,
                                  ),
                                  resume: true,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                    sliver: DecoratedSliver(
                      // One soft, low shadow beneath the whole chapter card;
                      // the rows themselves remain a single connected panel.
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_chapterCardRadius),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha:
                                  Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? 0.32
                                      : 0.08,
                            ),
                            blurRadius:
                                Theme.of(context).brightness == Brightness.dark
                                    ? 18
                                    : 22,
                            offset:
                                Theme.of(context).brightness == Brightness.dark
                                    ? const Offset(0, 6)
                                    : const Offset(0, 8),
                          ),
                          if (Theme.of(context).brightness != Brightness.dark)
                            BoxShadow(
                              color: const Color(
                                0xFF433159,
                              ).withValues(alpha: 0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                        ],
                      ),
                      sliver: SliverList.builder(
                        itemCount: book.chapters.length,
                        itemBuilder: (context, index) => _chapterRow(
                          context,
                          index,
                          narration(index),
                          saved,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: _selecting
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => _generate(_selected),
                    child: Text('Generate (${_selected.length})'),
                  ),
                ),
              )
            : null,
      ),
    );
  }

  Widget _chapterRow(
    BuildContext context,
    int index,
    ChapterAudioPresentation audio,
    Map<String, int>? saved,
  ) {
    final chapter = book.chapters[index];
    final colors = Theme.of(context).colorScheme;
    final selected = _selected.contains(index);
    final current = saved?['chapter'] == index;
    final last = index == book.chapters.length - 1;
    final savedOffset = math.max(
      widget.chapterOffsets['$index'] ?? 0,
      current ? (saved?['offset'] ?? 0) : 0,
    );
    final fraction =
        progressStore?.sectionFraction(book.id, index, chapter.text.length) ??
        (savedOffset / math.max(1, chapter.text.length)).clamp(0.0, 1.0);
    final job = narrationDelivery.books[book.id]?[index];
    final active =
        narrationDelivery.downloading(book.id, index) ||
        const ['waiting', 'queued', 'generating'].contains(job?['status']);
    final failed =
        job?['status'] == 'error' ||
        job?['failureStage'] == 'generation' ||
        job?['delivery'] == 'failed';
    final ready =
        audio.hasRecording || audio.action == ChapterAudioAction.download;
    final narrationTitle = 'Narration for ${chapter.title} · ${audio.label}';
    const targetWidth = 72.0;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final topColor = dark
        ? Colors.white.withValues(alpha: 0.035)
        : Color.alphaBlend(
            colors.primary.withValues(
              alpha: selected ? 0.19 : current ? 0.10 : 0,
            ),
            const Color(0xFFF5F3F8),
          );
    final midColor = dark
        ? Colors.white.withValues(alpha: 0)
        : Color.alphaBlend(
            colors.primary.withValues(
              alpha: selected ? 0.19 : current ? 0.10 : 0,
            ),
            const Color(0xFFEFEDF4),
          );
    final bottomColor = dark
        ? Colors.black.withValues(alpha: 0.10)
        : Color.alphaBlend(
            colors.primary.withValues(
              alpha: selected ? 0.19 : current ? 0.10 : 0,
            ),
            const Color(0xFFE8E5EF),
          );

    return Material(
      key: ValueKey('chapter-row-$index'),
      color: dark
          ? Color.alphaBlend(
              colors.primary.withValues(
                alpha: selected ? 0.19 : current ? 0.10 : 0,
              ),
              colors.surfaceContainerLow,
            )
          : midColor,
      borderRadius: BorderRadius.vertical(
        top: index == 0
            ? const Radius.circular(_chapterCardRadius)
            : Radius.zero,
        bottom: last ? const Radius.circular(_chapterCardRadius) : Radius.zero,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Directional shading: a satin porcelain gradient in light mode
          // and subtle lift-to-depth shading in dark mode.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      topColor,
                      midColor,
                      bottomColor,
                    ],
                    stops: const [0, 0.45, 1],
                  ),
                ),
              ),
            ),
          ),
          // Faint, refined outer border in light mode around the connected card;
          // seamlessly clipped at top and bottom corners by Material's borderRadius.
          if (!dark) ...[
            const Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 1,
              child: IgnorePointer(
                child: ColoredBox(color: Color(0xFFDDD8E5)),
              ),
            ),
            const Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 1,
              child: IgnorePointer(
                child: ColoredBox(color: Color(0xFFDDD8E5)),
              ),
            ),
            if (index == 0)
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 1,
                child: IgnorePointer(
                  child: ColoredBox(color: Color(0xFFDDD8E5)),
                ),
              ),
            if (last)
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 1,
                child: IgnorePointer(
                  child: ColoredBox(color: Color(0xFFDDD8E5)),
                ),
              ),
          ],
          // Soft top highlight; beneath the previous row's separator it reads
          // as a subtly engraved divider rather than a flat rule.
          Positioned(
            left: dark ? 0 : 1,
            right: dark ? 0 : 1,
            top: (!dark && index == 0) ? 1 : 0,
            height: 1,
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.white.withValues(
                  alpha: dark ? 0.06 : (index == 0 ? 0.85 : 0.7),
                ),
              ),
            ),
          ),
          if (current || selected)
            Positioned(
              left: 0,
              top: 14,
              bottom: 14,
              width: 3.5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(4),
                  ),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(right: _selecting ? 0 : targetWidth),
            child: Semantics(
              checked: _selecting ? selected : null,
              child: InkWell(
                onTap: _selecting
                    ? () => _toggle(index)
                    : () => openChapter(context, index),
                onLongPress: _selecting ? null : () => _startSelection(index),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 96),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        if (_selecting)
                          ExcludeSemantics(
                            child: Icon(
                              selected
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
                              color: selected
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        if (_selecting) const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            chapter.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.3,
                              letterSpacing: -0.1,
                              fontWeight: current || selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (!_selecting && fraction >= 1) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.check_circle_outline,
                            size: 18,
                            color: colors.onSurfaceVariant,
                            semanticLabel: 'Section completed',
                          ),
                        ],
                        if (_selecting) const SizedBox(width: 10),
                        if (_selecting)
                          _headphones(
                            active,
                            failed,
                            ready,
                            colors,
                            dark: dark,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!_selecting)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: targetWidth,
              child: Semantics(
                label: narrationTitle,
                button: true,
                child: Tooltip(
                  message: narrationTitle,
                  excludeFromSemantics: true,
                  triggerMode: TooltipTriggerMode.manual,
                  child: InkWell(
                    onTap: () => openBookNarration(
                      context,
                      book,
                      onSave,
                      chapter: index,
                    ),
                    onLongPress: () => _startSelection(index),
                    child: Center(
                      child: _headphones(
                        active,
                        failed,
                        ready,
                        colors,
                        dark: dark,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (!last || (!_selecting && fraction > 0))
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: LinearProgressIndicator(
                  value: _selecting ? 0 : fraction,
                  minHeight: 2.5,
                  borderRadius: BorderRadius.zero,
                  stopIndicatorRadius: 0,
                  trackGap: 0,
                  backgroundColor: last
                      ? Colors.transparent
                      : Color.alphaBlend(
                          colors.outline.withValues(alpha: dark ? 0.55 : 0.62),
                          colors.outlineVariant,
                        ),
                  color: colors.primary.withValues(alpha: 0.65),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _headphones(
    bool active,
    bool failed,
    bool ready,
    ColorScheme colors, {
    bool dark = true,
  }) {
    final lightBaseFill = Color.alphaBlend(
      colors.primary.withValues(alpha: ready || active ? 0.16 : 0.04),
      const Color(0xFFEBE6F2),
    );
    final lightTopFill = Color.alphaBlend(
      colors.primary.withValues(alpha: ready || active ? 0.16 : 0.04),
      const Color(0xFFF3F0F8),
    );
    final lightBottomFill = Color.alphaBlend(
      colors.primary.withValues(alpha: ready || active ? 0.16 : 0.04),
      const Color(0xFFE2DDE9),
    );

    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dark
                  ? Color.alphaBlend(
                      colors.primary.withValues(
                        alpha: ready || active ? 0.14 : 0.05,
                      ),
                      colors.surfaceContainerHighest.withValues(alpha: 0.55),
                    )
                  : null,
              gradient: dark
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        lightTopFill,
                        lightBaseFill,
                        lightBottomFill,
                      ],
                      stops: const [0, 0.5, 1],
                    ),
              boxShadow: dark
                  ? null
                  : [
                      BoxShadow(
                        color: const Color(0xFF433159).withValues(alpha: 0.08),
                        blurRadius: 4,
                        offset: const Offset(0, 1.5),
                      ),
                    ],
              border: Border.all(
                color: dark
                    ? (ready || active
                        ? colors.primary.withValues(alpha: 0.35)
                        : colors.outlineVariant.withValues(alpha: 0.7))
                    : (ready || active
                        ? colors.primary.withValues(alpha: 0.42)
                        : const Color(0xFFD6D0DF)),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Image.asset(
                'assets/images/chapter_headphones.webp',
                width: 38,
                height: 38,
                filterQuality: FilterQuality.high,
                excludeFromSemantics: true,
              ),
            ),
          ),
          if (active || failed || ready)
            Positioned(
              right: 1,
              bottom: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colors.outlineVariant.withValues(alpha: 0.6),
                    width: 0.75,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2.5),
                  child: active
                      ? const SizedBox.square(
                          dimension: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.75),
                        )
                      : Icon(
                          failed ? Icons.error_outline : Icons.circle,
                          size: failed ? 12 : 8,
                          color: failed ? colors.error : colors.primary,
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void openChapter(BuildContext context, int index, {bool resume = false}) {
    final saved = progressStore?.continuePosition(book.id) ?? widget.saved;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingScreen(
          book: book,
          chapterIndex: index,
          initialOffset: resume ? (saved?['offset'] ?? 0) : 0,
          onSave: onSave,
          progressStore: progressStore,
        ),
      ),
    );
  }
}

class NarrationQueueScreen extends StatefulWidget {
  final ImportedBook book;
  final SavePosition onSave;
  final int? initialChapter;
  final Set<int>? generationChapters;
  const NarrationQueueScreen({
    super.key,
    required this.book,
    required this.onSave,
    this.initialChapter,
    this.generationChapters,
  });
  @override
  State<NarrationQueueScreen> createState() => _NarrationQueueScreenState();
}

class _NarrationQueueScreenState extends State<NarrationQueueScreen> {
  String narrationEngine = defaultPlayStorePreference.engine;
  String narrator = defaultPlayStorePreference.voice;
  bool previewing = false;
  int previewSequence = 0;
  final Set<int> selected = {};
  late final Map<int, Map<String, dynamic>> jobs = narrationDelivery.books
      .putIfAbsent(widget.book.id, () => {});
  static final Set<String> _checkingBooks = {};
  bool submitting = false;
  String host = '';
  String token = '';
  bool busy = false;
  String? notice;
  Timer? timer;
  int? focusedChapter;
  bool loaded = false;

  Future<File> get queueFile async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/dogreader_queue.json');
  }

  Future<void> load() async {
    narrationDelivery.registerBookChapters(
      widget.book.id,
      widget.book.chapters,
    );
    await narrationDelivery.load();
    await narrationDictionary.load();
    await narrationCostTracker.load();
    await byokCredentials.load();
    try {
      final file = await queueFile;
      if (await file.exists()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        host = data['host'] as String? ?? '';
        token = data['token'] as String? ?? '';
        final preference = NarrationPreference.fromJson(data);
        narrationEngine = preference.engine;
        narrator = preference.voice;
        final bookJobs = (data['books'] as Map?)?[widget.book.id];
        if (bookJobs is Map) {
          for (final entry in bookJobs.entries) {
            final index = int.tryParse(entry.key.toString());
            if (index != null && entry.value is Map) {
              jobs.putIfAbsent(
                index,
                () => Map<String, dynamic>.from(entry.value as Map),
              );
            }
          }
        }
      }
    } catch (_) {}
    unawaited(offlineNarration.initialize().catchError((Object _) {}));
    final root = await getApplicationDocumentsDirectory();
    Map<String, dynamic> stateData = const {};
    try {
      final stateFile = File('${root.path}/narration_state.json');
      if (await stateFile.exists()) {
        final decoded = jsonDecode(await stateFile.readAsString());
        if (decoded is Map<String, dynamic>) stateData = decoded;
      }
    } catch (_) {}
    for (var index = 0; index < widget.book.chapters.length; index++) {
      final file = File('${root.path}/narration/${widget.book.id}_$index.mp3');
      if (!narrationDelivery.deliveryInFlight(widget.book.id, index)) {
        await recoverNarrationFile(file);
      }
      final stateEntry = stateData['${widget.book.id}:$index'];
      var activeFile = file;
      if (stateEntry is Map && stateEntry['path'] is String) {
        final candidate = File(stateEntry['path'] as String);
        if (!candidate.path.endsWith('.part') &&
            !candidate.path.endsWith('.bak') &&
            await candidate.exists() &&
            await candidate.length() >= 1000) {
          activeFile = candidate;
        }
      }
      final localAvailable =
          identical(activeFile, file)
          ? (await file.exists() && await file.length() >= 1000)
          : true;
      if (localAvailable &&
          stateEntry is Map &&
          stateEntry['engine'] == 'kokoro_offline' &&
          ![
            'waiting',
            'queued',
            'generating',
          ].contains(jobs[index]?['status'])) {
        jobs[index] = {
          ...?jobs[index],
          for (final key in [
            'engine',
            'voice',
            'model_version',
            'settings',
            'narration_dictionary',
            'narration_offsets',
            'offlineJobId',
          ])
            if (stateEntry.containsKey(key)) key: stateEntry[key],
          'status': 'ready',
          'delivery': 'downloaded',
          'localAvailable': true,
        };
      }
      if (jobs[index] != null) jobs[index]!['localAvailable'] = localAvailable;
      if (localAvailable &&
          jobs[index]?['previousRecording'] == null &&
          (jobs[index]?['delivery'] == null ||
              jobs[index]?['delivery'] == 'downloaded') &&
          ![
            'waiting',
            'queued',
            'generating',
            'error',
          ].contains(jobs[index]?['status'])) {
        jobs[index] = {
          ...?jobs[index],
          'status': 'ready',
          'delivery': 'downloaded',
          'localAvailable': true,
          'id': jobs[index]?['id'],
        };
      }
    }
    if (!mounted) return;
    setState(() {
      loaded = true;
      final chapter = focusedChapter;
      if (chapter != null && jobs[chapter] == null) selected.add(chapter);
    });
    if (widget.generationChapters == null) await checkJobs();
  }

  Future<void> save() async {
    narrationDelivery.host = host;
    narrationDelivery.token = token;
    narrationDelivery.attachBook(widget.book.id, jobs);
    await narrationDelivery.save();
    await savePreference();
  }

  Future<void> savePreference() async {
    final preference = NarrationPreference(narrationEngine, narrator);
    await updateNarrationJson(await queueFile, (data) {
      data['narrator'] = preference.voice;
      data['engine'] = preference.engine;
    });
  }

  void deliveryChanged() {
    if (mounted) setState(() {});
  }

  Future<void> openApiSettings() async {
    await stopPreview();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ApiSettingsScreen(
          credentials: byokCredentials,
          ttsClient: byokTtsClient,
          offlineNarration: offlineNarration,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void selectEntireBook() {
    setState(() {
      selected.clear();
      for (var i = 0; i < widget.book.chapters.length; i++) {
        if (_needsGeneration(i)) selected.add(i);
      }
      notice = selected.isEmpty
          ? 'All chapters are already generated or queued.'
          : '${selected.length} chapters selected. Review and tap Generate.';
    });
  }

  Future<void> deleteChapterAudio(int index) async {
    if (busy || narrationDelivery.deliveryInFlight(widget.book.id, index)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chapter audio?'),
        content: Text(
          'Remove the downloaded narration for "${widget.book.chapters[index].title}"? '
          'The chapter text and reading progress will remain. '
          'You can generate it again with another voice.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete audio'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || busy || narrationDelivery.deliveryInFlight(widget.book.id, index)) return;
    setState(() => busy = true);
    try {
      final root = await getApplicationDocumentsDirectory();
      await deleteNarrationFile(
        root: root, bookId: widget.book.id, index: index,
        pause: () => audioHandler.unloadChapter(widget.book.id, index),
        jobs: jobs, selected: selected,
      );
      await save();
      notice = 'Audio deleted. Choose a narrator and generate this chapter again.';
    } catch (e) {
      notice = 'Could not delete audio: $e';
    } finally {
      busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> stopPreview() async {
    previewSequence++;
    await audioHandler.stopPreview();
    if (mounted) setState(() => previewing = false);
  }

  Future<void> previewVoice() async {
    final preference = NarrationPreference(narrationEngine, narrator);
    if (!preference.isOffline && !byokCredentials.isConfigured(narrationEngine)) {
      setState(() => notice = byokCredentials.missingConfigMessage(narrationEngine));
      return;
    }
    final sequence = ++previewSequence;
    setState(() { previewing = true; notice = 'Preparing voice preview…'; });
    try {
      final preview = await byokTtsClient.synthesizePreview(
        preference: preference,
        sample: 'Welcome to Dogreader. “Shall we begin?” he asked. '
            'Settle in, choose a chapter, and enjoy a few quiet moments with your next story.',
        isCurrent: () => mounted && sequence == previewSequence,
      );
      if (preview == null || !mounted || sequence != previewSequence) return;
      setState(() => notice = 'Preview: ${recordingLabel(preference.toJson())}');
      await audioHandler.playPreview(preview.path, 'Preview: ${recordingLabel(preference.toJson())}');
    } catch (e) {
      if (mounted && sequence == previewSequence) { setState(() => notice = 'Voice preview: $e'); }
    } finally {
      if (mounted && sequence == previewSequence) { setState(() => previewing = false); }
    }
  }

  int _chapterSpokenCharacters(int index) {
    if (index < 0 || index >= widget.book.chapters.length) return 0;
    final transformed = narrationDictionary
        .effective(widget.book.id)
        .transform(widget.book.chapters[index]);
    return transformed.text.trim().isEmpty ? 0 : transformed.text.runes.length;
  }

  int _selectedNewCharacters(Iterable<int> indices) => indices
      .where(_needsGeneration)
      .fold<int>(0, (sum, index) => sum + _chapterSpokenCharacters(index));

  Future<void> regenerate(int index) async {
    if (busy ||
        _checkingBooks.contains(widget.book.id) ||
        byokNarrationRunner.inFlight(widget.book.id, index) ||
        narrationDelivery.deliveryInFlight(widget.book.id, index)) {
      return;
    }
    final preference = NarrationPreference(narrationEngine, narrator);
    final estimate = narrationCostTracker.estimate(
      preference: preference,
      selectionCharacters: _chapterSpokenCharacters(index),
    );
    final costSummary = estimate.confirmationSummary();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Regenerate narration?'),
        content: Text(
          'Generate ${widget.book.chapters[index].title} with ${recordingLabel(preference.toJson())}? '
          'The current recording is replaced only after the new audio finishes generating.'
          '${costSummary.isEmpty ? '' : '\n\n$costSummary'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Generate narration'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        busy ||
        _checkingBooks.contains(widget.book.id) ||
        byokNarrationRunner.inFlight(widget.book.id, index) ||
        narrationDelivery.deliveryInFlight(widget.book.id, index) ||
        const [
          'waiting',
          'queued',
          'generating',
        ].contains(jobs[index]?['status'])) {
      return;
    }
    if (!preference.isOffline && !byokCredentials.isConfigured(preference.engine)) {
      setState(() => notice = byokCredentials.missingConfigMessage(preference.engine));
      return;
    }
    narrationDelivery.registerBookChapters(
      widget.book.id,
      widget.book.chapters,
    );
    if (preference.isOffline) {
      await _startOfflineGeneration([index], preference, isRegenerate: true);
      return;
    }
    final job = <String, dynamic>{
      'previousRecording': jobs[index]?['previousRecording'] ?? jobs[index],
      'status': 'waiting',
      ...preference.toJson(),
      'narration_dictionary': narrationDictionary
          .effective(widget.book.id)
          .toJson(),
    };
    try {
      NarrationDelivery.prepareSubmissionPayload(
        job,
        chapter: widget.book.chapters[index],
      );
    } on StateError {
      // Defer silence StateError to runner so notice/error state is reported uniformly.
    }
    setState(() {
      jobs[index] = job;
    });
    await save();
    await _runByokJobs();
  }

  Future<void> _startOfflineGeneration(
    List<int> indices,
    NarrationPreference preference, {
    bool isRegenerate = false,
    Set<int>? requestedToClear,
  }) async {
    await offlineNarration.initialize().catchError((Object _) {});
    if (!offlineNarration.ready) {
      if (mounted) {
        setState(
          () => notice =
              'Download the offline Kokoro model and English frontend (372 MB) first.',
        );
      }
      return;
    }
    if (offlineNarration.busy) {
      if (mounted) {
        setState(
          () => notice = 'One offline generation job can run at a time.',
        );
      }
      return;
    }
    setState(() {
      busy = true;
      submitting = true;
      notice = null;
    });
    for (var i = 0; i < indices.length; i++) {
      final index = indices[i];
      jobs[index] = {
        if (isRegenerate)
          'previousRecording': jobs[index]?['previousRecording'] ?? jobs[index],
        'status': i == 0 ? 'generating' : 'waiting',
        ...preference.toJson(),
        'narration_dictionary': narrationDictionary
            .effective(widget.book.id)
            .toJson(),
      };
    }
    await save();
    try {
      await offlineNarration.enqueueChapters(
        bookId: widget.book.id,
        bookTitle: widget.book.title,
        chapters: [
          for (final index in indices)
            MapEntry(index, widget.book.chapters[index]),
        ],
        sid: offlineSidForVoice(preference.voice),
        threads: offlineNarration.threads,
      );
      final result =
          'Started offline generation on device (${indices.length} ${indices.length == 1 ? 'chapter' : 'chapters'}).';
      busy = false;
      submitting = false;
      if (!mounted) return;
      if (widget.generationChapters != null) {
        Navigator.pop(context, result);
      } else {
        setState(() {
          if (requestedToClear != null) selected.removeAll(requestedToClear);
          notice = result;
        });
      }
    } catch (e) {
      for (final index in indices) {
        jobs[index] = {
          ...?jobs[index],
          'status': 'error',
          'error': '$e',
        };
      }
      await save();
      busy = false;
      submitting = false;
      if (mounted) {
        setState(() => notice = 'Offline generation error: $e');
      }
    }
  }

  bool _needsGeneration(int index) {
    final job = jobs[index];
    if (job == null) return true;
    return job['status'] == 'error' &&
        job['localAvailable'] != true &&
        job['previousRecording'] == null &&
        job['id'] == null;
  }

  Future<void> confirmGeneration() async {
    if (busy || selected.isEmpty) return;
    final requested = Set<int>.of(selected);
    final preference = NarrationPreference(narrationEngine, narrator);
    final downloaded = requested
        .where((index) => jobs[index]?['localAvailable'] == true)
        .length;
    final active = requested
        .where(
          (index) => const [
            'waiting',
            'queued',
            'generating',
          ].contains(jobs[index]?['status']),
        )
        .length;
    final newJobs = requested.where(_needsGeneration).length;
    final newCharacters = _selectedNewCharacters(requested);
    final estimate = narrationCostTracker.estimate(
      preference: preference,
      selectionCharacters: newCharacters,
    );
    final costLine = estimate.confirmationSummary();
    final chapter = requested.length == 1
        ? '\n${widget.book.chapters[requested.single].title}'
        : '';
    var switchedToKokoro = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm narration generation'),
        content: Text(
          '${requested.length} ${requested.length == 1 ? 'chapter' : 'chapters'} selected$chapter\n'
          '${recordingLabel(preference.toJson())}\n\n'
          '$downloaded downloaded\n'
          '$active queued or generating\n'
          '$newJobs new generation jobs\n\n'
          '${costLine.isEmpty ? '' : '$costLine\n\n'}'
          'Existing recordings and active jobs will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(newJobs == 0 ? 'Close' : 'Cancel'),
          ),
          if (newJobs > 0 &&
              preference.engine == 'google' &&
              estimate.shouldSwitchToKokoro)
            TextButton(
              onPressed: () {
                switchedToKokoro = true;
                Navigator.pop(context, false);
              },
              child: const Text('Switch to Kokoro'),
            ),
          if (newJobs > 0)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Generate ($newJobs)'),
            ),
        ],
        scrollable: true,
      ),
    );
    if (!mounted) return;
    if (switchedToKokoro) {
      setState(() {
        narrationEngine = defaultPlayStorePreference.engine;
        narrator = defaultPlayStorePreference.voice;
      });
      unawaited(offlineNarration.initialize().catchError((Object _) {}));
      await savePreference();
      return;
    }
    if (confirmed == true) await generate(requested, preference);
  }

  Future<void> generate(
    Set<int> requested,
    NarrationPreference preference,
  ) async {
    if (busy) return;
    if (!preference.isOffline && !byokCredentials.isConfigured(preference.engine)) {
      setState(() => notice = byokCredentials.missingConfigMessage(preference.engine));
      return;
    }
    // Recheck after confirmation in case delivery or another view updated jobs.
    final indices = requested.where(_needsGeneration).toList()..sort();
    if (indices.isEmpty) {
      setState(
        () => notice = 'No new jobs needed. Existing narration was kept.',
      );
      return;
    }
    if (preference.isOffline) {
      await _startOfflineGeneration(
        indices,
        preference,
        requestedToClear: requested,
      );
      return;
    }
    final previous = {for (final index in indices) index: jobs[index]};
    setState(() {
      busy = true;
      submitting = true;
      notice = null;
    });
    narrationDelivery.registerBookChapters(
      widget.book.id,
      widget.book.chapters,
    );
    for (final index in indices) {
      final job = <String, dynamic>{
        'status': 'waiting',
        ...preference.toJson(),
        'narration_dictionary': narrationDictionary
            .effective(widget.book.id)
            .toJson(),
      };
      try {
        NarrationDelivery.prepareSubmissionPayload(
          job,
          chapter: widget.book.chapters[index],
        );
      } on StateError {
        // Defer silence StateError to runner so notice/error state is reported uniformly.
      }
      jobs[index] = job;
    }
    try {
      narrationDelivery.attachBook(widget.book.id, jobs);
      await narrationDelivery.save();
    } catch (_) {
      for (final index in indices) {
        final job = previous[index];
        if (job == null) {
          jobs.remove(index);
        } else {
          jobs[index] = job;
        }
      }
      busy = false;
      submitting = false;
      if (mounted) {
        setState(() => notice = 'Could not save narration jobs. Try again.');
      }
      return;
    }
    busy = false;
    submitting = false;
    unawaited(_runByokJobs());
    final result =
        'Started ${narrationEngines[preference.engine] ?? preference.engine} generation (${indices.length} ${indices.length == 1 ? 'chapter' : 'chapters'}).';
    if (!mounted) return;
    if (widget.generationChapters != null) {
      Navigator.pop(context, result);
    } else {
      setState(() {
        selected.removeAll(requested);
        notice = result;
      });
    }
  }

  Widget _voiceControls() => NarrationControls(
    preference: NarrationPreference(narrationEngine, narrator),
    onChanged: (value) {
      setState(() {
        narrationEngine = value.engine;
        narrator = value.voice;
      });
      if (value.isOffline) {
        unawaited(offlineNarration.initialize().catchError((Object _) {}));
      }
      unawaited(savePreference());
    },
    previewing: previewing,
    onPreview: previewing ? stopPreview : previewVoice,
  );

  Widget _offlineStatusCard() => ListenableBuilder(
    listenable: offlineNarration,
    builder: (context, _) {
      if (narrationEngine != 'kokoro_offline' && !offlineNarration.active) {
        return const SizedBox.shrink();
      }
      final colors = Theme.of(context).colorScheme;
      final current = offlineNarration.job;
      final completed = current?['completedChunks'] as int? ?? 0;
      final total = current?['totalChunks'] as int? ?? 0;
      final chapter = current?['chapter'];
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: DecoratedBox(
          key: const Key('offline_kokoro_status_card'),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      offlineNarration.ready
                          ? Icons.check_circle_outline
                          : Icons.download_for_offline_outlined,
                      size: 18,
                      color: offlineNarration.ready
                          ? colors.primary
                          : colors.secondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        offlineNarration.ready
                            ? 'On-device Kokoro model ready'
                            : 'On-device model download required (372 MB)',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (offlineNarration.ready)
                      DropdownButton<int>(
                        key: ValueKey(
                          'offline-threads-${offlineNarration.threads}',
                        ),
                        value: offlineNarration.threads,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final n in [1, 2, 4])
                            DropdownMenuItem(
                              value: n,
                              child: Text(
                                '$n CPU ${n == 1 ? 'thread' : 'threads'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                        onChanged: offlineNarration.busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  unawaited(offlineNarration.setThreads(value));
                                }
                              },
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  offlineNarration.ready
                      ? 'Generates complete chapter WAV audio locally on your phone (FP32 • Misaki English). Cloud settings are not required.'
                      : 'Optional one-time download: Kokoro FP32 model (349.9 MB) + Misaki English frontend (22.2 MB). Allow 1.5 GB free during setup.',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (offlineNarration.status.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    offlineNarration.status,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
                if (!offlineNarration.ready) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('download_offline_kokoro_button'),
                    onPressed: offlineNarration.busy
                        ? null
                        : () => unawaited(offlineNarration.install()),
                    icon: const Icon(Icons.download, size: 18),
                    label: Text(
                      offlineNarration.installing
                          ? 'Downloading offline files…'
                          : 'Download offline files (372 MB)',
                    ),
                  ),
                ],
                if (offlineNarration.active) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: total > 0 ? completed / total : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$completed/$total chunks saved'
                    '${chapter is Map ? ' • ${chapter['chapterTitle'] ?? ''}' : ''}'
                    '${offlineNarration.pendingQueueCount > 0 ? ' (+${offlineNarration.pendingQueueCount} queued)' : ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton(
                    key: const Key('cancel_offline_kokoro_button'),
                    onPressed: () => unawaited(offlineNarration.cancel()),
                    child: const Text('Cancel offline generation'),
                  ),
                ],
                if (!offlineNarration.busy &&
                    current != null &&
                    current['outcome'] != null &&
                    current['outcome'] != 'completed') ...[
                  const SizedBox(height: 6),
                  OutlinedButton(
                    key: const Key('retry_offline_kokoro_button'),
                    onPressed: () => unawaited(offlineNarration.resume()),
                    child: const Text('Retry saved chapter job'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _costBanner() => NarrationCostBanner(
    tracker: narrationCostTracker,
    preference: NarrationPreference(narrationEngine, narrator),
    selectionCharacters: _selectedNewCharacters(selected),
    onSwitchToKokoro: previewing
        ? null
        : (value) {
            setState(() {
              narrationEngine = value.engine;
              narrator = value.voice;
            });
            unawaited(savePreference());
          },
    onAdjustBudget: () async {
      await showNarrationBudgetDialog(context);
      if (mounted) setState(() {});
    },
  );

  Widget _generationSheet() => PopScope(
    canPop: true,
    child: SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          12 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Generate narration',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('${selected.length} ${selected.length == 1 ? 'chapter' : 'chapters'} selected'),
            if (!submitting)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
            if (!loaded)
              const Center(child: CircularProgressIndicator())
            else ...[
              if (notice != null) Text(notice!),
              if (narrationEngine != 'kokoro_offline' &&
                  !byokCredentials.isConfigured(narrationEngine))
                TextButton.icon(
                  onPressed: openApiSettings,
                  icon: const Icon(Icons.key_outlined, size: 18),
                  label: const Text('Configure API key'),
                ),
              if (!submitting) _voiceControls(),
              if (!submitting) _offlineStatusCard(),
              if (!submitting) _costBanner(),
              if (submitting)
                const Center(child: CircularProgressIndicator())
              else
                FilledButton(
                  onPressed:
                      busy ||
                          selected.isEmpty ||
                          (narrationEngine != 'kokoro_offline' &&
                              !byokCredentials.isConfigured(narrationEngine))
                      ? null
                      : confirmGeneration,
                  child: const Text('Review generation'),
                ),
            ],
          ],
        ),
      ),
    ),
  );

  Future<void> repairChapterAudio(int index) async {
    if (busy) return;
    final id = jobs[index]?['id'];
    if (id is! String || id.isEmpty) {
      setState(() => notice = 'No cloud recording is linked to this chapter.');
      return;
    }
    setState(() {
      busy = true;
      notice = 'Recovering existing cloud recording…';
    });
    try {
      await downloadAudio(index, id);
      await save();
      if (mounted) {
        setState(() => notice = jobs[index]?['delivery'] == 'downloaded'
            ? 'Recording recovered from cloud.' : 'Narration is still generating. Finished audio will download automatically.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => notice = jobs[index]?['deliveryError'] as String? ??
            'Download interrupted. Retry Download when connected.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> downloadAudio(int index, String id) async {
    narrationDelivery.host = host;
    narrationDelivery.token = token;
    narrationDelivery.attachBook(widget.book.id, jobs);
    jobs[index] = {...?jobs[index], 'id': id};
    await narrationDelivery.retryDownload(widget.book.id, index);
  }

  Map<String, dynamic> chapterPayload(int index) {
    final job = jobs.putIfAbsent(index, () => {});
    return NarrationDelivery.prepareSubmissionPayload(
      job,
      chapter: widget.book.chapters[index],
    );
  }

  bool dictionaryChanged(int index) {
    final job = jobs[index];
    if (job == null) return false;
    final chapter = widget.book.chapters[index];
    final snapshot = job['narration_dictionary'];
    final old = snapshot is Map
        ? NarrationDictionaryConfig.fromJson(Map<String, dynamic>.from(snapshot)).transform(chapter).text
        : chapter.text;
    return narrationDictionary.effective(widget.book.id).transform(chapter).text != old;
  }

  Future<void> _runByokJobs() async {
    if (jobs.isEmpty || byokNarrationRunner.bookBusy(widget.book.id)) return;
    await byokNarrationRunner.runWaitingJobs(
      bookId: widget.book.id,
      jobs: jobs,
      textForChapter: (index) {
        final payload = chapterPayload(index);
        return payload['text'] as String;
      },
      onSave: save,
    );
    if (mounted) setState(() {});
  }

  Future<void> checkJobs() async {
    if (busy || jobs.isEmpty || !_checkingBooks.add(widget.book.id)) {
      return;
    }
    try {
      await _runByokJobs();
    } finally {
      _checkingBooks.remove(widget.book.id);
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    focusedChapter = widget.initialChapter;
    selected.addAll(widget.generationChapters ?? const <int>{});
    narrationDelivery.registerBookChapters(
      widget.book.id,
      widget.book.chapters,
    );
    narrationDelivery.addListener(deliveryChanged);
    offlineNarration.addListener(deliveryChanged);
    byokCredentials.addListener(deliveryChanged);
    byokNarrationRunner.addListener(deliveryChanged);
    load();
  }

  @override
  void dispose() {
    narrationDelivery.removeListener(deliveryChanged);
    offlineNarration.removeListener(deliveryChanged);
    byokCredentials.removeListener(deliveryChanged);
    byokNarrationRunner.removeListener(deliveryChanged);
    timer?.cancel();
    previewSequence++;
    try {
      unawaited(audioHandler.stopPreview());
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.generationChapters != null) return _generationSheet();
    final byokRunning = byokNarrationRunner.bookBusy(widget.book.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(focusedChapter == null ? 'Book narration' : 'Chapter narration'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Book narration settings',
            onSelected: (action) {
              switch (action) {
                case 'api_settings':
                  openApiSettings();
                case 'budget':
                  showNarrationBudgetDialog(context);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'api_settings', child: Text('API keys & voices')),
              PopupMenuItem(value: 'budget', child: Text('TTS usage & budget')),
            ],
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverList.list(children: [
            if (loaded &&
                narrationEngine != 'kokoro_offline' &&
                !byokCredentials.isConfigured(narrationEngine))
              TextButton.icon(
                onPressed: openApiSettings,
                icon: const Icon(Icons.key_outlined, size: 18),
                label: const Text('Configure API key'),
              ),
            if (byokRunning)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: OutlinedButton.icon(
                  onPressed: () => byokNarrationRunner.cancelBook(widget.book.id),
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('Cancel API generation'),
                ),
              ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(notice!, textAlign: TextAlign.center),
              ),
            _voiceControls(),
            _offlineStatusCard(),
            _costBanner(),
            TextButton.icon(
              icon: const Icon(Icons.menu_book), label: const Text('Narration Dictionary'),
              onPressed: () async {
                await stopPreview();
                if (!mounted) return;
                await openNarrationDictionary(this.context,
                  bookTitles: {widget.book.id: widget.book.title}, bookId: widget.book.id,
                  preference: NarrationPreference(narrationEngine, narrator), host: host, token: token);
                if (mounted) setState(() {});
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                children: [
                  if (focusedChapter != null)
                    TextButton(
                      onPressed: () => setState(() => focusedChapter = null),
                      child: const Text('Show all chapters'),
                    )
                  else ...[
                    OutlinedButton(
                      onPressed: loaded && !busy ? selectEntireBook : null,
                      child: const Text('Select entire book'),
                    ),
                    TextButton(
                      onPressed: selected.isEmpty ? null
                          : () => setState(() => selected.clear()),
                      child: const Text('Clear selection'),
                    ),
                  ],
                ],
              ),
            ),
            if (selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '${selected.length} chapters • ${selected.fold<int>(0, (sum, i) => sum + widget.book.chapters[i].text.length)} characters selected',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ]),
          if (loaded)
            BookNarrationStatus(
              bookId: widget.book.id,
              delivery: narrationDelivery,
              builder: (context, narration) => SliverList.builder(
                itemCount: focusedChapter == null ? widget.book.chapters.length : 1,
                itemBuilder: (context, row) {
                  final index = focusedChapter ?? row;
                  final job = jobs[index];
                  final status = job?['status'];
                  final audio = narration(index);
                  final action = audio.action;
                  final inFlight = narrationDelivery.deliveryInFlight(widget.book.id, index);
                  final selectable = !audio.hasRecording && _needsGeneration(index);
                  final download = canRetryNarrationDownload(job);
                  final canRegenerate = status == 'ready' || status == 'error';
                  return ListTile(
                    leading: focusedChapter == null
                        ? Checkbox(
                            value: selected.contains(index),
                            semanticLabel: 'Select ${widget.book.chapters[index].title}',
                            onChanged: !selectable || busy ? null : (checked) {
                              setState(() {
                                if (checked == true) {
                                  selected.add(index);
                                } else {
                                  selected.remove(index);
                                }
                              });
                            },
                          )
                        : null,
                    title: Text(widget.book.chapters[index].title),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(audio.label),
                        if (status == 'error' || job?['delivery'] == 'failed')
                          Text(narrationDeliveryLabel(job)),
                        if (job != null) Text(recordingLabel(job)),
                        if (dictionaryChanged(index))
                          const Text('Dictionary changed. Regenerate to apply.'),
                        if (action != null &&
                            (action == ChapterAudioAction.play ||
                             action == ChapterAudioAction.pause))
                          TextButton(
                            onPressed: () => runChapterAudioAction(
                              context, widget.book, index, widget.onSave, action,
                            ),
                            child: Text(action.label),
                          )
                        else if (action != null &&
                            (action == ChapterAudioAction.download ||
                             action == ChapterAudioAction.retryDownload))
                          TextButton(
                            onPressed: busy || inFlight ? null : () => repairChapterAudio(index),
                            child: Text(action.label),
                          )
                        else if (action == ChapterAudioAction.retryGeneration)
                          TextButton(
                            onPressed: busy || inFlight ? null : () => regenerate(index),
                            child: const Text('Retry generation'),
                          ),
                      ],
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Narration actions for ${widget.book.chapters[index].title}',
                      onSelected: (choice) {
                        switch (choice) {
                          case 'player':
                            openChapterPlayer(context, widget.book, index, widget.onSave);
                          case 'download':
                            repairChapterAudio(index);
                          case 'regenerate':
                            regenerate(index);
                          case 'delete':
                            deleteChapterAudio(index);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'player', child: Text('Open player')),
                        if (download && audio.hasRecording)
                          PopupMenuItem(value: 'download', enabled: !busy && !inFlight,
                            child: const Text('Retry download')),
                        if (canRegenerate)
                          PopupMenuItem(value: 'regenerate', enabled: !busy && !inFlight,
                            child: Text(status == 'error' ? 'Retry generation' : 'Regenerate narration')),
                        if (audio.hasRecording)
                          PopupMenuItem(value: 'delete', enabled: !busy && !inFlight,
                            child: const Text('Delete chapter audio')),
                      ],
                    ),
                  );
                },
              ),
            )
          else
            const SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: selected.isEmpty || busy || !loaded ? null : confirmGeneration,
            child: Text(focusedChapter != null
                ? 'Generate narration'
                : 'Generate narration (${selected.length})'),
          ),
        ),
      ),
    );
  }
}

class ReadingScreen extends StatefulWidget {
  final bool continuous;
  final BookProgress? progressStore;
  final SavePosition? onCheckpoint;
  final ImportedBook book;
  final int chapterIndex;
  final int initialOffset;
  final SavePosition onSave;
  const ReadingScreen({
    this.continuous = false,
    super.key,
    required this.book,
    required this.chapterIndex,
    required this.initialOffset,
    required this.onSave,
    this.onCheckpoint,
    this.progressStore,
  });

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> with WidgetsBindingObserver {
  final _articleScroll = ScrollController();
  Object? _readingSession;
  double fontSize = 19;
  late int chapterIndex;
  late int currentOffset;
  PageController? controller;
  List<int> starts = [0];
  List<String> pages = [];
  double previousWidth = -1;
  double previousHeight = -1;
  double previousFont = -1;
  int currentPage = 0;
  int _paginationGeneration = 0;
  bool _paginating = false;

  @override
  void initState() {
    super.initState();
    unawaited(narrationDelivery.reconcile());
    WidgetsBinding.instance.addObserver(this);
    chapterIndex = widget.chapterIndex;
    currentOffset = widget.initialOffset;
    if (widget.continuous) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_articleScroll.hasClients) return;
        final length = widget.book.chapters[chapterIndex].text.length;
        if (length > 0) _articleScroll.jumpTo(_articleScroll.position.maxScrollExtent * (currentOffset / length).clamp(0.0, 1.0));
      });
    }
    _saveReading(chapterIndex, currentOffset, activate: true);
  }

  TextSpan styledPage(int start, int end) {
    final chapter = widget.book.chapters[chapterIndex];
    final text = chapter.text;
    // Restrict style checks to ranges intersecting this page. Pagination
    // invokes this method many times; scanning the whole chapter for every
    // text segment makes long chapters disproportionately expensive.
    final relevant = chapter.ranges
        .where((r) => r.end > start && r.start < end)
        .toList();
    final boundaries = <int>{start, end};
    for (final r in relevant) {
      boundaries.add(math.max(start, math.min(end, r.start)));
      boundaries.add(math.max(start, math.min(end, r.end)));
    }
    final cuts = boundaries.toList()..sort();
    final children = <TextSpan>[];
    for (int i = 0; i + 1 < cuts.length; i++) {
      final a = cuts[i], b = cuts[i + 1];
      if (a == b) continue;
      final active = relevant.where((r) => r.start < b && r.end > a);
      children.add(
        TextSpan(
          text: text.substring(a, b),
          style: TextStyle(
            fontStyle: active.any((r) => r.italic)
                ? FontStyle.italic
                : FontStyle.normal,
            fontWeight: active.any((r) => r.bold || r.heading)
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        ),
      );
    }
    return TextSpan(
      style: TextStyle(fontSize: fontSize, height: 1.55, color: Theme.of(context).colorScheme.onSurface),
      children: children,
    );
  }

  // Pagination is expensive for long EPUB chapters. Measure a small batch
  // of pages per event-loop turn instead of blocking the UI isolate until
  // the entire chapter has been laid out.
  void calculatePages(double width, double height) {
    if (width == previousWidth &&
        height == previousHeight &&
        fontSize == previousFont &&
        (pages.isNotEmpty || _paginating)) {
      return;
    }
    previousWidth = width;
    previousHeight = height;
    previousFont = fontSize;
    final generation = ++_paginationGeneration;
    final targetChapter = chapterIndex;
    final targetFont = fontSize;
    _paginating = true;
    pages = [];
    starts = [];
    // Do not call setState from LayoutBuilder; the scheduled job will
    // publish its result after yielding to the event loop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _paginationGeneration) return;
      _paginateChapter(width, height, targetChapter, targetFont, generation);
    });
  }

  Future<void> _paginateChapter(
    double width,
    double height,
    int targetChapter,
    double targetFont,
    int generation,
  ) async {
    final text = widget.book.chapters[targetChapter].text;
    final painter = TextPainter(textDirection: TextDirection.ltr);
    bool fits(int start, int end) {
      painter.text = styledPage(start, end);
      painter.layout(maxWidth: width);
      return painter.height <= height;
    }

    final nextPages = <String>[];
    final nextStarts = <int>[];
    int offset = 0;
    try {
      while (offset < text.length) {
        if (!mounted ||
            generation != _paginationGeneration ||
            chapterIndex != targetChapter ||
            fontSize != targetFont) {
          return;
        }
        // Cap the binary-search range near a plausible page length.
        // Expand only when necessary, avoiding repeated full-chapter
        // layout on every page.
        int low = offset + 1;
        int high = math.min(text.length, offset + 1200);
        while (high < text.length && fits(offset, high)) {
          low = high;
          high = math.min(text.length, offset + (high - offset) * 2);
        }
        while (low < high) {
          final mid = low + (high - low + 1) ~/ 2;
          if (fits(offset, mid)) {
            low = mid;
          } else {
            high = mid - 1;
          }
        }
        int pageEnd = low;
        if (pageEnd < text.length) {
          final whitespace = text.lastIndexOf(RegExp(r'\s'), pageEnd - 1);
          if (whitespace > offset + (pageEnd - offset) ~/ 2) {
            pageEnd = whitespace + 1;
          }
        }
        if (pageEnd <= offset) pageEnd = math.min(offset + 1, text.length);
        nextStarts.add(offset);
        nextPages.add(text.substring(offset, pageEnd));
        offset = pageEnd;
        // Let navigation, media controls, and frames run between batches.
        if (nextPages.length % 2 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
      if (nextPages.isEmpty) {
        nextPages.add('');
        nextStarts.add(0);
      }
      if (!mounted || generation != _paginationGeneration ||
          chapterIndex != targetChapter || fontSize != targetFont) {
          return;
        }
      final nextPage = math.max(
        0,
        nextStarts.lastIndexWhere((value) => value <= currentOffset),
      );
      final oldController = controller;
      setState(() {
        pages = nextPages;
        starts = nextStarts;
        currentPage = nextPage;
        currentOffset = starts[currentPage];
        controller = PageController(initialPage: currentPage, keepPage: false);
        _paginating = false;
      });
      saveCurrent(activate: false);
      if (oldController != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          oldController.dispose();
        });
      }
    } finally {
      painter.dispose();
    }
  }

  // Keep navigation tied to the existing paginated text and saved offset.
  void jumpToPage(int page) {
    if (pages.isEmpty || controller == null) return;
    final target = page.clamp(0, pages.length - 1);
    currentPage = target;
    currentOffset = starts[target];
    saveCurrent();
    controller!.jumpToPage(target);
    if (mounted) setState(() {});
  }

  Future<void> showPageJump() async {
    if (_paginating || pages.isEmpty) return;
    final originalPage = currentPage;
    var previewPage = currentPage.toDouble();
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, updatePreview) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Jump to page',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Text('Page ${previewPage.round() + 1} of ${pages.length}'),
                Slider(
                  value: previewPage.clamp(0.0, (pages.length - 1).toDouble()),
                  min: 0,
                  max: math.max(1, pages.length - 1).toDouble(),
                  onChanged: (value) => updatePreview(() {
                    previewPage = value.clamp(0.0, (pages.length - 1).toDouble());
                  }),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, previewPage.round()),
                      child: const Text('Go to page'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || selected == null || currentPage != originalPage) return;
    jumpToPage(selected);
  }

  void _saveReading(int chapter, int offset, {required bool activate}) {
    final store = widget.progressStore;
    if (store != null) {
      if (activate) _readingSession = store.startReading(widget.book.id);
      unawaited(store.saveReading(widget.book.id, chapter, offset,
        activate: activate, session: _readingSession).catchError((Object _) {}));
    } else {
      final save = activate ? widget.onSave : widget.onCheckpoint ?? widget.onSave;
      unawaited(save(chapter, offset).catchError((Object _) {}));
    }
  }

  void saveCurrent({bool activate = true}) {
    final visible = ModalRoute.of(context)?.isCurrent ?? true;
    _saveReading(chapterIndex, currentOffset, activate: activate && visible);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    saveCurrent(activate: false);
  }

  void changeChapter(int next) {
    if (next < 0 || next >= widget.book.chapters.length) return;
    unawaited(narrationDelivery.reconcile());
    if (next > chapterIndex) {
      _saveReading(chapterIndex, widget.book.chapters[chapterIndex].text.length, activate: false);
    }
    setState(() {
      chapterIndex = next;
      currentOffset = 0;
      ++_paginationGeneration;
      _paginating = false;
      pages = [];
      previousWidth = -1;
    });
    saveCurrent();
  }

  void turnPage(int delta) {
    final target = currentPage + delta;
    if (target >= 0 && target < pages.length) {
      controller?.animateToPage(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else if (target >= pages.length) {
      if (chapterIndex == widget.book.chapters.length - 1) {
        currentOffset = widget.book.chapters[chapterIndex].text.length;
        saveCurrent();
      } else {
        changeChapter(chapterIndex + 1);
      }
    } else if (target < 0 && chapterIndex > 0) {
      changeChapter(chapterIndex - 1);
    }
  }

  @override
  void dispose() {
    ++_paginationGeneration;
    WidgetsBinding.instance.removeObserver(this);
    // Do not use ModalRoute.of(context) during disposal.
    _saveReading(chapterIndex, currentOffset, activate: false);
    _articleScroll.dispose();
    controller?.dispose();
    super.dispose();
  }

  void listenFromCurrentPage() {
    if (!widget.continuous && (_paginating || pages.isEmpty)) return;
    if (!widget.continuous && currentPage >= 0 && currentPage < pages.length) {
      currentOffset = starts[currentPage];
    }
    saveCurrent();
    final textLength = widget.book.chapters[chapterIndex].text.length;
    final fraction = textLength == 0
        ? 0.0
        : (currentOffset / textLength).clamp(0.0, 1.0);
    final audioChapter = chapterIndex;
    Navigator.push<void>(context, MaterialPageRoute<void>(
      builder: (_) => ChapterNarrationScreen(
        book: widget.book,
        chapterIndex: audioChapter,
        onSave: widget.onSave,
        initialTextFraction: fraction,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.book.chapters[chapterIndex];
    final pageChapter = chapterIndex;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          chapter.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Decrease text size',
            onPressed: () => setState(() {
              fontSize = (fontSize - 2).clamp(14.0, 32.0);
            }),
            icon: const Icon(Icons.text_decrease),
          ),
          IconButton(
            tooltip: 'Increase text size',
            onPressed: () => setState(() {
              fontSize = (fontSize + 2).clamp(14.0, 32.0);
            }),
            icon: const Icon(Icons.text_increase),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          const horizontalPadding = 24.0;
          const verticalPadding = 20.0;
          const footerHeight = 48.0;
          final width = math.max(
            100.0,
            constraints.maxWidth - horizontalPadding * 2,
          );
          final height = math.max(
            100.0,
            constraints.maxHeight - verticalPadding * 2 - footerHeight,
          );
          if (!widget.continuous) calculatePages(width, height);
          if (!widget.continuous && (_paginating || pages.isEmpty || controller == null)) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
          return Column(
            children: [
              Expanded(
                child: widget.continuous
                    ? NotificationListener<ScrollNotification>(
                        onNotification: (event) {
                          final max = event.metrics.maxScrollExtent;
                          if (max > 0 && event is ScrollUpdateNotification) {
                            currentOffset = (chapter.text.length * (event.metrics.pixels / max).clamp(0.0, 1.0)).round();
                          }
                          if (event is ScrollEndNotification) saveCurrent();
                          return false;
                        },
                        child: SingleChildScrollView(
                          controller: _articleScroll,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                          child: RichText(text: styledPage(0, chapter.text.length)),
                        ),
                      )
                    : PageView.builder(
                  key: ValueKey('reading-chapter-$chapterIndex'),
                  controller: controller,
                  itemCount: pages.length,
                  onPageChanged: (index) {
                    if (pageChapter != chapterIndex || _paginating || index >= starts.length) return;
                    currentPage = index;
                    currentOffset = starts[index];
                    saveCurrent();
                    setState(() {});
                  },
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                      vertical: verticalPadding,
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapUp: (details) {
                        final x = details.localPosition.dx;
                        if (x < width * 0.28) turnPage(-1);
                        if (x > width * 0.72) turnPage(1);
                      },
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: RichText(
                          text: styledPage(
                            starts[index],
                            starts[index] + pages[index].length,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: footerHeight,
                child: BookNarrationStatus(
                  bookId: widget.book.id,
                  delivery: narrationDelivery,
                  builder: (context, narration) {
                    final audio = narration(pageChapter);
                    final action = audio.action;
                    final playing = action == ChapterAudioAction.pause;
                    return Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: widget.continuous ? null : showPageJump,
                            child: Center(
                              child: Text(
                                widget.continuous ? 'Article' : '${currentPage + 1} / ${pages.length}  •  Tap to jump',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (audio.hasRecording)
                          IconButton(
                            tooltip: playing ? 'Pause narration' : 'Play narration',
                            onPressed: () => runChapterAudioAction(
                              context, widget.book, pageChapter, widget.onSave, action!,
                            ),
                            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                          ),
                        PopupMenuButton<String>(
                          tooltip: 'Narration',
                          onSelected: (choice) {
                            if (choice == 'page') {
                              listenFromCurrentPage();
                            } else if (choice == 'player') {
                              openChapterPlayer(context, widget.book, pageChapter, widget.onSave);
                            } else {
                              openBookNarration(context, widget.book, widget.onSave, chapter: pageChapter);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(enabled: false, child: Text(audio.label)),
                            const PopupMenuItem(value: 'page', child: Text('Listen from this page')),
                            const PopupMenuItem(value: 'manage', child: Text('Manage chapter narration')),
                            const PopupMenuItem(value: 'player', child: Text('Open player')),
                          ],
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            child: Text('Narration', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ChapterNarrationScreen extends StatefulWidget {
  final ImportedBook book;
  final int chapterIndex;
  // Carried for synchronization integration; listening alone never moves a
  // saved reader offset or guesses one from the audio position.
  final SavePosition onSave;
  // Present only when arriving from the reader; normal player navigation
  // continues to restore the last saved audio position.
  final double? initialTextFraction;
  final bool playOnOpen;
  const ChapterNarrationScreen({
    super.key,
    required this.book,
    required this.chapterIndex,
    required this.onSave,
    this.initialTextFraction,
    this.playOnOpen = false,
  });

  @override
  State<ChapterNarrationScreen> createState() => _ChapterNarrationScreenState();
}

class _ChapterNarrationScreenState extends State<ChapterNarrationScreen> {
  final player = audioHandler.player;
  late int chapterIndex;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  bool playing = false;
  bool loading = true;
  bool importing = false;
  String? audioPath;
  String? error;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double speed = 1.0;

  int _restoreGeneration = 0;
  late bool _playOnOpen = widget.playOnOpen;

  String get chapterKey => '${widget.book.id}:$chapterIndex';

  Future<File> get stateFile async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/narration_state.json');
  }

  Future<Map<String, dynamic>> readState() async {
    try {
      final file = await stateFile;
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (_) {}
    return {};
  }

  Future<void> updateState(Map<String, dynamic> values) async {
    await updateNarrationJson(await stateFile, (data) {
      final existing = Map<String, dynamic>.from((data[chapterKey] as Map?) ?? {});
      data[chapterKey] = {...existing, ...values};
    });
  }

  @override
  void initState() {
    super.initState();
    chapterIndex = widget.chapterIndex;
    subscriptions.add(audioHandler.mediaItem.listen((item) {
      final prefix = '${widget.book.id}:';
      if (!mounted || loading || item == null || !item.id.startsWith(prefix)) return;
      final index = int.tryParse(item.id.substring(prefix.length));
      if (index == null || index < 0 || index >= widget.book.chapters.length || index == chapterIndex) return;
      setState(() {
        ++_restoreGeneration;
        chapterIndex = index;
        audioPath = audioHandler.activeAudioPath;
        position = player.position;
        duration = player.duration ?? Duration.zero;
        loading = false;
      });
    }));

    subscriptions.add(
      player.playerStateStream.listen((state) {
        if (mounted) {
          setState(() => playing = state.playing);
        }
      }),
    );

    subscriptions.add(
      player.positionStream.listen((value) {
        if (!mounted) return;
        setState(() => position = value);
      }),
    );

    subscriptions.add(
      player.durationStream.listen((value) {
        if (mounted && value != null) {
          setState(() => duration = value);
        }
      }),
    );

    subscriptions.add(
      player.processingStateStream.listen((state) {
        if (state == ja.ProcessingState.completed) {
          if (mounted) {
            setState(() {
              playing = false;
              position = Duration.zero;
            });
          }
        }
      }),
    );

    narrationDelivery.addListener(deliveryChanged);
    unawaited(narrationDelivery.reconcile());
    restore();
  }

  String? lastDelivery;
  void deliveryChanged() {
    if (!mounted) return;
    final next = narrationDelivery.books[widget.book.id]?[chapterIndex]?['delivery'] as String?;
    final completed = next == 'downloaded' && lastDelivery != next;
    lastDelivery = next;
    if (completed && !loading && (ModalRoute.of(context)?.isCurrent ?? true) &&
        (audioPath == null || audioHandler.mediaItem.value == null)) {
      setState(() => loading = true);
      unawaited(restore());
    } else {
      setState(() {});
    }
  }

  Future<void> restore() async {
    audioHandler.recordDiagnostic(MediaDiagnosticEvent.restoreRequested);
    final generation = ++_restoreGeneration;
    bool active() => mounted && generation == _restoreGeneration &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    try {
      await narrationDelivery.waitForDownload(widget.book.id, chapterIndex);
      if (!active()) return;
      final root = await getApplicationDocumentsDirectory();
      final localFile = File(
        '${root.path}/narration/${widget.book.id}_$chapterIndex.mp3',
      );

      if (!narrationDelivery.deliveryInFlight(widget.book.id, chapterIndex)) {
        await recoverNarrationFile(localFile);
      }
      final data = await readState();
      final entry = data[chapterKey];
      String? path;
      int savedPosition = 0;

      if (entry is Map) {
        final storedPath = entry['path'];
        if (storedPath is String && !storedPath.endsWith('.part') && !storedPath.endsWith('.bak') &&
            await File(storedPath).exists() && await File(storedPath).length() >= 1000) {
          path = storedPath;
          savedPosition = (entry['positionMs'] as num?)?.toInt() ?? 0;
        }
      }

      if (path == null && await localFile.exists() && await localFile.length() >= 1000) {
        path = localFile.path;
        if (!active()) return;
        savedPosition = entry is Map ? (entry['positionMs'] as num?)?.toInt() ?? 0 : 0;
        await updateState({'path': path});
      }

      if (!active()) return;
      if (path != null) {
        audioPath = path;
        Future<void> load() => audioHandler.loadChapter(
          path: path!,
          title: widget.book.chapters[chapterIndex].title,
          author: widget.book.author,
          bookId: widget.book.id,
          chapterIndex: chapterIndex,
          chapterCount: widget.book.chapters.length,
          startPosition: Duration(milliseconds: savedPosition),
          isCurrent: active,
        );
        var prepared = false;
        Future<void> prepare() async {
          await load();
          prepared = true;
        }
        if (widget.initialTextFraction != null) {
          // loadChapter deliberately preserves an already loaded chapter.
          // Seeking is a separate step and always runs for reader navigation.
          final completed = await seekNarrationFromText(
            fraction: narrationFraction(widget.initialTextFraction!,
                entry is Map ? entry['narration_offsets'] : null), load: prepare,
            pause: () => audioHandler.pause(origin: 'reader jump'),
            seek: (target) => audioHandler.seek(target, origin: 'reader jump'),
            duration: () => player.duration, position: () => player.position,
            isCurrent: () => active() &&
                (!prepared || audioHandler.mediaItem.value?.id == chapterKey),
          );
          if (!completed) return;
        } else {
          await load();
          if (!active() || audioHandler.mediaItem.value?.id != chapterKey) return;
          await refreshDuration();
        }
        if (!active() || audioHandler.mediaItem.value?.id != chapterKey) return;
        duration = player.duration ?? Duration.zero;
        position = player.position;
        if (_playOnOpen) {
          _playOnOpen = false;
          if (!audioHandler.playbackState.value.playing) {
            await audioHandler.play(origin: 'chapter narration controls');
          }
        }
      }
    } catch (e) {
      if (active()) error = 'Could not load recording: $e';
    } finally {
      audioHandler.recordDiagnostic(MediaDiagnosticEvent.restoreFinished);
      if (active()) setState(() => loading = false);
    }
  }

  Future<void> refreshDuration() async {
    // Some Android decoders report duration only after preparing the source.
    for (var attempt = 0; attempt < 40; attempt++) {
      if (!mounted) return;
      Duration? found;
      try {
        found = player.duration;
      } catch (_) {
        // Android may not have prepared the decoder yet.
      }
      if (found != null && found.inMilliseconds > 0) {
        if (mounted) setState(() => duration = found!);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> importAudio() async {
    if (importing) return;
    setState(() {
      importing = true;
      error = null;
    });
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['mp3'],
      );
      if (picked == null) return;
      if (picked.path == null) {
        throw Exception('Android did not provide access to this MP3.');
      }
      final root = await getApplicationDocumentsDirectory();
      final folder = Directory('${root.path}/narration');
      await folder.create(recursive: true);
      final target = File(
        '${folder.path}/${widget.book.id}_$chapterIndex.mp3',
      );
      if (!mounted) return;
      await audioHandler.unloadChapter(widget.book.id, chapterIndex);
      if (!mounted) return;
      await File(picked.path!).copy(target.path);
      if (mounted) setState(() => duration = Duration.zero);
      await audioHandler.loadChapter(
        path: target.path,
        title: widget.book.chapters[chapterIndex].title,
        author: widget.book.author,
        bookId: widget.book.id,
        chapterIndex: chapterIndex,
        chapterCount: widget.book.chapters.length,
        forceReload: true,
        isCurrent: () => mounted,
      );
      if (!mounted) return;
      await refreshDuration();
      if (!mounted || audioHandler.mediaItem.value?.id != chapterKey) return;
      await audioHandler.seek(Duration.zero, origin: 'import audio');
      await updateState({'path': target.path, 'positionMs': 0,
        'narration_offsets': null, 'narration_dictionary': null});
      if (mounted) {
        setState(() {
          audioPath = target.path;
          position = Duration.zero;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Could not import MP3: $e');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> togglePlayback() async {
    try {
      if (playing) {
        await audioHandler.pause(origin: 'in-app');
      } else if (audioPath != null) {
        await audioHandler.play(origin: 'in-app');
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Playback error: $e');
    }
  }

  Future<void> seekTo(Duration value) async {
    if (audioPath == null || loading) return;
    final maxMs = duration.inMilliseconds;
    final ms = value.inMilliseconds.clamp(
      0,
      maxMs > 0 ? maxMs : value.inMilliseconds,
    );
    final target = Duration(milliseconds: ms);
    await audioHandler.seek(target, origin: 'in-app seek');
    if (mounted) setState(() => position = target);
  }

  Future<void> changeSpeed() async {
    const speeds = [1.0, 1.25, 1.5, 1.75, 2.0, 0.75];
    final next = speeds[(speeds.indexOf(speed) + 1) % speeds.length];
    try {
      await audioHandler.setSpeed(next);
      if (mounted) setState(() => speed = next);
    } catch (e) {
      if (mounted) setState(() => error = 'Speed change failed: $e');
    }
  }

  String clock(Duration value) {
    final seconds = value.inSeconds;
    final minutes = seconds ~/ 60;
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainder';
  }

  @override
  void dispose() {
    unawaited(audioHandler.checkpointPosition());
    narrationDelivery.removeListener(deliveryChanged);
    ++_restoreGeneration;
    for (final sub in subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasAudio = audioPath != null;
    final maxMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final currentMs = position.inMilliseconds.toDouble().clamp(0.0, maxMs);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chapter narration'),
        actions: [
          IconButton(
            tooltip: 'Audio diagnostics',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
              builder: (_) => const AudioDiagnosticsScreen(),
            )),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/chapter_headphones.webp',
                  width: 76,
                  height: 76,
                  filterQuality: FilterQuality.high,
                  excludeFromSemantics: true,
                ),
                const SizedBox(height: 14),
                Text(
                  widget.book.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.book.chapters[chapterIndex].title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (loading) const CircularProgressIndicator(),
                if (!loading && !hasAudio)
                  Text(
                    narrationDelivery.books[widget.book.id]?[chapterIndex] == null
                        ? 'Narration is not downloaded yet. Finished cloud audio downloads automatically.'
                        : narrationDeliveryLabel(narrationDelivery.books[widget.book.id]?[chapterIndex]),
                    textAlign: TextAlign.center,
                  ),
                if (!hasAudio && canRetryNarrationDownload(narrationDelivery.books[widget.book.id]?[chapterIndex]))
                  TextButton.icon(
                    onPressed: narrationDelivery.deliveryInFlight(widget.book.id, chapterIndex) ? null : () async {
                      try {
                        await narrationDelivery.retryDownload(widget.book.id, chapterIndex);
                      } catch (_) {
                        if (mounted) setState(() => error = 'Download interrupted. Retry Download when connected.');
                      }
                    },
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: Text(narrationDelivery.downloading(widget.book.id, chapterIndex)
                        ? 'Downloading…' : 'Retry Download'),
                  ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: importing || loading ? null : importAudio,
                  icon: const Icon(Icons.audio_file),
                  label: Text(
                    importing
                        ? 'Importing…'
                        : hasAudio
                        ? 'Replace chapter MP3'
                        : 'Import chapter MP3',
                  ),
                ),
                if (hasAudio) ...[
                  const SizedBox(height: 24),
                  Slider(
                    value: currentMs,
                    max: maxMs,
                    onChanged: loading || duration.inMilliseconds <= 0
                        ? null
                        : (v) => setState(
                            () => position = Duration(milliseconds: v.round()),
                          ),
                    onChangeEnd: (v) =>
                        seekTo(Duration(milliseconds: v.round())),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(clock(position)),
                      Text(
                        duration.inMilliseconds > 0
                            ? clock(duration)
                            : "Loading duration…",
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Back 15 seconds',
                        onPressed: () =>
                            seekTo(position - const Duration(seconds: 15)),
                        icon: const Icon(Icons.replay_10),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: loading ? null : togglePlayback,
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        label: Text(playing ? 'Pause' : 'Play'),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        tooltip: 'Forward 15 seconds',
                        onPressed: () =>
                            seekTo(position + const Duration(seconds: 15)),
                        icon: const Icon(Icons.forward_10),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: loading ? null : changeSpeed,
                    child: Text('$speed× speed'),
                  ),
                  TextButton.icon(
                    onPressed: () => seekTo(Duration.zero),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Restart chapter'),
                  ),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Text(
                      error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}



class AudioDiagnosticsScreen extends StatelessWidget {
  const AudioDiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Audio diagnostics'),
      actions: [
        IconButton(
          tooltip: 'Share diagnostic log',
          icon: const Icon(Icons.share),
          onPressed: () async {
            final diagnostics = audioHandler.diagnostics;
            if (diagnostics == null) return;
            try {
              await NativeMediaDiagnostics.share(diagnostics);
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Could not share diagnostics. Please try again.'),
                ));
              }
            }
          },
        ),
      ],
    ),
    body: ValueListenableBuilder<List<String>>(
      valueListenable: audioHandler.diagnosticCommands,
      builder: (context, commands, _) => StreamBuilder<PlaybackState>(
        stream: audioHandler.playbackState,
        builder: (context, snapshot) {
          final player = audioHandler.player;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Build $dogreaderBuild • audio command diagnostics',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text('Before testing, note the command count. Open the notification '
                    'or lock screen and press Pause or Play once. Return here without '
                    'using the in-app playback buttons. Did the count increase?'),
                const SizedBox(height: 16),
                SelectableText('Narration delivery\n${narrationDelivery.diagnostics.join("\n")}'),
                Text('Commands received: ${audioHandler.diagnosticCommandCount}'),
                Text('Playing: ${player.playing}'),
                Text('Playback requested: ${audioHandler.diagnosticWantsPlayback}'),
                Text('Player state: ${player.processingState.name}'),
                Text('Session playing: ${audioHandler.playbackState.value.playing}'),
                Text('Session state: ${audioHandler.playbackState.value.processingState.name}'),
                Text('Session error code: ${audioHandler.playbackState.value.errorCode ?? "none"}'),
                SelectableText('Last error: ${audioHandler.diagnosticLastError ?? "none"}'),
                SelectableText('Last session bridge error: ${audioHandler.diagnosticLastSessionError ?? "none"}'),
                const SizedBox(height: 16),
                const Text('Both in-app and external commands appear below. '
                    'The count resets when the audio handler restarts. '
                    'Share exports bounded logs from this and the previous process. '
                    'Opening this screen does not issue playback commands.'),
                const SizedBox(height: 16),
                SelectableText('Handler started: ${audioHandler.diagnosticStarted.toIso8601String()}\n\n'
                    '${commands.isEmpty ? "No commands received yet." : commands.join("\n\n")}'),
              ],
            ),
          );
        },
      ),
    ),
  );
}

