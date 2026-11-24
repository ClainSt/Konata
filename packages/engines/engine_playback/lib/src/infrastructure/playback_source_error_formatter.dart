import 'dart:async';
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';

/// 播放期媒体源访问异常中文归类器（零 `smb_connect` 直接耦合，支持可选外部翻译回调扩展）。
abstract final class PlaybackSourceErrorFormatter {
  /// 将底层异常翻译为面向用户的中文错误说明。
  static String toChineseMessage(
    Object error,
    MediaSourceKind sourceKind, {
    String Function(Object error, MediaSourceKind sourceKind)? customFormatter,
  }) {
    if (customFormatter != null) {
      return customFormatter(error, sourceKind);
    }
    if (error is SourceAccessException) {
      return error.message;
    }
    if (error is SourceRateLimitException) {
      return error.message;
    }
    if (error is TerminalSourceAuthException) {
      return error.message;
    }
    if (error is TimeoutException) {
      return '连接媒体源超时，请检查网络或服务状态';
    }
    if (error is PathAccessException) {
      return '无权读取目标媒体路径：${error.message}';
    }
    if (error is PathNotFoundException) {
      return '找不到目标媒体路径或文件已移动：${error.message}';
    }
    if (error is SocketException) {
      return '无法连接媒体服务器：${error.message}';
    }
    if (error is HttpException) {
      return '媒体流 HTTP 访问失败：${error.message}';
    }
    final kindLabel = switch (sourceKind) {
      MediaSourceKind.local => '本地媒体源',
      MediaSourceKind.webdav => 'WebDAV 媒体源',
      MediaSourceKind.smb => 'SMB 共享媒体源',
    };
    return '$kindLabel访问失败：$error';
  }
}
