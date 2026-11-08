import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

class StyledRange {
  final int start, end;
  final bool italic, bold, heading;
  const StyledRange(this.start, this.end,
      {this.italic = false, this.bold = false, this.heading = false});
}

class ReaderChapter {
  final String title;
  final String text;
  final List<StyledRange> ranges;
  const ReaderChapter(this.title, this.text, this.ranges);
}

// EPUB paths are archive paths, never network URLs. Resolve relative links
// against their owning document, including escaped names and parent segments.
String? epubResourcePath(String owner, String href) {
  final uri = Uri.tryParse(href);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  return Uri.decodeFull(Uri(path: owner).resolveUri(uri).path);
}

String? _resource(Map<String, String> files, String path) {
  if (files.containsKey(path)) return files[path];
  final matches = files.entries.where((e) => e.key.endsWith('/$path'));
  return matches.length == 1 ? matches.single.value : null;
}

ReaderChapter parseReaderChapter(String title, String rawHtml,
    {String documentPath = '', Map<String, String> styleSheets = const {}}) {
  // EPUB XHTML allows an empty <title/>. HTML treats title as raw text and
  // otherwise consumes the following body until a closing </title>, leaving
  // the chapter empty. Expand only this metadata element before HTML parsing.
  final source = rawHtml.replaceAllMapped(
      RegExp(r'<title\b([^<>]*?)/\s*>', caseSensitive: false),
      (match) => '<title${match.group(1)}></title>');
  final document = html_parser.parse(source);
  final spaced = <dom.Element>{};
  final visited = <String>{};
  final cssRules = RegExp(r'([^{}]+)\{([^{}]+)\}');
  final comments = RegExp(r'/\*[\s\S]*?\*/');
  final imports = RegExp(r'''@import\s+(?:url\(\s*)?["']?([^"'\s);]+)["']?\s*\)?[^;]*;''', caseSensitive: false);
  bool hasSpace(String declarations) {
    for (final declaration in declarations.split(';')) {
      final parts = declaration.split(':');
      if (parts.length != 2) continue;
      final property = parts.first.trim().toLowerCase();
      if (!RegExp(r'^(?:(?:min-)?height|(?:margin|padding)(?:-(?:top|bottom|block|block-start|block-end))?)$').hasMatch(property)) continue;
      final values = parts.last.replaceAll('!important', '').trim().split(RegExp(r'\s+'));
      // Horizontal-only shorthand spacing does not create a scene break.
      final vertical = (property == 'margin' || property == 'padding') && values.length > 1
          ? [values.first, if (values.length > 2) values[2]] : values;
      if (vertical.any((v) => (double.tryParse(RegExp(r'^[+]?\d*\.?\d+').stringMatch(v) ?? '') ?? 0) > 0)) return true;
    }
    return false;
  }

  void readCss(String css, String owner) {
    css = css.replaceAll(comments, '');
    for (final match in imports.allMatches(css)) {
      final path = epubResourcePath(owner, match.group(1)!);
      if (path != null && visited.add(path)) {
        final linked = _resource(styleSheets, path);
        if (linked != null) readCss(linked, path);
      }
    }
    css = css.replaceAll(imports, '');
    for (final rule in cssRules.allMatches(css)) {
      if (!hasSpace(rule.group(2)!)) continue;
      for (final selector in rule.group(1)!.split(',')) {
        try {
          spaced.addAll(document.querySelectorAll(selector.trim()));
        } on FormatException {
          // Unsupported publisher selectors must not prevent book import.
        }
      }
    }
  }

  for (final link in document.querySelectorAll('link[href]')) {
    if (!(link.attributes['rel'] ?? '').toLowerCase().split(RegExp(r'\s+')).contains('stylesheet')) continue;
    final path = epubResourcePath(documentPath, link.attributes['href']!);
    if (path != null && visited.add(path)) {
      final css = _resource(styleSheets, path);
      if (css != null) readCss(css, path);
    }
  }
  for (final style in document.querySelectorAll('style')) {
    readCss(style.text, documentPath);
  }
  for (final element in document.querySelectorAll('script, style, nav')) {
    element.remove();
  }
  final output = StringBuffer();
  final ranges = <StyledRange>[];
  final pending = StringBuffer();
  final pendingRanges = <StyledRange>[];
  bool previousHeading = false;
  bool scenePending = false;
  bool hasBlock = false;

  void flush({bool heading = false, bool scene = false}) {
    final raw = pending.toString();
    pending.clear();
    final clean = StringBuffer();
    final offsets = List<int>.filled(raw.length + 1, 0);
    final last = raw.trimRight().length;
    for (var i = 0; i < raw.length;) {
      final start = i;
      if (RegExp(r'\s').hasMatch(raw[i])) {
        while (i < raw.length && RegExp(r'\s').hasMatch(raw[i])) { i++; }
        if (clean.isNotEmpty && i <= last) clean.write(' ');
      } else {
        clean.write(raw[i]);
        i++;
      }
      for (var j = start + 1; j <= i; j++) { offsets[j] = clean.length; }
    }
    final text = clean.toString();
    if (text.isNotEmpty) {
      final prefix = !hasBlock ? '' : scenePending ? '\n\n\n' : heading ? '\n\n' : '\n';
      final indent = hasBlock && !heading && !previousHeading && !scenePending ? '　' : '';
      output.write(prefix);
      output.write(indent);
      final base = output.length;
      output.write(text);
      for (final range in pendingRanges) {
        final a = offsets[range.start], b = offsets[range.end];
        if (b > a) {
          ranges.add(StyledRange(base + a, base + b, italic: range.italic, bold: range.bold));
        }
      }
      if (heading) ranges.add(StyledRange(base, base + text.length, heading: true));
      hasBlock = true;
      previousHeading = heading;
      scenePending = false;
    }
    pendingRanges.clear();
    if (scene) scenePending = true;
  }

  void walk(dom.Node node, {bool italic = false, bool bold = false, bool heading = false}) {
    if (node is dom.Text) {
      final start = pending.length;
      pending.write(node.text);
      if ((italic || bold) && pending.length > start) {
        pendingRanges.add(StyledRange(start, pending.length, italic: italic, bold: bold));
      }
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName ?? '';
    if (tag == 'br') { flush(heading: heading); return; }
    final marker = ['class', 'epub:type', 'role'].map((key) => node.attributes[key] ?? '').join(' ');
    final semantic = RegExp(r'(?:^|[\s_-])(?:scene[\s_-]*break|section[\s_-]*break|thought[\s_-]*break|asterism|separator|ornament|dinkus|spacer)(?:$|[\s_-])', caseSensitive: false).hasMatch(marker);
    final empty = node.text.trim().isEmpty && node.querySelector('img, svg, image') == null;
    if (tag == 'hr' || (empty && (semantic || spaced.contains(node) || hasSpace(node.attributes['style'] ?? '')))) {
      flush();
      flush(scene: true);
      return;
    }
    final isHeading = heading || {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag);
    final isBlock = {'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote', 'pre', 'tr'}.contains(tag);
    if (isBlock && pending.isNotEmpty) flush();
    for (final child in node.nodes) {
      walk(child, italic: italic || tag == 'i' || tag == 'em', bold: bold || tag == 'b' || tag == 'strong', heading: isHeading);
    }
    if (isBlock) flush(heading: isHeading);
  }
  if (document.body != null) walk(document.body!);
  flush();
  return ReaderChapter(title, output.toString(), ranges);
}
