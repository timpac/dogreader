import 'dart:io';

import 'package:epubx/epubx.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;

void main() => runApp(const AudiobookApp());

const background = Color(0xFF10131A);
const panel = Color(0xFF202638);
const accent = Color(0xFFB7A6F6);

class AudiobookApp extends StatelessWidget {
  const AudiobookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'The Listening Room',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
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

class ReaderChapter {
  final String title;
  final String text;
  const ReaderChapter(this.title, this.text);
}

class ImportedBook {
  final String title;
  final String author;
  final List<ReaderChapter> chapters;
  const ImportedBook(this.title, this.author, this.chapters);
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

  void showUpcoming(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is coming in a future version.')),
    );
  }

  void collectChapters(List<EpubChapter> source, List<ReaderChapter> output) {
    for (final chapter in source) {
      final rawHtml = chapter.HtmlContent ?? '';
      final document = html_parser.parse(rawHtml);
      // Remove non-reading material that would otherwise appear as text.
      for (final element in document.querySelectorAll('script, style')) {
        element.remove();
      }
      final text = document.body?.text.trim() ?? '';
      if (text.isNotEmpty) {
        final title = (chapter.Title ?? '').trim();
        output.add(ReaderChapter(
          title.isEmpty ? 'Section ${output.length + 1}' : title,
          text,
        ));
      }
      collectChapters(chapter.SubChapters ?? [], output);
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
      collectChapters(epub.Chapters ?? [], chapters);

      if (chapters.isEmpty) {
        throw Exception('No readable chapters were found in this EPUB.');
      }

      final title = (epub.Title ?? '').trim();
      final author = (epub.Author ?? '').trim();
      final imported = ImportedBook(
        title.isEmpty ? file.name : title,
        author.isEmpty ? 'Unknown author' : author,
        chapters,
      );
      if (!mounted) return;
      setState(() => books.add(imported));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported ${imported.title}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import EPUB: $error')),
      );
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _libraryPage(),
      _placeholderPage(Icons.queue_music_rounded, 'Narration queue',
          'Generated chapters will appear here.'),
      _placeholderPage(Icons.tune_rounded, 'Settings',
          'Choose narration providers, voices, and API keys.'),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: background,
        title: const Row(
          children: [
            Icon(Icons.auto_stories_rounded, color: accent),
            SizedBox(width: 12),
            Text('The Listening Room',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 19)),
          ],
        ),
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
              label: 'Library'),
          NavigationDestination(
              icon: Icon(Icons.queue_music_outlined),
              selectedIcon: Icon(Icons.queue_music),
              label: 'Queue'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }

  Widget _libraryPage() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 22),
      children: [
        const Text('Your library',
            style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Great books. Your choice of voice.',
            style: TextStyle(fontSize: 15, color: Colors.white.withValues(alpha: 0.65))),
        const SizedBox(height: 26),
        if (books.isEmpty) _emptyLibrary(),
        for (final book in books)
          Card(
            color: panel,
            margin: const EdgeInsets.only(bottom: 14),
            child: ListTile(
              contentPadding: const EdgeInsets.all(15),
              leading: const Icon(Icons.menu_book_rounded, color: accent, size: 36),
              title: Text(book.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${book.author}\n${book.chapters.length} sections'),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ChapterListScreen(book: book)),
              ),
            ),
          ),
        if (books.isNotEmpty) const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: importing ? null : importBook,
          icon: importing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_rounded),
          label: Text(importing ? 'Importing…' : 'Import a book'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: accent,
            foregroundColor: const Color(0xFF171321),
          ),
        ),
        const SizedBox(height: 25),
        const Text('Built for reading and listening your way',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        const _FeatureRow(Icons.record_voice_over_rounded, 'Choose your narrator',
            'Bring your preferred AI voice service.'),
        const SizedBox(height: 12),
        const _FeatureRow(Icons.offline_bolt_rounded, 'Listen offline',
            'Keep generated audio on your device.'),
        const SizedBox(height: 12),
        const _FeatureRow(Icons.bookmark_added_outlined, 'Pick up where you left off',
            'Reading progress is coming next.'),
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
          const Text('A new chapter begins',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(
            'Import an EPUB, browse its chapters, and start reading.',
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.5, color: Colors.white.withValues(alpha: 0.72)),
          ),
        ],
      ),
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
            Text(title, style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.65))),
          ],
        ),
      ),
    );
  }
}

class ChapterListScreen extends StatelessWidget {
  final ImportedBook book;
  const ChapterListScreen({super.key, required this.book});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(book.title)),
      body: ListView.builder(
        padding: const EdgeInsets.all(14),
        itemCount: book.chapters.length,
        itemBuilder: (context, index) {
          final chapter = book.chapters[index];
          return ListTile(
            leading: const Icon(Icons.auto_stories_outlined, color: accent),
            title: Text(chapter.title),
            subtitle: Text('${chapter.text.length} characters'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ReadingScreen(chapter: chapter),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ReadingScreen extends StatefulWidget {
  final ReaderChapter chapter;
  const ReadingScreen({super.key, required this.chapter});

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  double fontSize = 19;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Decrease text size',
            onPressed: () => setState(() => fontSize = (fontSize - 2).clamp(14.0, 32.0)),
            icon: const Icon(Icons.text_decrease),
          ),
          IconButton(
            tooltip: 'Increase text size',
            onPressed: () => setState(() => fontSize = (fontSize + 2).clamp(14.0, 32.0)),
            icon: const Icon(Icons.text_increase),
          ),
        ],
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          children: [
            Text(widget.chapter.title,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 24),
            Text(widget.chapter.text,
                style: TextStyle(fontSize: fontSize, height: 1.65)),
          ],
        ),
      ),
    );
  }
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
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 4),
              Text(subtitle,
                  style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.6))),
            ],
          ),
        ),
      ],
    );
  }
}
