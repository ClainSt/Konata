import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_request.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_response.dart';
import 'package:smb_connect/src/connect/common/smb_negotiation_response.dart';
import 'package:smb_connect/src/connect/impl/base_configuration.dart';
import 'package:smb_connect/src/connect/impl/smb2/create/smb2_close_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/io/smb2_read_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/io/smb2_read_response.dart';
import 'package:smb_connect/src/connect/smb_file.dart';
import 'package:smb_connect/src/connect/smb_file_stream.dart';
import 'package:smb_connect/src/connect/smb_transport.dart';
import 'package:smb_connect/src/connect/smb_tree.dart';
import 'package:smb_connect/src/smb/request_param.dart';
import 'package:smb_connect/src/smb/ntlm_password_authenticator.dart';

class _Negotiated extends Fake implements SmbNegotiationResponse {
  _Negotiated(this.limit);
  final int limit;
  @override
  int getReceiveBufferSize() => limit;
}

class _Transport extends Fake implements SmbTransport {
  _Transport({this.limit = 65536, this.shortRead});
  final int limit;
  final int? shortRead;
  final configuration = BaseConfiguration(
    credentials: NtlmPasswordAuthenticator(),
    username: '',
    password: '',
    domain: '',
  );
  final lengths = <int>[];
  int closes = 0;

  @override
  bool isSMB2() => true;
  @override
  SmbNegotiationResponse getNegotiatedResponse() => _Negotiated(limit);
  @override
  Future<T> sendrecv<T extends CommonServerMessageBlockResponse>(
    CommonServerMessageBlockRequest request, {
    CommonServerMessageBlockResponse? response,
    Set<RequestParam>? params,
  }) async {
    if (request is Smb2ReadRequest) {
      lengths.add(request.readLength);
      final count = min(request.readLength, shortRead ?? request.readLength);
      for (var i = 0; i < count; i++) {
        request.outputBuffer[request.outputBufferOffset + i] =
            ((request.offset + i) ~/ 257) % 251;
      }
      return (Smb2ReadResponse(
            configuration,
            request.outputBuffer,
            request.outputBufferOffset,
          )..dataLength = count)
          as T;
    }
    closes++;
    return Smb2CloseResponse(configuration, Uint8List(16), 'clip') as T;
  }
}

class _Tree extends Fake implements SmbTree {
  _Tree(this.transport);
  @override
  final _Transport transport;
  @override
  BaseConfiguration get config => transport.configuration;
  @override
  void prepare(CommonServerMessageBlockRequest request) {}
}

void main() {
  Stream<Uint8List> read(_Transport transport, int length) => smbOpenRead(
    SmbFile('/qa/clip', 'clip', 'qa', 0, 0, 0, 0, length, true),
    _Tree(transport),
    Uint8List(16),
    0,
    0,
    length,
  );

  test('SMB2 sequential reads use bounded negotiated blocks', () async {
    final transport = _Transport();
    await read(transport, 1048576).drain<void>();
    expect(transport.lengths.length, lessThanOrEqualTo(18));
    expect(transport.lengths.every((n) => n <= 64936), isTrue);
    final limited = _Transport(limit: 8192);
    await read(limited, 20000).drain<void>();
    expect(limited.lengths.every((n) => n <= 8192), isTrue);
  });

  test(
    'retained chunks remain byte exact after subsequent and short reads',
    () async {
      for (final shortRead in <int?>[null, 777]) {
        final transport = _Transport(shortRead: shortRead);
        final chunks = await read(transport, 20000).toList();
        final actual = chunks.expand((chunk) => chunk).toList();
        expect(actual, List.generate(20000, (i) => (i ~/ 257) % 251));
        expect(transport.closes, 1);
      }
    },
  );

  test('cancelling a read closes its SMB file handle', () async {
    final transport = _Transport();
    await read(transport, 20000).take(1).drain<void>();
    expect(transport.closes, 1);
  });
}
