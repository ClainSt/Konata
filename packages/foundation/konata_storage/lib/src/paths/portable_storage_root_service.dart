import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

/// 纯 Dart 跨端统一存储根目录解析服务（实现 [StorageRootPort]，严格 0 Flutter 依赖）。
///
/// - **Windows 桌面端（纯绿色便携、零写 C 盘）**：
///   - 发布运行态：严格定位 `Platform.resolvedExecutable` 同级目录；
///   - 开发/测试态：检测到 `pubspec.yaml` 时自动向上定位工作区根目录；
///   - 非主干隔离车道（`KONATA_LANE`）：自动分流至 `<Base>/Konata_<lane>`；
///   - 绝不向 `%APPDATA%`、`%LOCALAPPDATA%` 或系统 `%TEMP%` 写入业务文件与缓存。
/// - **Android 端**：由 `apps/konata` 宿主壳通过 `overrideRootPath` 注入
///   `ApplicationSupportDirectory` 路径，底层存储包无需任何 Flutter 依赖。
final class PortableStorageRootService implements StorageRootPort {
  /// 创建存储根目录解析服务（Android 与测试环境可通过 [overrideRootPath] 显式注入）。
  const PortableStorageRootService({
    this._overrideRootPath,
    this._laneOverride,
  });

  final String? _overrideRootPath;
  final String? _laneOverride;

  /// 同步解析当前有效应用根路径（包含可选隔离车道子目录）。
  String resolveAppRootPathSync() {
    final override = _overrideRootPath;
    if (override != null && override.trim().isNotEmpty) {
      return _applyLaneIfNeeded(override.trim(), respectCompileTimeLane: false);
    }
    final base = _detectDesktopPortableBasePathSync();
    return _applyLaneIfNeeded(base, respectCompileTimeLane: true);
  }

  /// 计算桌面绿色便携基础路径（支持测试传入显式工作目录与可执行路径）。
  static String detectDesktopBasePathSync({
    required String workingDirectoryPath,
    required String resolvedExecutablePath,
  }) {
    final cwdPubspec = File(p.join(workingDirectoryPath, 'pubspec.yaml'));
    if (cwdPubspec.existsSync()) {
      return _resolveWorkspaceRootIfPresent(workingDirectoryPath);
    }
    return p.dirname(resolvedExecutablePath);
  }

  @override
  Future<String> resolveAppRootPath() async => resolveAppRootPathSync();

  @override
  Future<String> ensureUserdataDirPath() async {
    final dir = Directory(
      p.join(resolveAppRootPathSync(), StoragePathNames.userdataDir),
    );
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> ensureDatabaseDirPath() async {
    final userdata = await ensureUserdataDirPath();
    final dir = Directory(p.join(userdata, StoragePathNames.dbSubdir));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> resolveDatabaseFilePath(String dbFileName) async {
    final dbDir = await ensureDatabaseDirPath();
    return p.join(dbDir, dbFileName);
  }

  @override
  Future<String> ensureLogsDirPath() async {
    final userdata = await ensureUserdataDirPath();
    final dir = Directory(p.join(userdata, StoragePathNames.logsSubdir));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> resolvePhotosDirPath() async =>
      p.join(resolveAppRootPathSync(), StoragePathNames.photosDir);

  @override
  Future<String> ensureTempDirPath() async {
    final dir = Directory(
      p.join(
        resolveAppRootPathSync(),
        StoragePathNames.cacheDir,
        StoragePathNames.tempSubdir,
      ),
    );
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> resolveCacheRootPath() async =>
      p.join(resolveAppRootPathSync(), StoragePathNames.cacheDir);

  String _applyLaneIfNeeded(
    String basePath, {
    required bool respectCompileTimeLane,
  }) {
    final effectiveOverride = _laneOverride;
    if (!respectCompileTimeLane && effectiveOverride == null) {
      return basePath;
    }
    final isolatedDir = KonataLaneConfig.isolatedDirectoryName(
      effectiveOverride,
    );
    if (isolatedDir == null) {
      return basePath;
    }
    return p.join(basePath, isolatedDir);
  }

  static String _detectDesktopPortableBasePathSync() {
    return detectDesktopBasePathSync(
      workingDirectoryPath: Directory.current.path,
      resolvedExecutablePath: Platform.resolvedExecutable,
    );
  }

  /// 若当前位于工作区子包目录（含 `resolution: workspace`），向上回溯至包含 `workspace:` 的仓根目录。
  static String _resolveWorkspaceRootIfPresent(String startDirPath) {
    var cursor = Directory(startDirPath).absolute;
    for (var depth = 0; depth < 5; depth++) {
      final pubspec = File(p.join(cursor.path, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        if (RegExp(r'^workspace:\s*$', multiLine: true).hasMatch(content)) {
          return cursor.path;
        }
      }
      final parent = cursor.parent;
      if (parent.path == cursor.path) break;
      cursor = parent;
    }
    return startDirPath;
  }
}

/// 纯内存敏感凭据存储实现（仅供纯 Dart 单元测试与无宿主验证场景使用）。
final class InMemorySecureStorage implements SecureStoragePort {
  /// 创建纯内存安全存储实例。
  InMemorySecureStorage([Map<String, String>? initial])
    : _entries = <String, String>{...?initial};

  final Map<String, String> _entries;

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      _entries.remove(key);
      return;
    }
    _entries[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }

  @override
  Future<Map<String, String>> readAllWithPrefix(String prefix) async {
    return <String, String>{
      for (final entry in _entries.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }
}
