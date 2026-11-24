import 'dart:async';
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import 'video_playback_preferences.dart';

/// 待导入自定义着色器源描述符（支持文件路径与内存字节流两种来源）。
@immutable
class ShaderImportSource {
  /// 创建着色器导入源描述。
  const ShaderImportSource({
    required this.name,
    this.sourcePath,
    this.bytes,
    this.readBytes,
  });

  /// 原始文件名称（含扩展名）。
  final String name;

  /// 本地文件系统源路径。
  final String? sourcePath;

  /// 内存字节载荷。
  final Uint8List? bytes;

  /// 异步字节读取回调（适配移动平台文档句柄直读）。
  final Future<Uint8List> Function()? readBytes;
}

/// 批量导入着色器脚本的执行摘要统计。
@immutable
class ShaderImportResult {
  /// 创建着色器导入结果摘要。
  const ShaderImportResult({
    this.imported = const <ShaderFileEntry>[],
    this.skippedUnsupported = 0,
    this.failedCount = 0,
  });

  /// 成功复制并落盘的着色器条目列表。
  final List<ShaderFileEntry> imported;

  /// 因扩展名非标准脚本而跳过的数量。
  final int skippedUnsupported;

  /// 读写失败的文件数量。
  final int failedCount;
}

/// 面向界面展示的着色器只读描述条目。
@immutable
class ShaderFileEntry {
  /// 创建着色器文件条目。
  const ShaderFileEntry({required this.path, required this.name});

  /// 着色器完整磁盘路径。
  final String path;

  /// 着色器文件名。
  final String name;

  @override
  bool operator ==(Object other) =>
      other is ShaderFileEntry && other.path == path && other.name == name;

  @override
  int get hashCode => Object.hash(path, name);
}

/// 着色器目录扫描状态不可变快照。
@immutable
class ShaderDiscoveryState {
  /// 创建着色器目录发现状态快照。
  const ShaderDiscoveryState({
    this.directoryPath,
    this.files = const <ShaderFileEntry>[],
    this.isScanning = false,
  });

  /// 应用专属着色器目录绝对路径。
  final String? directoryPath;

  /// 已扫描到的可用着色器文件清单。
  final List<ShaderFileEntry> files;

  /// 是否正在执行后台异步扫描。
  final bool isScanning;

  /// 生成局部替换后的新状态快照。
  ShaderDiscoveryState copyWith({
    String? directoryPath,
    List<ShaderFileEntry>? files,
    bool? isScanning,
  }) {
    return ShaderDiscoveryState(
      directoryPath: directoryPath ?? this.directoryPath,
      files: files ?? this.files,
      isScanning: isScanning ?? this.isScanning,
    );
  }
}

/// 异步着色器目录发现、原子导入与安全删除服务（完全隔离界面线程磁盘遍历）。
class ShaderDiscoveryService extends ChangeNotifier {
  /// 创建着色器发现服务实例。
  ShaderDiscoveryService({
    required this.storageRoot,
    required this.preferencesStore,
    this.logStore,
  });

  /// 跨端存储根目录端口。
  final StorageRootPort storageRoot;

  /// 视频播放偏好自治存储仓储。
  final VideoPlaybackPreferencesStore preferencesStore;

  /// 可选脱敏结构化诊断日志端口。
  final DiagnosticLogPort? logStore;

  static final RegExp _unsafeShaderNameChars = RegExp(
    r'[<>:"/\\|?*;\x00-\x1F]',
  );

  ShaderDiscoveryState _state = const ShaderDiscoveryState();
  bool _pendingRefresh = false;
  bool _disposed = false;

  /// 当前最新的着色器发现状态快照。
  ShaderDiscoveryState get state => _state;

  /// 异步扫描便携根目录及用户数据目录内全部可用的着色器文件。
  Future<void> refresh() async {
    if (_disposed) return;
    if (_state.isScanning) {
      _pendingRefresh = true;
      return;
    }
    do {
      _pendingRefresh = false;
      _setState(_state.copyWith(isScanning: true));
      try {
        final targetDir = await _ensureUserShadersDir();
        final files = await PlaybackStoragePaths.discoverShaderFiles(
          storageRoot,
        );
        if (_disposed) return;
        _setState(
          ShaderDiscoveryState(
            directoryPath: targetDir.path,
            files: List<ShaderFileEntry>.unmodifiable(<ShaderFileEntry>[
              for (final file in files)
                ShaderFileEntry(path: file.path, name: p.basename(file.path)),
            ]),
            isScanning: false,
          ),
        );
      } catch (error) {
        if (!_disposed) {
          PlaybackLogHelper.record(
            logStore,
            'SHADER',
            '异步扫描着色器目录失败：$error',
            isError: true,
            error: error,
          );
          _setState(_state.copyWith(isScanning: false));
        }
        return;
      }
    } while (_pendingRefresh && !_disposed);
  }

  /// 确保用户着色器存放目录已创建并返回绝对路径。
  Future<String> ensureDirectoryPath() async {
    final existing = _state.directoryPath;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final dir = await _ensureUserShadersDir();
    if (!_disposed) {
      _setState(_state.copyWith(directoryPath: dir.path));
    }
    return dir.path;
  }

  /// 校验扩展名并原子写入自定义着色器文件至用户专属着色器目录。
  Future<ShaderImportResult> importShaderFiles(
    List<ShaderImportSource> sources,
  ) async {
    if (sources.isEmpty) {
      return const ShaderImportResult();
    }
    final dir = await _ensureUserShadersDir();
    final imported = <ShaderFileEntry>[];
    var skippedUnsupported = 0;
    var failedCount = 0;

    for (final src in sources) {
      final segments = src.name.trim().split(RegExp(r'[/\\]'));
      final rawName = segments.isEmpty ? '' : segments.last.trim();
      final dotIdx = rawName.lastIndexOf('.');
      final ext = dotIdx > 0 ? rawName.substring(dotIdx).toLowerCase() : '';
      if (ext != '.glsl' && ext != '.hook') {
        skippedUnsupported++;
        continue;
      }
      final stem = rawName
          .substring(0, dotIdx)
          .replaceAll(_unsafeShaderNameChars, '_')
          .trim();
      final safeName = '${stem.isEmpty ? 'shader' : stem}$ext';

      try {
        Uint8List? content = src.bytes;
        if (content == null && src.readBytes != null) {
          content = await src.readBytes!();
        }
        if (content == null) {
          final srcPath = src.sourcePath?.trim() ?? '';
          if (srcPath.isEmpty) {
            failedCount++;
            continue;
          }
          content = await File(srcPath).readAsBytes();
        }
        if (content.isEmpty) {
          failedCount++;
          continue;
        }

        final targetPath = p.join(dir.path, safeName);
        final tempFile = File(
          '$targetPath.tmp_${DateTime.now().microsecondsSinceEpoch}',
        );
        try {
          await tempFile.writeAsBytes(content, flush: true);
          final targetFile = File(targetPath);
          if (targetFile.existsSync()) {
            targetFile.deleteSync();
          }
          await tempFile.rename(targetPath);
        } finally {
          if (tempFile.existsSync()) {
            tempFile.deleteSync();
          }
        }
        imported.add(ShaderFileEntry(path: targetPath, name: safeName));
      } catch (error) {
        failedCount++;
        PlaybackLogHelper.record(
          logStore,
          'SHADER',
          '导入着色器 $rawName 失败：$error',
          isError: true,
          error: error,
        );
      }
    }

    if (!_disposed) {
      await refresh();
    }
    return ShaderImportResult(
      imported: List<ShaderFileEntry>.unmodifiable(imported),
      skippedUnsupported: skippedUnsupported,
      failedCount: failedCount,
    );
  }

  /// 安全删除用户专属着色器目录内的文件并同步移除激活列表中的对应项。
  Future<bool> deleteShaderFile(String shaderPath) async {
    final normalizedTarget = p.normalize(shaderPath.trim());
    if (normalizedTarget.isEmpty) return false;
    try {
      final dir = await _ensureUserShadersDir();
      final normalizedDir = p.normalize(dir.path);
      if (!p.isWithin(normalizedDir, normalizedTarget)) {
        return false;
      }
      final file = File(normalizedTarget);
      if (file.existsSync()) {
        file.deleteSync();
      }
      if (!_disposed) {
        preferencesStore.toggleShaderPath(shaderPath, false);
        await refresh();
      }
      return true;
    } catch (error) {
      PlaybackLogHelper.record(
        logStore,
        'SHADER',
        '删除着色器失败：$error',
        isError: true,
        error: error,
      );
      return false;
    }
  }

  Future<Directory> _ensureUserShadersDir() async {
    final userdataPath = await storageRoot.ensureUserdataDirPath();
    final dir = Directory(
      p.join(userdataPath, StoragePathNames.shadersSubdir),
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  void _setState(ShaderDiscoveryState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
