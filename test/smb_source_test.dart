import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:smb_connect/smb_connect.dart';
import 'package:ccplayer/core/sources.dart';

class FakeSmb extends Fake implements SmbConnect {
  bool closed = false;
  String? requested;
  @override
  Future<SmbFile> file(String path) async {
    requested = path;
    return SmbFile(path, path, 'share', 0, 0, 0, 0, 10, true);
  }

  @override
  Future<List<SmbFile>> listFiles(
    SmbFile folder, [
    String wildcard = '*',
  ]) async => [
    SmbFile('/share/中文 文件.mkv', '', 'share', 0, 0, 0, 0, 10, true),
    SmbFile('/share/子目录', '', 'share', 0, 0, 0, 16, 0, true),
  ];
  @override
  Future<Stream<Uint8List>> openRead(
    SmbFile file, [
    int? start,
    int? end,
  ]) async => Stream.value(
    Uint8List.fromList(
      List.generate(10, (i) => i).sublist(start ?? 0, end ?? 10),
    ),
  );
  @override
  Future<void> close() async {
    closed = true;
  }
}

class ClosedPeerSmb extends FakeSmb {
  @override
  Future<void> close() async {
    closed = true;
    throw StateError('peer already closed');
  }
}

class InterruptedReadSmb extends FakeSmb {
  @override
  Future<SmbFile> file(String path) async =>
      SmbFile(path, path, 'share', 0, 0, 0, 0, 131072, true);
  @override
  Future<Stream<Uint8List>> openRead(
    SmbFile file, [
    int? start,
    int? end,
  ]) async => _chunks();
  Stream<Uint8List> _chunks() async* {
    yield Uint8List(65536);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    throw const SocketException('SMB peer disconnected during body');
  }
}

class PendingReadSmb extends InterruptedReadSmb {
  final chunks = StreamController<Uint8List>();
  int closeCount = 0;
  @override
  Future<Stream<Uint8List>> openRead(
    SmbFile file, [
    int? start,
    int? end,
  ]) async {
    chunks.onListen = () => chunks.add(Uint8List(65536));
    return chunks.stream;
  }

  @override
  Future<void> close() async {
    closeCount++;
    closed = true;
    chunks.addError(const SocketException('cancelled'));
    await chunks.close();
  }
}

void main() {
  test(
    'SMB ticket close interrupts its body and closes the client once',
    () async {
      final client = PendingReadSmb();
      final source = SmbSource({
        'location': 'smb://nas/share',
      }, connector: () async => client);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final served = server.first.then((request) {
        request.response.bufferOutput = false;
        return source.serve(request, 'clip.mkv');
      });
      final http = HttpClient();
      try {
        final response = await (await http.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/clip'),
        )).close();
        final first = Completer<void>();
        final body = response.map((chunk) {
          if (!first.isCompleted) first.complete();
          return chunk;
        }).drain<void>();
        final interrupted = expectLater(body, throwsA(isA<HttpException>()));
        await first.future;
        source.close();
        source.close();
        await interrupted.timeout(const Duration(seconds: 3));
        await served.timeout(const Duration(seconds: 3));
        expect(client.closeCount, 1);
      } finally {
        http.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'SMB ticket revoked during connect releases the eventual client',
    () async {
      final connecting = Completer<SmbConnect>();
      final entered = Completer<void>();
      final client = FakeSmb();
      final source = SmbSource(
        {'location': 'smb://nas/share'},
        connector: () {
          entered.complete();
          return connecting.future;
        },
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final served = server.first.then(
        (request) => source.serve(request, 'clip.mkv'),
      );
      final http = HttpClient();
      try {
        final response = (await http.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/clip'),
        )).close();
        await entered.future;
        source.close();
        connecting.complete(client);
        final result = await response.timeout(const Duration(seconds: 3));
        expect(result.statusCode, HttpStatus.badGateway);
        await result.drain<void>();
        await served;
        expect(client.closed, isTrue);
        expect(client.requested, isNull);
      } finally {
        http.close(force: true);
        await server.close(force: true);
      }
    },
  );
  test(
    'SMB mid-body failure aborts the response and still releases the client',
    () async {
      final client = InterruptedReadSmb();
      final source = SmbSource({
        'location': 'smb://nas/share',
      }, connector: () async => client);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final served = server.first.then((request) {
        request.response.bufferOutput = false;
        return source.serve(request, 'clip.mkv');
      });
      final http = HttpClient();
      try {
        final response = await (await http.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/clip'),
        )).close();
        await expectLater(
          response.drain<void>(),
          throwsA(isA<HttpException>()),
        );
        await served;
        expect(client.closed, isTrue);
      } finally {
        http.close(force: true);
        await server.close(force: true);
      }
    },
  );
  test('SMB response cleanup tolerates an already closed peer', () async {
    final client = ClosedPeerSmb();
    final source = SmbSource({
      'location': 'smb://nas/share',
    }, connector: () async => client);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final served = server.first.then(
      (request) => source.serve(request, 'clip.mkv'),
    );
    final http = HttpClient();
    try {
      final response = await (await http.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/clip'),
      )).close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      await served;
      expect(client.closed, isTrue);
    } finally {
      http.close(force: true);
      await server.close(force: true);
    }
  });
  test(
    'SMB validates share URLs and rejects embedded credentials and traversal',
    () {
      expect(SmbSource.validateLocation('smb://nas/share/动画').host, 'nas');
      for (final url in [
        'https://nas/share',
        'smb://nas',
        'smb://u:p@nas/share',
        'smb://nas/share/../other',
        'smb://nas:139/share',
      ]) {
        expect(() => SmbSource.validateLocation(url), throwsArgumentError);
      }
      expect(
        WebDav({'kind': 'smb', 'location': 'smb://nas/share'}),
        isA<SmbSource>(),
      );
    },
  );

  test(
    'SMB directory adapter preserves Unicode names and closes connection',
    () async {
      final client = FakeSmb();
      final source = SmbSource({
        'location': 'smb://nas/share',
      }, connector: () async => client);
      final rows = await source.list(source.directoryUri('动画'));
      expect(client.requested, '/share/动画');
      expect(rows.first.name, '中文 文件.mkv');
      expect(rows.first.uri.pathSegments.last, '中文 文件.mkv');
      expect(rows.last.isDirectory, isTrue);
      expect(client.closed, isTrue);
    },
  );

  test(
    'SMB playback proxy streams byte ranges, suffixes, HEAD and invalid ranges',
    () async {
      final clients = <FakeSmb>[];
      final source = SmbSource(
        {'location': 'smb://nas/share'},
        connector: () async {
          final client = FakeSmb();
          clients.add(client);
          return client;
        },
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final pending = <Future<void>>[];
      server.listen((request) {
        pending.add(source.serve(request, 'movie.mkv'));
      });
      final http = HttpClient();
      try {
        for (final entry in [
          ('GET', null, 200, List.generate(10, (i) => i)),
          ('GET', 'bytes=3-5', 206, [3, 4, 5]),
          ('GET', 'bytes=-2', 206, [8, 9]),
          ('HEAD', 'bytes=3-', 206, <int>[]),
          ('GET', 'bytes=99-', 416, <int>[]),
        ]) {
          final request = await http.openUrl(
            entry.$1,
            Uri.parse('http://127.0.0.1:${server.port}/video'),
          );
          if (entry.$2 != null) {
            request.headers.set(HttpHeaders.rangeHeader, entry.$2!);
          }
          final response = await request.close();
          expect(response.statusCode, entry.$3);
          if (entry.$1 == 'GET' && entry.$3 != 416) {
            expect(response.persistentConnection, isFalse);
          }
          expect(
            await response.fold<List<int>>([], (a, b) => a..addAll(b)),
            entry.$4,
          );
        }
        await Future.wait(pending);
        expect(clients.every((c) => c.closed), isTrue);
      } finally {
        http.close(force: true);
        await server.close(force: true);
      }
    },
  );
}
