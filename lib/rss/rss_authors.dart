import 'rss_models.dart';

/// Author normalization, alias matching, and authors-first filtering utilities.
///
/// Handles real-world author byline variations across RSS feeds, Substack,
/// and multi-author publications like The Free Press.
class RssAuthors {
  static const List<FollowedAuthor> suggestedAuthors = [
    FollowedAuthor(
      id: 'author_ross_douthat',
      name: 'Ross Douthat',
      normalizedName: 'ross douthat',
      aliases: ['r douthat', 'ross g douthat'],
    ),
    FollowedAuthor(
      id: 'author_coleman_hughes',
      name: 'Coleman Hughes',
      normalizedName: 'coleman hughes',
      aliases: ['coleman c hughes', 'c hughes'],
    ),
    FollowedAuthor(
      id: 'author_douglas_murray',
      name: 'Douglas Murray',
      normalizedName: 'douglas murray',
      aliases: ['douglas k murray', 'd murray'],
    ),
    FollowedAuthor(
      id: 'author_bari_weiss',
      name: 'Bari Weiss',
      normalizedName: 'bari weiss',
      aliases: [],
    ),
  ];

  /// Normalizes a single author name for canonical comparison.
  ///
  /// Strips leading "By ", parenthetical notes, email addresses, role suffixes,
  /// punctuation, and single-letter middle initials.
  static String normalizeAuthorName(String raw) {
    var cleaned = raw.trim();
    if (cleaned.isEmpty) return '';

    // Remove email addresses like "jane@example.com (Jane Doe)" -> "Jane Doe"
    final parenName = RegExp(r'^[^\s@]+@[^\s@]+\s*\(([^)]+)\)$').firstMatch(cleaned);
    if (parenName != null) {
      cleaned = parenName.group(1)!.trim();
    } else {
      cleaned = cleaned.replaceAll(RegExp(r'<[^>]*>'), ' ');
      cleaned = cleaned.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    }

    cleaned = cleaned.replaceFirst(RegExp(r'^(?:by|written by|author:)\s+', caseSensitive: false), '');
    cleaned = cleaned.toLowerCase();
    // Replace punctuation with spaces.
    cleaned = cleaned.replaceAll(RegExp(r"[^a-z0-9\s']"), ' ');
    cleaned = cleaned.replaceAll("'", '');

    final tokens = cleaned
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return '';

    // Remove single-letter middle initials when there are >= 3 tokens
    // e.g. ["ross", "g", "douthat"] -> ["ross", "douthat"]
    if (tokens.length >= 3) {
      final filtered = <String>[tokens.first];
      for (var i = 1; i < tokens.length - 1; i++) {
        if (tokens[i].length > 1) filtered.add(tokens[i]);
      }
      filtered.add(tokens.last);
      return filtered.join(' ');
    }

    return tokens.join(' ');
  }

  /// Splits a potentially multi-author byline (e.g. "Ross Douthat and Coleman Hughes"
  /// or "Douglas Murray, Bari Weiss") into individual normalized author names.
  static List<String> extractNormalizedAuthors(String? rawAuthor, {String? fallbackTitleOrText}) {
    final results = <String>{};
    if (rawAuthor != null && rawAuthor.trim().isNotEmpty) {
      final parts = rawAuthor.split(
        RegExp(r'\s+(?:and|&|with)\s+|[,;|/]', caseSensitive: false),
      );
      for (final part in parts) {
        final norm = normalizeAuthorName(part);
        if (norm.isNotEmpty && norm.length >= 2) {
          results.add(norm);
        }
      }
      final wholeNorm = normalizeAuthorName(rawAuthor);
      if (wholeNorm.isNotEmpty && wholeNorm.split(' ').length <= 4) {
        results.add(wholeNorm);
      }
    }
    return results.toList(growable: false);
  }

  /// Creates a [FollowedAuthor] from a user-supplied display name and optional aliases.
  static FollowedAuthor createFollowedAuthor(
    String name, {
    List<String> aliases = const [],
    bool favorite = true,
    bool autoNarrateEligible = false,
  }) {
    final cleanName = name.trim();
    final norm = normalizeAuthorName(cleanName);
    final normalizedAliases = <String>{
      for (final alias in aliases)
        if (normalizeAuthorName(alias).isNotEmpty) normalizeAuthorName(alias),
    };
    for (final preset in suggestedAuthors) {
      if (preset.normalizedName == norm) {
        normalizedAliases.addAll(preset.aliases.map(normalizeAuthorName));
      }
    }
    return FollowedAuthor(
      id: generateRssId('author', norm.isEmpty ? cleanName : norm),
      name: cleanName,
      normalizedName: norm,
      aliases: normalizedAliases.toList(growable: false),
      favorite: favorite,
      autoNarrateEligible: autoNarrateEligible,
    );
  }

  /// Returns true if [article] was written by or matches [followedAuthor].
  static bool articleMatchesAuthor(RssArticle article, FollowedAuthor followedAuthor) {
    final targetNorm = followedAuthor.normalizedName.isNotEmpty
        ? followedAuthor.normalizedName
        : normalizeAuthorName(followedAuthor.name);
    if (targetNorm.isEmpty) return false;

    final candidateTargets = <String>{
      targetNorm,
      for (final alias in followedAuthor.aliases)
        if (normalizeAuthorName(alias).isNotEmpty) normalizeAuthorName(alias),
    };

    for (final articleAuthor in article.normalizedAuthors) {
      if (candidateTargets.contains(articleAuthor)) return true;
      for (final target in candidateTargets) {
        if (articleAuthor.contains(target) || target.contains(articleAuthor)) {
          // Ensure full token boundary match
          if (_hasTokenPhrase(articleAuthor, target)) return true;
        }
      }
    }

    final rawNorm = normalizeAuthorName(article.author ?? '');
    if (rawNorm.isNotEmpty) {
      for (final target in candidateTargets) {
        if (rawNorm == target || _hasTokenPhrase(rawNorm, target)) return true;
      }
    }

    // Also check if the article title or summary starts with or explicitly credits the author
    // (common in multi-author newsletters/podcasts like "Ross Douthat: ...").
    final titleLower = article.title.toLowerCase();
    if (titleLower.contains(targetNorm)) {
      return true;
    }

    return false;
  }

  /// Checks whether an article matches a raw author query string.
  static bool articleMatchesAuthorQuery(RssArticle article, String query) {
    final normQuery = normalizeAuthorName(query);
    if (normQuery.isEmpty) return false;
    final tempAuthor = createFollowedAuthor(query);
    return articleMatchesAuthor(article, tempAuthor);
  }

  static bool _hasTokenPhrase(String haystack, String needle) {
    final pattern = RegExp(r'(?:^|\s)' + RegExp.escape(needle) + r'(?:$|\s)');
    return pattern.hasMatch(haystack);
  }
}
