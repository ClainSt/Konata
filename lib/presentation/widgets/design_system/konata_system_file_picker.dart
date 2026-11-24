import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../theme/konata_adaptive_tokens.dart';

/// 全局唯一系统文件/目录选择器 Provider（单飞互斥锁，全应用同一时刻至多弹出一个原生系统窗口）。
final konataSystemFilePickerProvider = Provider<KonataSystemFilePicker>(
  (ref) => KonataSystemFilePicker(),
);

/// 统一系统文件与目录选择器封装。
///
/// 职责：
/// 1. 通过单飞互斥锁拦截连续点击导致的原生文件浏览窗口无限重复弹出；
/// 2. 在 Windows 端优先经由主窗口同线程原生 COM 桥（`konata/win_file_picker`）拉起
///    `IFileOpenDialog` / `IFileSaveDialog`，彻底规避 `windows_file_picker` 在后台隔离区
///    跨线程锁定主窗口 `HWND` 引起的模态死锁卡死；
/// 3. 兜底回退至 `FilePicker` 时在 Windows 上强制关闭跨线程父窗口锁，防止回退路径再次死锁。
class KonataSystemFilePicker {
  /// Windows 同线程原生文件对话框通信通道。
  static const MethodChannel windowsMethodChannel = MethodChannel(
    'konata/win_file_picker',
  );

  /// 常见图像扩展名映射（供 `FileType.image` / `FileType.media` 构造原生过滤项）。
  static const List<String> _imageExtensions = <String>[
    'png',
    'jpg',
    'jpeg',
    'webp',
    'bmp',
    'gif',
    'tif',
    'tiff',
    'avif',
  ];

  /// 常见视频扩展名映射（供 `FileType.video` / `FileType.media` 构造原生过滤项）。
  static const List<String> _videoExtensions = <String>[
    'mp4',
    'mkv',
    'webm',
    'mov',
    'avi',
    'm2ts',
    'ts',
    'flv',
    'wmv',
  ];

  /// 常见音频扩展名映射（供 `FileType.audio` 构造原生过滤项）。
  static const List<String> _audioExtensions = <String>[
    'flac',
    'wav',
    'mp3',
    'aac',
    'm4a',
    'ogg',
    'opus',
    'ape',
    'wv',
    'tak',
    'dsf',
    'dff',
  ];

  /// 创建系统文件选择器实例（支持在单测中注入替身实现验证并发互斥与跨端桥接行为）。
  KonataSystemFilePicker({
    this.pickFilesImpl,
    this.getDirectoryPathImpl,
    this.saveFileImpl,
    this.useWindowsNativeBridge,
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

  /// 是否启用 Windows 同线程原生对话框桥（缺省按当前宿主平台自动判定）。
  final bool? useWindowsNativeBridge;

  bool _isDialogOpen = false;

  /// 当前是否已有原生文件/目录选择窗口处于打开态。
  bool get isDialogOpen => _isDialogOpen;

  bool get _shouldUseWindowsNativeBridge =>
      useWindowsNativeBridge ?? KonataAdaptiveTokens.isWindows;

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

  List<String> _resolveExtensions(FileType type, List<String>? custom) {
    return switch (type) {
      FileType.custom => custom ?? const <String>[],
      FileType.image => _imageExtensions,
      FileType.video => _videoExtensions,
      FileType.audio => _audioExtensions,
      FileType.media => const <String>[..._imageExtensions, ..._videoExtensions],
      FileType.any => const <String>[],
    };
  }

  /// 解析当前宿主平台实际传递给底层文件选择器的类型与扩展名过滤条件。
  ///
  /// Android `MimeTypeMap` 未注册 `.konata`、`.ass`、`.ssa`、`.sup` 等自定义扩展名；
  /// 当 `FileType.custom` 同时包含未注册与已注册扩展名（如 `['konata', 'json']`）时，
  /// `android_file_picker` 会静默丢弃未注册项并仅按已注册 MIME（如 `application/json`）过滤，
  /// 导致目标文件在系统文档选择器中不可见或灰显。Android 端统一退化为 `FileType.any`（`*/*`），
  /// 再由调用方配合 [matchesAllowedExtension] 与内容校验兜底。
  static ({FileType type, List<String>? allowedExtensions})
  resolvePlatformPickerFilter({
    required bool isAndroid,
    required FileType type,
    required List<String>? allowedExtensions,
  }) {
    if (isAndroid && type == FileType.custom) {
      return (type: FileType.any, allowedExtensions: null);
    }
    return (type: type, allowedExtensions: allowedExtensions);
  }

  /// 判断所选文件名后缀是否在允许列表中（忽略大小写与前导点号）。
  ///
  /// 当 Android 云盘或 SAF 文档提供方省略文件后缀时，可通过 [allowNoExtension] 放行交由内容解析校验。
  static bool matchesAllowedExtension(
    String fileName,
    Iterable<String> allowedExtensions, {
    bool allowNoExtension = false,
  }) {
    final ext = p.extension(fileName.trim()).replaceFirst('.', '').toLowerCase();
    if (ext.isEmpty) {
      return allowNoExtension;
    }
    for (final raw in allowedExtensions) {
      final normalized = raw.trim().replaceFirst('.', '').toLowerCase();
      if (normalized.isNotEmpty && normalized == ext) {
        return true;
      }
    }
    return false;
  }

  Future<List<PlatformFile>> _fallbackPickFiles({
    required String? dialogTitle,
    required String? initialDirectory,
    required FileType type,
    required List<String>? allowedExtensions,
    required bool allowMultiple,
  }) async {
    const safeFallbackWinOptions = WindowsOptions(lockParentWindow: false);
    final effective = resolvePlatformPickerFilter(
      isAndroid: KonataAdaptiveTokens.isAndroid,
      type: type,
      allowedExtensions: allowedExtensions,
    );
    if (!allowMultiple) {
      final single = await FilePicker.pickFile(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        type: effective.type,
        allowedExtensions: effective.allowedExtensions,
        windowsOptions: safeFallbackWinOptions,
      );
      return single == null ? const <PlatformFile>[] : <PlatformFile>[single];
    }
    return FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: effective.type,
      allowedExtensions: effective.allowedExtensions,
      windowsOptions: safeFallbackWinOptions,
    );
  }

  Future<String?> _fallbackGetDirectoryPath({
    required String? dialogTitle,
    required String? initialDirectory,
  }) async {
    const safeFallbackWinOptions = WindowsOptions(lockParentWindow: false);
    final uri = await FilePicker.pickDirectory(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      windowsOptions: safeFallbackWinOptions,
    );
    if (uri == null) return null;
    return uri.isScheme('file') ? uri.toFilePath() : uri.toString();
  }

  Future<Uri?> _fallbackSaveFile({
    required String fileName,
    required Uint8List bytes,
    required String? dialogTitle,
    required String? initialDirectory,
  }) {
    const safeFallbackWinOptions = WindowsOptions(lockParentWindow: false);
    return FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      windowsOptions: safeFallbackWinOptions,
    );
  }

  /// 打开系统文件选择窗口（若已有窗口打开则直接忽略并返回空列表）。
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = true,
  }) async {
    const customWinOptions = WindowsOptions(lockParentWindow: true);
    final result = await _runSingleFlight<List<PlatformFile>>(() async {
      final custom = pickFilesImpl;
      if (custom != null) {
        final effective = resolvePlatformPickerFilter(
          isAndroid: KonataAdaptiveTokens.isAndroid,
          type: type,
          allowedExtensions: allowedExtensions,
        );
        return custom(
          dialogTitle: dialogTitle,
          initialDirectory: initialDirectory,
          type: effective.type,
          allowedExtensions: effective.allowedExtensions,
          windowsOptions: customWinOptions,
        );
      }
      if (_shouldUseWindowsNativeBridge) {
        try {
          final rawPaths = await windowsMethodChannel
              .invokeListMethod<String>('pickFiles', <String, Object?>{
                'dialogTitle': dialogTitle,
                'initialDirectory': initialDirectory,
                'allowMultiple': allowMultiple,
                'allowedExtensions': _resolveExtensions(type, allowedExtensions),
              });
          if (rawPaths == null || rawPaths.isEmpty) {
            return const <PlatformFile>[];
          }
          return rawPaths
              .where((path) => path.trim().isNotEmpty)
              .map((path) => _WindowsPickedPlatformFile(path.trim()))
              .toList(growable: false);
        } on MissingPluginException {
          return _fallbackPickFiles(
            dialogTitle: dialogTitle,
            initialDirectory: initialDirectory,
            type: type,
            allowedExtensions: allowedExtensions,
            allowMultiple: allowMultiple,
          );
        }
      }
      return _fallbackPickFiles(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        type: type,
        allowedExtensions: allowedExtensions,
        allowMultiple: allowMultiple,
      );
    });
    return result ?? const <PlatformFile>[];
  }

  /// 打开系统目录选择窗口（若已有窗口打开则直接忽略并返回 `null`）。
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
  }) {
    const customWinOptions = WindowsOptions(lockParentWindow: true);
    return _runSingleFlight<String?>(() async {
      final custom = getDirectoryPathImpl;
      if (custom != null) {
        return custom(
          dialogTitle: dialogTitle,
          initialDirectory: initialDirectory,
          windowsOptions: customWinOptions,
        );
      }
      if (_shouldUseWindowsNativeBridge) {
        try {
          final rawPath = await windowsMethodChannel.invokeMethod<String>(
            'pickDirectory',
            <String, Object?>{
              'dialogTitle': dialogTitle,
              'initialDirectory': initialDirectory,
            },
          );
          if (rawPath == null || rawPath.trim().isEmpty) {
            return null;
          }
          return rawPath.trim();
        } on MissingPluginException {
          return _fallbackGetDirectoryPath(
            dialogTitle: dialogTitle,
            initialDirectory: initialDirectory,
          );
        }
      }
      return _fallbackGetDirectoryPath(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
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
    const customWinOptions = WindowsOptions(lockParentWindow: true);
    return _runSingleFlight<Uri?>(() async {
      final custom = saveFileImpl;
      if (custom != null) {
        return custom(
          fileName: fileName,
          bytes: bytes,
          dialogTitle: dialogTitle,
          initialDirectory: initialDirectory,
          windowsOptions: customWinOptions,
        );
      }
      if (_shouldUseWindowsNativeBridge) {
        try {
          final ext = p.extension(fileName).replaceFirst('.', '');
          final rawPath = await windowsMethodChannel.invokeMethod<String>(
            'saveFile',
            <String, Object?>{
              'dialogTitle': dialogTitle,
              'initialDirectory': initialDirectory,
              'fileName': fileName,
              'allowedExtensions': ext.isEmpty ? const <String>[] : <String>[ext],
            },
          );
          if (rawPath == null || rawPath.trim().isEmpty) {
            return null;
          }
          final targetFile = File(rawPath.trim());
          await targetFile.writeAsBytes(bytes, flush: true);
          return Uri.file(targetFile.path);
        } on MissingPluginException {
          return _fallbackSaveFile(
            fileName: fileName,
            bytes: bytes,
            dialogTitle: dialogTitle,
            initialDirectory: initialDirectory,
          );
        }
      }
      return _fallbackSaveFile(
        fileName: fileName,
        bytes: bytes,
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
      );
    });
  }
}

/// Windows 原生文件对话框返回的本地文件适配器（避免额外引入传递依赖）。
final class _WindowsPickedPlatformFile extends PlatformFile {
  _WindowsPickedPlatformFile(this._filePath);

  final String _filePath;

  @override
  String get name => p.basename(_filePath);

  @override
  String? get path => _filePath;

  @override
  Uri get uri => Uri.file(_filePath);

  @override
  int? lengthSync() {
    try {
      return File(_filePath).lengthSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<int?> length() async {
    try {
      return await File(_filePath).length();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<Uint8List> readAsBytes() => File(_filePath).readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() => File(_filePath).openRead().map(
    (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
