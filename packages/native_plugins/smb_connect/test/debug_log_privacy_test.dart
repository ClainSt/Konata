import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/src/utils/socket/socket_reader.dart';
import 'package:smb_connect/src/utils/socket/socket_writer.dart';
import 'package:test/test.dart';

void main() {
  test('显式调试模式仅记录传输字节数而不泄露报文正文', () async {
    final messages = <String>[];
    await runZoned(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peerFuture = server.first;
      final client =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final peer = await peerFuture;
      final reader = SocketReader2(peer, () {}, debugPrint: true);
      final writer = SocketWriter(client, debugPrint: true);
      final bytes = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02]);
      try {
        writer.write(bytes, 0, bytes.length);
        await writer.flush();
        final received = Uint8List(bytes.length);
        expect(await reader.read(received, 0, received.length), bytes.length);
        expect(received, bytes);
      } finally {
        await reader.close();
        client.destroy();
        await server.close();
      }
    },
        zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, message) => messages.add(message)));
    expect(messages.any((s) => s.contains('SMB 发送字节数：6')), isTrue);
    expect(messages.any((s) => s.contains('SMB 接收字节数：')), isTrue);
    expect(
        messages.every((s) =>
            RegExp(r'^SMB (?:发送字节数|接收字节数|刷新字节数)：\d+$|^SMB 读取已关闭$').hasMatch(s)),
        isTrue,
        reason: messages.toString());
  });
}
