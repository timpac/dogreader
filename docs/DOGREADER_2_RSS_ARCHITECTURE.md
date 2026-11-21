# DogReader 2.0 — RSS Architecture & Main-App Integration Guide

## 1. Baseline & Implementation Inventory

### Verified Baseline (Build 141)
- **Release Tag**: `v141-dog-reader-2.0` (`Dog Reader 2.0 — Experimental build 141`)
- **Baseline Branch**: `origin/experimental/dog-reader-2-installation`
- **Baseline Commit**: `9807f066242ca9e0738bd153dd8486b7c5a5de6b`
- **Development Branch**: `feature/dogreader2-rss-experience`
- **Application ID**: `com.example.audiobook_app.experimental` (co-installs cleanly alongside main DogReader `com.example.audiobook_app` and DogReader 3.0 `com.dogreader.v3`).

### Pre-Existing Capabilities in Build 141 (`lib/article_*.dart`)
Build 141 already contained single-URL web article import and cleanup:
- `lib/article_import.dart`: Public HTTP/HTTPS URL validation (`articleUrl`), DNS-pinned TLS socket connection (`connectValidatedArticleAddress`), HTML clutter removal and block extraction (`extractArticle`, `cleanArticleBlocks`, `ArticleBlock`, `ArticleSpan`), paywall detection (`ArticleAccessException`), truncation detection (`articleLooksIncomplete`), and conversion to `ReaderChapter` (`ImportedArticle.chapter`).
- `lib/article_feed.dart`: Single-article RSS/Atom fallback (`discoverArticleFeeds`, `extractFeedArticle`) used only when a single imported webpage was a JS shell.
- `lib/article_library.dart` & `lib/article_screen.dart`: Queueing and viewing individually pasted/shared article URLs.
- `lib/article_summary.dart`: On-demand AI summary client (`Brief`, `Standard`, `Detailed`) with local caching and experimental cost guards.

### Newly Implemented RSS Experience (`lib/rss/*.dart`)
All multi-entry RSS/Atom feed management, folder organization, OPML import/export, 5-state content status classification, full-text extraction, authors-first organization, natural-language rules, and the main library RSS shelf are implemented in self-contained modules under `lib/rss/`:

| Module | Responsibility |
| --- | --- |
| `lib/rss/rss_models.dart` | Core immutable models: `ArticleContentStatus` (`full`, `previewOnly`, `subscriberOnly`, `extractionFailed`, `unavailable`), `RssFolder`, `RssSubscription`, `FollowedAuthor`, and `RssArticle` (including `toImportedArticle()` bridge to DogReader reading/narration). |
| `lib/rss/rss_parser.dart` | Full RSS 2.0, RSS 1.0/RDF, and Atom 1.0 XML parser (`RssParser.parseFeedXml`), website-to-feed candidate discovery (`discoverCandidateFeedUrls`), and feed-entry content completeness classifier (`classifyFeedEntryContent`). |
| `lib/rss/rss_opml.dart` | OPML 1.0/2.0 parser and exporter (`RssOpml.parseOpml`, `RssOpml.exportOpml`) preserving nested folder hierarchies, deduplicating feed URLs, and reporting malformed outlines. |
| `lib/rss/rss_authors.dart` | Author byline normalization (`RssAuthors.normalizeAuthorName`), multi-author splitting, variation/alias matching, and starter suggestions (Ross Douthat, Coleman Hughes, Douglas Murray, Bari Weiss). |
| `lib/rss/rss_rules.dart` | Deterministic natural-language rule translator (`RssRulesEngine.translateNaturalLanguageRule`) and local evaluator (`applyRulesToArticle`) producing inspectable `IF ... → THEN ...` rules without recurring AI calls. |
| `lib/rss/rss_extractor.dart` | Feed discovery fetcher and webpage full-text upgrader (`RssExtractor.fetchAndDiscoverFeed`, `extractFullArticle`) using DNS-pinned public HTTP/HTTPS transport and classifying results into the 5 `ArticleContentStatus` states. |
| `lib/rss/rss_store.dart` | Atomic local JSON persistence under `<documents>/rss/state_v1.json` and `<documents>/rss/articles/<id>.json` with explicit `schemaVersion: 1` and automatic migration/recovery. |
| `lib/rss/rss_controller.dart` | `RssLibraryController` (`ChangeNotifier`) managing subscriptions, folders, throttled refreshes, OPML import/export, full-text extraction, read/unread/starred state, reading progress, authors, and rules. |
| `lib/rss/rss_shelf.dart` | `RssLibraryShelf`: compact, collapsible RSS shelf at the top of the main library featuring the traditional orange RSS icon (`#F26522`), unread badge, one-tap reader entry, and expandable writer/folder/feed pills. |
| `lib/rss/rss_screens.dart` | `RssHomeScreen`, `RssArticleReadingScreen`, `RssSubscriptionsAndOpmlScreen`, `RssAuthorsScreen`, and `RssRulesScreen`. |

---

## 2. Storage Layout & Schema Migration

All RSS data is stored in an isolated subdirectory (`<documents>/rss/`) so it never conflicts with EPUB files (`<documents>/epubs/`), `reading_state.json`, `dogreader_queue.json`, or single-URL imports (`<documents>/articles/`):

1. `<documents>/rss/state_v1.json`:
   - `schemaVersion`: integer (`1`)
   - `shelfExpanded`: boolean
   - `folders`: list of `RssFolder` JSON objects
   - `subscriptions`: list of `RssSubscription` JSON objects
   - `followedAuthors`: list of `FollowedAuthor` JSON objects
   - `rules`: list of `FeedRule` JSON objects
2. `<documents>/rss/articles/<id>.json`:
   - Individual article files written atomically via `.tmp` rename, storing structured `ArticleBlock`s, `contentStatus`, `statusReason`, `isRead`, `isStarred`, `isSavedToLibrary`, `readingOffset`, `readingScrollFraction`, and `narrationOffset`.
3. **Book Library Separation**:
   - Ordinary RSS articles remain inside `<documents>/rss/articles/` and are **not** added to the EPUB `books` list unless the user explicitly selects **Save to Book Library** (`isSavedToLibrary: true`).

---

## 3. Step-by-Step Integration into Main DogReader

To integrate the RSS experience into the main DogReader application (`dogreader-oct22-update` / Build 153+):

1. **Copy the self-contained modules**:
   - Copy `lib/rss/` (`rss_models.dart`, `rss_parser.dart`, `rss_opml.dart`, `rss_authors.dart`, `rss_rules.dart`, `rss_extractor.dart`, `rss_store.dart`, `rss_controller.dart`, `rss_shelf.dart`, `rss_screens.dart`).
   - Copy `lib/article_import.dart`, `lib/article_feed.dart`, `lib/article_library.dart`, `lib/article_screen.dart`, `lib/article_share.dart`, and `lib/article_summary.dart` if not already present on the target branch.
2. **Verify dependencies in `pubspec.yaml`**:
   - Ensure `xml` (`^6.6.1`) and `html` (`^0.15.6`) are present in `pubspec.yaml`.
3. **Wire `RssLibraryController` and `RssLibraryShelf` in `lib/main.dart`**:
   - Instantiate `rss = RssLibraryController(getApplicationDocumentsDirectory())` in `_LibraryScreenState.initState()`.
   - Render `RssLibraryShelf(controller: rss, ...)` near the top of `_libraryPage()` above the EPUB book cards.
   - Pass `openArticle` as the `onOpenArticle` callback so tapping **Listen / Narrate** or **Book View** on any RSS article reuses DogReader's existing `NarrationQueueScreen`, `DogreaderAudioHandler`, voice selection, and `NarrationDictionary`.
4. **Copy and run the test suite**:
   - Copy `test/rss_experience_test.dart` and run `flutter test test/rss_experience_test.dart`.
