import 'dart:typed_data';

import 'package:smb_connect/src/utils/extensions.dart';

class AvPair {
  final int type;
  final Uint8List raw;

  AvPair(this.type, this.raw);

  @override
  String toString() => "AvPair(type: $type, raw: ${raw.toHexString()})";

  /// NTLMv2 AvPair 结束标记类型（MsvAvEOL）。
  static const int MsvAvEOL = 0x0;

  /// NTLMv2 AvPair 认证控制标志类型（MsvAvFlags）。
  static const int MsvAvFlags = 0x6;

  /// NTLMv2 AvPair 服务端时间戳类型（MsvAvTimestamp）。
  static const int MsvAvTimestamp = 0x7;

  /// NTLMv2 AvPair 单主机数据标识类型（MsvAvSingleHost）。
  static const int MsvAvSingleHost = 0x08;

  /// NTLMv2 AvPair 目标服务主体名 SPN 类型（MsvAvTargetName）。
  static const int MsvAvTargetName = 0x09;

  /// NTLMv2 AvPair TLS 通道绑定哈希类型（MsvAvChannelBindings）。
  static const int MsvAvChannelBindings = 0x0A;
}
