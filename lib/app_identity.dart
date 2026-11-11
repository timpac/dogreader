const dogreaderExperimental = bool.fromEnvironment('DOGREADER_EXPERIMENTAL');
const dogreaderAppName = dogreaderExperimental ? 'Dog Reader 2.0' : 'Dogreader';
const dogreaderApplicationId = dogreaderExperimental
    ? 'com.example.audiobook_app.experimental'
    : 'com.example.audiobook_app';
const narrationNotificationChannel = '$dogreaderApplicationId.audio';

/// In the experimental app, consent is one submission for one chapter. It is
/// never persisted, restored, or shared with a timer/restart in another screen.
class ChapterGenerationConsent {
  final Set<int> _approved = {};
  void approve(int index) => _approved.add(index);
  bool take(int index) => !dogreaderExperimental || _approved.remove(index);
  void clear() => _approved.clear();
}

void requireNarrationRequestConsent(
  String method,
  String path, {
  required bool approved,
}) {
  if (!dogreaderExperimental || method == 'GET') return;
  if (method == 'POST' && path == '/dogreader/jobs' && approved) return;
  throw StateError(
    'Approve one chapter or preview before submitting paid cloud work.',
  );
}
