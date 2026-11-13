import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/narration_delivery.dart';
import 'package:audiobook_app/narration_storage.dart';
import 'package:audiobook_app/media_diagnostics.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late NarrationDelivery delivery;
  late DateTime now;
  late List<String> requests;
  late Future<void> Function(HttpRequest) respond;
  final bytes = List<int>.filled(2200, 7);

  Future<void> audio(HttpRequest req) async {
    req.response.headers.contentType = ContentType('audio', 'mpeg');
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  NarrationDelivery create({
    Duration timeout = const Duration(seconds: 2),
    void Function(Map<String, Object?>)? diagnosticSink,
  }) => NarrationDelivery(
    documentsDirectory: () async => root,
    beforeReplace: (_, _) async {},
    clock: () => now,
    responseTimeout: timeout,
    idleTimeout: timeout,
    diagnosticSink: diagnosticSink,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('delivery-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = [];
    respond = (req) async {
      if (req.uri.path.startsWith('/dogreader/jobs/')) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'ready'}));
        await req.response.close();
      } else {
        await audio(req);
      }
    };
    server.listen((req) {
      requests.add('${req.method} ${req.uri.path}');
      unawaited(respond(req).catchError((Object _) {}));
    });
    now = DateTime.utc(2026, 11, 11);
    delivery = create();
    await delivery.load();
    delivery.host = 'http://127.0.0.1:${server.port}';
    delivery.token = 'TEST_PRIVATE_TOKEN';
    delivery.books['book'] = {
      0: {'id': 'existing', 'status': 'ready'},
    };
    await delivery.save();
  });
  tearDown(() async {
    delivery.dispose();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test('status discovers stored audio despite stale generation state without submission', () async {
    delivery.books['book']![0]!['status'] = 'generating';
    await delivery.reconcile();
    expect(requests, [
      'GET /dogreader/jobs/existing',
      'GET /dogreader/audio/existing',
    ]);
    expect(delivery.books['book']![0]!['delivery'], 'downloaded');
    expect(await (await delivery.audioFile('book', 0)).readAsBytes(), bytes);
    expect(delivery.diagnostics.join(), isNot(contains('TEST_PRIVATE_TOKEN')));
  });

  test('manual retry makes only audio GET, including 404, and preserves old audio and position', () async {
    final target = await delivery.audioFile('book', 0);
    await target.parent.create();
    await target.writeAsBytes(List.filled(1300, 3));
    final state = File('${root.path}/narration_state.json');
    await state.writeAsString(
      jsonEncode({
        'book:0': {'path': target.path, 'positionMs': 17000},
        'other:2': {'positionMs': 12},
      }),
    );
    respond = (req) async {
      req.response.statusCode = 404;
      await req.response.close();
    };
    await expectLater(
      delivery.retryDownload('book', 0),
      throwsA(isA<DeliveryHttpError>()),
    );
    expect(requests, ['GET /dogreader/audio/existing']);
    expect(await target.readAsBytes(), List.filled(1300, 3));
    expect(delivery.books['book']![0]!['localAvailable'], isTrue);
    respond = audio;
    await delivery.retryDownload('book', 0);
    final saved = jsonDecode(await state.readAsString()) as Map;
    expect(saved['book:0']['positionMs'], 17000);
    expect(saved['other:2']['positionMs'], 12);
    expect(requests.every((r) => r == 'GET /dogreader/audio/existing'), isTrue);
  });

  test('truncated transfer is never published; restarts retry from durable ID after backoff', () async {
    respond = (req) async {
      req.response.contentLength = bytes.length;
      req.response.add(bytes.take(1100).toList());
      final socket = await req.response.detachSocket();
      socket.destroy();
    };
    await delivery.reconcile();
    final target = await delivery.audioFile('book', 0);
    expect(await target.exists(), isFalse);
    expect(await File('${target.path}.part').exists(), isFalse);
    expect(delivery.books['book']![0]!['delivery'], 'failed');
    delivery.dispose();
    delivery = create();
    await delivery.load();
    final count = requests.length;
    await delivery.reconcile();
    expect(requests.length, count);
    respond = audio;
    now = now.add(const Duration(minutes: 1));
    await delivery.reconcile();
    expect(await target.readAsBytes(), bytes);
    expect(delivery.books['book']![0]!['delivery'], 'downloaded');
  });

  test('deduplicates overlapping resume, polling and manual retry', () async {
    final arrived = Completer<void>(), release = Completer<void>();
    respond = (req) async {
      arrived.complete();
      await release.future;
      await audio(req);
    };
    final first = delivery.retryDownload('book', 0);
    await arrived.future;
    final second = delivery.retryDownload('book', 0);
    final reconcile = delivery.reconcile();
    var prepared = false;
    final preparation = delivery
        .waitForDownload('book', 0)
        .then((_) => prepared = true);
    await Future<void>.delayed(Duration.zero);
    expect(prepared, isFalse);
    release.complete();
    await Future.wait([first, second, reconcile, preparation]);
    expect(prepared, isTrue);
    expect(requests, ['GET /dogreader/audio/existing']);
  });

  test('stalled responses enter durable cooldown; automatic delivery recovers later', () async {
    delivery.dispose();
    delivery = create(timeout: const Duration(milliseconds: 80));
    await delivery.load();
    respond = (_) async {};
    for (var i = 0; i < NarrationDelivery.maxAttempts + 2; i++) {
      await delivery.reconcile();
      if (i < NarrationDelivery.maxAttempts - 1) {
        now = DateTime.fromMillisecondsSinceEpoch(
          delivery.books['book']![0]!['deliveryNextAttempt'] as int,
        );
      }
    }
    expect(requests.length, NarrationDelivery.maxAttempts);
    delivery.dispose();
    delivery = create();
    await delivery.reconcile();
    expect(requests.length, NarrationDelivery.maxAttempts);
    respond = audio;
    now = now.add(const Duration(minutes: 15));
    await delivery.reconcile();
    expect(delivery.books['book']![0]!['delivery'], 'downloaded');
    expect(requests.length, NarrationDelivery.maxAttempts + 1);
  });

  test('known completed recording never polls the dispatching status endpoint after delivery failure', () async {
    delivery.books['book']![0]!['status'] = 'ready';
    respond = (req) async {
      req.response.statusCode = 404;
      await req.response.close();
    };
    await delivery.reconcile();
    expect(requests, ['GET /dogreader/audio/existing']);
    expect(delivery.books['book']![0]!['failureStage'], 'download');
  });

  test('app startup and resume reconcile without opening the queue', () async {
    delivery.setActive(true);
    await delivery.reconcile();
    expect(delivery.books['book']![0]!['delivery'], 'downloaded');
    delivery.setActive(false);
    delivery.books['book']![1] = {'id': 'second', 'status': 'queued'};
    await delivery.save();
    delivery.setActive(true);
    await delivery.reconcile();
    expect(delivery.books['book']![1]!['delivery'], 'downloaded');
    expect(requests, [
      'GET /dogreader/audio/existing',
      'GET /dogreader/jobs/second',
      'GET /dogreader/audio/second',
    ]);
  });

  test('stalled response body cannot publish partial audio', () async {
    delivery.dispose();
    delivery = create(timeout: const Duration(milliseconds: 80));
    await delivery.load();
    respond = (req) async {
      req.response.headers.contentType = ContentType('audio', 'mpeg');
      req.response.contentLength = bytes.length;
      await req.response.flush();
    };
    await expectLater(
      delivery.retryDownload('book', 0),
      throwsA(isA<TimeoutException>()),
    );
    final target = await delivery.audioFile('book', 0);
    expect(await target.exists(), isFalse);
    expect(await File('${target.path}.part').exists(), isFalse);
  });

  test('normal generation polling never announces downloading or failure and shows actual progress', () async {
    delivery.books['book']![0]!['status'] = 'generating';
    final states = <String?>[];
    delivery.addListener(
      () => states.add(delivery.books['book']![0]!['delivery'] as String?),
    );
    respond = (req) async {
      if (req.uri.path.contains('/audio/')) {
        req.response.statusCode = 404;
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({'status': 'generating', 'progress': 8, 'chunks': 31}),
        );
      }
      await req.response.close();
    };
    for (var i = 0; i < 8; i++) {
      await delivery.reconcile();
      now = now.add(const Duration(seconds: 12));
    }
    expect(delivery.books['book']![0]!['status'], 'generating');
    expect(delivery.books['book']![0]!['deliveryAttempts'], 0);
    expect(requests, List.filled(8, 'GET /dogreader/jobs/existing'));
    expect(states, isNot(contains('downloading')));
    expect(states, isNot(contains('failed')));
    expect(
      narrationDeliveryLabel(delivery.books['book']![0]),
      contains('8/31 chunks complete'),
    );
    expect(canRetryNarrationDownload(delivery.books['book']![0]), isFalse);
    expect(requests.every((r) => r.startsWith('GET ')), isTrue);
  });

  test('process death while downloading discards partial bytes and discovers completed audio on reopen', () async {
    delivery.books['book']![0]!.addAll({
      'delivery': 'downloading',
      'status': 'ready',
    });
    await delivery.save();
    final target = await delivery.audioFile('book', 0);
    await target.parent.create();
    await File('${target.path}.part').writeAsBytes(List.filled(1400, 2));
    delivery.dispose();
    delivery = create();
    await delivery.reconcile();
    expect(await target.readAsBytes(), bytes);
    expect(await File('${target.path}.part').exists(), isFalse);
  });

  test('serialized download metadata and playback position writes retain both updates', () async {
    final state = File('${root.path}/narration_state.json');
    await state.writeAsString(
      jsonEncode({
        'book:0': {'positionMs': 9000},
        'other:0': {'positionMs': 1},
      }),
    );
    await Future.wait([
      delivery.retryDownload('book', 0),
      updateNarrationJson(state, (data) {
        (data['book:0'] as Map)['positionMs'] = 22000;
      }),
    ]);
    final saved = jsonDecode(await state.readAsString()) as Map;
    expect(saved['book:0']['positionMs'], 22000);
    expect(saved['book:0']['recording_id'], 'existing');
    expect(saved['other:0']['positionMs'], 1);
  });

  test('waiting remains visible until accepted audio headers, then downloads automatically', () async {
    delivery.books['book']![0]!['status'] = 'generating';
    final arrived = Completer<void>(), headers = Completer<void>();
    var polls = 0;
    final states = <String?>[];
    delivery.addListener(
      () => states.add(delivery.books['book']![0]!['delivery'] as String?),
    );
    respond = (req) async {
      if (req.uri.path.contains('/jobs/')) {
        polls++;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(
            polls == 1
                ? {'status': 'queued', 'progress': 15, 'chunks': 31}
                : {'status': 'ready'},
          ),
        );
        await req.response.close();
      } else {
        arrived.complete();
        await headers.future;
        await audio(req);
      }
    };
    await delivery.reconcile();
    expect(
      narrationDeliveryLabel(delivery.books['book']![0]),
      'Queued in cloud • 15/31 chunks complete',
    );
    expect(requests, ['GET /dogreader/jobs/existing']);
    // Emulate a process restart without creating a generation-screen widget.
    delivery.dispose();
    delivery = create();
    await delivery.load();
    delivery.addListener(
      () => states.add(delivery.books['book']![0]!['delivery'] as String?),
    );
    now = now.add(const Duration(seconds: 12));
    final pending = delivery.reconcile();
    await arrived.future;
    expect(
      narrationDeliveryLabel(delivery.books['book']![0]),
      'Waiting to download',
    );
    expect(delivery.deliveryInFlight('book', 0), isTrue);
    expect(delivery.downloading('book', 0), isFalse);
    expect(states, isNot(contains('downloading')));
    expect(states, isNot(contains('failed')));
    headers.complete();
    await pending;
    expect(states, contains('downloading'));
    expect(delivery.books['book']![0]!['delivery'], 'downloaded');
    expect(requests, [
      'GET /dogreader/jobs/existing',
      'GET /dogreader/jobs/existing',
      'GET /dogreader/audio/existing',
    ]);
  });

  test('opening the queue during an active transfer preserves its job and actual downloading state', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    delivery.addListener(() {
      if (delivery.downloading('book', 0) && !started.isCompleted) {
        started.complete();
      }
    });
    respond = (req) async {
      req.response.headers.contentType = ContentType('audio', 'mpeg');
      req.response.contentLength = bytes.length;
      req.response.add(bytes.take(100).toList());
      await req.response.flush();
      await release.future;
      req.response.add(bytes.skip(100).toList());
      await req.response.close();
    };
    final live = delivery.books['book']![0]!;
    final transfer = delivery.retryDownload('book', 0);
    await started.future;
    final stale = <int, Map<String, dynamic>>{
      0: {'id': 'existing', 'status': 'ready', 'delivery': 'server_ready'},
    };
    delivery.attachBook('book', stale);
    expect(identical(stale[0], live), isTrue);
    expect(delivery.downloading('book', 0), isTrue);
    final joined = delivery.retryDownload('book', 0);
    expect(identical(transfer, joined), isTrue);
    release.complete();
    await transfer;
    expect(stale[0]!['delivery'], 'downloaded');
    expect(await (await delivery.audioFile('book', 0)).readAsBytes(), bytes);
    expect(requests, ['GET /dogreader/audio/existing']);
  });

  test('manual 404 for unfinished audio stays pending and never polls or submits jobs', () async {
    delivery.books['book']![0]!['status'] = 'generating';
    final states = <String?>[];
    delivery.addListener(
      () => states.add(delivery.books['book']![0]!['delivery'] as String?),
    );
    respond = (req) async {
      req.response.statusCode = 404;
      await req.response.close();
    };
    await delivery.retryDownload('book', 0);
    final job = delivery.books['book']![0]!;
    expect(requests, ['GET /dogreader/audio/existing']);
    expect(job['status'], 'generating');
    expect(job['delivery'], 'pending');
    expect(job['deliveryAttempts'], 0);
    expect(job['failureStage'], isNull);
    expect(states, isNot(contains('downloading')));
    expect(states, isNot(contains('failed')));
    expect(DeliveryHttpError(404).toString(), 'HTTP 404');
  });

  test('missing legacy status falls back quietly and recovers the existing recording', () async {
    delivery.books['book']![0]!['status'] = 'queued';
    final states = <String?>[];
    delivery.addListener(
      () => states.add(delivery.books['book']![0]!['delivery'] as String?),
    );
    respond = (req) async {
      if (req.uri.path.contains('/jobs/')) {
        req.response.statusCode = 404;
        await req.response.close();
      } else {
        await audio(req);
      }
    };
    await delivery.reconcile();
    expect(requests, [
      'GET /dogreader/jobs/existing',
      'GET /dogreader/audio/existing',
    ]);
    expect(delivery.books['book']![0]!['delivery'], 'downloaded');
    expect(states, isNot(contains('failed')));
  });

  test('legacy status and audio both missing remain pending without download failures', () async {
    delivery.books['book']![0]!['status'] = 'queued';
    respond = (req) async {
      req.response.statusCode = 404;
      await req.response.close();
    };
    await delivery.reconcile();
    expect(delivery.books['book']![0]!['delivery'], 'pending');
    expect(delivery.books['book']![0]!['deliveryAttempts'], 0);
    expect(requests.every((r) => r.startsWith('GET ')), isTrue);
  });

  test('status outage backs off across restart and automatically downloads after recovery', () async {
    delivery.books['book']![0]!['status'] = 'generating';
    respond = (req) async {
      req.response.statusCode = 503;
      await req.response.close();
    };
    await delivery.reconcile();
    expect(delivery.books['book']![0]!['failureStage'], 'status');
    expect(delivery.books['book']![0]!['status'], 'generating');
    final count = requests.length;
    delivery.dispose();
    delivery = create();
    await delivery.reconcile();
    expect(requests.length, count);
    respond = (req) async {
      if (req.uri.path.contains('/jobs/')) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'ready'}));
        await req.response.close();
      } else {
        await audio(req);
      }
    };
    now = now.add(const Duration(seconds: 15));
    await delivery.reconcile();
    expect(delivery.books['book']![0]!['delivery'], 'downloaded');
    expect(requests.every((r) => r.startsWith('GET ')), isTrue);
  });

  test(
    'build-143 false 404 failure is normalized when restored or attached',
    () async {
      final jobs = <int, Map<String, dynamic>>{
        0: {
          'id': 'existing',
          'status': 'generating',
          'delivery': 'failed',
          'deliveryError': 'Download HTTP 404',
          'deliveryAttempts': 6,
          'deliveryNextAttempt': now
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        },
      };
      delivery.attachBook('book', jobs);
      expect(jobs[0]!['delivery'], 'pending');
      expect(jobs[0]!['deliveryAttempts'], 0);
      expect(jobs[0]!['deliveryNextAttempt'], isNull);
      expect(narrationDeliveryLabel(jobs[0]), 'Generating…');
    },
  );

  test('delivery diagnostics persist job IDs, transitions, HTTP codes and retry modes without content', () async {
    final journal = MediaDiagnostics(
      directory: () async => Directory('${root.path}/logs'),
    );
    delivery.dispose();
    delivery = create(
      diagnosticSink: (fields) =>
          journal.record(MediaDiagnosticEvent.narrationDelivery, fields),
    );
    await delivery.load();
    const id = '0123456789abcdef0123456789abcdef';
    delivery.books.clear();
    delivery.books['Private book title'] = {
      0: {'id': id, 'status': 'ready', 'text': 'Sensitive chapter'},
    };
    respond = (req) async {
      req.response.statusCode = 503;
      req.response.write('Sensitive chapter TEST_PRIVATE_TOKEN');
      await req.response.close();
    };
    await expectLater(
      delivery.retryDownload('Private book title', 0),
      throwsA(isA<DeliveryHttpError>()),
    );
    respond = audio;
    now = now.add(const Duration(seconds: 15));
    await delivery.reconcile();
    await journal.flush();
    final reopened = MediaDiagnostics(
      directory: () async => Directory('${root.path}/logs'),
    );
    final exported = await reopened.export();
    expect(exported, contains(id));
    expect(exported, contains('"httpStatus":503'));
    expect(exported, contains('"retryMode":"manual"'));
    expect(exported, contains('"retryMode":"automatic"'));
    expect(exported, contains('"fromDeliveryState":"failed"'));
    expect(exported, contains('"deliveryState":"downloaded"'));
    for (final secret in [
      'Private book title',
      'Sensitive chapter',
      'TEST_PRIVATE_TOKEN',
      delivery.host,
    ]) {
      expect(exported, isNot(contains(secret)));
      expect(delivery.diagnostics.join(), isNot(contains(secret)));
    }
  });

  test('labels distinguish generation, readiness, transfer and retryable failure using valid counts only', () {
    expect(
      narrationDeliveryLabel({
        'status': 'generating',
        'progress': 7,
        'chunks': 31,
      }),
      'Generating… • 7/31 chunks complete',
    );
    expect(
      narrationDeliveryLabel({
        'status': 'generating',
        'progress': 32,
        'chunks': 31,
      }),
      'Generating…',
    );
    expect(
      narrationDeliveryLabel({'status': 'generating', 'progress': 0}),
      'Generating…',
    );
    expect(
      narrationDeliveryLabel({'status': 'ready', 'delivery': 'server_ready'}),
      'Waiting to download',
    );
    expect(
      narrationDeliveryLabel({'status': 'ready', 'delivery': 'downloading'}),
      'Downloading…',
    );
    expect(
      narrationDeliveryLabel({
        'status': 'ready',
        'delivery': 'failed',
        'deliveryError': 'Download HTTP 503',
      }),
      contains('Retrying automatically.'),
    );
    expect(
      canRetryNarrationDownload({'id': 'existing', 'status': 'generating'}),
      isFalse,
    );
    expect(
      canRetryNarrationDownload({'id': 'existing', 'status': 'ready'}),
      isTrue,
    );
  });
}
