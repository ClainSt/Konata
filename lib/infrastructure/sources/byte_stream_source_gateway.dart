/// 支持按字节范围流式读取的媒体源网关扩展契约（供 LocalStreamBridge 透传视频与外挂字幕）。
abstract interface class ByteRangeReadableGateway {
  /// 探测目标文件的精确字节总长度；若未知返回 `null`。
  Future<int?> probeFileLength(String relativePath);

  /// 打开指定字节区间的只读字节流（[start] 含，[endInclusive] 含，未传时读至文件末尾）。
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  });

  /// 释放底层网络连接或会话资源。
  Future<void> close();
}
