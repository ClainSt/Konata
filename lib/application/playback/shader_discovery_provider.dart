import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../providers/diagnostics_providers.dart';
import 'playback_preferences_provider.dart';

/// 供表现层提交的待导入着色器源文件描述符（支持 Android SAF 异步流读取与本地路径双来源）。
@immutable
class ShaderImportSource {
  /// 创建着色器导入源描述。
  const ShaderImportSource({
    required this.name,
    this.sourcePath,
    this.bytes,
    this.readBytes,
  });

  /// 原始文件名（含扩展名）。
  final String name;

  /// 可选本地文件路径（当未提供字节读取回调时按路径读取）。
  final String? sourcePath;

  /// 可选内存字节流。
  final Uint8List? bytes;

  /// 可选异步字节读取回调（适配 Android SAF `content://` 句柄直读）。
  final Future<Uint8List> Function()? readBytes;
}

/// 批量导入着色器脚本的执行摘要。
@immutable
class ShaderImportResult {
  /// 创建着色器导入结果摘要。
  const ShaderImportResult({
    this.imported = const <ShaderFileEntry>[],
    this.skippedUnsupported = 0,
    this.failedCount = 0,
  });

  /// 成功落盘的着色器条目列表。
  final List<ShaderFileEntry> imported;

  /// 因扩展名不属于 `.glsl` / `.hook` 而跳过的数量。
  final int skippedUnsupported;

  /// 读取或写入磁盘失败的数量。
  final int failedCount;
}

/// 面向表现层的着色器文件只读描述符（隔离 `dart:io` `File` 类型）。
@immutable
class ShaderFileEntry {
  /// 创建着色器文件条目。
  const ShaderFileEntry({required this.path, required this.name});

  /// 着色器完整文件路径。
  final String path;

  /// 着色器文件名。
  final String name;

  @override
  bool operator ==(Object other) {
    return other is ShaderFileEntry && other.path == path && other.name == name;
  }

  @override
  int get hashCode => Object.hash(path, name);
}

/// 着色器目录异步扫描状态快照。
@immutable
class ShaderDiscoveryState {
  /// 创建着色器目录状态快照。
  const ShaderDiscoveryState({
    this.directoryPath,
    this.files = const <ShaderFileEntry>[],
    this.isScanning = false,
  });

  /// 当前着色器目录路径。
  final String? directoryPath;

  /// 已发现的 `.glsl` / `.hook` 着色器列表。
  final List<ShaderFileEntry> files;

  /// 当前是否正在异步扫描目录。
  final bool isScanning;

  /// 生成更新后的状态副本。
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

/// 异步着色器目录发现与目录路径解析编排器（消除 UI 主线程同步磁盘遍历与 `dart:io` 泄漏）。
class ShaderDiscoveryNotifier extends Notifier<ShaderDiscoveryState> {
  bool _pendingRefresh = false;

  @override
  ShaderDiscoveryState build() {
    unawaited(Future<void>.microtask(refresh));
    return const ShaderDiscoveryState();
  }

  /// 异步扫描 `userdata/shaders/` 下的全部可用着色器脚本（若扫描进行中则合并为结束后自动补扫一次）。
  Future<void> refresh() async {
    if (!ref.mounted) return;
    if (state.isScanning) {
      _pendingRefresh = true;
      return;
    }
    do {
      _pendingRefresh = false;
      state = state.copyWith(isScanning: true);
      try {
        final dir = await ref.read(storageRootProvider).ensureShadersDir();
        final files = await MpvQualityProfile.discoverShaderFiles(dir);
        if (!ref.mounted) return;
        state = ShaderDiscoveryState(
          directoryPath: dir.path,
          files: List<ShaderFileEntry>.unmodifiable([
            for (final f in files)
              ShaderFileEntry(path: f.path, name: path.basename(f.path)),
          ]),
          isScanning: false,
        );
      } catch (e) {
        if (ref.mounted) {
          ref
              .read(diagnosticsLogStoreProvider)
              .record('SHADER', '异步扫描着色器目录失败：$e', isError: true);
          state = state.copyWith(isScanning: false);
        }
        return;
      }
    } while (_pendingRefresh && ref.mounted);
  }

  static final RegExp _unsafeShaderNameChars = RegExp(
    r'[<>:"/\\|?*;\x00-\x1F]',
  );

  /// 确保着色器目录已创建并返回其文件系统路径。
  Future<String> ensureDirectoryPath() async {
    final existing = state.directoryPath;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final dir = await ref.read(storageRootProvider).ensureShadersDir();
    if (ref.mounted) {
      state = state.copyWith(directoryPath: dir.path);
    }
    return dir.path;
  }

  /// 校验扩展名、清洗路径分隔风险字符并原子导入 `.glsl` / `.hook` 脚本至应用专属着色器目录。
  Future<ShaderImportResult> importShaderFiles(
    List<ShaderImportSource> sources,
  ) async {
    if (sources.isEmpty) {
      return const ShaderImportResult();
    }
    final dir = await ref.read(storageRootProvider).ensureShadersDir();
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

        final targetPath = path.join(dir.path, safeName);
        final tempFile = File(
          '$targetPath.tmp_${DateTime.now().microsecondsSinceEpoch}',
        );
        try {
          await tempFile.writeAsBytes(content, flush: true);
          final targetFile = File(targetPath);
          if (await targetFile.exists()) {
            await targetFile.delete();
          }
          await tempFile.rename(targetPath);
        } finally {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        }
        imported.add(ShaderFileEntry(path: targetPath, name: safeName));
      } catch (e) {
        failedCount++;
        if (ref.mounted) {
          ref
              .read(diagnosticsLogStoreProvider)
              .record('SHADER', '导入着色器 $rawName 失败：$e', isError: true);
        }
      }
    }

    if (ref.mounted) {
      await refresh();
    }
    return ShaderImportResult(
      imported: List<ShaderFileEntry>.unmodifiable(imported),
      skippedUnsupported: skippedUnsupported,
      failedCount: failedCount,
    );
  }

  /// 安全删除位于应用专属 `userdata/shaders/` 目录内的着色器文件，并同步取消其激活状态。
  Future<bool> deleteShaderFile(String shaderPath) async {
    final normalizedTarget = path.normalize(shaderPath.trim());
    if (normalizedTarget.isEmpty) return false;
    try {
      final dir = await ref.read(storageRootProvider).ensureShadersDir();
      final normalizedDir = path.normalize(dir.path);
      if (!path.isWithin(normalizedDir, normalizedTarget)) {
        return false;
      }
      final file = File(normalizedTarget);
      if (await file.exists()) {
        await file.delete();
      }
      if (ref.mounted) {
        await ref
            .read(playbackPreferencesProvider.notifier)
            .toggleShaderPath(shaderPath, false);
        await refresh();
      }
      return true;
    } catch (e) {
      if (ref.mounted) {
        ref
            .read(diagnosticsLogStoreProvider)
            .record('SHADER', '删除着色器失败：$e', isError: true);
      }
      return false;
    }
  }
}

/// 全局按需着色器目录异步发现 Provider（关闭页面自动释放）。
final shaderDiscoveryProvider =
    NotifierProvider.autoDispose<
      ShaderDiscoveryNotifier,
      ShaderDiscoveryState
    >(ShaderDiscoveryNotifier.new);
