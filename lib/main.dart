import 'package:just_audio/just_audio.dart' as ja;
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:async';

import 'package:path_provider/path_provider.dart';

import 'package:epubx/epubx.dart' hide Image;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:audio_service/audio_service.dart';

import 'dogreader_audio_handler.dart';
import 'app_theme.dart';
import 'theme_preferences.dart';
export 'app_theme.dart' show background, panel, accent;

import 'reader_content.dart';
export 'reader_content.dart' show ReaderChapter, StyledRange;
import 'narration_seek.dart';
import 'narration_files.dart';
import 'narration_options.dart';

late final DogreaderAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  audioHandler = await AudioService.init(
    builder: () => DogreaderAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.audiobook_app.audio',
      androidNotificationChannelName: 'Dogreader narration',
      androidNotificationOngoing: true,
    ),
  );

  final appearance = ThemePreferences();
  await appearance.load();
  runApp(AudiobookApp(appearance: appearance));
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
  const LibraryScreen({super.key, this.appearance});

  final ThemePreferences? appearance;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int selectedTab = 0;
  bool importing = false;
  final List<ImportedBook> books = [];
  final Map<String, Map<String, int>> progress = {};
  final Map<String, Map<String, int>> chapterProgress = {};
  final Map<String, int> lastOpened = {};
  Future<void> _pendingStateWrite = Future<void>.value();

  void sortBooks() {
    books.sort((a, b) {
      final recent = (lastOpened[b.id] ?? 0).compareTo(lastOpened[a.id] ?? 0);
      if (recent != 0) return recent;
      return b.id.compareTo(a.id);
    });
  }

  Future<void> persistReadingState() {
    final snapshot = jsonEncode({
      'positions': progress,
      'chapterProgress': chapterProgress,
      'lastOpened': lastOpened,
    });
    _pendingStateWrite = _pendingStateWrite.catchError((Object _) {}).then((
      _,
    ) async {
      final directory = await bookDirectory();
      final stateFile = File('${directory.parent.path}/reading_state.json');
      final temporary = File('${stateFile.path}.tmp');
      await temporary.writeAsString(snapshot);
      await temporary.rename(stateFile.path);
    });
    return _pendingStateWrite;
  }

  void openBook(ImportedBook book) {
    setState(() {
      lastOpened[book.id] = DateTime.now().microsecondsSinceEpoch;
      sortBooks();
    });
    persistReadingState().catchError((Object _) {});

    final saved = progress[book.id];
    final chapter = (saved?['chapter'] ?? 0).clamp(0, book.chapters.length - 1);
    final offset = (saved?['offset'] ?? 0).clamp(
      0,
      book.chapters[chapter].text.length,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingScreen(
          book: book,
          chapterIndex: chapter,
          initialOffset: offset,
          onSave: (chapter, offset) => saveProgress(book.id, chapter, offset),
        ),
      ),
    );
  }

  void openChapters(ImportedBook book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChapterListScreen(
          book: book,
          saved: progress[book.id],
          onSave: (chapter, offset) => saveProgress(book.id, chapter, offset),
          chapterOffsets: chapterProgress[book.id] ?? {},
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    loadLibrary();
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
      final stateFile = File('${directory.parent.path}/reading_state.json');
      if (await stateFile.exists()) {
        final data =
            jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
        final recent = data['lastOpened'] as Map<String, dynamic>? ?? {};
        for (final entry in recent.entries) {
          lastOpened[entry.key] = (entry.value as num?)?.toInt() ?? 0;
        }
        final history = data['chapterProgress'] as Map<String, dynamic>? ?? {};
        for (final entry in history.entries) {
          if (entry.value is Map) {
            chapterProgress[entry.key] = (entry.value as Map).map((key, value) =>
              MapEntry(key.toString(), (value as num?)?.toInt() ?? 0));
          }
        }
        final positions = data['positions'] as Map<String, dynamic>? ?? {};
        for (final entry in positions.entries) {
          final position = entry.value as Map<String, dynamic>;
          progress[entry.key] = {
            'chapter': (position['chapter'] as num?)?.toInt() ?? 0,
            'offset': (position['offset'] as num?)?.toInt() ?? 0,
          };
        }
      }
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
          restored.add(
            ImportedBook(
              title.isEmpty ? 'Untitled book' : title,
              author.isEmpty ? 'Unknown author' : author,
              chapters,
              entity.uri.pathSegments.last.replaceAll('.epub', ''),
              extractCover(epub),
            ),
          );
        } catch (_) {
          /* Ignore unreadable files. */
        }
      }
      if (!mounted) return;
      setState(() {
        books.clear();
        books.addAll(restored);
        sortBooks();
      });
    } catch (_) {
      /* Library remains usable even if restoration fails. */
    }
  }

  Future<void> saveProgress(String id, int chapter, int offset) async {
    progress[id] = {'chapter': chapter, 'offset': offset};
    final offsets = chapterProgress.putIfAbsent(id, () => {});
    final key = '$chapter';
    if (offset > (offsets[key] ?? 0)) offsets[key] = offset;
    try {
      await persistReadingState();
    } catch (_) {
      /* Don't interrupt reading for a save failure. */
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
      ],
    );
  }

  Widget _libraryPage() {
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
        const SizedBox(height: 26),
        if (books.isEmpty) _emptyLibrary(),
        for (final book in books)
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
                builder: (_) => NarrationQueueScreen(book: book),
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

class ChapterListScreen extends StatelessWidget {
  final ImportedBook book;
  final Map<String, int>? saved;
  final SavePosition onSave;
  final Map<String, int> chapterOffsets;
  const ChapterListScreen({
    super.key,
    required this.book,
    required this.saved,
    required this.onSave,
    required this.chapterOffsets,
  });

  @override
  Widget build(BuildContext context) {
    final lastChapter = saved?['chapter'] ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(book.title),
        actions: [
          IconButton(
            tooltip: 'Generate narration',
            icon: const Icon(Icons.record_voice_over),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => NarrationQueueScreen(book: book),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => NarrationQueueScreen(book: book),
                ),
              ),
              icon: const Icon(Icons.headphones),
              label: const Text('Listen / Generate narration'),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(14),
              itemCount: book.chapters.length + (saved == null ? 0 : 1),
              itemBuilder: (context, row) {
                if (saved != null && row == 0) {
                  return Card(
                    child: ListTile(
                      leading: Icon(Icons.bookmark, color: Theme.of(context).colorScheme.primary),
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
                        lastChapter.clamp(0, book.chapters.length - 1),
                        resume: true,
                      ),
                    ),
                  );
                }
                final index = row - (saved == null ? 0 : 1);
                final chapter = book.chapters[index];
                final savedOffset = math.max(
                  chapterOffsets['$index'] ?? 0,
                  saved != null && saved!['chapter'] == index
                      ? (saved!['offset'] ?? 0) : 0,
                );
                final fraction =
                    (savedOffset / math.max(1, chapter.text.length)).clamp(
                      0.0,
                      1.0,
                    );

                return ListTile(
                  leading: Icon(
                    Icons.auto_stories_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(chapter.title),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 3,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openChapter(context, index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void openChapter(BuildContext context, int index, {bool resume = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingScreen(
          book: book,
          chapterIndex: index,
          initialOffset: resume ? (saved?['offset'] ?? 0) : 0,
          onSave: onSave,
        ),
      ),
    );
  }
}

class NarrationQueueScreen extends StatefulWidget {
  final ImportedBook book;
  const NarrationQueueScreen({super.key, required this.book});
  @override
  State<NarrationQueueScreen> createState() => _NarrationQueueScreenState();
}

class _NarrationQueueScreenState extends State<NarrationQueueScreen> {
  String narrationEngine = 'google';
  String narrator = 'en-US-Chirp3-HD-Achernar';
  ja.AudioPlayer? previewPlayer;
  bool previewing = false;
  int previewSequence = 0;
  final Set<int> selected = {};
  final Map<int, Map<String, dynamic>> jobs = {};
  String host = '';
  String token = '';
  bool busy = false;
  String? notice;
  Timer? timer;

  Future<File> get queueFile async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/dogreader_queue.json');
  }

  Future<void> load() async {
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
              jobs[index] = Map<String, dynamic>.from(entry.value as Map);
            }
          }
        }
      }
    } catch (_) {}
    final root = await getApplicationDocumentsDirectory();
    for (var index = 0; index < widget.book.chapters.length; index++) {
      final file = File('${root.path}/narration/${widget.book.id}_$index.mp3');
      if (await file.exists() && await file.length() > 1000 &&
          !['waiting', 'queued', 'generating', 'error'].contains(jobs[index]?['status'])) {
        jobs[index] = {
          ...?jobs[index],
          'status': 'ready',
          'id': jobs[index]?['id'],
        };
      }
    }
    if (mounted) setState(() {});
    await checkJobs();
  }

  Future<void> save() async {
    final file = await queueFile;
    Map<String, dynamic> data = {};
    try {
      if (await file.exists()) {
        data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {}
    data['host'] = host;
    data['token'] = token;
    data['narrator'] = narrator;
    data['engine'] = narrationEngine;
    final books = Map<String, dynamic>.from((data['books'] as Map?) ?? {});
    books[widget.book.id] = jobs.map((k, v) => MapEntry('$k', v));
    data['books'] = books;
    await file.writeAsString(jsonEncode(data));
  }

  Uri endpoint(String path) =>
      Uri.parse('${host.replaceAll(RegExp(r'/$'), '')}$path');

  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client
          .openUrl(method, endpoint(path))
          .timeout(const Duration(seconds: 8));
      req.headers.set('X-Dogreader-Token', token);
      if (payload != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(payload));
      }
      final response = await req.close().timeout(const Duration(seconds: 15));
      final body = await utf8.decoder.bind(response).join();
      final result = jsonDecode(body) as Map<String, dynamic>;
      if (response.statusCode >= 400) {
        throw Exception(result['error'] ?? 'HTTP ${response.statusCode}');
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> configure() async {
    final hostController = TextEditingController(text: host);
    final tokenController = TextEditingController(text: token);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect Dogreader Cloud'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter your Cloud Run HTTPS URL and the private access token printed by the deployment script. Keep the token secret.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: hostController,
                decoration: const InputDecoration(
                  labelText: 'Cloud Run URL',
                  hintText: 'https://dogreader-api-....run.app',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokenController,
                decoration: const InputDecoration(
                  labelText: 'Private access token',
                ),
                autocorrect: false,
                obscureText: true,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      final candidate = hostController.text.trim();
      if (!candidate.startsWith('https://') ||
          Uri.tryParse(candidate)?.host.isEmpty != false) {
        if (mounted) {
          setState(() => notice = 'Enter a valid HTTPS Cloud Run URL.');
        }
        hostController.dispose();
        tokenController.dispose();
        return;
      }
      host = candidate;
      token = tokenController.text.trim();
      await save();
      if (mounted) {
        setState(() => notice = 'Settings saved. Tap Check connection.');
      }
    }
    hostController.dispose();
    tokenController.dispose();
  }

  Future<void> checkConnection() async {
    try {
      final data = await requestJson('GET', '/dogreader/ping');
      if (mounted) {
        setState(() => notice = 'Connected! Voice: ${data['voice']}');
      }
    } catch (e) {
      if (mounted) setState(() => notice = 'Cannot reach cloud server: $e');
    }
  }

  void selectEntireBook() {
    setState(() {
      selected.clear();
      for (var i = 0; i < widget.book.chapters.length; i++) {
        final status = jobs[i]?['status'];
        if (status == null || status == 'error') selected.add(i);
      }
      notice = selected.isEmpty
          ? 'All chapters are already generated or queued.'
          : '${selected.length} chapters selected. Review and tap Generate.';
    });
  }

  Future<void> deleteChapterAudio(int index) async {
    if (busy) return;
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
    if (confirmed != true || !mounted || busy) return;
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

  Future<void> playChapter(int index) async {
    final root = await getApplicationDocumentsDirectory();
    final file = File('${root.path}/narration/${widget.book.id}_$index.mp3');
    if (!await file.exists()) {
      if (mounted) {
        setState(
          () =>
              notice = 'Recording not found locally. Try refreshing the queue.',
        );
      }
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChapterNarrationScreen(book: widget.book, chapterIndex: index),
      ),
    );
  }

  Future<void> stopPreview() async {
    previewSequence++;
    await previewPlayer?.stop();
    if (mounted) setState(() => previewing = false);
  }

  Future<void> previewVoice() async {
    if (host.isEmpty || token.isEmpty) {
      setState(() => notice = 'Connect Dogreader Cloud before previewing.');
      return;
    }
    final sequence = ++previewSequence;
    final preference = NarrationPreference(narrationEngine, narrator);
    setState(() { previewing = true; notice = 'Preparing voice preview…'; });
    try {
      var response = await requestJson('POST', '/dogreader/jobs', {
        ...preference.toJson(),
        'title': 'Voice preview',
        'text': 'Welcome to Dogreader. “Shall we begin?” he asked. '
            'Settle in, choose a chapter, and enjoy a few quiet moments with your next story.',
      });
      final id = response['id'] as String;
      for (var attempt = 0; attempt < 60; attempt++) {
        if (!mounted || sequence != previewSequence) { return; }
        if (response['status'] == 'ready') { break; }
        if (response['status'] == 'error') { throw Exception(response['error'] ?? 'Preview generation failed'); }
        await Future<void>.delayed(const Duration(seconds: 2));
        response = await requestJson('GET', '/dogreader/jobs/$id');
      }
      if (response['status'] != 'ready') { throw Exception('Preview is still queued. Tap Preview voice again to resume.'); }
      if ((response['engine'] ?? 'google') != preference.engine ||
          (response['voice'] != null && response['voice'] != preference.voice)) {
        throw Exception('Server returned a different engine or voice. Update the backend.');
      }
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      late File preview;
      try {
        final req = await client.getUrl(endpoint('/dogreader/audio/$id'));
        req.headers.set('X-Dogreader-Token', token);
        final audio = await req.close().timeout(const Duration(seconds: 20));
        if (audio.statusCode != 200) { throw Exception('Preview download failed (${audio.statusCode})'); }
        final root = await getTemporaryDirectory();
        preview = File('${root.path}/preview_$id.mp3');
        final staged = File('${preview.path}.part');
        await audio.pipe(staged.openWrite());
        if (await staged.length() < 1000 ||
            (audio.contentLength >= 0 && await staged.length() != audio.contentLength)) {
          throw Exception('Preview download was incomplete');
        }
        await staged.rename(preview.path);
      } finally {
        client.close(force: true);
      }
      if (!mounted || sequence != previewSequence) { return; }
      await audioHandler.pause();
      final player = previewPlayer ??= ja.AudioPlayer();
      await player.setFilePath(preview.path);
      if (!mounted || sequence != previewSequence) { return; }
      setState(() => notice = 'Preview: ${recordingLabel(preference.toJson())}');
      await player.play();
    } catch (e) {
      if (mounted && sequence == previewSequence) { setState(() => notice = 'Voice preview: $e'); }
    } finally {
      if (mounted && sequence == previewSequence) { setState(() => previewing = false); }
    }
  }

  Future<void> regenerate(int index) async {
    if (busy) return;
    final preference = NarrationPreference(narrationEngine, narrator);
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Regenerate narration?'),
      content: Text('Generate ${widget.book.chapters[index].title} with ${recordingLabel(preference.toJson())}? '
          'The current download is replaced only after the new audio downloads successfully.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Generate narration')),
      ],
    ));
    if (confirmed != true || !mounted || busy) return;
    if (host.isEmpty || token.isEmpty) {
      setState(() => notice = 'Connect Dogreader Cloud first.');
      return;
    }
    setState(() {
      jobs[index] = {
        'previousRecording': jobs[index]?['previousRecording'] ?? jobs[index],
        'status': 'waiting', ...preference.toJson(),
      };
    });
    await save();
    await checkJobs();
  }

  Future<void> generate() async {
    if (busy || selected.isEmpty) return;
    if (host.isEmpty || token.isEmpty) {
      setState(() => notice = 'Set your Cloud Run URL and access token first.');
      return;
    }
    setState(() {
      busy = true;
      notice = null;
    });
    for (final index in selected.toList()..sort()) {
      jobs[index] = {'status': 'waiting', 'engine': narrationEngine, 'voice': narrator};
    }
    await save();
    if (mounted) {
      setState(() {
        selected.clear();
        busy = false;
      });
    }
    await checkJobs();
  }

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
      if (mounted) setState(() => notice = 'Recording recovered from cloud.');
    } catch (e) {
      if (mounted) setState(() => notice = 'Recovery failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> downloadAudio(int index, String id) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(endpoint('/dogreader/audio/$id'));
      req.headers.set('X-Dogreader-Token', token);
      final response = await req.close();
      if (response.statusCode != 200) {
        throw Exception('Download failed: ${response.statusCode}');
      }
      final root = await getApplicationDocumentsDirectory();
      final folder = Directory('${root.path}/narration');
      await folder.create(recursive: true);
      final target = File('${folder.path}/${widget.book.id}_$index.mp3');
      await replaceNarrationFile(target, response,
          contentLength: response.contentLength,
          beforeReplace: () => audioHandler.unloadChapter(widget.book.id, index));
      final stateFile = File('${root.path}/narration_state.json');
      Map<String, dynamic> data = {};
      if (await stateFile.exists()) {
        try {
          data = jsonDecode(
            await stateFile.readAsString(),
          ) as Map<String, dynamic>;
        } catch (_) {}
      }
      data['${widget.book.id}:$index'] = {'path': target.path, 'positionMs': 0,
        ...recordingMetadata(jobs[index] ?? {})};
      await stateFile.writeAsString(jsonEncode(data));
      jobs[index] = {...?jobs[index], 'status': 'ready', 'id': id};
      jobs[index]!.remove('previousRecording');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> checkJobs() async {
    if (busy || host.isEmpty || token.isEmpty || jobs.isEmpty) return;
    busy = true;
    try {
      for (final index in jobs.keys.toList()..sort()) {
        final status = jobs[index]?['status'];
        if (status == 'ready') {
          final root = await getApplicationDocumentsDirectory();
          final file = File(
            '${root.path}/narration/${widget.book.id}_$index.mp3',
          );
          if (await file.exists()) continue;
          final id = jobs[index]?['id'];
          if (id is String) {
            try {
              await downloadAudio(index, id);
            } catch (_) {
              notice = 'Recording needs downloading. Check your connection and refresh.';
            }
          }
          continue;
        }
        try {
          if (status == 'waiting') {
            final chapter = widget.book.chapters[index];
            final response = await requestJson('POST', '/dogreader/jobs', {
              'title': chapter.title,
              'text': chapter.text,
              'engine': jobs[index]?['engine'] ?? 'google',
              'voice': jobs[index]?['voice'] ?? 'en-US-Chirp3-HD-Achernar',
              ...{for (final key in ['model_version', 'settings'])
                if (jobs[index]?.containsKey(key) == true) key: jobs[index]![key]},
            });
            jobs[index] = {
              ...?jobs[index],
              ...recordingMetadata(response),
              'status': response['status'],
              'id': response['id'],
            };
          }
          final id = jobs[index]?['id'];
          if (id is! String) continue;
          Map<String, dynamic> result;
          try {
            result = await requestJson('GET', '/dogreader/jobs/$id');
          } catch (e) {
            // Re-submit if the cloud job record is missing; the server caches completed audio.
            if (!e.toString().contains('Unknown job') && !e.toString().contains('Job not found')) {
              rethrow;
            }
            final chapter = widget.book.chapters[index];
            final submitted = await requestJson('POST', '/dogreader/jobs', {
              'title': chapter.title,
              'text': chapter.text,
              'engine': jobs[index]?['engine'] ?? 'google',
              'voice': jobs[index]?['voice'] ?? 'en-US-Chirp3-HD-Achernar',
              ...{for (final key in ['model_version', 'settings'])
                if (jobs[index]?.containsKey(key) == true) key: jobs[index]![key]},
            });
            jobs[index] = {
              ...?jobs[index],
              ...recordingMetadata(submitted),
              'status': submitted['status'],
              'id': submitted['id'],
            };
            result = await requestJson(
              'GET',
              '/dogreader/jobs/${submitted['id']}',
            );
          }
          final nextStatus = result['status'] as String? ?? 'waiting';
          final currentId = jobs[index]?['id'] as String? ?? id;
          jobs[index] = {
            ...?jobs[index],
            ...recordingMetadata(result),
            'status': nextStatus,
            'id': currentId,
            'error': result['error'],
          };
          if (nextStatus == 'ready') await downloadAudio(index, currentId);
          if (nextStatus == 'error') {
            notice =
                '${widget.book.chapters[index].title}: ${result['error'] ?? 'Narration failed. Retry to resume saved chunks.'}';
          }
        } catch (e) {
          // Preserve pending work for a later retry.
          if (jobs[index]?['id'] == null) {
            jobs[index] = {...?jobs[index], 'status': 'waiting'};
          }
          // A temporary socket failure should not masquerade as a failed job.
          // Keep the job queued and retry on the next refresh.
          if (e is SocketException ||
              e is TimeoutException ||
              e.toString().contains('SocketException')) {
            notice =
                'Connection temporarily unavailable. Will retry automatically.';
          } else {
            notice = 'Cloud request failed: $e';
          }
        }
      }
      await save();
    } finally {
      busy = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 12), (_) => checkJobs());
  }

  @override
  void dispose() {
    timer?.cancel();
    previewSequence++;
    previewPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Generate narration'),
        actions: [
          IconButton(
            tooltip: 'Cloud settings',
            onPressed: configure,
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: 'Check connection and jobs',
            onPressed: checkJobs,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  host.isEmpty ? 'Cloud not configured' : 'Cloud: $host',
                  style: const TextStyle(fontSize: 12),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: configure,
                      child: const Text('Settings'),
                    ),
                    TextButton(
                      onPressed: checkConnection,
                      child: const Text('Check connection'),
                    ),
                  ],
                ),
                if (notice != null) Text(notice!, textAlign: TextAlign.center),
              ],
            ),
          ),
          NarrationControls(
            preference: NarrationPreference(narrationEngine, narrator),
            onChanged: (value) {
              setState(() { narrationEngine = value.engine; narrator = value.voice; });
              save();
            },
            previewing: previewing,
            onPreview: previewing ? stopPreview : previewVoice,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: selectEntireBook,
                  icon: const Icon(Icons.select_all),
                  label: const Text('Entire book'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() => selected.clear()),
                  child: const Text('Clear selection'),
                ),
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
          Expanded(
            child: ListView.builder(
              itemCount: widget.book.chapters.length,
              itemBuilder: (context, index) {
                final chapter = widget.book.chapters[index];
                final status = jobs[index]?['status'] as String?;
                final voiceLabel = jobs[index] == null ? null : recordingLabel(jobs[index]);
                return Column(children: [CheckboxListTile(
                  secondary: status == 'ready' || jobs[index]?['previousRecording'] is Map
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: status == 'ready' ? 'Play downloaded chapter' : 'Play previous recording',
                              icon: Icon(Icons.play_circle_fill, color: Theme.of(context).colorScheme.primary, size: 32),
                              onPressed: () => playChapter(index),
                            ),
                            if (jobs[index]?['id'] is String)
                              IconButton(
                                tooltip: 'Repair audio from cloud',
                                icon: const Icon(Icons.cloud_download_outlined),
                                onPressed: busy ? null : () => repairChapterAudio(index),
                              ),
                            IconButton(
                              tooltip: 'Delete chapter audio',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: busy ? null : () => deleteChapterAudio(index),
                            ),
                          ],
                        )
                      : null,
                  value: selected.contains(index),
                  title: Text(chapter.title),
                  subtitle: Text(
                    (status == null
                            ? 'Not generated'
                            : status == 'ready'
                            ? 'Ready to listen'
                            : status == 'waiting'
                            ? 'Waiting to submit'
                            : status == 'generating'
                            ? 'Generating…'
                            : status == 'queued'
                            ? 'Queued in cloud'
                            : status == 'error'
                            ? ((jobs[index]?['error'] as String?) ?? 'Narration failed. Retry to resume.')
                            : status) +
                        (voiceLabel == null ? '' : ' • $voiceLabel'),
                  ),
                  onChanged:
                      status == 'ready' ||
                          status == 'queued' ||
                          status == 'generating' ||
                          status == 'waiting'
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            selected.add(index);
                          } else {
                            selected.remove(index);
                          }
                        }),
                ),
                  if (status == 'ready' || status == 'error')
                    Align(alignment: Alignment.centerRight, child: TextButton(
                      onPressed: busy ? null : () => regenerate(index),
                      child: const Text('Regenerate narration'),
                    )),
                ]);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: selected.isEmpty || busy ? null : generate,
              icon: const Icon(Icons.record_voice_over),
              label: Text(
                'Generate narration (${selected.length})',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ReadingScreen extends StatefulWidget {
  final ImportedBook book;
  final int chapterIndex;
  final int initialOffset;
  final SavePosition onSave;
  const ReadingScreen({
    super.key,
    required this.book,
    required this.chapterIndex,
    required this.initialOffset,
    required this.onSave,
  });

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
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
    chapterIndex = widget.chapterIndex;
    currentOffset = widget.initialOffset;
    widget.onSave(chapterIndex, currentOffset);
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
      saveCurrent();
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

  void saveCurrent() {
    widget.onSave(chapterIndex, currentOffset);
  }

  void changeChapter(int next) {
    if (next < 0 || next >= widget.book.chapters.length) return;
    if (next > chapterIndex) {
      widget.onSave(chapterIndex, widget.book.chapters[chapterIndex].text.length);
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
      changeChapter(chapterIndex + 1);
    } else if (target < 0 && chapterIndex > 0) {
      changeChapter(chapterIndex - 1);
    }
  }

  @override
  void dispose() {
    ++_paginationGeneration;
    saveCurrent();
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.book.chapters[chapterIndex];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          chapter.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Listen from this page',
            onPressed: _paginating || pages.isEmpty ? null : () {
              if (_paginating || pages.isEmpty) return;
              // Capture the visible page's start offset, not a stale saved
              // offset from before a page turn or a pagination change.
              if (pages.isNotEmpty && currentPage >= 0 && currentPage < pages.length) {
                currentOffset = starts[currentPage];
              }
              saveCurrent();
              final textLength = widget.book.chapters[chapterIndex].text.length;
              final fraction = textLength == 0
                  ? 0.0
                  : (currentOffset / textLength).clamp(0.0, 1.0);
              final audioChapter = chapterIndex;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChapterNarrationScreen(
                    book: widget.book,
                    chapterIndex: audioChapter,
                    initialTextFraction: fraction,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.headphones),
          ),
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
          const footerHeight = 38.0;
          final width = math.max(
            100.0,
            constraints.maxWidth - horizontalPadding * 2,
          );
          final height = math.max(
            100.0,
            constraints.maxHeight - verticalPadding * 2 - footerHeight,
          );
          calculatePages(width, height);
          if (_paginating || pages.isEmpty || controller == null) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
          return Column(
            children: [
              Expanded(
                child: PageView.builder(
                  key: ValueKey('reading-chapter-$chapterIndex'),
                  controller: controller,
                  itemCount: pages.length,
                  onPageChanged: (index) {
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
                child: InkWell(
                  onTap: showPageJump,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.tune, size: 15, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${currentPage + 1} / ${pages.length}  •  Tap to jump',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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
  // Present only when arriving from the reader; normal player navigation
  // continues to restore the last saved audio position.
  final double? initialTextFraction;
  const ChapterNarrationScreen({
    super.key,
    required this.book,
    required this.chapterIndex,
    this.initialTextFraction,
  });

  @override
  State<ChapterNarrationScreen> createState() => _ChapterNarrationScreenState();
}

class _ChapterNarrationScreenState extends State<ChapterNarrationScreen> {
  final player = audioHandler.player;
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

  String get chapterKey => '${widget.book.id}:${widget.chapterIndex}';

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
    try {
      final file = await stateFile;
      final data = await readState();
      final existing = data[chapterKey];
      final chapterData = existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      chapterData.addAll(values);
      data[chapterKey] = chapterData;
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();

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

    restore();
  }

  Future<void> restore() async {
    final generation = ++_restoreGeneration;
    bool active() => mounted && generation == _restoreGeneration &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    try {
      final data = await readState();
      final entry = data[chapterKey];
      final root = await getApplicationDocumentsDirectory();
      final localFile = File(
        '${root.path}/narration/${widget.book.id}_${widget.chapterIndex}.mp3',
      );

      String? path;
      int savedPosition = 0;

      if (entry is Map) {
        final storedPath = entry['path'];
        if (storedPath is String && await File(storedPath).exists()) {
          path = storedPath;
          savedPosition = (entry['positionMs'] as num?)?.toInt() ?? 0;
        }
      }

      if (path == null && await localFile.exists()) {
        path = localFile.path;
        if (!active()) return;
        await updateState({'path': path, 'positionMs': 0});
      }

      if (!active()) return;
      if (path != null) {
        audioPath = path;
        Future<void> load() => audioHandler.loadChapter(
          path: path!,
          title: widget.book.chapters[widget.chapterIndex].title,
          author: widget.book.author,
          bookId: widget.book.id,
          chapterIndex: widget.chapterIndex,
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
            fraction: widget.initialTextFraction!, load: prepare,
            pause: audioHandler.pause, seek: audioHandler.seek,
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
      }
    } catch (e) {
      if (active()) error = 'Could not load recording: $e';
    } finally {
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
        '${folder.path}/${widget.book.id}_${widget.chapterIndex}.mp3',
      );
      if (!mounted) return;
      await audioHandler.unloadChapter(widget.book.id, widget.chapterIndex);
      if (!mounted) return;
      await File(picked.path!).copy(target.path);
      if (mounted) setState(() => duration = Duration.zero);
      await audioHandler.loadChapter(
        path: target.path,
        title: widget.book.chapters[widget.chapterIndex].title,
        author: widget.book.author,
        bookId: widget.book.id,
        chapterIndex: widget.chapterIndex,
        chapterCount: widget.book.chapters.length,
        forceReload: true,
        isCurrent: () => mounted,
      );
      if (!mounted) return;
      await refreshDuration();
      if (!mounted || audioHandler.mediaItem.value?.id != chapterKey) return;
      await audioHandler.seek(Duration.zero);
      await updateState({'path': target.path, 'positionMs': 0});
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
        await audioHandler.pause();
      } else if (audioPath != null) {
        await audioHandler.play();
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
    await audioHandler.seek(target);
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
                Icon(Icons.headphones, size: 62, color: Theme.of(context).colorScheme.primary),
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
                  widget.book.chapters[widget.chapterIndex].title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (loading) const CircularProgressIndicator(),
                if (!loading && !hasAudio)
                  const Text(
                    'No narration imported for this chapter yet.',
                    textAlign: TextAlign.center,
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
    appBar: AppBar(title: const Text('Audio diagnostics')),
    body: ValueListenableBuilder<List<String>>(
      valueListenable: audioHandler.diagnosticCommands,
      builder: (context, commands, _) => StreamBuilder<ja.PlayerState>(
        stream: audioHandler.player.playerStateStream,
        builder: (context, snapshot) {
          final player = audioHandler.player;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Build 132 • audio command diagnostics',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text('Before testing, note the command count. Open the notification '
                    'or lock screen and press Pause or Play once. Return here without '
                    'using the in-app playback buttons. Did the count increase?'),
                const SizedBox(height: 16),
                Text('Commands received: ${audioHandler.diagnosticCommandCount}'),
                Text('Playing: ${player.playing}'),
                Text('Player state: ${player.processingState.name}'),
                Text('Session playing: ${audioHandler.playbackState.value.playing}'),
                Text('Session state: ${audioHandler.playbackState.value.processingState.name}'),
                const SizedBox(height: 16),
                const Text('Both in-app and external commands appear below. '
                    'The count resets when the audio handler restarts. '
                    'Take a screenshot before restarting the phone. '
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
