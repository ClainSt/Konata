import 'dart:typed_data';

abstract class Message {
  /// 标记当前请求须在响应到达时完整保留原始报文字节快照。
  void setRetainPayload();

  /// 是否保留该请求报文的原始字节载荷开关。
  bool isRetainPayload();

  /// 关联响应的原始报文字节数组（若已请求保留）。
  Uint8List? getRawPayload();

  void setRawPayload(Uint8List rawPayload);
}
