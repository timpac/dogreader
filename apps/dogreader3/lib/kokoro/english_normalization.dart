import 'third_party/fonnx_misaki/diacritic.dart';
import 'third_party/fonnx_misaki/num2words_en.dart';

/// Character provenance is retained through each replacement. All offsets UTF-16.
class SourceRange {
  const SourceRange(this.start, this.end);
  final int start, end;
  List<int> toJson() => [start, end];
}
class EnglishText {
  EnglishText(this.original)
      : text = original,
        origins = List.generate(original.length, (i) => SourceRange(i, i + 1));
  final String original;
  String text;
  List<SourceRange> origins;
  final edits = <Map<String, dynamic>>[];

  List<List<int>> sourceRanges(int start, int end) {
    final result = <List<int>>[];
    for (final span in origins.sublist(start, end)) {
      if (result.isNotEmpty && span.start <= result.last[1] && span.end >= result.last[0]) {
        if (span.start < result.last[0]) result.last[0] = span.start;
        if (span.end > result.last[1]) result.last[1] = span.end;
      } else { result.add(span.toJson()); }
    }
    return result;
  }

  void replace(RegExp pattern, String Function(Match) replacement, String reason) {
    final buffer = StringBuffer(), mapping = <SourceRange>[];
    var last = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start == m.end) throw StateError('Empty normalization match');
      buffer.write(text.substring(last, m.start));
      mapping.addAll(origins.sublist(last, m.start));
      final value = replacement(m);
      final covered = sourceRanges(m.start, m.end);
      final start = covered.first[0], end = covered.last[1];
      buffer.write(value);
      mapping.addAll(List.filled(value.length, SourceRange(start, end)));
      edits.add({'sourceStart': start, 'sourceEnd': end, 'original': original.substring(start, end),
        'spoken': value, 'reason': reason});
      last = m.end;
    }
    buffer.write(text.substring(last));
    mapping.addAll(origins.sublist(last));
    text = buffer.toString(); origins = mapping;
  }
}

const _months = ['January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'];
String _cardinal(String digits) => num2wordsCardinal(BigInt.parse(digits.replaceAll(',', '')));
String _number(String input) {
  final p = input.replaceAll(',', '').split('.');
  return _cardinal(p.first) + (p.length == 1 ? '' :
    ' point ${p[1].split('').map(_cardinal).join(' ')}');
}
String _date(int year, int month, int day) {
  if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1 || day > 31) {
    throw const FormatException('Invalid calendar date.');
  }
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw const FormatException('Invalid calendar date.');
  }
  return '${_months[month - 1]} ${num2wordsOrdinal(BigInt.from(day))}, ${num2wordsYear(year)}';
}

EnglishText normalizeEnglish(String original, {String locale = 'en-US', Map<String, dynamic>? dictionary}) {
  if (original.trim().isEmpty || original.length > 100000) {
    throw const FormatException('Enter between one and 100,000 characters.');
  }
  if (locale != 'en-US' && locale != 'en-GB') throw const FormatException('Unsupported English locale.');
  final out = EnglishText(original);
  // Snapshot ranges refer to ORIGINAL text; apply descending before all edits.
  final ranges = [for (final r in dictionary?['silenced_utf16_ranges'] as List? ?? [])
    Map<String, dynamic>.from(r as Map)]..sort((a, b) => (b['start'] as int).compareTo(a['start'] as int));
  var previousStart = original.length;
  for (final r in ranges) {
    final start = r['start'] as int, end = r['end'] as int;
    if (start < 0 || end <= start || end > previousStart ||
        RegExp(r'[^\s*#~_=•·—–-]').hasMatch(original.substring(start, end))) {
      throw const FormatException('Invalid or nondecorative suppression range.');
    }
    // Prefix mapping is unchanged: all suppression operations run descending.
    final prefix = out.text.substring(0, start);
    out.text = out.text.substring(start);
    out.origins = out.origins.sublist(start);
    out.replace(RegExp('^[\\s\\S]{${end - start}}'), (_) => '', 'dictionary-decoration-suppression');
    out.text = prefix + out.text;
    out.origins = [for (var i = 0; i < start; i++) SourceRange(i, i + 1), ...out.origins];
    previousStart = start;
  }
  for (final entry in dictionary?['substitutions'] as List? ?? []) {
    final rule = Map<String, dynamic>.from(entry as Map);
    final from = rule['original'] as String, to = rule['replacement'] as String;
    if (from.isEmpty || to.trim().isEmpty) throw const FormatException('Empty pronunciation substitution.');
    out.replace(RegExp(RegExp.escape(from)), (_) => to, 'dictionary-text-substitution');
  }
  // Formatting transforms retain provenance.
  // Brackets, braces, and chevrons become speech parentheses (parenthetical cadence).
  out.replace(RegExp(r'[[{⟨〔【「『]'), (_) => '(', 'left-bracket');
  out.replace(RegExp(r'[\]\}⟩〕】」』]'), (_) => ')', 'right-bracket');
  out.replace(RegExp(r'<'), (_) => '(', 'left-angle-bracket');
  out.replace(RegExp(r'>'), (_) => ')', 'right-angle-bracket');

  out.replace(RegExp(r'[«»‹›„“”]'), (_) => '"', 'quotation-mark');
  out.replace(RegExp(r'[‘’ʼ‚]'), (_) => "'", 'apostrophe');
  out.replace(RegExp(r'[\u00a0\u202f\u2000-\u200b\u3000]'), (_) => ' ', 'nonbreaking-space');
  out.replace(RegExp(r'\r\n?'), (_) => '\n', 'line-ending');
  out.replace(RegExp(r'\u00ad'), (_) => '', 'soft-hyphen');
  out.replace(RegExp(r'[ﬁﬂﬀﬃﬄ]'), (m) => const {'ﬁ':'fi','ﬂ':'fl','ﬀ':'ff','ﬃ':'ffi','ﬄ':'ffl'}[m[0]]!, 'ligature');
  out.replace(RegExp(r'[æÆ]'), (_) => 'ae', 'ae-ligature');
  out.replace(RegExp(r'[œŒ]'), (_) => 'oe', 'oe-ligature');
  out.replace(RegExp(r'ß'), (_) => 'ss', 'eszett');
  out.replace(RegExp(r'[\u0300-\u036f]'), (_) => '', 'combining-diacritic');
  out.replace(RegExp(r'[\u00c0-\u024f\u1e00-\u1eff]'), (m) => removeDiacritics(m[0]!), 'Latin-diacritic');
  out.replace(RegExp(r'[–—―‒−]'), (_) => ' — ', 'dash-pause');
  out.replace(RegExp(r'-{2,}'), (_) => ' — ', 'double-hyphen-pause');
  out.replace(RegExp(r'\.{2,}'), (_) => '…', 'ellipsis');
  out.replace(RegExp(r"\*([A-Za-z][A-Za-z '-]*)\*"), (m) => m[1]!, 'paired-emphasis-markup');
  out.replace(RegExp(r'\*+'), (_) => ' ', 'asterisk-symbol');
  out.replace(RegExp(r'×'), (_) => ' times ', 'multiplication');
  out.replace(RegExp(r'\+'), (_) => ' plus ', 'addition');
  out.replace(RegExp(r'='), (_) => ' equals ', 'equality');
  out.replace(RegExp(r'&'), (_) => ' and ', 'ampersand');
  out.replace(RegExp(r'@'), (_) => ' at ', 'at-symbol');
  out.replace(RegExp(r'#(\d+)\b'), (m) => 'number ${m[1]}', 'number-sign');
  out.replace(RegExp(r'#+'), (_) => ' ', 'hash-symbol');
  out.replace(RegExp(r'_+'), (_) => ' ', 'underscore');
  out.replace(RegExp(r'[•·~^|§©®™°†‡]'), (_) => ' ', 'symbol-pause');

  out.replace(RegExp(r'\band/or\b', caseSensitive: false), (_) => 'and or', 'and-or');
  out.replace(RegExp(r'\b1/2\b'), (_) => 'one half', 'fraction');
  out.replace(RegExp(r'\b1/4\b'), (_) => 'one quarter', 'fraction');
  out.replace(RegExp(r'\b3/4\b'), (_) => 'three quarters', 'fraction');
  out.replace(RegExp(r'(?<=[A-Za-z])/(?=[A-Za-z])'), (_) => ' or ', 'slash-alternation');

  out.replace(RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{4})\b'), (m) {
    try {
      final first = int.parse(m[1]!), second = int.parse(m[2]!);
      return _date(int.parse(m[3]!), locale == 'en-US' ? first : second, locale == 'en-US' ? second : first);
    } catch (_) {
      return '${_cardinal(m[1]!)} slash ${_cardinal(m[2]!)} slash ${_cardinal(m[3]!)}';
    }
  }, 'numeric-date-$locale');
  out.replace(RegExp('\\b(${_months.join('|')})\\s+(\\d{1,2}),?\\s+(\\d{4})\\b', caseSensitive: false), (m) {
    try {
      final month = _months.indexWhere((s) => s.toLowerCase() == m[1]!.toLowerCase()) + 1;
      return _date(int.parse(m[3]!), month, int.parse(m[2]!));
    } catch (_) {
      return '${m[1]} ${_cardinal(m[2]!)} ${_cardinal(m[3]!)}';
    }
  }, 'named-date');
  out.replace(RegExp(r'\b(\d{1,2}):(\d{2})\b'), (m) {
    final hour = int.parse(m[1]!), minute = int.parse(m[2]!);
    if (hour > 23 || minute > 59) return '${_cardinal(m[1]!)} ${_cardinal(m[2]!)}';
    return '${_cardinal(m[1]!)} ${minute == 0 ? "o'clock" : minute < 10 ? "oh ${_cardinal(m[2]!)}" : _cardinal(m[2]!)}';
  }, 'clock-time');
  out.replace(RegExp(r'/'), (_) => ' slash ', 'slash');
  out.replace(RegExp(r'\\'), (_) => ' ', 'backslash');
  out.replace(RegExp(r'\b(a|p)\.m\.', caseSensitive: false), (m) => '${m[1]!.toUpperCase()} M', 'time-abbreviation');
  const titles = {'mr':'Mister', 'mrs':'Missus', 'ms':'Miz', 'dr':'Doctor', 'st':'Saint'};
  out.replace(RegExp(r'\b(Mr|Mrs|Ms|Dr|St)\.', caseSensitive: false), (m) => titles[m[1]!.toLowerCase()]!, 'title-abbreviation-Saint-default');
  out.replace(RegExp(r'\be\.g\.', caseSensitive: false), (_) => 'for example', 'abbreviation');
  out.replace(RegExp(r'\bi\.e\.', caseSensitive: false), (_) => 'that is', 'abbreviation');
  out.replace(RegExp(r'\b(\d+(?:\.\d+)?)\s*(km|kg|cm)\b'), (m) =>
    '${m[1]} ${const {'km':'kilometers','kg':'kilograms','cm':'centimeters'}[m[2]]}', 'metric-unit');
  out.replace(RegExp(r'([$£€])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(?![\d.])'), (m) {
    final value = BigInt.parse(m[2]!.replaceAll(',', ''));
    final names = switch (m[1]) { '£' => ('pound', 'pounds', 'penny', 'pence'),
      '€' => ('euro', 'euros', 'cent', 'cents'), _ => ('dollar', 'dollars', 'cent', 'cents') };
    final cents = m[3] == null ? 0 : int.parse(m[3]!.padRight(2, '0'));
    final mainText = '${num2wordsCardinal(value)} ${value == BigInt.one ? names.$1 : names.$2}';
    final centsText = cents == 0 ? '' : ' and ${_cardinal('$cents')} ${cents == 1 ? names.$3 : names.$4}';
    return '$mainText$centsText';
  }, 'currency');
  out.replace(RegExp(r'\b(\d+(?:\.\d+)?)%'), (m) => '${_number(m[1]!)} percent', 'percentage');
  out.replace(RegExp(r'\b(\d+)(st|nd|rd|th)\b'), (m) => num2wordsOrdinal(BigInt.parse(m[1]!)), 'ordinal');
  out.replace(RegExp(r'\b\d+(?:,\d{3})*(?:\.\d+)?\b'), (m) => _number(m[0]!), 'number');
  out.replace(RegExp(r'\d'), (m) => _cardinal(m[0]!), 'isolated-digit');
  out.replace(RegExp(r'[ \t]+'), (_) => ' ', 'horizontal-whitespace');
  out.replace(RegExp(r' *\n(?:[ \t]*\n)+ *'), (_) => '\n\n', 'paragraph-break');
  out.replace(RegExp(r'(?<!\n)\n(?!\n)'), (_) => ' ', 'line-wrap');
  // Safe fallback for any remaining unsupported characters so chapters never abort
  out.replace(RegExp(r'''[^A-Za-z\s,.!?;:'"()—…-]'''), (_) => ' ', 'unsupported-char-fallback');
  out.replace(RegExp(r'[ \t]+'), (_) => ' ', 'horizontal-whitespace');
  if (!RegExp(r'[A-Za-z]').hasMatch(out.text)) throw const FormatException('No spoken words. No audio generated.');
  return out;
}
