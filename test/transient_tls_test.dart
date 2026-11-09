import 'dart:async';
import 'dart:io';
import 'package:ccplayer/core/optional_feature_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'optional_features_test.dart' show LocalPeopleClient;

class _InterruptedClient extends LocalPeopleClient {
  _InterruptedClient(int port, this.opens, this.closes, this.failure)
    : super(port, []);
  final List<Uri> opens;
  final List<bool> closes;
  final Object? Function() failure;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    opens.add(uri);
    final error = failure();
    if (error != null) throw error;
    return super.getUrl(uri);
  }

  @override
  void close({bool force = false}) {
    closes.add(force);
    super.close(force: force);
  }
}

class _StalledClient extends LocalPeopleClient {
  _StalledClient() : super(1, []);
  final pending = Completer<HttpClientRequest>();
  bool closed = false;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) => pending.future;
  @override
  void close({bool force = false}) {
    closed = true;
    super.close(force: force);
  }
}

void main() {
  test(
    'deadline settles even when closing a native handshake does not',
    () async {
      final scope = OptionalFeatureScope(() {});
      final client = _StalledClient();
      await expectLater(
        scope
            .readBytes(
              Uri.https('api.bgm.tv', '/sample'),
              64,
              clientFactory: () => client,
              timeout: const Duration(milliseconds: 30),
            )
            .timeout(const Duration(seconds: 1)),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            'Optional request deadline',
          ),
        ),
      );
      expect(client.closed, true);
      expect(scope.count<HttpClient>(), 0);
      expect(scope.count<Timer>(), 0);
      // A late native failure is consumed, never retried or published.
      client.pending.completeError(
        const HandshakeException('Connection terminated during handshake'),
      );
      await Future<void>.delayed(Duration.zero);
      scope.dispose();
    },
  );
  test(
    'interrupted TLS retries once, successful connections reuse, shutdown releases',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        r.response.write('ok');
        await r.response.close();
      });
      final scope = OptionalFeatureScope(() {});
      final opens = <Uri>[], closes = <bool>[];
      var creations = 0;
      HttpClient factory() {
        creations++;
        return _InterruptedClient(
          server.port,
          opens,
          closes,
          () => opens.length == 1
              ? const HandshakeException(
                  'Connection terminated during handshake',
                )
              : null,
        );
      }

      try {
        for (var i = 0; i < 2; i++) {
          expect(
            await scope.readBytes(
              Uri.https('api.bgm.tv', '/sample'),
              64,
              clientFactory: factory,
            ),
            [111, 107],
          );
        }
        expect(opens.length, 3);
        expect(creations, 1);
        scope.dispose();
        expect(closes, hasLength(1));
        expect(scope.count<HttpClient>(), 0);
        expect(scope.count<Timer>(), 0);
      } finally {
        scope.dispose();
        await server.close(force: true);
      }
    },
  );
  test('TLS certificate failures are never retried or bypassed', () async {
    final scope = OptionalFeatureScope(() {});
    final opens = <Uri>[], closes = <bool>[];
    try {
      await expectLater(
        scope.readBytes(
          Uri.https('api.bgm.tv', '/sample'),
          64,
          clientFactory: () => _InterruptedClient(
            1,
            opens,
            closes,
            () => const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
          ),
        ),
        throwsA(isA<HandshakeException>()),
      );
      expect(opens, hasLength(1));
      expect(closes, hasLength(1));
    } finally {
      scope.dispose();
    }
  });
  test('repeated interrupted TLS is bounded to two opens', () async {
    final scope = OptionalFeatureScope(() {});
    final opens = <Uri>[], closes = <bool>[];
    await expectLater(
      scope.readBytes(
        Uri.https('api.bgm.tv', '/sample'),
        64,
        clientFactory: () => _InterruptedClient(
          1,
          opens,
          closes,
          () => const HandshakeException(
            'Connection terminated during handshake',
          ),
        ),
      ),
      throwsA(isA<HandshakeException>()),
    );
    expect(opens.length, 2);
    expect(closes.length, 1);
    expect(scope.count<HttpClient>(), 0);
    expect(scope.count<Timer>(), 0);
    scope.dispose();
  });
}
