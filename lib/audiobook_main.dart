import 'package:flutter/material.dart';

void main() => runApp(const AudiobookApp());

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
        scaffoldBackgroundColor: const Color(0xFF10131A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB7A6F6),
          brightness: Brightness.dark,
          surface: const Color(0xFF1A1F2A),
        ),
      ),
      home: const LibraryScreen(),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int selectedTab = 0;

  void showUpcoming(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is coming in the next version.')),
    );
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
        backgroundColor: const Color(0xFF10131A),
        title: const Row(
          children: [
            Icon(Icons.auto_stories_rounded, color: Color(0xFFB7A6F6)),
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
        const SizedBox(height: 30),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF202638),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF353D54)),
          ),
          child: Column(
            children: [
              const Icon(Icons.menu_book_rounded,
                  size: 62, color: Color(0xFFB7A6F6)),
              const SizedBox(height: 20),
              const Text('A new chapter begins',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                'Import an EPUB and turn the chapters you choose into an audiobook.',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.5, color: Colors.white.withValues(alpha: 0.72)),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => showUpcoming('EPUB import'),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Import a book'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: const Color(0xFFB7A6F6),
                  foregroundColor: const Color(0xFF171321),
                ),
              ),
              const SizedBox(height: 10),
              Text('EPUB import is the next feature we will build.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5))),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const Text('Built for listening your way',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        const _FeatureRow(Icons.record_voice_over_rounded, 'Choose your narrator',
            'Bring your preferred AI voice service.'),
        const SizedBox(height: 12),
        const _FeatureRow(Icons.offline_bolt_rounded, 'Listen offline',
            'Keep generated audio on your device.'),
        const SizedBox(height: 12),
        const _FeatureRow(Icons.bookmark_added_outlined, 'Pick up where you left off',
            'Resume your books and chapters.'),
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
            Icon(icon, size: 64, color: const Color(0xFFB7A6F6)),
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
            color: const Color(0xFF202638),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: const Color(0xFFB7A6F6)),
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
