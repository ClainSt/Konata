import 'package:konata_contracts/konata_contracts.dart';

/// 媒体源地址格式校验与规范化结果。
class ValidatedSourceLocation {
  /// 创建地址校验结果。
  const ValidatedSourceLocation({
    required this.normalizedLocation,
    this.errorMessage,
  });

  /// 规范化后的媒体源地址。
  final String normalizedLocation;

  /// 中文错误说明（为空表示校验通过）。
  final String? errorMessage;

  /// 是否合法。
  bool get isValid => errorMessage == null;
}

/// 媒体源地址校验与规范化工具（纯函数，无磁盘或网络开销）。
class SourceLocationValidator {
  const SourceLocationValidator._();

  /// 校验并规范化本地目录、WebDAV 地址或 SMB 共享地址。
  static ValidatedSourceLocation validate(
    MediaSourceKind kind,
    String rawLocation,
  ) {
    final trimmed = rawLocation.trim();
    if (trimmed.isEmpty) {
      return const ValidatedSourceLocation(
        normalizedLocation: '',
        errorMessage: '请填写媒体源路径或服务器地址',
      );
    }

    switch (kind) {
      case MediaSourceKind.local:
        return ValidatedSourceLocation(normalizedLocation: trimmed);

      case MediaSourceKind.webdav:
        final uri = Uri.tryParse(trimmed);
        if (uri == null ||
            (uri.scheme != 'http' && uri.scheme != 'https') ||
            uri.host.trim().isEmpty) {
          return ValidatedSourceLocation(
            normalizedLocation: trimmed,
            errorMessage: 'WebDAV 地址必须以 http:// 或 https:// 开头并包含主机名',
          );
        }
        return ValidatedSourceLocation(normalizedLocation: uri.toString());

      case MediaSourceKind.smb:
        return _validateSmb(trimmed);
    }
  }

  static ValidatedSourceLocation _validateSmb(String raw) {
    final decoded = raw
        .replaceAll(RegExp('%2e', caseSensitive: false), '.')
        .replaceAll(RegExp('%2f|%5c', caseSensitive: false), '/')
        .replaceAll('\\', '/');
    if (decoded.split('/').any((s) => s == '..' || s == '.')) {
      return ValidatedSourceLocation(
        normalizedLocation: raw,
        errorMessage: 'SMB 地址不能包含 . 或 .. 相对路径片段',
      );
    }

    var candidate = raw.trim().replaceAll('\\', '/');
    if (candidate.startsWith('//')) {
      candidate = 'smb:$candidate';
    } else if (!candidate.contains('://')) {
      candidate = 'smb://${candidate.replaceFirst(RegExp(r'^/+'), '')}';
    }

    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.scheme != 'smb' || uri.host.trim().isEmpty) {
      return ValidatedSourceLocation(
        normalizedLocation: raw,
        errorMessage: 'SMB 地址格式无效，示例：smb://192.168.1.2/Anime 或 \\\\192.168.1.2\\Anime',
      );
    }

    if (uri.hasPort && uri.port != 445) {
      return ValidatedSourceLocation(
        normalizedLocation: raw,
        errorMessage: 'SMB 共享当前仅支持标准 445 端口，请移除自定义端口',
      );
    }

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      return ValidatedSourceLocation(
        normalizedLocation: raw,
        errorMessage: 'SMB 地址必须包含共享文件夹名称，例如 smb://192.168.1.2/Anime',
      );
    }

    final normalized = uri.replace(
      port: uri.hasPort ? 445 : null,
      path: '/${segments.join('/')}',
      query: null,
      fragment: null,
    );
    return ValidatedSourceLocation(normalizedLocation: normalized.toString());
  }
}
