import 'package:konata_contracts/konata_contracts.dart';

export 'package:konata_contracts/konata_contracts.dart' show MediaSourceKind;

/// 各协议的默认名称，不从地址提取内部标识。
String defaultSourceLabel(MediaSourceKind kind) => switch (kind) {
  MediaSourceKind.local => '本地目录',
  MediaSourceKind.webdav => 'WebDAV',
  MediaSourceKind.smb => 'SMB',
  MediaSourceKind.cloudDrive => '光鸭云盘',
};

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
