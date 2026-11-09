import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smb_connect/src/utils/socket/socket_writer.dart';
import 'package:smb_connect/src/utils/socket/socket_reader.dart';
import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_connect.dart';
import 'package:smb_connect/src/connect/smb_transport.dart';
import 'package:smb_connect/src/connect/smb_tree.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_response.dart';

class _ErrorSocket extends Fake implements Socket {
  final events = StreamController<Uint8List>();
  bool destroyed = false;
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void destroy() => destroyed = true;
}

class _Response extends Fake implements CommonServerMessageBlockResponse {}

class _Config extends Fake implements Configuration {
  @override
  bool get debugPrint => false;
}

class _Transport extends Fake implements SmbTransport {
  bool closed = false;
  @override
  String get host => 'test-host';
  @override
  Future<void> close() async {
    closed = true;
  }
}

class _Tree extends Fake implements SmbTree {
  @override
  Future<void> setup() async {}
  @override
  Future<void> close() async {
    throw StateError('peer already closed');
  }
}

class _Connection extends Smb2Connect {
  _Connection(super.configuration, super.transport);
  @override
  SmbTree initTree(String share) => _Tree();
  Future<void> openTestShare() async {
    await shareTree('qa');
  }
}

void main() {
  test('SMB socket errors reach pending reads and response waiters', () async {
    final socket = _ErrorSocket();
    final transport = SmbTransport(_Config(), 'test-host');
    final response = _Response();
    final pending = Completer<CommonServerMessageBlockResponse>();
    transport.responses[1] = (response: response, completer: pending);
    final reader = SocketReader2(
      socket,
      () {},
      onFailure: transport.onReaderFailure,
    );
    const failure = SocketException('connection reset');
    final read = reader.read(Uint8List(4), 0, 4);
    final checks = Future.wait([
      expectLater(
        read.timeout(const Duration(milliseconds: 500)),
        throwsA(same(failure)),
      ),
      expectLater(
        pending.future.timeout(const Duration(milliseconds: 500)),
        throwsA(same(failure)),
      ),
    ]);
    try {
      socket.events.addError(failure, StackTrace.current);
      await checks;
      expect(socket.destroyed, isTrue);
      expect(transport.responses, isEmpty);
      await expectLater(
        transport.waitResponse(2, response),
        throwsA(same(failure)),
      );
      await expectLater(
        reader.read(Uint8List(1), 0, 1),
        throwsA(same(failure)),
      );
    } finally {
      await reader.close();
      await socket.events.close();
    }
  });
  test(
    'SMB final buffered bytes remain readable but truncated reads fail promptly',
    () async {
      final socket = _ErrorSocket();
      final reader = SocketReader2(socket, () {});
      socket.events.add(Uint8List.fromList([1, 2]));
      await socket.events.close();
      final bytes = Uint8List(2);
      expect(await reader.read(bytes, 0, 2), 2);
      expect(bytes, [1, 2]);
      await expectLater(
        reader
            .read(Uint8List(1), 0, 1)
            .timeout(const Duration(milliseconds: 500)),
        throwsA(isA<SocketException>()),
      );
      await reader.close();
    },
  );
  test(
    'peer EOF during a bound write does not throw from the SMB reader callback',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final socket = await Socket.connect(server.address, server.port);
      final peer = await accepted;
      final reader = SocketReader2(socket, () {});
      final payload = StreamController<List<int>>();
      final sending = socket
          .addStream(payload.stream)
          .catchError((Object _) {});
      try {
        await peer.close();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } finally {
        await payload.close();
        await sending;
        await reader.close();
        socket.destroy();
        peer.destroy();
        await server.close();
      }
    },
  );
  test('SMB transport is released even when tree disconnect fails', () async {
    final transport = _Transport();
    final connection = _Connection(_Config(), transport);
    await connection.openTestShare();
    await expectLater(connection.close(), throwsStateError);
    expect(transport.closed, isTrue);
  });
  test('a closed SMB socket reports write failure to its caller', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final socket = await Socket.connect(server.address, server.port);
    final peer = await accepted;
    try {
      final writer = SocketWriter(socket);
      await socket.close();
      Object? failure;
      try {
        writer.write(Uint8List.fromList([1, 2, 3]), 0, 3);
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<StateError>());
    } finally {
      socket.destroy();
      peer.destroy();
      await server.close();
    }
  });
}
