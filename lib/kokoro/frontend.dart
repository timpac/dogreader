// Deliberately constrained lexicon frontend, not a general English G2P engine.
class PreparedText {
  final List<String> chunks;
  final int words;
  PreparedText(this.chunks, this.words);
}

PreparedText prepareText(String text, Map<String, List<String>> lexicon) {
  if (text.trim().isEmpty || text.length > 100000) {
    throw FormatException('Enter between one and 100,000 characters.');
  }
  if (RegExp(r"[^A-Za-z\s,.!?;:']").hasMatch(text)) {
    throw FormatException('This probe accepts English letters, plain apostrophes '
        'and ,.!?;: only. Spell out numbers. Full normalization is not implemented.');
  }
  final pieces = RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)*|[,.!?;:]|\s+")
      .allMatches(text).map((m) => m.group(0)!).toList();
  // Reject stray apostrophes instead of silently removing unsupported text.
  if (pieces.join() != text) {
    throw FormatException('Only apostrophes inside dictionary words are supported.');
  }
  final unknown = <String>{};
  var words = 0;
  for (final piece in pieces) {
    if (RegExp('[A-Za-z]').hasMatch(piece)) {
      words++;
      if (!lexicon.containsKey(piece.toLowerCase())) unknown.add(piece);
    }
  }
  if (unknown.isNotEmpty) {
    throw FormatException('No audio generated. Words absent from the lexicon: '
        '${unknown.take(20).join(', ')}. Use a spoken spelling or different text.');
  }
  if (words == 0) throw FormatException('No spoken words.');
  final chunks = <String>[];
  var current = StringBuffer();
  var phones = 0;
  for (final piece in pieces) {
    final cost = lexicon[piece.toLowerCase()]?.length ?? 1;
    if (cost > 400) throw FormatException('Dictionary word exceeds the token limit.');
    if (phones + cost > 400 && current.isNotEmpty) {
      chunks.add(current.toString());
      current = StringBuffer();
      phones = 0;
    }
    current.write(piece);
    phones += cost;
    if (RegExp(r'[.!?]').hasMatch(piece) && current.isNotEmpty) {
      chunks.add(current.toString());
      current = StringBuffer();
      phones = 0;
    }
  }
  if (current.toString().trim().isNotEmpty) chunks.add(current.toString());
  return PreparedText(chunks.where((c) => RegExp('[A-Za-z]').hasMatch(c)).toList(), words);
}

Map<String, List<String>> parseLexicon(String content) {
  final result = <String, List<String>>{};
  for (final line in content.split('\n')) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length > 1) result[fields.first] = fields.sublist(1);
  }
  return result;
}
