import 'dart:async';
import 'dart:io';

import 'package:ccplayer/core/sources.dart';
import 'package:flutter_test/flutter_test.dart';

class _ListenFailureSocket extends Fake implements ServerSocket {
  final failure = StateError('synthetic listen failure');
  final closing = Completer<ServerSocket>();
  int closes = 0;
  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;
  @override
  int get port => 12345;
  @override
  StreamSubscription<Socket> listen(
    void Function(Socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => throw failure;
  @override
  Future<ServerSocket> close() {
    closes++;
    return closing.future;
  }
}

class _TrackedSocket extends Fake implements ServerSocket {
  _TrackedSocket(this.inner);
  final ServerSocket inner;
  final peers = <Socket>[];
  int listens = 0;
  @override
  InternetAddress get address => inner.address;
  @override
  int get port => inner.port;
  @override
  Future<ServerSocket> close() => inner.close();
  @override
  StreamSubscription<Socket> listen(
    void Function(Socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listens++;
    return inner.listen(
      (socket) {
        peers.add(socket);
        onData?.call(socket);
      },
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

void main() {
  // One scenario deliberately owns the singleton's first initialization.
  test(
    'broker shares startup, releases failed listener and independently revokes concurrent tickets',
    () async {
      final broker = StreamBroker.instance;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final backing = _TrackedSocket(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      );
      final failedSocket = _ListenFailureSocket();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      final tickets = <Uri>[];
      var upstreamReads = 0;
      upstream.listen((request) async {
        upstreamReads++;
        request.response.write('payload:${request.uri.path}');
        await request.response.close();
      });
      final source = <String, Object?>{
        'id': 'fixture',
        'kind': 'webdav',
        'username': '',
        'location': 'http://127.0.0.1:${upstream.port}/',
      };
      var binds = 0;
      var gate = Completer<ServerSocket>();
      Future<(int, String)> read(Uri uri) async {
        final request = await client.getUrl(uri);
        final response = await request.close();
        final bytes = await response.expand((chunk) => chunk).toList();
        return (response.statusCode, String.fromCharCodes(bytes));
      }

      try {
        await IOOverrides.runZoned(
          () async {
            // All callers reach the same pending bind, including its failure.
            const bindError = SocketException('synthetic bind failure');
            final failed = [
              for (var i = 0; i < 12; i++)
                expectLater(
                  broker.issue(source, 'failure-$i.mkv'),
                  throwsA(same(bindError)),
                ),
            ];
            final firstBinds = binds;
            gate.completeError(bindError);
            await Future.wait(failed);
            expect(firstBinds, 1);

            // A bound server that cannot install its listener must be closed before
            // the shared failure completes and the next attempt becomes available.
            gate = Completer<ServerSocket>();
            final listening = [
              for (var i = 0; i < 12; i++)
                expectLater(
                  broker.issue(source, 'listen-$i.mkv'),
                  throwsA(same(failedSocket.failure)),
                ),
            ];
            gate.complete(failedSocket);
            await Future<void>.delayed(Duration.zero);
            expect(binds, 2);
            expect(failedSocket.closes, 1);
            final duringCleanup = expectLater(
              broker.issue(source, 'during-cleanup.mkv'),
              throwsA(same(failedSocket.failure)),
            );
            expect(binds, 2, reason: 'Cleanup is part of the shared attempt');
            failedSocket.closing.complete(failedSocket);
            await Future.wait(listening);
            await duringCleanup;

            gate = Completer<ServerSocket>();
            final pending = [
              for (var i = 0; i < 24; i++) broker.issue(source, 'clip-$i.mkv'),
            ];
            expect(binds, 3);
            gate.complete(backing);
            tickets.addAll(await Future.wait(pending));
            expect(backing.listens, 1);
            expect(tickets.map((uri) => uri.port).toSet(), {backing.port});
            expect(tickets.map((uri) => uri.path).toSet(), hasLength(24));
            final bodies = await Future.wait(tickets.map(read));
            for (var i = 0; i < bodies.length; i++) {
              expect(bodies[i], (200, 'payload:/clip-$i.mkv'));
            }
            expect(upstreamReads, 24);
            for (final uri in tickets.take(12)) {
              broker.revoke(uri);
              broker.revoke(uri); // Repeated revocation is harmless.
            }
            final revoked = await Future.wait(tickets.take(12).map(read));
            expect(revoked.every((r) => r.$1 == 404), isTrue);
            expect(
              upstreamReads,
              24,
              reason: 'Revoked tickets must not reach upstream',
            );
            expect(await read(tickets.last), (200, 'payload:/clip-23.mkv'));
            for (final uri in tickets) {
              broker.revoke(uri);
            }
            final next = await broker.issue(source, 'again.mkv');
            tickets.add(next);
            expect(
              binds,
              3,
              reason: 'The app-lifetime server is reused after revocation',
            );
            expect(await read(next), (200, 'payload:/again.mkv'));
          },
          serverSocketBind:
              (address, port, {backlog = 0, v6Only = false, shared = false}) {
                binds++;
                expect(address, InternetAddress.loopbackIPv4);
                expect(port, 0);
                return gate.future;
              },
        );
      } finally {
        if (!failedSocket.closing.isCompleted) {
          failedSocket.closing.complete(failedSocket);
        }
        for (final uri in tickets) {
          broker.revoke(uri);
        }
        client.close(force: true);
        for (final socket in backing.peers) {
          socket.destroy();
        }
        await backing.close();
        await upstream.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
