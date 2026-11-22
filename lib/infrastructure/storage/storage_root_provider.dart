import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/config/konata_lane_config.dart';

/// 应用级便携路径常量配置（严禁在业务层硬编码目录名或写死系统 `%TEMP%`）。
abstract final class StoragePathConfig {
  static const String userdataDirName = 'userdata';
  static const String mpvSubdirName = 'mpv';
  static const String shadersSubdirName = 'shaders';
  static const String logsSubdirName = 'logs';
  static const String cacheDirName = 'cache';
  static const String tempSubdirName = 'tmp';
  static const String photosDirName = 'photos';
  static const String subtitleStageSubdirName = 'konata_subs';
  static const String cueStageSubdirName = 'konata_cues';
  static const String fontPoolSubdirName = 'konata_fonts';
  static const String cloudSubsetCacheSubdirName = 'konata_cloud_subs';
  static const String scanSnapshotsSubdirName = 'scan_snapshots';
}

/// Konata 统一便携根目录解析与工作区路径服务。
///
/// - **Windows 桌面端（纯绿色便携）**：
///   - 开发/测试模式（检测到 `pubspec.yaml`）：定位项目根目录；
///   - 发布运行模式：严格定位 `File(Platform.resolvedExecutable).parent`；
///   - 非主干隔离车道（如 `next`、`maint`）：在基础目录下自动分流至 `Konata_<lane>`；
///   - 绝不向 C 盘 `%APPDATA%`、`%LOCALAPPDATA%` 或系统 `%TEMP%` 写入缓存与截图。
/// - **Android 端**：统一委托 `ApplicationSupportDirectory`，上层代码零平台分支。
class StorageRootService {
  /// 创建路径服务（可选注入隔离根目录或测试专用车道覆盖值）。
  const StorageRootService({this._overrideRoot, this._laneOverride});

  /// 按当前运行平台构建根路径服务（Android 预先解析应用私有支持目录，避免同步读取可执行文件 `/system/bin`）。
  static Future<StorageRootService> createForCurrentPlatform() async {
    if (Platform.isAndroid) {
      final appSupport = await getApplicationSupportDirectory();
      return StorageRootService(overrideRoot: appSupport);
    }
    return const StorageRootService();
  }

  final Directory? _overrideRoot;
  final String? _laneOverride;

  static final RegExp _invalidPathChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
  static final RegExp _safePlainId = RegExp(r'^[A-Za-z0-9_-]{1,32}$');
  static final RegExp _nonTagChars = RegExp(r'[^A-Za-z0-9_-]+');

  /// 解析当前应用便携根目录（异步版，完整支持 Android `ApplicationSupportDirectory`）。
  Future<Directory> resolveAppRoot() async {
    final override = _overrideRoot;
    if (override != null) {
      return _applyOptionalLaneOverride(override);
    }

    if (Platform.isAndroid) {
      return getApplicationSupportDirectory();
    }
    return resolvePortableDesktopRootSync(laneOverride: _laneOverride);
  }

  /// 同步解析桌面端或测试覆盖根路径（供同步初始化流程使用）。
  Directory resolveAppRootSync() {
    final override = _overrideRoot;
    if (override != null) {
      return _applyOptionalLaneOverride(override);
    }
    return resolvePortableDesktopRootSync(laneOverride: _laneOverride);
  }

  Directory _applyOptionalLaneOverride(Directory baseDirectory) {
    final laneOverride = _laneOverride;
    if (laneOverride == null) {
      return baseDirectory;
    }
    final isolatedSubdir = KonataLaneConfig.isolatedDirectoryName(laneOverride);
    if (isolatedSubdir == null) {
      return baseDirectory;
    }
    return Directory(p.join(baseDirectory.path, isolatedSubdir));
  }

  /// 计算桌面开发态或打包运行态根路径：主干直取基础目录，隔离车道追加 `Konata_<lane>`。
  static Directory resolvePortableDesktopRootSync({
    Directory? baseDirectory,
    String? laneOverride,
  }) {
    final base = baseDirectory ?? _detectDesktopBaseDirectorySync();
    final isolatedSubdir = KonataLaneConfig.isolatedDirectoryName(laneOverride);
    if (isolatedSubdir == null) {
      return base;
    }
    return Directory(p.join(base.path, isolatedSubdir));
  }

  static Directory _detectDesktopBaseDirectorySync() {
    final cwd = Directory.current;
    if (File(p.join(cwd.path, 'pubspec.yaml')).existsSync()) {
      return cwd;
    }
    return Directory(p.dirname(Platform.resolvedExecutable));
  }

  /// 解析 `photos/` 图片总根目录（按需建目录，不预建）。
  Future<Directory> photosRootDir() async {
    final root = await resolveAppRoot();
    return Directory(p.join(root.path, StoragePathConfig.photosDirName));
  }

  /// 同步解析 `photos/` 图片总根目录（Windows / 测试环境使用）。
  Directory photosRootDirSync() {
    final root = resolveAppRootSync();
    return Directory(p.join(root.path, StoragePathConfig.photosDirName));
  }

  /// 解析并按需创建 `userdata/` 目录。
  Future<Directory> ensureUserdataDir() async {
    final root = await resolveAppRoot();
    final dir = Directory(p.join(root.path, StoragePathConfig.userdataDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 解析并按需创建内置 `libmpv` 隔离配置沙箱 `<Root>/userdata/mpv/`。
  Future<Directory> ensureMpvConfigDir() async {
    final userdata = await ensureUserdataDir();
    final dir = Directory(
      p.join(userdata.path, StoragePathConfig.mpvSubdirName),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 解析并按需创建自定义 `.glsl` 着色器目录 `<Root>/userdata/shaders/`。
  Future<Directory> ensureShadersDir() async {
    final userdata = await ensureUserdataDir();
    final dir = Directory(
      p.join(userdata.path, StoragePathConfig.shadersSubdirName),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 同步只读解析自定义 `.glsl` 着色器目录路径（不自动建空目录）。
  Directory resolveShadersDirSync() {
    final root = resolveAppRootSync();
    return Directory(
      p.join(
        root.path,
        StoragePathConfig.userdataDirName,
        StoragePathConfig.shadersSubdirName,
      ),
    );
  }

  /// 同步只读解析运行诊断日志目录 `<Root>/userdata/logs/`（不自动建空目录）。
  Directory resolveLogsDirSync() {
    final root = resolveAppRootSync();
    return Directory(
      p.join(
        root.path,
        StoragePathConfig.userdataDirName,
        StoragePathConfig.logsSubdirName,
      ),
    );
  }

  /// 解析并按需创建运行诊断日志目录 `<Root>/userdata/logs/`。
  Future<Directory> ensureLogsDir() async {
    final userdata = await ensureUserdataDir();
    final dir = Directory(
      p.join(userdata.path, StoragePathConfig.logsSubdirName),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 解析并按需创建媒体源目录扫描快照与断点续扫目录 `<Root>/userdata/cache/scan_snapshots/`。
  Future<Directory> ensureScanSnapshotsDir() async {
    final userdata = await ensureUserdataDir();
    final dir = Directory(
      p.join(
        userdata.path,
        StoragePathConfig.cacheDirName,
        StoragePathConfig.scanSnapshotsSubdirName,
      ),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 解析并按需创建应用隔离缓存临时目录 `<Root>/cache/tmp/`（替代系统 `%TEMP%`）。
  Future<Directory> ensureTempDir() async {
    final root = await resolveAppRoot();
    final dir = Directory(
      p.join(
        root.path,
        StoragePathConfig.cacheDirName,
        StoragePathConfig.tempSubdirName,
      ),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 返回远程外挂字幕暂存目录 `<Root>/cache/tmp/konata_subs/<workHash>/`。
  Future<Directory> ensureSubtitleStageDir(String workHash) async {
    final tmp = await ensureTempDir();
    final dir = Directory(
      p.join(tmp.path, StoragePathConfig.subtitleStageSubdirName, workHash),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 返回本地外部音频归一化影子 `.cue` 暂存目录 `<Root>/cache/tmp/konata_cues/`。
  Future<Directory> ensureCueStageDir() async {
    final tmp = await ensureTempDir();
    final dir = Directory(
      p.join(tmp.path, StoragePathConfig.cueStageSubdirName),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 返回单级字体哈希池目录 `<Root>/cache/tmp/konata_fonts/`。
  Future<Directory> ensureFontPoolDir() async {
    final tmp = await ensureTempDir();
    final dir = Directory(
      p.join(tmp.path, StoragePathConfig.fontPoolSubdirName),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 返回云端字体子集化字幕原子缓存目录 `<Root>/cache/tmp/konata_cloud_subs/`。
  Future<Directory> ensureCloudSubtitleCacheDir() async {
    final tmp = await ensureTempDir();
    final dir = Directory(
      p.join(tmp.path, StoragePathConfig.cloudSubsetCacheSubdirName),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 规范化作品名，过滤 Windows 非法路径字符与尾随句点。
  static String sanitizeWorkTitle(String raw) {
    var cleaned = raw.replaceAll(_invalidPathChars, ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    while (cleaned.endsWith('.')) {
      cleaned = cleaned.substring(0, cleaned.length - 1).trim();
    }
    if (cleaned.length > 48) {
      cleaned = cleaned.substring(0, 48).trim();
      while (cleaned.endsWith('.')) {
        cleaned = cleaned.substring(0, cleaned.length - 1).trim();
      }
    }
    return cleaned.isEmpty ? '未命名作品' : cleaned;
  }

  /// 将作品 ID 映射为确定性的安全目录后缀标签。
  static String encodeWorkIdTag(String workId) {
    final trimmed = workId.trim();
    if (_safePlainId.hasMatch(trimmed)) {
      return trimmed;
    }
    final prefix = trimmed.replaceAll(_nonTagChars, '');
    final head = prefix.isEmpty
        ? 'w'
        : (prefix.length > 12 ? prefix.substring(0, 12) : prefix);
    var hash = 2166136261;
    for (final unit in trimmed.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    final suffix = hash.toRadixString(16).padLeft(8, '0');
    return '$head-$suffix';
  }

  /// 生成视频纯净截图的目标路径（`<Root>/photos/<作品名> [<workId>]/konata_<stamp>.png`）。
  Future<File> allocateWorkScreenshotFile({
    required Directory workPhotoDirectory,
    required DateTime timestamp,
    String? episodeTag,
  }) async {
    await workPhotoDirectory.create(recursive: true);
    final stamp =
        '${timestamp.year}'
        '${timestamp.month.toString().padLeft(2, '0')}'
        '${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}'
        '${timestamp.minute.toString().padLeft(2, '0')}'
        '${timestamp.second.toString().padLeft(2, '0')}';
    final cleanTag = (episodeTag ?? '')
        .replaceAll(_invalidPathChars, '')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    final prefix = cleanTag.isEmpty ? 'shot' : cleanTag;
    var candidate = File(
      p.join(workPhotoDirectory.path, '${prefix}_$stamp.png'),
    );
    var index = 1;
    while (candidate.existsSync()) {
      candidate = File(
        p.join(workPhotoDirectory.path, '${prefix}_${stamp}_$index.png'),
      );
      index += 1;
    }
    return candidate;
  }
}

/// 全局统一便携根目录服务 Provider。
final storageRootProvider = Provider<StorageRootService>((ref) {
  return const StorageRootService();
});
