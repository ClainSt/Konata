import 'dart:async';
import 'dart:io';
import 'package:ccplayer/core/webdav_stream.dart';
import 'package:ccplayer/core/debug_log.dart';
import 'package:flutter_test/flutter_test.dart';

class Fixture {
  Fixture(this.origin, this.proxy, this.relay);
  final HttpServer origin, proxy;
  final WebDavStream relay;
  final client = HttpClient()..autoUncompress = false;
  static Future<Fixture> start(
    Future<void> Function(HttpRequest) handler, {
    String? auth,
    Duration headerTimeout = const Duration(seconds: 15),
  }) async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((r) async {
      try {
        await handler(r);
      } catch (_) {
        try {
          await r.response.close();
        } catch (_) {}
      }
    });
    final relay = WebDavStream(
      target: Uri.parse(
        'http://127.0.0.1:${origin.port}/private/movie.mkv?token=secret',
      ),
      authorization: auth,
      headerTimeout: headerTimeout,
    );
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen(relay.serve);
    return Fixture(origin, proxy, relay);
  }

  Future<HttpClientResponse> request({
    String? range,
    String method = 'GET',
  }) async {
    final r = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${proxy.port}/ticket'),
    );
    if (range != null) r.headers.set('Range', range);
    return r.close().timeout(const Duration(seconds: 3));
  }

  Future<void> close() async {
    relay.close();
    client.close(force: true);
    await proxy.close(force: true);
    await origin.close(force: true);
  }
}

Future<List<int>> body(HttpClientResponse r) => r
    .fold<List<int>>([], (a, b) => a..addAll(b))
    .timeout(const Duration(seconds: 3));
void main() {
  test(
    'completed ranges reuse one connection until its idle timeout',
    () async {
      final ports = <int>[];
      final f = await Fixture.start((r) async {
        ports.add(r.connectionInfo!.remotePort);
        r.response.statusCode = 206;
        r.response.headers.set('content-range', 'bytes 0-3/100');
        r.response.contentLength = 4;
        r.response.add([0, 1, 2, 3]);
        await r.response.close();
      });
      Future<void> read() async {
        expect(await body(await f.request(range: 'bytes=0-3')), [0, 1, 2, 3]);
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return f.relay.activeRequests != 0;
        }).timeout(const Duration(seconds: 2));
      }

      try {
        await read();
        await read();
        expect(ports[1], ports[0]);
        await Future<void>.delayed(const Duration(milliseconds: 5200));
        await read();
        expect(ports[2], isNot(ports[1]));
        final head = await f.request(range: 'bytes=0-3', method: 'HEAD');
        expect(head.statusCode, 206);
        expect(await body(head), isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await read();
        expect(ports[3], ports[2]);
        expect(ports[4], ports[2]);
        expect(f.origin.connectionsInfo().total, 1);
        f.relay.close();
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return f.origin.connectionsInfo().total != 0;
        }).timeout(const Duration(seconds: 2));
        expect((await f.request()).statusCode, 410);
        expect(ports, hasLength(5));
      } finally {
        await f.close();
      }
    },
  );

  test('cancelling one leased connection leaves another read usable', () async {
    final release = Completer<void>();
    final ports = <int>[];
    final f = await Fixture.start((r) async {
      ports.add(r.connectionInfo!.remotePort);
      r.response.contentLength = 8;
      r.response.add([0, 1, 2, 3]);
      await r.response.flush();
      await release.future;
      r.response.add([4, 5, 6, 7]);
      await r.response.close();
    });
    final aborting = HttpClient();
    try {
      final request = await aborting.getUrl(
        Uri.parse('http://127.0.0.1:${f.proxy.port}/ticket'),
      );
      final first = await request.close();
      final subscription = first.listen((_) {}, onError: (Object _) {});
      final second = await f.request();
      final completed = body(second);
      expect(ports.toSet(), hasLength(2));
      aborting.close(force: true);
      await subscription.cancel();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return f.relay.activeRequests > 1;
      }).timeout(const Duration(seconds: 2));
      expect(f.relay.activeRequests, 1);
      release.complete();
      expect(await completed, List.generate(8, (i) => i));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await body(await f.request()), List.generate(8, (i) => i));
      expect(ports.last, ports[1]);
    } finally {
      if (!release.isCompleted) release.complete();
      aborting.close(force: true);
      await f.close();
    }
  });

  test(
    'downstream disconnect releases a stalled upstream without ticket-wide cancellation',
    () async {
      final release = Completer<void>();
      final f = await Fixture.start((r) async {
        r.response.contentLength = 1000000;
        r.response.add(List.filled(32768, 1));
        await r.response.flush();
        await release.future;
        await r.response.close();
      });
      try {
        final response = await f.request();
        final subscription = response.listen((_) {}, onError: (Object _) {});
        f.client.close(force: true);
        await subscription.cancel();
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (f.relay.activeRequests != 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(f.relay.activeRequests, 0);
      } finally {
        release.complete();
        await f.close();
      }
    },
  );

  test(
    'parallel repeated seeks stay byte exact and diagnostics expose no resource identity',
    () async {
      final dir = await Directory.systemTemp.createTemp('ccplayer-stream-log-');
      final enabled = DebugLog.enabled, previous = DebugLog.directory;
      DebugLog.enabled = true;
      DebugLog.directory = dir;
      final f = await Fixture.start((r) async {
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(r.headers.value('range')!)![1]!,
        );
        r.response.statusCode = 206;
        r.response.headers.set(
          'content-range',
          'bytes $start-${start + 3}/10000',
        );
        r.response.add(List.generate(4, (i) => (i + start) % 251));
        await r.response.close();
      });
      try {
        await Future.wait(
          List.generate(20, (i) async {
            final r = await f.request(range: 'bytes=$i-${i + 3}');
            expect(await body(r), List.generate(4, (j) => (i + j) % 251));
          }),
        );
        await DebugLog.flush();
        final logs = await File('${dir.path}/current.log').readAsString();
        expect(logs, contains('rangeBytes=4'));
        expect(logs, contains('bytes=4'));
        for (final secret in [
          'secret',
          'private',
          'token',
          'movie.mkv',
          '127.0.0.1',
        ]) {
          expect(logs, isNot(contains(secret)));
        }
      } finally {
        await f.close();
        await DebugLog.flush();
        DebugLog.enabled = enabled;
        DebugLog.directory = previous;
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'diagnostics distinguish an upstream 502, a header timeout and invalid range',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'ccplayer-relay-errors-',
      );
      final previous = DebugLog.directory, enabled = DebugLog.enabled;
      DebugLog.directory = dir;
      DebugLog.enabled = true;
      final release = Completer<void>();
      var attempt = 0;
      final f = await Fixture.start((req) async {
        attempt++;
        if (attempt == 1) {
          req.response.statusCode = 502;
        } else if (attempt == 2) {
          await release.future;
        } else {
          req.response.statusCode = 206;
          req.response.headers.set('content-range', 'bytes 1-1/10');
        }
        await req.response.close();
      }, headerTimeout: const Duration(milliseconds: 400));
      try {
        for (var i = 0; i < 3; i++) {
          final response = await f.request(range: 'bytes=0-0');
          expect(response.statusCode, 502);
          expect(await body(response), isEmpty);
        }
        // The client can see the 502 before the relay logs its cleanup.
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return f.relay.activeRequests != 0;
        }).timeout(const Duration(seconds: 3));
        await DebugLog.flush();
        final log = await File('${dir.path}/current.log').readAsString();
        expect(
          log,
          matches(
            RegExp(
              r'upstreamStatus=502 .*headersMs=\d+ phase=headers failure=upstreamHttp',
            ),
          ),
        );
        expect(
          log,
          matches(
            RegExp(
              r'upstreamStatus=0 .*headersMs=-1 phase=headers failure=TimeoutException',
            ),
          ),
        );
        expect(
          log,
          matches(
            RegExp(
              r'upstreamStatus=206 .*phase=validate failure=HttpException',
            ),
          ),
        );
      } finally {
        release.complete();
        await f.close();
        await DebugLog.flush();
        DebugLog.directory = previous;
        DebugLog.enabled = enabled;
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'raw full and partial bytes, suffix/open ranges and HEAD remain exact',
    () async {
      final bytes = List.generate(65536, (i) => i % 251);
      final f = await Fixture.start((r) async {
        expect(r.headers.value('accept-encoding'), 'identity');
        final range = r.headers.value('range');
        var start = 0, end = bytes.length - 1;
        if (range != null) {
          final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range)!;
          if (m[1]!.isEmpty) {
            start = bytes.length - int.parse(m[2]!);
          } else {
            start = int.parse(m[1]!);
            if (m[2]!.isNotEmpty) end = int.parse(m[2]!);
          }
          r.response.statusCode = 206;
          r.response.headers.set(
            'content-range',
            'bytes $start-$end/${bytes.length}',
          );
        }
        // Intentionally omit Content-Length: chunked transfer is still byte-exact.
        if (r.method != 'HEAD') r.response.add(bytes.sublist(start, end + 1));
        await r.response.close();
      });
      try {
        expect(await body(await f.request()), bytes);
        for (final entry in [
          ('bytes=3-55', 3, 56),
          ('bytes=60000-', 60000, 65536),
          ('bytes=-128', 65408, 65536),
        ]) {
          final r = await f.request(range: entry.$1);
          expect(r.statusCode, 206);
          expect(r.contentLength, entry.$3 - entry.$2);
          expect(await body(r), bytes.sublist(entry.$2, entry.$3));
        }
        final head = await f.request(range: 'bytes=1-8', method: 'HEAD');
        expect(head.statusCode, 206);
        expect(await body(head), isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'ignored Range never masquerades as partial or forwards an unwanted full body',
    () async {
      final f = await Fixture.start((r) async {
        r.response.contentLength = 10000;
        r.response.add(List.filled(10000, 7));
        await r.response.close();
      });
      try {
        for (final range in ['bytes=5-8', 'bytes=0-8', 'bytes=-8']) {
          final r = await f.request(range: range);
          expect(r.statusCode, 502);
          expect(await body(r), isEmpty);
        }
        for (final range in ['bytes=0-', 'bytes=0-99999', 'bytes=-99999']) {
          final r = await f.request(range: range);
          expect(r.statusCode, 200);
          expect((await body(r)).length, 10000);
        }
        final head = await f.request(range: 'bytes=5-8', method: 'HEAD');
        expect(head.statusCode, 200);
        expect(await body(head), isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'invalid Content-Range, length, encoding and multipart requests fail closed',
    () async {
      for (final values in [
        <String, String>{},
        {'content-range': 'bytes 4-7/10'},
        {'content-range': 'bytes 0-99/10'},
        {'content-range': 'bytes 1-4/10', 'content-length': '2'},
        {'content-range': 'bytes 1-4/10', 'content-encoding': 'gzip'},
      ]) {
        final f = await Fixture.start((r) async {
          r.response.statusCode = 206;
          values.forEach(r.response.headers.set);
          await r.response.close();
        });
        try {
          final r = await f.request(range: 'bytes=1-4');
          expect(r.statusCode, 502);
          expect(await body(r), isEmpty);
        } finally {
          await f.close();
        }
      }
      var calls = 0;
      final f = await Fixture.start((r) async {
        calls++;
        r.response.statusCode = 416;
        r.response.headers.set('content-range', 'bytes */10');
        await r.response.close();
      });
      try {
        final rejected = await f.request(range: 'bytes=0-1,3-4');
        expect(rejected.statusCode, 416);
        await body(rejected);
        expect(calls, 0);
        final r = await f.request(range: 'bytes=99-');
        expect(r.statusCode, 416);
        expect(r.headers.value('content-range'), 'bytes */10');
        await body(r);
        final post = await f.request(method: 'POST');
        expect(post.statusCode, 405);
        await body(post);
        expect(calls, 1);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'cross-origin CloudDrive-style redirect keeps Range and strips credentials',
    () async {
      final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      cdn.listen((r) async {
        expect(r.headers.value('authorization'), isNull);
        expect(r.headers.value('cookie'), isNull);
        expect(r.headers.value('range'), 'bytes=2-4');
        r.response.statusCode = 206;
        r.response.headers.set('content-range', 'bytes 2-4/10');
        r.response.add([2, 3, 4]);
        await r.response.close();
      });
      final f = await Fixture.start((r) async {
        expect(r.headers.value('authorization'), 'Basic private');
        r.response.statusCode = 302;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${cdn.port}/signed?signature=private',
        );
        await r.response.close();
      }, auth: 'Basic private');
      try {
        final r = await f.request(range: 'bytes=2-4');
        expect(r.statusCode, 206);
        expect(await body(r), [2, 3, 4]);
      } finally {
        await f.close();
        await cdn.close(force: true);
      }
    },
  );

  test(
    'upstream truncation remains a failed transfer, not a successful short video',
    () async {
      final f = await Fixture.start((r) async {
        r.response.statusCode = 206;
        r.response.headers.set('content-range', 'bytes 0-99/100');
        r.response.contentLength = 100;
        r.response.add(List.filled(10, 1));
        await r.response.flush();
        (await r.response.detachSocket()).destroy();
      });
      try {
        await expectLater(() async {
          final r = await f.request(range: 'bytes=0-99');
          await body(r);
        }, throwsA(isA<Exception>()));
      } finally {
        await f.close();
      }
    },
  );

  test(
    'ticket closure cancels active reads and rejects future requests',
    () async {
      final connected = Completer<void>();
      final release = Completer<void>();
      final f = await Fixture.start((r) async {
        connected.complete();
        await release.future;
        r.response.add([1]);
        await r.response.close();
      });
      try {
        final pending = f.request();
        await connected.future.timeout(const Duration(seconds: 2));
        expect(f.relay.activeRequests, 1);
        f.relay.close();
        final r = await pending;
        await body(r);
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (f.relay.activeRequests != 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(f.relay.activeRequests, 0);
        final gone = await f.request();
        expect(gone.statusCode, 410);
        await body(gone);
      } finally {
        release.complete();
        await f.close();
      }
    },
  );
}
