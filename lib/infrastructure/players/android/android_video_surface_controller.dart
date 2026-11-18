import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Android `ccplayer/android_surface` 硬件表面变化快照。
class AndroidSurfaceDescriptor {
  /// 创建 Android 表面状态快照。
  const AndroidSurfaceDescriptor({
    required this.wid,
    required this.width,
    required this.height,
    required this.hdrPeak,
  });

  /// 绑定给 libmpv `wid` 选项的 `MediaKitAndroidHelper` 全局引用句柄。
  final int wid;

  /// 当前 Surface 像素宽。
  final int width;

  /// 当前 Surface 像素高。
  final int height;

  /// 屏幕硬件 HDR 峰值（nits，未知时为 0）。
  final double hdrPeak;
}

/// Android 10-bit (`RGBA_1010102`) 原生硬件表面控制器，与 `AndroidVideoSurface.kt` 通信。
class AndroidVideoSurfaceController {
  /// 为指定 `PlatformView` ID 创建通道控制器。
  AndroidVideoSurfaceController(int viewId)
    : _channel = MethodChannel('ccplayer/android_surface/$viewId') {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// Kotlin 端注册的 `PlatformView` 唯一 ViewType。
  static const String viewType = 'ccplayer/android_surface';

  final MethodChannel _channel;
  final StreamController<AndroidSurfaceDescriptor?> _surfaceChanges =
      StreamController<AndroidSurfaceDescriptor?>.broadcast();

  AndroidSurfaceDescriptor? _current;

  /// 当前已知表面描述符（若已销毁或尚未创建则为 null）。
  AndroidSurfaceDescriptor? get current => _current;

  /// 表面就绪、尺寸变更或销毁丢失通知流。
  Stream<AndroidSurfaceDescriptor?> get surfaceChanges =>
      _surfaceChanges.stream;

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'changed':
        final args = call.arguments;
        if (args is Map) {
          final wid = (args['wid'] as num?)?.toInt() ?? 0;
          final width = (args['width'] as num?)?.toInt() ?? 0;
          final height = (args['height'] as num?)?.toInt() ?? 0;
          final hdrPeak = (args['hdrPeak'] as num?)?.toDouble() ?? 0.0;
          // 仅在句柄与像素宽高均有效时派发就绪事件，避免将 0x0 表面传入 libmpv
          if (wid > 0 && (width <= 0 || height <= 0)) {
            _current = null;
            return null;
          }
          _current = (wid > 0 && width > 0 && height > 0)
              ? AndroidSurfaceDescriptor(
                  wid: wid,
                  width: width,
                  height: height,
                  hdrPeak: hdrPeak,
                )
              : null;
          if (!_surfaceChanges.isClosed) {
            _surfaceChanges.add(_current);
          }
        }
      case 'lost':
        _current = null;
        if (!_surfaceChanges.isClosed) {
          _surfaceChanges.add(null);
        }
    }
    return null;
  }

  /// 主动向原生端查询当前可用表面信息（句柄与宽高均需大于 0）。
  Future<AndroidSurfaceDescriptor?> queryCurrent() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('current');
      if (result == null) return null;
      final wid = (result['wid'] as num?)?.toInt() ?? 0;
      final width = (result['width'] as num?)?.toInt() ?? 0;
      final height = (result['height'] as num?)?.toInt() ?? 0;
      if (wid <= 0 || width <= 0 || height <= 0) {
        _current = null;
        return null;
      }
      _current = AndroidSurfaceDescriptor(
        wid: wid,
        width: width,
        height: height,
        hdrPeak: (result['hdrPeak'] as num?)?.toDouble() ?? 0.0,
      );
      return _current;
    } catch (_) {
      return null;
    }
  }

  /// 控制器是否已释放。
  bool _disposed = false;

  /// 当前已释放标识。
  bool get isDisposed => _disposed;

  /// 在 libmpv 解绑 `vo=null` / `wid=0` 后精确释放指定旧表面的 JNI 全局引用。
  Future<void> releaseReference(int wid) async {
    if (wid <= 0) return;
    try {
      await _channel.invokeMethod<void>('release', wid);
    } catch (_) {}
  }

  /// 释放与当前视图关联的全局 Surface 引用。
  Future<void> releaseSurface() async {
    try {
      await _channel.invokeMethod<void>('releaseAll');
    } catch (_) {}
    _current = null;
  }

  /// 为 Android 端便携 `mpv` 配置目录准备 `fonts/` 子目录及系统 CJK 字体符号链接，
  /// 保障 ASS/SSA 番剧外挂字幕不因缺失字体方框乱码。
  static Future<void> preparePortableCjkFontSymlinks(
    Directory mpvConfigDir,
  ) async {
    if (!Platform.isAndroid) return;
    final fontsDir = Directory(p.join(mpvConfigDir.path, 'fonts'));
    if (!await fontsDir.exists()) {
      await fontsDir.create(recursive: true);
    }

    const systemFontCandidates = [
      '/system/fonts/NotoSansCJK-Regular.ttc',
      '/system/fonts/NotoSerifCJK-Regular.ttc',
      '/system/fonts/DroidSansFallback.ttf',
      '/system/fonts/NotoSansSC-Regular.otf',
    ];
    for (final sysPath in systemFontCandidates) {
      final source = File(sysPath);
      if (!await source.exists()) continue;
      final linkPath = p.join(fontsDir.path, p.basename(sysPath));
      final link = Link(linkPath);
      if (!await link.exists() && !await File(linkPath).exists()) {
        try {
          await link.create(sysPath);
        } catch (_) {
          // 部分 ROM 限制沙箱外符号链接时静默忽略，由 libmpv 默认字体兜底
        }
      }
    }
  }

  /// 注销通道监听器。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    if (!_surfaceChanges.isClosed) {
      await _surfaceChanges.close();
    }
  }
}
