/// 媒体源协议类型枚举。
enum MediaSourceKind {
  /// 本地磁盘目录。
  local,

  /// WebDAV 远程目录。
  webdav,

  /// SMB / CIFS 局域网共享目录。
  smb,
}

/// 根据媒体源协议与路径/地址自动推导友好的默认显示名称。
String deriveDefaultSourceLabel(MediaSourceKind kind, String rawLocation) {
  final location = rawLocation.trim();
  if (location.isEmpty) {
    return switch (kind) {
      MediaSourceKind.local => '本地媒体库',
      MediaSourceKind.webdav => 'WebDAV 媒体库',
      MediaSourceKind.smb => 'SMB 媒体库',
    };
  }

  if (kind == MediaSourceKind.local) {
    final normalized = location.replaceAll('\\', '/');
    final segments = normalized
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return '本地媒体库';
    final last = segments.last;
    if (segments.length == 1 && last.endsWith(':')) {
      return '${last.substring(0, last.length - 1).toUpperCase()} 盘';
    }
    return last;
  }

  // 兼容 `//192.168.1.10/Anime` 或 `\\192.168.1.10\Anime` 简写 SMB 地址
  var candidate = location.replaceAll('\\', '/');
  if (candidate.startsWith('//')) {
    candidate = 'smb:$candidate';
  }
  final uri = Uri.tryParse(candidate);
  if (uri != null && uri.host.isNotEmpty) {
    final segments = uri.pathSegments
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isNotEmpty) {
      return '${segments.last} (${uri.host})';
    }
    return uri.host;
  }

  final fallback = candidate
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .lastOrNull;
  return fallback ?? '远程媒体库';
}

/// 媒体源强类型领域实体。
///
/// 账号密码等敏感凭据不直接落入 SQLite，由基础设施层通过安全存储按 `id` 存取。
class MediaSource {
  /// 创建媒体源实例。
  const MediaSource({
    required this.id,
    required this.kind,
    required this.label,
    required this.location,
    this.username,
    this.createdAt,
  });

  /// 媒体源唯一标识（UUID）。
  final String id;

  /// 媒体源协议类型。
  final MediaSourceKind kind;

  /// 用户可见的展示名称。
  final String label;

  /// 根路径或远程 URL 地址。
  final String location;

  /// 可选登录用户名（仅远程源使用）。
  final String? username;

  /// 创建时间。
  final DateTime? createdAt;

  /// 返回修改部分字段后的媒体源副本。
  MediaSource copyWith({
    String? id,
    MediaSourceKind? kind,
    String? label,
    String? location,
    String? username,
    DateTime? createdAt,
  }) {
    return MediaSource(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      label: label ?? this.label,
      location: location ?? this.location,
      username: username ?? this.username,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
