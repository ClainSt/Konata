import 'dart:async';
import 'dart:io';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../subtitles/subtitle_font_pool_manager.dart';

/// Android 根窗口底层（Underlay）硬件表面变化快照。
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

/// Android 10-bit (`RGBA_1010102`) 根窗口 Underlay 硬件表面控制器。
///
/// 通过 `ccplayer/android_underlay_surface` 直接驱动挂载于透明 Flutter 画布之下的底层 `SurfaceView`，
/// 实现零 `PlatformView` 跨线程同步损耗与全类弹窗天然置顶覆盖。
class AndroidVideoSurfaceController {
  /// 创建根窗口底层表面通道控制器。
  AndroidVideoSurfaceController([int _ = 0])
    : _channel = const MethodChannel(underlayChannelName) {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// Kotlin 端注册的根窗口 Underlay 唯一通道名。
  static const String underlayChannelName = 'ccplayer/android_underlay_surface';

  final MethodChannel _channel;
  final StreamController<AndroidSurfaceDescriptor?> _surfaceChanges =
      StreamController<AndroidSurfaceDescriptor?>.broadcast();

  AndroidSurfaceDescriptor? _current;
  bool _disposed = false;
  int? _lastLeftPx;
  int? _lastTopPx;
  int? _lastRightPx;
  int? _lastBottomPx;
  double? _lastRadiusPx;
  bool _shown = false;

  /// 当前已知表面描述符（若已销毁或尚未创建则为 null）。
  AndroidSurfaceDescriptor? get current => _current;

  /// 表面就绪、尺寸变更或销毁丢失通知流。
  Stream<AndroidSurfaceDescriptor?> get surfaceChanges =>
      _surfaceChanges.stream;

  /// 当前已释放标识。
  bool get isDisposed => _disposed;

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'changed':
        final args = call.arguments;
        if (args is Map) {
          final wid = (args['wid'] as num?)?.toInt() ?? 0;
          final width = (args['width'] as num?)?.toInt() ?? 0;
          final height = (args['height'] as num?)?.toInt() ?? 0;
          final hdrPeak = (args['hdrPeak'] as num?)?.toDouble() ?? 0.0;
          // 仅在句柄与像素宽高均有效时派发就绪事件，避免将 0x0 表面传入 libmpv。
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

  /// 显示并同步底层 Underlay 表面在物理像素坐标系下的矩形与圆角半径。
  Future<void> syncViewportRect({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
  }) async {
    if (_disposed || rightPx <= leftPx || bottomPx <= topPx) return;
    final radiusChanged =
        _lastRadiusPx == null || (cornerRadiusPx - _lastRadiusPx!).abs() > 0.25;
    if (_shown &&
        _lastLeftPx == leftPx &&
        _lastTopPx == topPx &&
        _lastRightPx == rightPx &&
        _lastBottomPx == bottomPx &&
        !radiusChanged) {
      return;
    }
    _lastLeftPx = leftPx;
    _lastTopPx = topPx;
    _lastRightPx = rightPx;
    _lastBottomPx = bottomPx;
    _lastRadiusPx = cornerRadiusPx;
    final method = _shown ? 'setRect' : 'show';
    _shown = true;
    try {
      await _channel.invokeMethod<Object?>(method, <String, Object>{
        'leftPx': leftPx,
        'topPx': topPx,
        'rightPx': rightPx,
        'bottomPx': bottomPx,
        'radiusPx': cornerRadiusPx,
      });
    } on MissingPluginException catch (error) {
  // 非 Android 原生宿主或单元测试未挂载插件通道时静默跳过。
  developer.log('可恢复异常已记录', name: 'konata.android_video_surface_controller', error: error);
} on PlatformException catch (error) {
  // 底层窗口销毁竞态下的瞬态平台异常，由后续表面重绑恢复。
  developer.log('可恢复异常已记录', name: 'konata.android_video_surface_controller', error: error);
}
  }

  /// 隐藏底层 Underlay 表面（纯音频模式或退出播放时立即释放系统缓冲）。
  Future<void> hideViewport() async {
    if (_disposed || !_shown) return;
    _shown = false;
    _lastLeftPx = null;
    _lastTopPx = null;
    _lastRightPx = null;
    _lastBottomPx = null;
    _lastRadiusPx = null;
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException catch (error) {
  // 非原生宿主环境下无需隐藏底层表面。
  developer.log('可恢复异常已记录', name: 'konata.android_video_surface_controller', error: error);
} on PlatformException catch (error) {
  // 窗口已销毁时无需重复隐藏。
  developer.log('可恢复异常已记录', name: 'konata.android_video_surface_controller', error: error);
}
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
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 在 libmpv 解绑 `vo=null` / `wid=0` 后精确释放指定旧表面的 JNI 全局引用。
  Future<void> releaseReference(int wid) async {
    if (wid <= 0) return;
    try {
      await _channel.invokeMethod<void>('release', wid);
    } on MissingPluginException catch (error) {
  // 单元测试或非原生宿主环境跳过 JNI 释放。
  developer.log('可恢复异常已记录', name: 'konata.android_video_surface_controller', error: error);
} on PlatformException catch (error) {
  // 旧句柄已被系统回收时静默放行。
  developer.log('可恢复异常已记录', name: 'konata.android_video_surface_controller', error: error);
}
  }

  /// 隐藏底层表面并释放与当前会话关联的全部 JNI 全局 Surface 引用。
  Future<void> releaseSurface() async {
    _shown = false;
    _lastLeftPx = null;
    _lastTopPx = null;
    _lastRightPx = null;
    _lastBottomPx = null;
    _lastRadiusPx = null;
    try {
      await _channel.invokeMethod<void>('releaseAll');
    } on MissingPluginException catch (error) {
  // 单元测试或非原生宿主环境跳过全量释放。
  developer.log('可恢复异常已记录', name: 'konata.android_video_surface_controller', error: error);
} on PlatformException catch (error) {
  // 宿主已关闭时静默放行。
  developer.log('可恢复异常已记录', name: 'konata.android_video_surface_controller', error: error);
}
    _current = null;
  }

  static const String _bundledFallbackCjkFontAsset =
      'assets/fonts/NotoSansCJKsc-VF.ttf';

  /// 为 Android 端便携 `mpv` 配置目录准备 `fonts/` 与 `subfont.ttf` 兜底字体：
  ///
  /// `libmpv` 在 Android 开启 `sub-font-provider=none` 时，若缺少 `<config-dir>/subfont.ttf`
  /// 且字幕指定了未随包提供的字幕组字体，`libass` 将无法命中默认字体导致整条字幕完全空白。
  /// 此处先链接/复制系统已核验 CJK 字体，若系统目录受限或无可用字体，则自动解压内置 `NotoSansCJKsc-VF.ttf` 兜底。
  static Future<void> preparePortableCjkFontSymlinks(
    Directory mpvConfigDir, {
    bool? isAndroidOverride,
    List<Directory>? systemFontRootsOverride,
    Future<ByteData> Function(String assetKey)? assetLoaderOverride,
  }) async {
    final isAndroid = isAndroidOverride ?? Platform.isAndroid;
    if (!isAndroid) return;
    final fontsDir = Directory(p.join(mpvConfigDir.path, 'fonts'));
    if (!await fontsDir.exists()) {
      await fontsDir.create(recursive: true);
    }

    final verifiedFonts =
        await SubtitleFontPoolManager.discoverVerifiedSystemCjkFonts(
          searchRootsOverride: systemFontRootsOverride,
        );

    File? preferredDefaultFont;
    for (final source in verifiedFonts) {
      final ext = p.extension(source.path).toLowerCase();
      if (preferredDefaultFont == null ||
          ((ext == '.ttf' || ext == '.otf') &&
              p.extension(preferredDefaultFont.path).toLowerCase() == '.ttc')) {
        preferredDefaultFont = source;
      }
      final targetPath = p.join(fontsDir.path, p.basename(source.path));
      await _linkOrCopyReadableFont(
        source: source,
        targetPath: targetPath,
        allowCopyFallback: source == preferredDefaultFont,
      );
    }

    // 确保 `<config-dir>/subfont.ttf` 存在且内核可读，作为 libass `ASS_FONTPROVIDER_NONE` 终极默认字体。
    final subfontPath = p.join(mpvConfigDir.path, 'subfont.ttf');
    var subfontReady = await _isReadableNonEmptyFont(subfontPath);
    if (!subfontReady && preferredDefaultFont != null) {
      subfontReady = await _linkOrCopyReadableFont(
        source: preferredDefaultFont,
        targetPath: subfontPath,
        allowCopyFallback: true,
      );
    }
    if (!subfontReady) {
      try {
        final loader = assetLoaderOverride ?? rootBundle.load;
        final data = await loader(_bundledFallbackCjkFontAsset);
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        if (bytes.length > 1024) {
          final subfontFile = File(subfontPath);
          await subfontFile.writeAsBytes(bytes, flush: true);
          final dirCopyPath = p.join(fontsDir.path, 'KonataFallbackCJK.ttf');
          if (!await _isReadableNonEmptyFont(dirCopyPath)) {
            await File(dirCopyPath).writeAsBytes(bytes, flush: true);
          }
        }
      } catch (error) {
        developer.log(
          '内置 CJK 兜底字体写入失败',
          name: 'konata.android_video_surface_controller',
          error: error,
        );
      }
    }
  }

  static Future<bool> _isReadableNonEmptyFont(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      return await f.length() > 1024;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _linkOrCopyReadableFont({
    required File source,
    required String targetPath,
    bool allowCopyFallback = false,
  }) async {
    if (await _isReadableNonEmptyFont(targetPath)) {
      return true;
    }
    try {
      final existingLink = Link(targetPath);
      if (await existingLink.exists()) {
        await existingLink.delete();
      }
      await existingLink.create(source.path);
      if (await _isReadableNonEmptyFont(targetPath)) {
        return true;
      }
    } catch (error) {
      developer.log(
        '符号链接系统字体受限，按需降级拷贝',
        name: 'konata.android_video_surface_controller',
        error: error,
      );
    }
    if (!allowCopyFallback) {
      return false;
    }
    try {
      await source.copy(targetPath);
      return await _isReadableNonEmptyFont(targetPath);
    } catch (error) {
      developer.log(
        '拷贝系统兜底字体失败',
        name: 'konata.android_video_surface_controller',
        error: error,
      );
      return false;
    }
  }

  /// 热重绑交接给新控制器时仅关闭自身事件流，保留单例原生通道处理器不被误清零。
  Future<void> detachWithoutClearingChannel() async {
    if (_disposed) return;
    _disposed = true;
    if (!_surfaceChanges.isClosed) {
      await _surfaceChanges.close();
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
