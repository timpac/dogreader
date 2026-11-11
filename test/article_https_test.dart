import 'dart:convert';
import 'dart:io';

import 'package:audiobook_app/article_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pinned HTTPS uses TLS and verifies the requested DNS name', () async {
    final serverContext = SecurityContext()
      ..useCertificateChain('test/fixtures/article_tls/localhost-cert.pem')
      ..usePrivateKey('test/fixtures/article_tls/localhost-key.pem');
    final trusted = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/article_tls/localhost-cert.pem');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    final subscription = server.listen((request) async {
      request.response.write('secure article transport');
      await request.response.close();
    }, onError: (Object _) {}); // Expected rejected client handshakes below.
    final address = (await InternetAddress.lookup(
      'localhost',
      type: InternetAddressType.IPv4,
    )).first;
    Future<String> request(
      String host,
      InternetAddress pinned,
      SecurityContext? context,
    ) async {
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, proxyHost, proxyPort) =>
          connectValidatedArticleAddress(uri, pinned, context: context);
      try {
        final request = await client.getUrl(
          Uri.parse('https://$host:${server.port}/article'),
        );
        final response = await request.close();
        return await utf8.decoder.bind(response).join();
      } finally {
        client.close(force: true);
      }
    }

    try {
      expect(
        await request(
          'localhost',
          address,
          trusted,
        ).timeout(const Duration(seconds: 3)),
        'secure article transport',
      );
      // Trusting a CA must not disable hostname verification: this certificate
      // covers localhost, not the numeric IP used in the second URI.
      await expectLater(
        request('127.0.0.1', InternetAddress.loopbackIPv4, trusted),
        throwsA(isA<HandshakeException>()),
      );
      await expectLater(
        request('localhost', address, null),
        throwsA(isA<HandshakeException>()),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('pinned HTTP remains usable without TLS', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.write('plain HTTP');
      await request.response.close();
    });
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        connectValidatedArticleAddress(uri, InternetAddress.loopbackIPv4);
    try {
      final response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}'),
      )).close();
      expect(await utf8.decoder.bind(response).join(), 'plain HTTP');
    } finally {
      client.close(force: true);
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
