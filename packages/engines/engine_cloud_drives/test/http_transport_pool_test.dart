import 'dart:async';
import 'dart:io';

import 'package:engine_cloud_drives/engine_cloud_drives.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

final class _Headers implements HttpHeaders {
  @override
  ContentType? contentType;
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  bool get isRedirect => false;
  @override
  final headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value([123, 125]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  @override
  final headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  void write(Object? obj) {}
  @override
  Future<HttpClientResponse> close() async => _Response();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Client implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  set findProxy(String Function(Uri)? value) {}
  bool closed = false;
  final requests = <_Request>[];
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = _Request();
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('十三页目录共用连接客户端，代理变化与退出释放连接', () async {
    var config = const KonataNetworkConfig(proxyMode: ProxyMode.none);
    final clients = <_Client>[];
    final transport = GuangYaHttpTransport(
      config: () => config,
      clientFactory: () {
        final client = _Client();
        clients.add(client);
        return client;
      },
    );
    addTearDown(transport.close);
    final uri = Uri.https(
      'api.guangyapan.com',
      '/userres/v1/file/get_file_list',
    );
    for (var i = 0; i < 13; i++) {
      final response = await transport.request(
        'POST',
        uri,
        {'Authorization': 'Bearer fixture-$i'},
        {'page': i},
      );
      expect(response.statusCode, 200);
    }
    expect(clients.length, 1);
    expect(clients.single.requests.length, 13);
    expect(clients.single.closed, isFalse);
    for (var i = 0; i < 13; i++) {
      expect(
        clients.single.requests[i].headers.value('authorization'),
        'Bearer fixture-$i',
      );
      expect(clients.single.requests[i].followRedirects, isFalse);
    }
    config = const KonataNetworkConfig(proxyMode: ProxyMode.system);
    await transport.request('POST', uri, {}, {});
    expect(clients.length, 2);
    expect(clients.first.closed, isTrue);
    expect(clients.last.requests.single.headers.value('authorization'), isNull);
    transport.close();
    expect(clients.last.closed, isTrue);
    await expectLater(
      transport.request('POST', uri, {}, {}),
      throwsA(isA<SourceAccessException>()),
    );
    expect(clients.length, 2);
  });
}
