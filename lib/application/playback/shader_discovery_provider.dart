import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../providers/diagnostics_providers.dart';

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
class ShaderDiscoveryNotifier extends StateNotifier<ShaderDiscoveryState> {
  /// 创建着色器发现编排器并在后台异步完成首次扫描。
  ShaderDiscoveryNotifier(this._ref) : super(const ShaderDiscoveryState()) {
    unawaited(refresh());
  }

  final Ref _ref;

  /// 异步扫描 `userdata/shaders/` 下的全部可用着色器脚本。
  Future<void> refresh() async {
    if (state.isScanning) return;
    state = state.copyWith(isScanning: true);
    try {
      final dir = await _ref.read(storageRootProvider).ensureShadersDir();
      final files = await MpvQualityProfile.discoverShaderFiles(dir);
      if (!mounted) return;
      state = ShaderDiscoveryState(
        directoryPath: dir.path,
        files: List<ShaderFileEntry>.unmodifiable([
          for (final f in files)
            ShaderFileEntry(path: f.path, name: path.basename(f.path)),
        ]),
        isScanning: false,
      );
    } catch (e) {
      _ref
          .read(diagnosticsLogStoreProvider)
          .record('SHADER', '异步扫描着色器目录失败：$e', isError: true);
      if (!mounted) return;
      state = state.copyWith(isScanning: false);
    }
  }

  /// 确保着色器目录已创建并返回其文件系统路径。
  Future<String> ensureDirectoryPath() async {
    final existing = state.directoryPath;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final dir = await _ref.read(storageRootProvider).ensureShadersDir();
    if (mounted) {
      state = state.copyWith(directoryPath: dir.path);
    }
    return dir.path;
  }
}

/// 全局按需着色器目录异步发现 Provider（关闭页面自动释放）。
final shaderDiscoveryProvider =
    StateNotifierProvider.autoDispose<
      ShaderDiscoveryNotifier,
      ShaderDiscoveryState
    >((ref) => ShaderDiscoveryNotifier(ref));
