/// Reader indentation is layout, not part of the next English word. Replace
/// this one UTF-16 code unit with one ASCII space so dictionary/reader offsets
/// and paragraph boundaries remain valid. No letters or punctuation are dropped.
String offlineReaderText(String text) => text.replaceAll('\u3000', ' ');
