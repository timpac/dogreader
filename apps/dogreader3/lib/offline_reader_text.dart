/// Reader indentation is layout, not part of the next English word. A reader
/// newline + ideographic indent becomes the two-newline paragraph separator
/// understood by Misaki. Both forms occupy two UTF-16 units, preserving word
/// and dictionary offsets. Remaining ideographic spacing becomes ASCII space.
String offlineReaderText(String text) =>
    text.replaceAll('\n\u3000', '\n\n').replaceAll('\u3000', ' ');
