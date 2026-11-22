import 'dart:async';
import 'dart:io';

import 'package:smb_connect/smb_connect.dart';

import '../../domain/models/media_source.dart';

/// 媒体源连接与读取故障 7 类精确分类。
enum SourceAccessProblemKind {
  /// 用户名或密码认证失败（401 / NT_STATUS_LOGON_FAILURE）。
  authentication,

  /// 权限不足（403 / ACCESS_DENIED / PathAccessException）。
  permission,

  /// 路径或共享名不存在（404 / BAD_NETWORK_NAME / PathNotFoundException）。
  path,

  /// 网络连接或响应超时。
  timeout,

  /// 网络不可达（连接拒绝 / 主机不可达 / DNS 解析失败）。
  network,

  /// TLS / HTTPS 证书或协议握手失败。
  tls,

  /// 远程网盘或网关触发频控限流（HTTP 429 / 503 / 509）。
  rateLimited,

  /// 其他未知访问异常。
  unknown,
}

/// 远程网盘或 WebDAV 网关返回频控/限流（HTTP 429 / 503 / 509）时抛出的强类型异常。
///
/// 供自适应扫描调度器读取 [retryAfter] 并立即执行乘性降速与冷静退避，避免触发云盘风控。
class SourceRateLimitException implements Exception {
  /// 创建网盘限流异常实例。
  const SourceRateLimitException({
    required this.statusCode,
    required this.message,
    this.retryAfter,
    this.uri,
  });

  /// 服务端返回的 HTTP 状态码（典型值 `429`、`503`、`509`）。
  final int statusCode;

  /// 中文可读故障说明。
  final String message;

  /// 服务端通过 `Retry-After` 建议的冷却等待时长（缺省时为 `null`）。
  final Duration? retryAfter;

  /// 触发限流的目标请求地址。
  final Uri? uri;

  @override
  String toString() => message;
}

/// 携带中文友好说明的媒体源访问异常。
class SourceAccessException implements Exception {
  /// 创建强类型媒体源访问异常。
  const SourceAccessException(this.kind, this.message, [this.cause]);

  /// 7 类精确分类。
  final SourceAccessProblemKind kind;

  /// 中文错误说明。
  final String message;

  /// 原始异常。
  final Object? cause;

  @override
  String toString() => message;
}

/// 将任意底层文件系统 / HTTP / SMB / Socket 异常分类并翻译为 7 类中文故障说明。
class SourceAccessErrorClassifier {
  const SourceAccessErrorClassifier._();

  /// 返回分类枚举及面向用户的中文错误描述。
  static ({SourceAccessProblemKind kind, String message}) classify(
    Object error,
    MediaSourceKind sourceKind,
  ) {
    final kind = _detectKind(error);
    return (kind: kind, message: formatKind(kind, sourceKind, error));
  }

  /// 直接生成中文错误文本。
  static String toChineseMessage(Object error, MediaSourceKind sourceKind) =>
      classify(error, sourceKind).message;

  /// 判断该异常是否属于云盘/网关限流或过载信号（强类型限流异常及 429/509 文本特征）。
  static bool isRateLimitError(Object error) {
    if (error is SourceRateLimitException) return true;
    if (error is SourceAccessException) {
      return error.kind == SourceAccessProblemKind.rateLimited;
    }
    final lower = error.toString().toLowerCase();
    return lower.contains('http 429') ||
        lower.contains('http 509') ||
        lower.contains('too many requests') ||
        lower.contains('rate limit');
  }

  /// 从异常对象中提取服务端建议的 `Retry-After` 等待时长；无明确值时返回 `null`。
  static Duration? extractRetryAfter(Object error) {
    if (error is SourceRateLimitException) return error.retryAfter;
    return null;
  }

  /// 解析 HTTP `Retry-After` 响应头（同时兼容整型秒数与 RFC 7231 HTTP-Date）。
  static Duration? parseRetryAfterHeader(
    Map<String, String> headers, {
    DateTime? now,
  }) {
    String? raw;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'retry-after') {
        raw = entry.value.trim();
        break;
      }
    }
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds != null) {
      return seconds > 0 ? Duration(seconds: seconds) : Duration.zero;
    }
    try {
      final target = HttpDate.parse(raw).toUtc();
      final current = (now ?? DateTime.now()).toUtc();
      final delta = target.difference(current);
      return delta.isNegative ? Duration.zero : delta;
    } on HttpException {
      return null;
    }
  }

  /// 判断该异常是否属于应放弃重试的确定性认证/权限/证书/参数错误。
  static bool isNonTransientError(Object error) {
    if (error is SourceRateLimitException) return false;
    if (error is ArgumentError || error is CertificateException) return true;
    final kind = _detectKind(error);
    return kind == SourceAccessProblemKind.authentication ||
        kind == SourceAccessProblemKind.permission ||
        kind == SourceAccessProblemKind.path;
  }

  static SourceAccessProblemKind _detectKind(Object error) {
    if (error is SourceRateLimitException) {
      return SourceAccessProblemKind.rateLimited;
    }
    if (error is SourceAccessException) return error.kind;
    if (error is TimeoutException) return SourceAccessProblemKind.timeout;
    if (error is HandshakeException || error is CertificateException) {
      return SourceAccessProblemKind.tls;
    }
    if (error is SocketException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('timed out') || msg.contains('timeout')) {
        return SourceAccessProblemKind.timeout;
      }
      return SourceAccessProblemKind.network;
    }
    if (error is PathAccessException) return SourceAccessProblemKind.permission;
    if (error is PathNotFoundException) return SourceAccessProblemKind.path;
    if (error is SmbAuthException) return SourceAccessProblemKind.authentication;

    final statusText = error is SmbException ? error.message : error.toString();
    final lower = statusText.toLowerCase();
    if (lower.contains('http 401') ||
        lower.contains('unauthorized') ||
        lower.contains('logon_failure') ||
        lower.contains('authentication')) {
      return SourceAccessProblemKind.authentication;
    }
    if (lower.contains('http 429') ||
        lower.contains('http 509') ||
        lower.contains('too many requests') ||
        lower.contains('rate limit')) {
      return SourceAccessProblemKind.rateLimited;
    }
    if (lower.contains('http 403') ||
        lower.contains('forbidden') ||
        lower.contains('access_denied')) {
      return SourceAccessProblemKind.permission;
    }
    if (lower.contains('http 404') ||
        lower.contains('http 410') ||
        lower.contains('bad_network_name') ||
        lower.contains('object_name_not_found') ||
        lower.contains('object_path_not_found') ||
        lower.contains('not_a_directory') ||
        lower.contains('不存在')) {
      return SourceAccessProblemKind.path;
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return SourceAccessProblemKind.timeout;
    }
    if (lower.contains('handshake') || lower.contains('certificate')) {
      return SourceAccessProblemKind.tls;
    }
    if (lower.contains('connection refused') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable')) {
      return SourceAccessProblemKind.network;
    }
    return SourceAccessProblemKind.unknown;
  }

  /// 将故障分类枚举映射为清晰的中文诊断提示。
  static String formatKind(
    SourceAccessProblemKind kind,
    MediaSourceKind sourceKind, [
    Object? rawError,
  ]) {
    final protocol = switch (sourceKind) {
      MediaSourceKind.local => '本地目录',
      MediaSourceKind.webdav => 'WebDAV',
      MediaSourceKind.smb => 'SMB 共享',
    };
    return switch (kind) {
      SourceAccessProblemKind.authentication =>
        '$protocol 认证失败：用户名或密码不正确，请检查凭据配置',
      SourceAccessProblemKind.permission =>
        '$protocol 权限不足：当前账号无权读取该目录或共享资源',
      SourceAccessProblemKind.path =>
        '$protocol 路径不存在：未找到目标目录或共享名称，请核对地址',
      SourceAccessProblemKind.timeout =>
        '$protocol 连接超时：服务器响应超过 15 秒，请检查网络或防火墙设置',
      SourceAccessProblemKind.network =>
        '$protocol 网络不可达：无法连接目标主机或端口，请确认设备在线',
      SourceAccessProblemKind.tls =>
        '$protocol TLS 证书握手失败：HTTPS 证书不受信任或协议不匹配',
      SourceAccessProblemKind.rateLimited =>
        '$protocol 触发云盘限流：请求过于频繁，请稍后重试或等待风控冷却',
      SourceAccessProblemKind.unknown =>
        '$protocol 读取失败：${rawError ?? '未知异常'}',
    };
  }
}
