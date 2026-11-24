import 'package:smb_connect/src/dialect_version.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block.dart';
import 'package:smb_connect/src/connect/transport/response.dart';

import 'smb_negotiation_request.dart';

abstract class SmbNegotiationResponse
    implements CommonServerMessageBlock, Response {
  bool isValid(SmbNegotiationRequest request);

  DialectVersion? getSelectedDialect();

  /// 服务端协商响应中是否启用了消息签名能力。
  bool isSigningEnabled();

  /// 服务端是否强制要求客户端对报文签名。
  bool isSigningRequired();

  void setupRequest(CommonServerMessageBlock request);

  void setupResponse(Response resp);

  /// 当前连接会话是否已完成消息签名协商。
  bool isSigningNegotiated();

  /// 指定的服务端能力标志位是否在协商中获确认。
  bool haveCapabilitiy(int cap);

  /// 当前会话协商确立的发送缓冲区尺寸。
  int getSendBufferSize();

  /// 当前会话协商确立的接收缓冲区尺寸。
  int getReceiveBufferSize();

  /// 当前会话协商确立的 Transaction 请求最大缓冲区尺寸。
  int getTransactionBufferSize();

  /// 服务端首次授予本连接的 SMB2 初始信用额度。
  int getInitialCredits();
}
