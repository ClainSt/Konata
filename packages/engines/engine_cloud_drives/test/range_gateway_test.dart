import 'dart:async';
import 'dart:io';
import 'package:engine_cloud_drives/engine_cloud_drives.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

const _size = 24307308858;
const _start = 12149460125;
const _end = _start + 3;

final class _Protocol implements GuangYaProtocol {
  int links = 0;
  int size = _size;
  Map<String, String> headers = {};
  @override
  Future<List<GuangYaFile>> list(String parentId) async => [
    (id: 'fixture', name: 'sample.mkv', directory: false, size: size),
  ];
  @override
  Future<RenewableLink> link(String fileId) async => RenewableLink(
    Uri.https('cdn.example.invalid', '/fixture', {
      'generation': (++links).toString(),
    }),
    headers: headers,
  );
  @override
  Future<void> close() async {}
}

final class _Headers implements HttpHeaders {
  final Map<String, String> values = {};
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
  _Response(this.statusCode, Map<String, String> values, this.body) {
    values.forEach((name, value) => headers.set(name, value));
  }
  @override
  final int statusCode;
  @override
  final headers = _Headers();
  final Stream<List<int>> body;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  _Request(this.uri, this.response);
  @override
  final Uri uri;
  final _Response Function(_Request) response;
  @override
  final headers = _Headers();
  @override
  bool followRedirects = true;
  bool aborted = false;
  @override
  Future<HttpClientResponse> close() async => response(this);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Client implements HttpClient {
  _Client(this.respond);
  final _Response Function(_Request) respond;
  final requests = <_Request>[];
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  bool closed = false;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final req = _Request(url, respond);
    requests.add(req);
    return req;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_Response _partial({
  int status = 206,
  String? range,
  String? etag = '"v1"',
  String? encoding,
  List<List<int>> chunks = const [
    [1, 2],
    [3, 4],
  ],
}) => _Response(status, {
  HttpHeaders.contentRangeHeader: range ?? 'bytes $_start-$_end/$_size',
  HttpHeaders.etagHeader: ?etag,
  HttpHeaders.contentEncodingHeader: ?encoding,
}, Stream.fromIterable(chunks));

Future<ValidatedByteRangeStream> read(
  GuangYaGateway gateway, {
  String? validator,
}) => gateway.openValidatedByteRange(
  'sample.mkv',
  start: _start,
  endInclusive: _end,
  expectedStrongValidator: validator,
);

Future<List<int>> bytes(ValidatedByteRangeStream result) async =>
    (await result.stream.toList()).expand((chunk) => chunk).toList();

void main() {
  test('大文件精确偏移与过期换链后相同字节范围', () async {
    final protocol = _Protocol();
    final client = _Client((req) {
      expect(req.headers.value('range'), 'bytes=$_start-$_end');
      expect(req.headers.value('accept-encoding'), 'identity');
      expect(req.followRedirects, isFalse);
      if (req.uri.queryParameters['generation'] == '1') {
        return _partial(status: 403, chunks: []);
      }
      return _partial();
    });
    final gateway = GuangYaGateway(
      protocol: protocol,
      rootId: 'root',
      createHttpClient: () => client,
    );
    addTearDown(gateway.close);
    final result = await read(gateway);
    expect(await bytes(result), [1, 2, 3, 4]);
    expect(result.start, _start);
    expect(result.totalLength, _size);
    expect(result.strongValidator, '"v1"');
    expect(protocol.links, 2);
    expect(client.requests.length, 2);
    expect(client.autoUncompress, isFalse);
  });

  test('直链重复拒绝时仅换链一次', () async {
    final protocol = _Protocol();
    final client = _Client((_) => _partial(status: 410, chunks: []));
    final gateway = GuangYaGateway(
      protocol: protocol,
      rootId: 'root',
      createHttpClient: () => client,
    );
    addTearDown(gateway.close);
    await expectLater(
      read(gateway),
      throwsA(isA<TerminalSourceAuthException>()),
    );
    expect(protocol.links, 2);
    expect(client.requests.length, 2);
  });

  test('拒绝完整响应、重定向、错误范围、错误总长和压缩响应', () async {
    for (final response in [
      () => _partial(status: 200),
      () => _partial(status: 302),
      () => _partial(range: 'bytes 0-3/$_size'),
      () => _partial(range: 'bytes $_start-$_end/42'),
      () => _partial(encoding: 'gzip'),
    ]) {
      final protocol = _Protocol();
      final client = _Client((_) => response());
      final gateway = GuangYaGateway(
        protocol: protocol,
        rootId: 'root',
        createHttpClient: () => client,
      );
      try {
        await expectLater(
          read(gateway),
          throwsA(isA<UpstreamRangeMismatchException>()),
        );
        expect(client.requests.length, 1);
      } finally {
        await gateway.close();
      }
    }
  });

  test('强验证器发生变化或消失时拒绝续读', () async {
    for (final tag in ['"v2"', null, 'W/"v1"']) {
      final protocol = _Protocol();
      var calls = 0;
      final client = _Client(
        (_) => _partial(etag: ++calls == 1 ? '"v1"' : tag),
      );
      final gateway = GuangYaGateway(
        protocol: protocol,
        rootId: 'root',
        createHttpClient: () => client,
      );
      try {
        expect(await bytes(await read(gateway)), [1, 2, 3, 4]);
        await expectLater(
          read(gateway),
          throwsA(isA<UpstreamRangeMismatchException>()),
        );
      } finally {
        await gateway.close();
      }
    }
  });

  test('流式读取拒绝提前结束和超量字节', () async {
    for (final chunks in [
      [
        [1, 2],
      ],
      [
        [1, 2, 3, 4, 5],
      ],
    ]) {
      final client = _Client((_) => _partial(chunks: chunks));
      final gateway = GuangYaGateway(
        protocol: _Protocol(),
        rootId: 'root',
        createHttpClient: () => client,
      );
      try {
        final result = await read(gateway);
        await expectLater(
          bytes(result),
          throwsA(
            anyOf(
              isA<SourceAccessException>(),
              isA<UpstreamRangeMismatchException>(),
            ),
          ),
        );
      } finally {
        await gateway.close();
      }
    }
  });

  test('不许可请求头在发出请求前被拒绝', () async {
    final protocol = _Protocol()..headers = {'Authorization': 'fixture'};
    final client = _Client((_) => _partial());
    final gateway = GuangYaGateway(
      protocol: protocol,
      rootId: 'root',
      createHttpClient: () => client,
    );
    addTearDown(gateway.close);
    await expectLater(read(gateway), throwsA(isA<SourceAccessException>()));
    expect(client.requests, isEmpty);
  });

  test('同一文件大小变化时连续查询均拒绝旧会话', () async {
    final protocol = _Protocol();
    final gateway = GuangYaGateway(
      protocol: protocol,
      rootId: 'root',
      directoryCacheTtl: Duration.zero,
    );
    addTearDown(gateway.close);
    await gateway.upstreamFor('sample.mkv');
    protocol.size++;
    for (var i = 0; i < 2; i++) {
      await expectLater(
        gateway.upstreamFor('sample.mkv'),
        throwsA(isA<UpstreamRangeMismatchException>()),
      );
    }
  });

  test('网关关闭后已持有的直链会话不可继续使用', () async {
    final protocol = _Protocol();
    final gateway = GuangYaGateway(protocol: protocol, rootId: 'root');
    final upstream = await gateway.upstreamFor('sample.mkv');
    await upstream.current();
    await gateway.close();
    await expectLater(
      upstream.current(),
      throwsA(isA<SourceAccessException>()),
    );
    await expectLater(upstream.renew(), throwsA(isA<SourceAccessException>()));
    expect(protocol.links, 1);
  });
}
