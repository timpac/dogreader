import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ArticleHttpHeaders implements HttpHeaders {
  final values = <String, Object>{};
  @override
  ContentType? contentType;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;
  @override
  String? value(String name) => values[name]?.toString();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ArticleHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  ArticleHttpResponse(this.statusCode, String body) : bytes = utf8.encode(body);
  final List<int> bytes;
  @override
  final int statusCode;
  @override
  final headers = ArticleHttpHeaders();
  @override
  int get contentLength => bytes.length;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ArticleHttpRequest implements HttpClientRequest {
  ArticleHttpRequest(this.response);
  final ArticleHttpResponse response;
  final body = StringBuffer();
  @override
  final headers = ArticleHttpHeaders();
  @override
  bool followRedirects = true;
  @override
  void write(Object? value) => body.write(value);
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ArticleHttpClient implements HttpClient {
  ArticleHttpClient(this.response);
  final ArticleHttpResponse response;
  final requests = <ArticleHttpRequest>[];
  final urls = <Uri>[];
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    urls.add(url);
    final req = ArticleHttpRequest(response);
    requests.add(req);
    return req;
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
