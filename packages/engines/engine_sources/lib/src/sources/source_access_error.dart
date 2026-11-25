import 'dart:async';
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:smb_connect/smb_connect.dart';

/// 将任意底层文件系统、HTTP、SMB 或套接字异常分类并翻译为 7 类中文故障说明。
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

  /// 判断该异常是否属于云盘或网关限流或过载信号。
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

  /// 解析 HTTP `Retry-After` 响应头（兼容整型秒数与 HTTP 日期格式）。
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

  /// 判断该异常是否属于应放弃重试的确定性认证、权限、证书或参数错误。
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
    if (error is SmbAuthException) {
      return SourceAccessProblemKind.authentication;
    }

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
    if (rawError is RiskControlled) return rawError.message;
    final protocol = switch (sourceKind) {
      MediaSourceKind.local => '本地目录',
      MediaSourceKind.webdav => 'WebDAV',
      MediaSourceKind.smb => 'SMB 共享',
      MediaSourceKind.cloudDrive => '云盘',
    };
    return switch (kind) {
      SourceAccessProblemKind.authentication =>
        '$protocol 认证失败：用户名或密码不正确，请检查凭据配置',
      SourceAccessProblemKind.permission => '$protocol 权限不足：当前账号无权读取该目录或共享资源',
      SourceAccessProblemKind.path => '$protocol 路径不存在：未找到目标目录或共享名称，请核对地址',
      SourceAccessProblemKind.timeout =>
        '$protocol 连接超时：服务器响应超过 15 秒，请检查网络或防火墙设置',
      SourceAccessProblemKind.network => '$protocol 网络不可达：无法连接目标主机或端口，请确认设备在线',
      SourceAccessProblemKind.tls => '$protocol TLS 证书握手失败：HTTPS 证书不受信任或协议不匹配',
      SourceAccessProblemKind.rateLimited =>
        '$protocol 触发云盘限流：请求过于频繁，请稍后重试或等待风控冷却',
      SourceAccessProblemKind.unknown => '$protocol 读取失败：${rawError ?? '未知异常'}',
    };
  }
}
