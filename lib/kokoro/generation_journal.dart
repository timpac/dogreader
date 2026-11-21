import 'dart:convert';
import 'dart:io';

class GenerationCancelled implements Exception {
  @override
  String toString() => 'Generation cancelled.';
}

/// Written synchronously by the inference isolate, never by the resumed UI.
class GenerationJournal {
  GenerationJournal(this.path, this.cancelPath) : clock = Stopwatch()..start();
  final String path, cancelPath;
  final Stopwatch clock;

  void checkCancellation() {
    if (File(cancelPath).existsSync()) throw GenerationCancelled();
  }

  void record(String event, [Map<String, dynamic> details = const {}]) {
    File(path).writeAsStringSync(
      '${jsonEncode({'event': event, 'utc': DateTime.now().toUtc().toIso8601String(), 'unixMs': DateTime.now().millisecondsSinceEpoch, 'workerMonotonicMs': clock.elapsedMilliseconds, 'pid': pid, ...details})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}
