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
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_service/audio_service.dart';

import 'dogreader_audio_handler.dart';

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

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

  runApp(const AudiobookApp());
}

const background = Color(0xFF10131A);
const panel = Color(0xFF202638);
const accent = Color(0xFFB7A6F6);
// Set by GitHub Actions at build time; visible on the library home screen.
const dogreaderBuild = String.fromEnvironment('DOGREADER_BUILD', defaultValue: 'DEV');

class AudiobookApp extends StatelessWidget {
  const AudiobookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dogreader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        textTheme: GoogleFonts.urbanistTextTheme(
          ThemeData(brightness: Brightness.dark).textTheme,
        ),
        primaryTextTheme: GoogleFonts.urbanistTextTheme(
          ThemeData(brightness: Brightness.dark).primaryTextTheme,
        ),
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
          surface: const Color(0xFF1A1F2A),
        ),
      ),
      home: const LibraryScreen(),
    );
  }
}

class StyledRange {
  final int start, end;
  final bool italic, bold, heading;
  const StyledRange(
    this.start,
    this.end, {
    this.italic = false,
    this.bold = false,
    this.heading = false,
  });
}

class ReaderChapter {
  final String title;
  final String text;
  final List<StyledRange> ranges;
  const ReaderChapter(this.title, this.text, this.ranges);
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
  const LibraryScreen({super.key});

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

  // Preserve semantic and publisher-styled scene spacing without adding
  // artificial ornaments. Offsets still match the paginated text.
  ReaderChapter parseChapter(String title, String rawHtml) {
    final document = html_parser.parse(rawHtml);
    // Resolve common embedded CSS scene-break selectors before stripping styles.
    final sceneClasses = <String>{};
    final cssRule = RegExp(r'([^{}]+)\{([^{}]+)\}', multiLine: true);
    final cssClass = RegExp(r'\.([a-zA-Z_][\w-]*)');
    final sceneSpace = RegExp(
      r'(?:break|separator|spacer|space|scene|section|thought|asterism|dinkus)',
      caseSensitive: false,
    );
    for (final style in document.querySelectorAll('style')) {
      for (final rule in cssRule.allMatches(style.text)) {
        final declarations = rule.group(2)!.toLowerCase();
        final isSpaced = RegExp(
          r'(?:margin-(?:top|bottom)|padding-(?:top|bottom)|height)\s*:\s*(?!0(?:px|em|rem|pt)?\s*(?:;|$))[1-9]',
        ).hasMatch(declarations);
        if (isSpaced || sceneSpace.hasMatch(rule.group(1)!)) {
          for (final match in cssClass.allMatches(rule.group(1)!)) {
            sceneClasses.add(match.group(1)!.toLowerCase());
          }
        }
      }
    }
    for (final element in document.querySelectorAll('script, style, nav')) {
      element.remove();
    }
    final output = StringBuffer();
    final ranges = <StyledRange>[];
    final blocks = <_TextBlock>[];
    final pending = StringBuffer();
    final pendingRanges = <StyledRange>[];

    void flush({bool heading = false, bool scene = false}) {
      final raw = pending.toString();
      pending.clear();
      final leading = raw.length - raw.trimLeft().length;
      final clean = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.isEmpty && !scene) {
        pendingRanges.clear();
        return;
      }
      // A blank line represents a break without inventing a printed symbol.
      final text = scene ? '' : clean;
      final indent =
          blocks.isNotEmpty &&
              !heading &&
              !scene &&
              blocks.last.heading == false &&
              blocks.last.scene == false
          ? '　'
          : '';
      final prefix = blocks.isEmpty ? '' : (scene ? '\n\n\n' : heading ? '\n\n' : '\n');
      final base = output.length + prefix.length + indent.length;
      output.write(prefix);
      output.write(indent);
      output.write(text);
      for (final range in pendingRanges) {
        final a = (range.start - leading).clamp(0, clean.length);
        final b = (range.end - leading).clamp(0, clean.length);
        if (b > a)
          ranges.add(
            StyledRange(
              base + a,
              base + b,
              italic: range.italic,
              bold: range.bold,
            ),
          );
      }
      pendingRanges.clear();
      if (heading)
        ranges.add(StyledRange(base, base + text.length, heading: true));
      blocks.add(_TextBlock(heading, scene));
    }

    void walk(
      dom.Node node, {
      bool italic = false,
      bool bold = false,
      bool heading = false,
    }) {
      if (node is dom.Text) {
        final start = pending.length;
        pending.write(node.text);
        if ((italic || bold) && pending.length > start) {
          pendingRanges.add(
            StyledRange(start, pending.length, italic: italic, bold: bold),
          );
        }
        return;
      }
      if (node is! dom.Element) return;
      final tag = node.localName ?? '';
      if (tag == 'br') {
        flush(heading: heading);
        return;
      }
      if (tag == 'hr') {
        flush();
        flush(scene: true);
        return;
      }
      // EPUBs often encode scene changes as empty, styled separators.
      // Recognize semantic markers without inserting ornaments for
      // ordinary paragraphs that merely have decorative CSS classes.
      final marker = [
        node.attributes['class'] ?? '',
        node.attributes['epub:type'] ?? '',
        node.attributes['role'] ?? '',
      ].join(' ').toLowerCase();
      final sceneMarker = RegExp(
        r'(?:^|[\s_-])(?:scene[\s_-]*break|section[\s_-]*break|thought[\s_-]*break|asterism|separator|ornament|dinkus)(?:$|[\s_-])',
      ).hasMatch(marker);
      final classes = (node.attributes['class'] ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'));
      final inlineStyle = (node.attributes['style'] ?? '').toLowerCase();
      final styledBreak = classes.any(sceneClasses.contains) ||
          (sceneSpace.hasMatch(marker) && marker.isNotEmpty) ||
          RegExp(r'(?:margin-(?:top|bottom)|padding-(?:top|bottom)|height)\s*:\s*[1-9]').hasMatch(inlineStyle);
      if ((sceneMarker || styledBreak) && node.text.trim().isEmpty) {
        flush();
        flush(scene: true);
        return;
      }
      final isHeading =
          heading || {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag);
      final isBlock = {
        'p',
        'div',
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'li',
        'blockquote',
        'pre',
        'tr',
      }.contains(tag);
      if (isBlock && pending.isNotEmpty) flush();
      for (final child in node.nodes) {
        walk(
          child,
          italic: italic || tag == 'i' || tag == 'em',
          bold: bold || tag == 'b' || tag == 'strong',
          heading: isHeading,
        );
      }
      if (isBlock) flush(heading: isHeading);
    }

    if (document.body != null) walk(document.body!);
    flush();
    return ReaderChapter(title, output.toString(), ranges);
  }

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

  void collectChapters(List<EpubChapter> source, List<ReaderChapter> output) {
    for (final chapter in source) {
      final title = (chapter.Title ?? '').trim();
      final parsed = parseChapter(
        title.isEmpty ? 'Section ${output.length + 1}' : title,
        chapter.HtmlContent ?? '',
      );
      if (parsed.text.isNotEmpty) output.add(parsed);
      collectChapters(chapter.SubChapters ?? [], output);
    }
  }

  void loadBookChapters(EpubBook epub, List<ReaderChapter> output) {
    collectChapters(epub.Chapters ?? [], output);
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

      final parsed = parseChapter('Section ${output.length + 1}', rawHtml);

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
      _placeholderPage(
        Icons.tune_rounded,
        'Settings',
        'Choose narration providers, voices, and API keys.',
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: background,
        title: const Row(
          children: [
            Icon(Icons.auto_stories_rounded, color: accent),
            SizedBox(width: 12),
            Text(
              'Dogreader',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 19),
            ),
          ],
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                'BUILD $dogreaderBuild',
                style: const TextStyle(
                  color: accent,
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
        backgroundColor: const Color(0xFF1A1F2A),
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

  Widget _libraryPage() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 22),
      children: [
        const Text(
          'Your library',
          style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          "I'm not surprised you're reading that, because you're stupid.",
          style: TextStyle(
            fontSize: 15,
            color: Colors.white.withValues(alpha: 0.65),
          ),
        ),
        const SizedBox(height: 26),
        if (books.isEmpty) _emptyLibrary(),
        for (final book in books)
          Card(
            color: panel,
            margin: const EdgeInsets.only(bottom: 14),
            child: ListTile(
              contentPadding: const EdgeInsets.all(15),
              leading: SizedBox(
                width: 54,
                height: 76,
                child: book.cover == null
                    ? const Icon(
                        Icons.menu_book_rounded,
                        color: accent,
                        size: 36,
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: Image.memory(
                          book.cover!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(
                                Icons.menu_book_rounded,
                                color: accent,
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
                icon: const Icon(Icons.list_rounded, color: accent),
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
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: accent,
            foregroundColor: const Color(0xFF171321),
          ),
        ),

      ],
    );
  }

  Widget _emptyLibrary() {
    return Container(
      padding: const EdgeInsets.all(24),
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF353D54)),
      ),
      child: Column(
        children: [
          const Icon(Icons.menu_book_rounded, size: 62, color: accent),
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
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ],
      ),
    );
  }

  Widget _narrationLibraryPage() {
    if (books.isEmpty)
      return _placeholderPage(
        Icons.queue_music_rounded,
        'Narration',
        'Import a book to generate or listen to narration.',
      );
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
            leading: const Icon(Icons.headphones, color: accent),
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
            Icon(icon, size: 64, color: accent),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
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
              label: const Text('Listen / Generate audiobook'),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(14),
              itemCount: book.chapters.length + (saved == null ? 0 : 1),
              itemBuilder: (context, row) {
                if (saved != null && row == 0) {
                  return Card(
                    color: panel,
                    child: ListTile(
                      leading: const Icon(Icons.bookmark, color: accent),
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
                  leading: const Icon(
                    Icons.auto_stories_outlined,
                    color: accent,
                  ),
                  title: Text(chapter.title),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                      color: accent,
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
  static const narratorNames = <String, String>{
    'en-US-Chirp3-HD-Achernar': 'Achernar',
    'en-US-Chirp3-HD-Charon': 'Charon',
    'en-US-Chirp3-HD-Kore': 'Kore',
    'en-US-Chirp3-HD-Puck': 'Puck',
    'en-GB-Wavenet-B': 'Oliver (Cheap)',
  };
  String narrator = 'en-US-Chirp3-HD-Achernar';
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
        final savedNarrator = data['narrator'];
        if (savedNarrator is String &&
            narratorNames.containsKey(savedNarrator)) {
          narrator = savedNarrator;
        }
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
      if (await file.exists() && await file.length() > 1000) {
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
      if (response.statusCode >= 400)
        throw Exception(result['error'] ?? 'HTTP ${response.statusCode}');
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
        if (mounted)
          setState(() => notice = 'Enter a valid HTTPS Cloud Run URL.');
        hostController.dispose();
        tokenController.dispose();
        return;
      }
      host = candidate;
      token = tokenController.text.trim();
      await save();
      if (mounted)
        setState(() => notice = 'Settings saved. Tap Check connection.');
    }
    hostController.dispose();
    tokenController.dispose();
  }

  Future<void> checkConnection() async {
    try {
      final data = await requestJson('GET', '/dogreader/ping');
      if (mounted)
        setState(() => notice = 'Connected! Voice: ${data['voice']}');
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

  Future<void> playChapter(int index) async {
    final root = await getApplicationDocumentsDirectory();
    final file = File('${root.path}/narration/${widget.book.id}_$index.mp3');
    if (!await file.exists()) {
      if (mounted)
        setState(
          () =>
              notice = 'Recording not found locally. Try refreshing the queue.',
        );
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
      jobs[index] = {'status': 'waiting', 'voice': narrator};
    }
    await save();
    if (mounted)
      setState(() {
        selected.clear();
        busy = false;
      });
    await checkJobs();
  }

  Future<void> downloadAudio(int index, String id) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(endpoint('/dogreader/audio/$id'));
      req.headers.set('X-Dogreader-Token', token);
      final response = await req.close();
      if (response.statusCode != 200)
        throw Exception('Download failed: ${response.statusCode}');
      final root = await getApplicationDocumentsDirectory();
      final folder = Directory('${root.path}/narration');
      await folder.create(recursive: true);
      final target = File('${folder.path}/${widget.book.id}_$index.mp3');
      final temp = File('${target.path}.part');
      final sink = temp.openWrite();
      await response.pipe(sink);
      if (await temp.length() < 1000) throw Exception('Audio file was empty');
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      final stateFile = File('${root.path}/narration_state.json');
      Map<String, dynamic> data = {};
      if (await stateFile.exists()) {
        try {
          data = jsonDecode(
            await stateFile.readAsString(),
          ) as Map<String, dynamic>;
        } catch (_) {}
      }
      data['${widget.book.id}:$index'] = {'path': target.path, 'positionMs': 0};
      await stateFile.writeAsString(jsonEncode(data));
      jobs[index] = {'status': 'ready', 'id': id};
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
              'voice': jobs[index]?['voice'] ?? 'en-US-Chirp3-HD-Achernar',
            });
            jobs[index] = {
              ...?jobs[index],
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
            if (!e.toString().contains('Unknown job')) rethrow;
            final chapter = widget.book.chapters[index];
            final submitted = await requestJson('POST', '/dogreader/jobs', {
              'title': chapter.title,
              'text': chapter.text,
              'voice': jobs[index]?['voice'] ?? 'en-US-Chirp3-HD-Achernar',
            });
            jobs[index] = {
              ...?jobs[index],
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
            'status': nextStatus,
            'id': currentId,
            'error': result['error'],
          };
          if (nextStatus == 'ready') await downloadAudio(index, currentId);
          if (nextStatus == 'error')
            notice =
                'Cloud narration failed for ${widget.book.chapters[index].title}. Check Cloud Run logs.';
        } catch (e) {
          // Preserve pending work for a later retry.
          if (jobs[index]?['id'] == null) jobs[index] = {'status': 'waiting'};
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DropdownButtonFormField<String>(
              value: narrator,
              decoration: const InputDecoration(
                labelText: 'Narrator',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.record_voice_over),
              ),
              items: narratorNames.entries
                  .map(
                    (entry) => DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => narrator = value);
                save();
              },
            ),
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
                final voice = jobs[index]?['voice'] as String?;
                final voiceLabel = voice == null
                    ? null
                    : narratorNames[voice] ?? voice;
                return CheckboxListTile(
                  secondary: status == 'ready'
                      ? IconButton(
                          tooltip: 'Play downloaded chapter',
                          icon: const Icon(
                            Icons.play_circle_fill,
                            color: accent,
                            size: 32,
                          ),
                          onPressed: () => playChapter(index),
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
                            ? 'Cloud job failed — check server logs'
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
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: selected.isEmpty || busy ? null : generate,
              icon: const Icon(Icons.record_voice_over),
              label: Text(
                'Generate ${selected.length} chapter${selected.length == 1 ? '' : 's'}',
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
      style: TextStyle(fontSize: fontSize, height: 1.55, color: Colors.white),
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
            fontSize != targetFont) return;
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
          chapterIndex != targetChapter || fontSize != targetFont) return;
      final nextPage = math.max(
        0,
        nextStarts.lastIndexWhere((value) => value <= currentOffset),
      );
      final oldController = controller;
      setState(() {
        pages = nextPages;
        starts = nextStarts;
        currentPage = nextPage;
        controller = PageController(initialPage: currentPage, keepPage: false);
        _paginating = false;
      });
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
            onPressed: () {
              saveCurrent();
              final textLength = widget.book.chapters[chapterIndex].text.length;
              final fraction = textLength == 0
                  ? 0.0
                  : (currentOffset / textLength).clamp(0.0, 1.0);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChapterNarrationScreen(
                    book: widget.book,
                    chapterIndex: chapterIndex,
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
                        const Icon(Icons.tune, size: 15, color: accent),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${currentPage + 1} / ${pages.length}  •  Tap to jump',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.75),
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
        await updateState({'path': path, 'positionMs': 0});
      }

      if (path != null) {
        audioPath = path;
        await audioHandler.loadChapter(
          path: path,
          title: widget.book.chapters[widget.chapterIndex].title,
          author: widget.book.author,
          bookId: widget.book.id,
          chapterIndex: widget.chapterIndex,
          chapterCount: widget.book.chapters.length,
          startPosition: Duration(milliseconds: savedPosition),
        );
        if (widget.initialTextFraction != null) {
          // Pause before waiting for metadata so the player never starts
          // unexpectedly while switching from reading to listening.
          await audioHandler.pause();
        }
        await refreshDuration();
        if (widget.initialTextFraction != null) {
          // Seek even when this same chapter was already loaded in the
          // background: loadChapter intentionally returns early in that case.
          final total = player.duration ?? duration;
          if (total.inMilliseconds > 0) {
            final fraction = widget.initialTextFraction!.clamp(0.0, 1.0);
            final target = Duration(
              milliseconds: (total.inMilliseconds * fraction).round(),
            );
            await audioHandler.seek(target);
          } else {
            error = 'Audio duration is unavailable; could not jump to your reading position.';
          }
        }
        position = player.position;
      }
    } catch (e) {
      error = 'Could not load recording: $e';
    } finally {
      if (mounted) setState(() => loading = false);
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
      await player.stop();
      await File(picked.path!).copy(target.path);
      if (mounted) setState(() => duration = Duration.zero);
      await audioHandler.loadChapter(
        path: target.path,
        title: widget.book.chapters[widget.chapterIndex].title,
        author: widget.book.author,
        bookId: widget.book.id,
        chapterIndex: widget.chapterIndex,
        chapterCount: widget.book.chapters.length,
      );
      await refreshDuration();
      await player.seek(Duration.zero);
      await updateState({'path': target.path, 'positionMs': 0});
      if (mounted)
        setState(() {
          audioPath = target.path;
          position = Duration.zero;
        });
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
    if (audioPath == null) return;
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
      appBar: AppBar(title: const Text('Chapter narration')),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.headphones, size: 62, color: accent),
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
                    onChanged: duration.inMilliseconds <= 0
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
                        onPressed: togglePlayback,
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
                    onPressed: changeSpeed,
                    child: Text('${speed}× speed'),
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
                      style: const TextStyle(color: Colors.orangeAccent),
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

class _TextBlock {
  final bool heading, scene;
  const _TextBlock(this.heading, this.scene);
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _FeatureRow(this.icon, this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
