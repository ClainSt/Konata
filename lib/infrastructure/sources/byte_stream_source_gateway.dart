import 'dart:io';

/// 远程流网桥唯一重试预算常量（严禁在多层同时叠加重试）。
abstract final class SourceRetryPolicy {
  /// 单次分块读取允许的最大重试次数。
  static const int maxRetries = 2;

  /// 单次分块续传允许消耗的最大墙钟时间上限。
  static const Duration maxWallClockBudget = Duration(seconds: 8);
}

/// 携带强验证器（非弱 `ETag`）与范围响应元数据的字节流封装。
class ValidatedByteRangeStream {
  /// 创建强验证字节范围流。
  const ValidatedByteRangeStream({
    required this.stream,
    required this.start,
    this.endInclusive,
    this.totalLength,
    this.strongValidator,
    this.isPartialContent = true,
  });

  /// 底层渐进式字节流。
  final Stream<List<int>> stream;

  /// 服务端实际返回范围起点（含）。
  final int start;

  /// 服务端实际返回范围终点（含，未知时可空）。
  final int? endInclusive;

  /// 服务端宣告的文件总字节数（未知时可空）。
  final int? totalLength;

  /// 服务端强验证器（仅接受非 `W/` 强 `ETag`，用于断流续传一致性核验）。
  final String? strongValidator;

  /// 响应状态是否为 `206 Partial Content`。
  final bool isPartialContent;
}

/// 上游认证终态拒绝异常（Digest 质询重试后仍为 `401` 或收到 `403` 时立即终止，严禁空转重试）。
class TerminalSourceAuthException implements HttpException {
  /// 创建认证终态异常。
  const TerminalSourceAuthException(
    this.message, {
    required this.statusCode,
    this.uri,
  });

  /// 简体中文故障描述。
  @override
  final String message;

  /// 关联请求地址。
  @override
  final Uri? uri;

  /// HTTP 状态码（`401` 或 `403`）。
  final int statusCode;

  @override
  String toString() => 'TerminalSourceAuthException($statusCode): $message';
}

/// 上游分块续传不一致异常（遇 `200` 整包响应、范围起点错位或强验证器换版时立即熔断，严禁错位拼接）。
class UpstreamRangeMismatchException implements HttpException {
  /// 创建续传一致性失配异常。
  const UpstreamRangeMismatchException(this.message, {this.uri});

  /// 简体中文故障描述。
  @override
  final String message;

  /// 关联请求地址。
  @override
  final Uri? uri;

  @override
  String toString() => 'UpstreamRangeMismatchException: $message';
}

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

/// 支持同时探测文件精确长度与真实源版本验证器（`ETag` / `mtime`）的媒体源网关扩展契约。
abstract interface class FileValidatorProbeGateway
    implements ByteRangeReadableGateway {
  /// 单次往返探测目标文件的字节总长度及真实版本验证器（`ETag` 或 `mtime:...`）。
  Future<({int? length, String? validator})> probeFileMetadata(
    String relativePath,
  );
}

/// 支持强验证器（强 `ETag` + `If-Range`）一致性断流续传的字节范围网关扩展契约。
abstract interface class ValidatedByteRangeGateway
    implements ByteRangeReadableGateway {
  /// 打开带强验证器核验的字节范围流；传入 [expectedStrongValidator] 时强制校验版本一致且返回 `206`。
  Future<ValidatedByteRangeStream> openValidatedByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
    String? expectedStrongValidator,
  });
}
