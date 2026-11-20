import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 全局唯一系统文件/目录选择器 Provider（单飞互斥锁，全应用同一时刻至多弹出一个原生系统窗口）。
final konataSystemFilePickerProvider = Provider<KonataSystemFilePicker>(
  (ref) => KonataSystemFilePicker(),
);

/// 统一系统文件与目录选择器封装。
///
/// 职责：
/// 1. 通过单飞互斥锁拦截连续点击导致的原生文件浏览窗口无限重复弹出；
/// 2. 在 Windows 端自动启用 `WindowsOptions(lockParentWindow: true)` 绑定主窗口模态归属，
///    防止系统对话框落到主窗口后方并引导焦点准确回落至已打开窗口。
class KonataSystemFilePicker {
  /// 创建系统文件选择器实例（支持在单测中注入替身实现验证并发互斥行为）。
  KonataSystemFilePicker({
    this.pickFilesImpl,
    this.getDirectoryPathImpl,
    this.saveFileImpl,
  });

  /// 可选文件选择替身实现（供测试注入验证单飞锁）。
  final Future<List<PlatformFile>> Function({
    String? dialogTitle,
    String? initialDirectory,
    FileType type,
    List<String>? allowedExtensions,
    WindowsOptions windowsOptions,
  })?
  pickFilesImpl;

  /// 可选目录选择替身实现（供测试注入验证单飞锁）。
  final Future<String?> Function({
    String? dialogTitle,
    String? initialDirectory,
    WindowsOptions windowsOptions,
  })?
  getDirectoryPathImpl;

  /// 可选保存文件替身实现（供测试注入验证单飞锁）。
  final Future<Uri?> Function({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
    String? initialDirectory,
    WindowsOptions windowsOptions,
  })?
  saveFileImpl;

  bool _isDialogOpen = false;

  /// 当前是否已有原生文件/目录选择窗口处于打开态。
  bool get isDialogOpen => _isDialogOpen;

  /// 从最近的 `ProviderScope` 解析全局单飞选择器；无容器的轻量单测场景回退至调用方局部实例。
  static KonataSystemFilePicker resolve(
    BuildContext context, {
    required KonataSystemFilePicker fallback,
  }) {
    try {
      return ProviderScope.containerOf(
        context,
        listen: false,
      ).read(konataSystemFilePickerProvider);
    } catch (_) {
      return fallback;
    }
  }

  Future<T?> _runSingleFlight<T>(Future<T> Function() action) async {
    if (_isDialogOpen) {
      return null;
    }
    _isDialogOpen = true;
    try {
      return await action();
    } finally {
      _isDialogOpen = false;
    }
  }

  /// 打开系统文件选择窗口（若已有窗口打开则直接忽略并返回空列表）。
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async {
    const winOptions = WindowsOptions(lockParentWindow: true);
    final result = await _runSingleFlight<List<PlatformFile>>(() {
      final custom = pickFilesImpl;
      if (custom != null) {
        return custom(
          dialogTitle: dialogTitle,
          initialDirectory: initialDirectory,
          type: type,
          allowedExtensions: allowedExtensions,
          windowsOptions: winOptions,
        );
      }
      return FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        type: type,
        allowedExtensions: allowedExtensions,
        windowsOptions: winOptions,
      );
    });
    return result ?? const <PlatformFile>[];
  }

  /// 打开系统目录选择窗口（若已有窗口打开则直接忽略并返回 `null`）。
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
  }) {
    const winOptions = WindowsOptions(lockParentWindow: true);
    return _runSingleFlight<String?>(() {
      final custom = getDirectoryPathImpl;
      if (custom != null) {
        return custom(
          dialogTitle: dialogTitle,
          initialDirectory: initialDirectory,
          windowsOptions: winOptions,
        );
      }
      return FilePicker.getDirectoryPath(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        windowsOptions: winOptions,
      );
    });
  }

  /// 打开系统保存文件窗口（若已有窗口打开则直接忽略并返回 `null`）。
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
    String? initialDirectory,
  }) {
    const winOptions = WindowsOptions(lockParentWindow: true);
    return _runSingleFlight<Uri?>(() {
      final custom = saveFileImpl;
      if (custom != null) {
        return custom(
          fileName: fileName,
          bytes: bytes,
          dialogTitle: dialogTitle,
          initialDirectory: initialDirectory,
          windowsOptions: winOptions,
        );
      }
      return FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        windowsOptions: winOptions,
      );
    });
  }
}
