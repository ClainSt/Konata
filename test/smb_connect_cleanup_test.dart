import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/impl/base_configuration.dart';
import 'package:smb_connect/src/connect/smb_connect.dart';
import 'package:smb_connect/src/connect/smb_transport.dart';
import 'package:smb_connect/src/credentials.dart';
import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/smb/ssp_context.dart';

class _Context extends Fake implements SSPContext {
  _Context(this.established);
  final bool established;
  int tokens = 0;
  @override
  Uint8List? initSecContext(Uint8List token, int off, int len) =>
      ++tokens < 3 ? Uint8List.fromList([tokens]) : null;
  @override
  bool isEstablished() => established;
  @override
  Uint8List? getSigningKey() => null;
}

class _Credentials extends Fake implements Credentials {
  _Credentials({this.failure, this.established = true});
  final Object? failure;
  final bool established;
  int contexts = 0;
  @override
  bool isAnonymous() => true;
  @override
  String getUserDomain() => '';
  @override
  SSPContext createContext(
    Configuration config,
    String? targetDomain,
    String host,
    Uint8List initialToken,
    bool doSigning,
  ) {
    contexts++;
    if (failure case final error?) throw error;
    return _Context(established);
  }
}

BaseConfiguration _config(_Credentials credentials) => BaseConfiguration(
  credentials: credentials,
  username: '',
  password: '',
  domain: '',
);

// Minimal SMB2 response envelopes for the existing decoder, not an NTLM server.
Uint8List _reply(int command, int messageId, {bool malformed = false}) {
  final length = command == 0 ? 128 : 72;
  final bytes = Uint8List(length + 4);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, length);
  bytes.setRange(4, 8, [0xfe, 0x53, 0x4d, 0x42]);
  data.setUint16(8, 64, Endian.little);
  data.setUint16(16, command, Endian.little);
  data.setUint16(18, 1, Endian.little);
  data.setUint32(20, 1, Endian.little);
  data.setUint64(28, messageId, Endian.little);
  data.setUint64(44, 1, Endian.little);
  data.setUint16(68, malformed ? 0 : (command == 0 ? 65 : 9), Endian.little);
  if (command == 0) {
    data.setUint16(70, 1, Endian.little);
    data.setUint16(72, 0x0202, Endian.little);
    for (final offset in [96, 100, 104]) {
      data.setUint32(offset, 65536, Endian.little);
    }
    data.setUint16(124, 128, Endian.little);
  } else {
    data.setUint16(72, 72, Endian.little);
  }
  return bytes;
}

class _Socket extends Fake implements Socket {
  _Socket({
    this.malformed = false,
    this.listenFailure = false,
    this.cancelFailure = false,
  }) {
    events = StreamController<Uint8List>(
      onCancel: () {
        cancellations++;
        if (cancelFailure) throw StateError('synthetic cancellation failure');
      },
    );
  }
  final bool malformed, listenFailure, cancelFailure;
  late final StreamController<Uint8List> events;
  final finished = Completer<void>();
  int destroys = 0, cancellations = 0, requests = 0;
  @override
  Future<void> get done => finished.future;
  @override
  void destroy() {
    destroys++;
    if (!finished.isCompleted) finished.complete();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (listenFailure) throw StateError('synthetic listener failure');
    return events.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void add(List<int> data) {
    requests++;
    final frame = ByteData.sublistView(Uint8List.fromList(data));
    events.add(
      _reply(
        requests == 1 ? 0 : 1,
        requests == 1 ? 0 : frame.getUint64(28, Endian.little),
        malformed: malformed,
      ),
    );
  }

  @override
  Future<void> flush() async {}

  Future<void> disposeEvents() async {
    // An unlistened single-subscription controller never completes close().
    if (!events.hasListener && cancellations == 0) {
      events.stream.listen((_) {});
    }
    await events.close();
  }
}

Future<T> _withSocket<T>(
  Future<Socket> Function() socket,
  Future<T> Function() action,
) => IOOverrides.runZoned(
  action,
  socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
      socket(),
);

void main() {
  for (final negotiationFails in [true, false]) {
    test(
      'real loopback peer observes EOF after failure: negotiation=$negotiationFails',
      () async {
        for (var repeat = 0; repeat < 3; repeat++) {
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final accepted = server.first;
          final client = await Socket.connect(server.address, server.port);
          final peer = await accepted;
          final peerClosed = Completer<void>();
          var replied = false;
          final subscription = peer.listen((_) {
            if (!replied) {
              replied = true;
              peer.add(_reply(0, 0, malformed: negotiationFails));
            }
          }, onDone: () => peerClosed.complete());
          final authError = SmbAuthException('loopback auth-context rejection');
          final credentials = _Credentials(failure: authError);
          try {
            await _withSocket(() async => client, () async {
              await expectLater(
                SmbConnect.connect(_config(credentials), 'fixture.invalid'),
                throwsA(
                  negotiationFails
                      ? "Can't connect to fixture.invalid"
                      : same(authError),
                ),
              );
            });
            // Assert peer EOF before the test's own cleanup destroys either side.
            await peerClosed.future.timeout(const Duration(seconds: 2));
            expect(credentials.contexts, negotiationFails ? 0 : 1);
          } finally {
            client.destroy();
            peer.destroy();
            await subscription.cancel();
            await server.close();
          }
        }
      },
    );
  }

  test(
    'closing before TCP initialization is safe, shared and terminal',
    () async {
      final transport = SmbTransport(
        _config(_Credentials()),
        'fixture.invalid',
      );
      final first = transport.close();
      expect(identical(first, transport.close()), isTrue);
      await first;
      expect(await transport.ensureConnected(), isFalse);
    },
  );

  test(
    'TCP failure preserves connect failure and ping returns false',
    () async {
      await _withSocket(
        () async => throw const SocketException('synthetic refusal'),
        () async {
          await expectLater(
            SmbConnect.connect(_config(_Credentials()), 'fixture.invalid'),
            throwsA("Can't connect to fixture.invalid"),
          );
          expect(
            await SmbConnect.pingConnection(
              host: 'fixture.invalid',
              username: '',
              password: '',
              domain: '',
            ),
            isFalse,
          );
        },
      );
    },
  );

  test(
    'socket arriving after close is destroyed without installing a reader',
    () async {
      final transport = SmbTransport(
        _config(_Credentials()),
        'fixture.invalid',
      );
      final socket = _Socket();
      final gate = Completer<Socket>();
      try {
        await _withSocket(() => gate.future, () async {
          final connecting = transport.ensureConnected();
          await transport.close();
          gate.complete(socket);
          expect(await connecting, isFalse);
          expect(socket.destroys, 1);
          expect(socket.requests, 0);
          await transport.close();
          expect(socket.destroys, 1);
        });
      } finally {
        await socket.disposeEvents();
      }
    },
  );

  for (final listenerFailure in [false, true]) {
    test(
      'failed negotiation releases partial connection: listenerFailure=$listenerFailure',
      () async {
        final socket = _Socket(malformed: true, listenFailure: listenerFailure);
        final credentials = _Credentials();
        try {
          await _withSocket(() async => socket, () async {
            await expectLater(
              SmbConnect.connect(_config(credentials), 'fixture.invalid'),
              throwsA("Can't connect to fixture.invalid"),
            );
          });
          expect(socket.destroys, greaterThan(0));
          expect(credentials.contexts, 0);
          expect(socket.cancellations, listenerFailure ? 0 : 1);
        } finally {
          await socket.disposeEvents();
        }
      },
    );
  }

  for (final cancelFailure in [false, true]) {
    test(
      'auth error is preserved while cleanup runs: cancelFailure=$cancelFailure',
      () async {
        final error = SmbAuthException('synthetic auth rejection');
        final credentials = _Credentials(failure: error);
        final socket = _Socket(cancelFailure: cancelFailure);
        try {
          await _withSocket(() async => socket, () async {
            await expectLater(
              SmbConnect.connect(_config(credentials), 'fixture.invalid'),
              throwsA(same(error)),
            );
          });
          expect(credentials.contexts, 1);
          expect(socket.cancellations, 1);
          expect(socket.destroys, greaterThan(0));
        } finally {
          await socket.disposeEvents();
        }
      },
    );
  }

  test(
    'false auth result releases connection; next fresh attempt succeeds',
    () async {
      for (final established in [false, false, true]) {
        final socket = _Socket();
        final credentials = _Credentials(established: established);
        try {
          await _withSocket(() async => socket, () async {
            final opening = SmbConnect.connect(
              _config(credentials),
              'fixture.invalid',
            );
            if (!established) {
              await expectLater(opening, throwsA(isA<SmbAuthException>()));
            } else {
              final connection = await opening;
              expect(
                socket.destroys,
                0,
                reason: 'Successful connection remains owned by caller',
              );
              await Future.wait([connection.close(), connection.close()]);
              final destroys = socket.destroys;
              await connection.close();
              expect(socket.destroys, destroys);
            }
          });
          expect(
            socket.requests,
            3,
            reason: 'Negotiation plus two session messages',
          );
          expect(socket.destroys, greaterThan(0));
          expect(socket.cancellations, 1);
        } finally {
          await socket.disposeEvents();
        }
      }
    },
  );
}
