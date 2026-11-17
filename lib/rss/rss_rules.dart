import 'rss_authors.dart';
import 'rss_models.dart';

enum RuleConditionType {
  author('Author matches'),
  topic('Topic / keyword matches'),
  publication('Publication / feed matches'),
  favoriteAuthors('Written by a favorite author'),
  any('Any article');

  const RuleConditionType(this.label);
  final String label;

  static RuleConditionType fromName(String? value) =>
      RuleConditionType.values
          .where((e) => e.name == value)
          .firstOrNull ??
      RuleConditionType.topic;
}

enum RuleActionType {
  showOnly('Filter / show matching articles'),
  hide('Hide matching articles'),
  star('Automatically star article'),
  assignFolder('Move to folder'),
  prioritize('Prioritize at top of feed');

  const RuleActionType(this.label);
  final String label;

  static RuleActionType fromName(String? value) =>
      RuleActionType.values
          .where((e) => e.name == value)
          .firstOrNull ??
      RuleActionType.star;
}

/// An explicit, inspectable, deterministic rule translated from natural language
/// or created/edited directly by the user.
class FeedRule {
  const FeedRule({
    required this.id,
    required this.naturalLanguagePrompt,
    required this.conditionType,
    required this.pattern,
    required this.actionType,
    this.targetFolderName,
    this.targetFolderId,
    this.enabled = true,
    required this.createdAt,
  });

  final String id;
  final String naturalLanguagePrompt;
  final RuleConditionType conditionType;
  final String pattern;
  final RuleActionType actionType;
  final String? targetFolderName;
  final String? targetFolderId;
  final bool enabled;
  final DateTime createdAt;

  /// Human-readable description of the explicit rule definition so the user
  /// can inspect exactly how DogReader evaluates it.
  String get explicitDescription {
    final condText = switch (conditionType) {
      RuleConditionType.author => 'Author matches "$pattern"',
      RuleConditionType.topic => 'Title or text matches topic "$pattern"',
      RuleConditionType.publication => 'Publication matches "$pattern"',
      RuleConditionType.favoriteAuthors => 'Author is in Favorite Writers',
      RuleConditionType.any => 'All incoming articles',
    };
    final actText = switch (actionType) {
      RuleActionType.showOnly => 'Show / highlight in filtered view',
      RuleActionType.hide => 'Hide from default article list',
      RuleActionType.star => 'Automatically star article',
      RuleActionType.assignFolder =>
        'Assign to folder "${targetFolderName ?? 'Unassigned'}"',
      RuleActionType.prioritize => 'Prioritize near top of feed',
    };
    return 'IF $condText → THEN $actText';
  }

  FeedRule copyWith({
    String? naturalLanguagePrompt,
    RuleConditionType? conditionType,
    String? pattern,
    RuleActionType? actionType,
    String? targetFolderName,
    String? targetFolderId,
    bool? enabled,
  }) =>
      FeedRule(
        id: id,
        naturalLanguagePrompt:
            naturalLanguagePrompt ?? this.naturalLanguagePrompt,
        conditionType: conditionType ?? this.conditionType,
        pattern: pattern ?? this.pattern,
        actionType: actionType ?? this.actionType,
        targetFolderName: targetFolderName ?? this.targetFolderName,
        targetFolderId: targetFolderId ?? this.targetFolderId,
        enabled: enabled ?? this.enabled,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'naturalLanguagePrompt': naturalLanguagePrompt,
        'conditionType': conditionType.name,
        'pattern': pattern,
        'actionType': actionType.name,
        'targetFolderName': targetFolderName,
        'targetFolderId': targetFolderId,
        'enabled': enabled,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  static FeedRule fromJson(Map<String, Object?> json) => FeedRule(
        id: json['id'] as String? ?? '',
        naturalLanguagePrompt: json['naturalLanguagePrompt'] as String? ?? '',
        conditionType:
            RuleConditionType.fromName(json['conditionType'] as String?),
        pattern: json['pattern'] as String? ?? '',
        actionType: RuleActionType.fromName(json['actionType'] as String?),
        targetFolderName: json['targetFolderName'] as String?,
        targetFolderId: json['targetFolderId'] as String?,
        enabled: json['enabled'] as bool? ?? true,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

class RuleTranslationResult {
  const RuleTranslationResult._({
    required this.isSupported,
    this.rule,
    this.errorMessage,
    this.examples = const [],
  });

  factory RuleTranslationResult.success(FeedRule rule) =>
      RuleTranslationResult._(isSupported: true, rule: rule);

  factory RuleTranslationResult.unsupported(
    String message, {
    List<String> examples = const [
      'Show me articles by Ross Douthat',
      'Hide articles from Jane Roe',
      'Automatically star articles matching AI',
      'Put articles about AI into Technology',
      'Prioritize articles from favorite writers',
    ],
  }) =>
      RuleTranslationResult._(
        isSupported: false,
        errorMessage: message,
        examples: examples,
      );

  final bool isSupported;
  final FeedRule? rule;
  final String? errorMessage;
  final List<String> examples;
}

class RssRulesEngine {
  /// Translates an ordinary-language rule prompt into an explicit, deterministic
  /// [FeedRule] without recurring AI API calls.
  static RuleTranslationResult translateNaturalLanguageRule(
    String rawInput, {
    List<RssFolder> existingFolders = const [],
    DateTime? now,
  }) {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return RuleTranslationResult.unsupported(
        'Please enter a rule instruction in plain English.',
      );
    }

    final timestamp = (now ?? DateTime.now()).toUtc();
    final cleaned = input.replaceAll(RegExp(r'[.!?]+$'), '').trim();

    // Reject rules that ask for unsupported capabilities (e.g., bypassing paywalls,
    // auto-billing cloud jobs, sending emails/webhooks, or time-of-day scheduling).
    final lower = cleaned.toLowerCase();
    if (lower.contains('paywall') || lower.contains('bypass')) {
      return RuleTranslationResult.unsupported(
        'DogReader cannot bypass publisher paywalls or subscriber restrictions.',
      );
    }
    if (lower.contains('email') ||
        lower.contains('webhook') ||
        lower.contains('sms') ||
        lower.contains('tweet')) {
      return RuleTranslationResult.unsupported(
        'External notifications (email/SMS/webhooks) are not supported by local feed rules.',
      );
    }

    // 1. "Prioritize articles from favorite writers / authors"
    final favPrioritizeRegex = RegExp(
      r'^(?:always\s+)?(?:prioritize|boost|pin|highlight)\s+(?:articles|posts|stories|pieces)?\s*(?:from|by)\s+(?:my\s+)?(?:favorite|followed)\s+(?:writers|authors)$',
      caseSensitive: false,
    );
    if (favPrioritizeRegex.hasMatch(cleaned)) {
      return RuleTranslationResult.success(
        FeedRule(
          id: generateRssId('rule', cleaned),
          naturalLanguagePrompt: input,
          conditionType: RuleConditionType.favoriteAuthors,
          pattern: 'favorite_writers',
          actionType: RuleActionType.prioritize,
          createdAt: timestamp,
        ),
      );
    }

    // 2. "Put / move articles about/matching [topic] into/to [folder]"
    final folderTopicRegex = RegExp(
      r'^(?:put|move|assign|file|route)\s+(?:all\s+)?(?:articles|posts|stories|pieces)\s+(?:about|matching|on|regarding|containing|with)\s+(.+?)\s+(?:into|in|to)\s+(?:the\s+)?(?:folder\s+)?(.+?)(?:\s+folder)?$',
      caseSensitive: false,
    );
    final folderTopicMatch = folderTopicRegex.firstMatch(cleaned);
    if (folderTopicMatch != null) {
      final topic = _stripQuotes(folderTopicMatch.group(1)!);
      final folderName = _stripQuotes(folderTopicMatch.group(2)!);
      if (topic.isNotEmpty && folderName.isNotEmpty) {
        final matchedFolder = existingFolders
            .where((f) => f.name.toLowerCase() == folderName.toLowerCase())
            .firstOrNull;
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', '$cleaned:$folderName'),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.topic,
            pattern: topic,
            actionType: RuleActionType.assignFolder,
            targetFolderName: matchedFolder?.name ?? folderName,
            targetFolderId: matchedFolder?.id,
            createdAt: timestamp,
          ),
        );
      }
    }

    // 3. "Put / move articles by/from [author] into/to [folder]"
    final folderAuthorRegex = RegExp(
      r'^(?:put|move|assign|file|route)\s+(?:all\s+)?(?:articles|posts|stories|pieces)\s+(?:by|from)\s+(.+?)\s+(?:into|in|to)\s+(?:the\s+)?(?:folder\s+)?(.+?)(?:\s+folder)?$',
      caseSensitive: false,
    );
    final folderAuthorMatch = folderAuthorRegex.firstMatch(cleaned);
    if (folderAuthorMatch != null) {
      final author = _stripQuotes(folderAuthorMatch.group(1)!);
      final folderName = _stripQuotes(folderAuthorMatch.group(2)!);
      if (author.isNotEmpty && folderName.isNotEmpty) {
        final matchedFolder = existingFolders
            .where((f) => f.name.toLowerCase() == folderName.toLowerCase())
            .firstOrNull;
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', '$cleaned:$folderName'),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.author,
            pattern: author,
            actionType: RuleActionType.assignFolder,
            targetFolderName: matchedFolder?.name ?? folderName,
            targetFolderId: matchedFolder?.id,
            createdAt: timestamp,
          ),
        );
      }
    }

    // 4. "Show (me) (only) articles by/from [author]"
    final showAuthorRegex = RegExp(
      r'^(?:show(?:\s+me)?|only\s+show|filter(?:\s+for)?|include(?:\s+only)?)\s+(?:only\s+)?(?:articles|posts|stories|pieces|columns|essays)\s+(?:by|from|written\s+by)\s+(.+)$',
      caseSensitive: false,
    );
    final showAuthorMatch = showAuthorRegex.firstMatch(cleaned);
    if (showAuthorMatch != null) {
      final author = _stripQuotes(showAuthorMatch.group(1)!);
      if (author.isNotEmpty) {
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', cleaned),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.author,
            pattern: author,
            actionType: RuleActionType.showOnly,
            createdAt: timestamp,
          ),
        );
      }
    }

    // 5. "Show (me) articles about/matching [topic]"
    final showTopicRegex = RegExp(
      r'^(?:show(?:\s+me)?|only\s+show|filter(?:\s+for)?)\s+(?:only\s+)?(?:articles|posts|stories|pieces)\s+(?:about|matching|on|regarding|containing)\s+(.+)$',
      caseSensitive: false,
    );
    final showTopicMatch = showTopicRegex.firstMatch(cleaned);
    if (showTopicMatch != null) {
      final topic = _stripQuotes(showTopicMatch.group(1)!);
      if (topic.isNotEmpty) {
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', cleaned),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.topic,
            pattern: topic,
            actionType: RuleActionType.showOnly,
            createdAt: timestamp,
          ),
        );
      }
    }

    // 6. "Hide / mute / ignore articles from/by [author]"
    final hideAuthorRegex = RegExp(
      r'^(?:hide|mute|ignore|skip|exclude|block)\s+(?:all\s+)?(?:articles|posts|stories|pieces)?\s*(?:from|by|written\s+by)\s+(.+)$',
      caseSensitive: false,
    );
    final hideAuthorMatch = hideAuthorRegex.firstMatch(cleaned);
    if (hideAuthorMatch != null) {
      final author = _stripQuotes(hideAuthorMatch.group(1)!);
      if (author.isNotEmpty) {
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', cleaned),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.author,
            pattern: author,
            actionType: RuleActionType.hide,
            createdAt: timestamp,
          ),
        );
      }
    }

    // 7. "Hide / mute / ignore articles about/matching [topic]"
    final hideTopicRegex = RegExp(
      r'^(?:hide|mute|ignore|skip|exclude|block)\s+(?:all\s+)?(?:articles|posts|stories|pieces)?\s*(?:about|matching|on|regarding|containing|with)\s+(.+)$',
      caseSensitive: false,
    );
    final hideTopicMatch = hideTopicRegex.firstMatch(cleaned);
    if (hideTopicMatch != null) {
      final topic = _stripQuotes(hideTopicMatch.group(1)!);
      if (topic.isNotEmpty) {
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', cleaned),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.topic,
            pattern: topic,
            actionType: RuleActionType.hide,
            createdAt: timestamp,
          ),
        );
      }
    }

    // 8. "(Automatically) star / save / bookmark articles matching/about [topic]"
    final starTopicRegex = RegExp(
      r'^(?:automatically\s+|auto[- ]?)?(?:star|save|bookmark|favorite)\s+(?:all\s+)?(?:articles|posts|stories|pieces)?\s*(?:matching|about|on|regarding|containing|with)\s+(.+)$',
      caseSensitive: false,
    );
    final starTopicMatch = starTopicRegex.firstMatch(cleaned);
    if (starTopicMatch != null) {
      final topic = _stripQuotes(starTopicMatch.group(1)!);
      if (topic.isNotEmpty) {
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', cleaned),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.topic,
            pattern: topic,
            actionType: RuleActionType.star,
            createdAt: timestamp,
          ),
        );
      }
    }

    // 9. "(Automatically) star / save / bookmark articles by/from [author]"
    final starAuthorRegex = RegExp(
      r'^(?:automatically\s+|auto[- ]?)?(?:star|save|bookmark|favorite)\s+(?:all\s+)?(?:articles|posts|stories|pieces)?\s*(?:by|from|written\s+by)\s+(.+)$',
      caseSensitive: false,
    );
    final starAuthorMatch = starAuthorRegex.firstMatch(cleaned);
    if (starAuthorMatch != null) {
      final author = _stripQuotes(starAuthorMatch.group(1)!);
      if (author.isNotEmpty) {
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', cleaned),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.author,
            pattern: author,
            actionType: RuleActionType.star,
            createdAt: timestamp,
          ),
        );
      }
    }

    // 10. "Prioritize articles by/from [author]" or "Prioritize articles about [topic]"
    final prioritizeAuthorRegex = RegExp(
      r'^(?:always\s+)?(?:prioritize|boost|pin|highlight)\s+(?:all\s+)?(?:articles|posts|stories|pieces)?\s*(?:by|from|written\s+by)\s+(.+)$',
      caseSensitive: false,
    );
    final prioritizeAuthorMatch = prioritizeAuthorRegex.firstMatch(cleaned);
    if (prioritizeAuthorMatch != null) {
      final author = _stripQuotes(prioritizeAuthorMatch.group(1)!);
      if (author.isNotEmpty) {
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', cleaned),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.author,
            pattern: author,
            actionType: RuleActionType.prioritize,
            createdAt: timestamp,
          ),
        );
      }
    }

    final prioritizeTopicRegex = RegExp(
      r'^(?:always\s+)?(?:prioritize|boost|pin|highlight)\s+(?:all\s+)?(?:articles|posts|stories|pieces)?\s*(?:about|matching|on|regarding|containing)\s+(.+)$',
      caseSensitive: false,
    );
    final prioritizeTopicMatch = prioritizeTopicRegex.firstMatch(cleaned);
    if (prioritizeTopicMatch != null) {
      final topic = _stripQuotes(prioritizeTopicMatch.group(1)!);
      if (topic.isNotEmpty) {
        return RuleTranslationResult.success(
          FeedRule(
            id: generateRssId('rule', cleaned),
            naturalLanguagePrompt: input,
            conditionType: RuleConditionType.topic,
            pattern: topic,
            actionType: RuleActionType.prioritize,
            createdAt: timestamp,
          ),
        );
      }
    }

    return RuleTranslationResult.unsupported(
      'Could not translate "$input" into a deterministic local rule. '
      'Supported actions are showing, hiding, starring, prioritizing, or moving articles into a folder by author or topic.',
    );
  }

  /// Evaluates whether [article] matches [rule]'s condition.
  static bool matchesCondition(
    RssArticle article,
    FeedRule rule, {
    List<FollowedAuthor> followedAuthors = const [],
  }) {
    if (!rule.enabled) return false;
    switch (rule.conditionType) {
      case RuleConditionType.any:
        return true;
      case RuleConditionType.favoriteAuthors:
        final favorites = followedAuthors.where((a) => a.favorite);
        for (final fav in favorites) {
          if (RssAuthors.articleMatchesAuthor(article, fav)) return true;
        }
        return false;
      case RuleConditionType.author:
        return RssAuthors.articleMatchesAuthorQuery(article, rule.pattern);
      case RuleConditionType.publication:
        final q = rule.pattern.trim().toLowerCase();
        if (q.isEmpty) return false;
        return article.feedTitle.toLowerCase().contains(q) ||
            article.url.toLowerCase().contains(q);
      case RuleConditionType.topic:
        return _matchesTopic(article, rule.pattern);
    }
  }

  /// Applies all enabled [rules] and [followedAuthors] to [article], returning
  /// an updated [RssArticle] with `isStarred`, `isHidden`, `isPrioritized`,
  /// `folderId`, and `matchedRuleIds` populated deterministically.
  static RssArticle applyRulesToArticle(
    RssArticle article, {
    required List<FeedRule> rules,
    required List<FollowedAuthor> followedAuthors,
    required Map<String, String> folderNameToId,
  }) {
    var isStarred = article.isStarred;
    var isHidden = false;
    var isPrioritized = false;
    var folderId = article.folderId;
    final matchedIds = <String>[];

    // Automatically prioritize favorite followed authors if any match
    for (final author in followedAuthors) {
      if (author.favorite && RssAuthors.articleMatchesAuthor(article, author)) {
        isPrioritized = true;
        break;
      }
    }

    final enabledRules = rules.where((r) => r.enabled).toList(growable: false);
    final showOnlyRules = enabledRules
        .where((r) => r.actionType == RuleActionType.showOnly)
        .toList(growable: false);

    var matchesAnyShowOnly = showOnlyRules.isEmpty;

    for (final rule in enabledRules) {
      final matched = matchesCondition(
        article,
        rule,
        followedAuthors: followedAuthors,
      );
      if (!matched) continue;
      matchedIds.add(rule.id);

      switch (rule.actionType) {
        case RuleActionType.showOnly:
          matchesAnyShowOnly = true;
        case RuleActionType.hide:
          isHidden = true;
        case RuleActionType.star:
          isStarred = true;
        case RuleActionType.prioritize:
          isPrioritized = true;
        case RuleActionType.assignFolder:
          final resolvedFolderId = rule.targetFolderId ??
              (rule.targetFolderName != null
                  ? folderNameToId[rule.targetFolderName!.toLowerCase()]
                  : null);
          if (resolvedFolderId != null) {
            folderId = resolvedFolderId;
          }
      }
    }

    if (!matchesAnyShowOnly) {
      isHidden = true;
    }

    return article.copyWith(
      isStarred: isStarred,
      isHidden: isHidden,
      isPrioritized: isPrioritized,
      folderId: folderId,
      matchedRuleIds: matchedIds,
    );
  }

  static bool _matchesTopic(RssArticle article, String rawPattern) {
    final pattern = rawPattern.trim().toLowerCase();
    if (pattern.isEmpty) return false;

    final haystack = [
      article.title,
      article.summaryPreview,
      for (final b in article.blocks) b.text,
    ].join(' ').toLowerCase();

    // If short acronym like "ai" or "eu", match on word boundaries so "ai" doesn't match "said".
    if (pattern.length <= 3 && RegExp(r'^[a-z0-9]+$').hasMatch(pattern)) {
      final wordRegex = RegExp(r'\b' + RegExp.escape(pattern) + r'\b', caseSensitive: false);
      return wordRegex.hasMatch(haystack);
    }

    return haystack.contains(pattern);
  }

  static String _stripQuotes(String value) {
    var v = value.trim();
    if ((v.startsWith('"') && v.endsWith('"')) ||
        (v.startsWith("'") && v.endsWith("'")) ||
        (v.startsWith('[') && v.endsWith(']'))) {
      v = v.substring(1, v.length - 1).trim();
    }
    return v;
  }
}
