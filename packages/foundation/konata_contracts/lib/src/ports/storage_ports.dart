/// 本机敏感凭据安全存储端口。
///
/// 媒体源密码、WebDAV 密码、第三方追番平台 PAT/Token 与 API 密钥仅允许通过本端口存取，
/// 严禁明文落入 SQLite 数据库或进入跨设备同步载荷。
abstract interface class SecureStoragePort {
  /// 读取指定键对应的明文凭据；不存在时返回 `null`。
  Future<String?> read(String key);

  /// 写入或覆盖指定键的敏感凭据；若 [value] 为空则应清除该键。
  Future<void> write(String key, String? value);

  /// 删除指定键的敏感凭据。
  Future<void> delete(String key);

  /// 批量读取指定前缀下的全部凭据键值（按需用于清理与诊断统计，严禁原样打印）。
  Future<Map<String, String>> readAllWithPrefix(String prefix);
}

/// Konata 标准化目录名常量（杜绝各包硬编码路径字符串或误用系统 `%TEMP%`）。
abstract final class StoragePathNames {
  /// 用户持久化数据目录名（`<Root>/userdata`）。
  static const String userdataDir = 'userdata';

  /// 三库 SQLite 存放子目录名（`<Root>/userdata/db`）。
  static const String dbSubdir = 'db';

  /// 核心媒体资产库文件名。
  static const String libraryDbFile = 'library.db';

  /// 用户态与同步库文件名。
  static const String userStateDbFile = 'user_state.db';

  /// 可丢弃惰性缓存库文件名。
  static const String cacheDbFile = 'cache.db';

  /// 内置 `libmpv` 配置沙箱子目录名。
  static const String mpvSubdir = 'mpv';

  /// 自定义 `.glsl` 着色器子目录名。
  static const String shadersSubdir = 'shaders';

  /// 运行诊断日志导出目录名。
  static const String logsSubdir = 'logs';

  /// 可丢弃缓存总目录名（`<Root>/cache`）。
  static const String cacheDir = 'cache';

  /// 隔离临时目录名（`<Root>/cache/tmp`，严禁写入系统 `%TEMP%`）。
  static const String tempSubdir = 'tmp';

  /// 作品本地艺术图与截图总目录名（`<Root>/photos`）。
  static const String photosDir = 'photos';
}

/// 跨端统一存储根目录解析端口（纯 Dart 路径契约，屏蔽 Windows 便携与 Android 沙箱差异）。
///
/// - Windows 桌面端严格绿色便携：落盘于可执行文件同级目录（开发期为仓根目录），绝不写 C 盘用户目录；
/// - Android 端委托宿主 `ApplicationSupportDirectory`。
abstract interface class StorageRootPort {
  /// 当前有效应用根路径（已包含隔离车道子目录 `Konata_<lane>`）。
  Future<String> resolveAppRootPath();

  /// 确保并返回用户数据目录路径（`<Root>/userdata`）。
  Future<String> ensureUserdataDirPath();

  /// 确保并返回三库 SQLite 存放目录路径（`<Root>/userdata/db`）。
  Future<String> ensureDatabaseDirPath();

  /// 返回指定数据库文件的完整落盘路径（`<Root>/userdata/db/<fileName>`）。
  Future<String> resolveDatabaseFilePath(String dbFileName);

  /// 确保并返回诊断日志落盘目录路径（`<Root>/userdata/logs`）。
  Future<String> ensureLogsDirPath();

  /// 返回艺术图总目录路径（`<Root>/photos`，按需创建）。
  Future<String> resolvePhotosDirPath();

  /// 确保并返回隔离临时目录路径（`<Root>/cache/tmp`）。
  Future<String> ensureTempDirPath();

  /// 返回缓存总根目录路径（`<Root>/cache`，不主动建空目录）。
  Future<String> resolveCacheRootPath();
}
