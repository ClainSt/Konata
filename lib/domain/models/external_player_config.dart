/// 外部程序类型（视频播放器、音频播放器及图片查看器）。
enum ExternalPlayerKind {
  /// MPV 播放器。
  mpv,

  /// PotPlayer 播放器。
  potplayer,

  /// 外部音频播放器（二期 CD/OST 预留）。
  audioPlayer,

  /// 外部图片查看器（二期扫图/画集预留）。
  imageViewer,

  /// 用户自定义外部程序。
  custom,
}

/// 外部播放器/查看器配置实体。
class ExternalPlayerConfig {
  /// 创建外部播放器配置实例。
  const ExternalPlayerConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.executablePath,
    this.argumentsTemplate = '{url}',
    this.isDefault = false,
  });

  /// 配置主键 ID。
  final String id;

  /// 显示名称。
  final String name;

  /// 外部程序类型。
  final ExternalPlayerKind kind;

  /// 可执行文件完整路径。
  final String executablePath;

  /// 启动参数模板（支持 `{url}` / `{path}` 等占位符）。
  final String argumentsTemplate;

  /// 是否作为默认启动器。
  final bool isDefault;
}
