import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/narration_delivery.dart';
import 'package:audiobook_app/narration_storage.dart';

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

  NarrationDelivery create({Duration timeout = const Duration(seconds: 2)}) =>
      NarrationDelivery(
        documentsDirectory: () async => root,
        beforeReplace: (_, _) async {},
        clock: () => now,
        responseTimeout: timeout,
        idleTimeout: timeout,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('delivery-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = [];
    respond = audio;
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
      0: {'id': 'existing', 'status': 'generating'},
    };
    await delivery.save();
  });
  tearDown(() async {
    delivery.dispose();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test('discovers stored audio despite stale generation state; no generation or status request', () async {
    await delivery.reconcile();
    expect(requests, ['GET /dogreader/audio/existing']);
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

  test('normal generation polling reuses existing server recovery without POST or resubmit', () async {
    respond = (req) async {
      if (req.uri.path.contains('/audio/')) {
        req.response.statusCode = 404;
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'generating'}));
      }
      await req.response.close();
    };
    for (var i = 0; i < 8; i++) {
      await delivery.reconcile();
      now = now.add(const Duration(seconds: 12));
    }
    expect(delivery.books['book']![0]!['status'], 'generating');
    expect(delivery.books['book']![0]!['deliveryAttempts'], 0);
    expect(requests.where((r) => r.contains('/jobs/')).length, 8);
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
}
