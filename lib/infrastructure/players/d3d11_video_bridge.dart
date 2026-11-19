import 'dart:async';

import 'package:flutter/services.dart';

import 'konata_video_texture_bridge.dart';
import 'dart:developer' as developer;

export 'konata_video_texture_bridge.dart'
    show
        KonataVideoTextureBridge,
        NativeSessionMetrics,
        NativeTextureChangedEvent,
        NativeVideoSessionHandle;

/// `"konata/d3d11_video"` MethodChannel 的 Windows 高色深 D3D11 / DirectComposition 桥接实现。
class D3D11VideoBridge implements KonataVideoTextureBridge {
  /// 构造 D3D11 桥接客户端。
  D3D11VideoBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// 与 C++ `D3D11TextureBridge` 约定的唯一通道名。
  static const String channelName = 'konata/d3d11_video';

  final MethodChannel _channel;
  final StreamController<NativeTextureChangedEvent> _changesController =
      StreamController<NativeTextureChangedEvent>.broadcast();

  /// 原生设备丢失降级时触发的新纹理 ID 推送流。
  @override
  Stream<NativeTextureChangedEvent> get textureChanges =>
      _changesController.stream;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onTextureChanged' && call.arguments is Map) {
      final raw = call.arguments as Map<Object?, Object?>;
      final sessionId = (raw['sessionId'] as num?)?.toInt() ?? 0;
      final textureId = (raw['textureId'] as num?)?.toInt() ?? -1;
      final backend = raw['backend']?.toString() ?? 'sw';
      final surfaceFormat = raw['surfaceFormat']?.toString() ?? '';
      final colorBitDepth = (raw['colorBitDepth'] as num?)?.toInt() ?? 8;
      final adapterName = raw['adapterName']?.toString() ?? '';
      final reason = raw['reason']?.toString() ?? '';
      if (!_changesController.isClosed) {
        _changesController.add(
          NativeTextureChangedEvent(
            sessionId: sessionId,
            textureId: textureId,
            backend: backend,
            surfaceFormat: surfaceFormat,
            colorBitDepth: colorBitDepth,
            adapterName: adapterName,
            reason: reason,
          ),
        );
      }
    }
    return null;
  }

  /// 为指定 `mpv_handle*` 创建高色深底层 10-bit/HDR 宿主或兼容共享纹理会话。
  @override
  Future<NativeVideoSessionHandle> createSession({
    required int mpvHandleAddress,
    int width = 1280,
    int height = 720,
    bool preferSoftware = false,
    String renderBackend = 'gpu_next',
  }) async {
    final nativeBackend = switch (renderBackend) {
      'comp_10bit' => 'dcomp_10bit',
      'comp_fp16' => 'dcomp_fp16',
      'texture_fallback' => 'd3d11_fp16',
      _ => renderBackend,
    };
    final result = await _channel.invokeMapMethod<String, Object?>(
      'createSession',
      <String, Object?>{
        'mpvHandle': mpvHandleAddress,
        'width': width,
        'height': height,
        'preferSoftware': preferSoftware,
        'renderBackend': nativeBackend,
      },
    );
    if (result == null) {
      throw StateError('konata/d3d11_video createSession returned null');
    }
    return NativeVideoSessionHandle(
      sessionId: (result['sessionId'] as num?)?.toInt() ?? 0,
      textureId: (result['textureId'] as num?)?.toInt() ?? -1,
      backend: result['backend']?.toString() ?? 'gpu_next',
      surfaceFormat:
          result['surfaceFormat']?.toString() ?? 'DXGI_FORMAT_R10G10B10A2_UNORM',
      colorBitDepth: (result['colorBitDepth'] as num?)?.toInt() ?? 10,
      underlaySwapChainActive: result['dcompActive'] == true,
      nativeWindowHandle: (result['nativeWindowHandle'] as num?)?.toInt() ?? 0,
      adapterName: result['adapterName']?.toString() ?? '',
    );
  }

  /// 通知原生渲染目标同步调整分辨率（最小节流至整数像素）。
  @override
  Future<void> resize({
    required int sessionId,
    required int width,
    required int height,
  }) async {
    if (sessionId <= 0 || width <= 0 || height <= 0) return;
    await _channel.invokeMethod<void>('resize', <String, Object?>{
      'sessionId': sessionId,
      'width': width,
      'height': height,
    });
  }

  /// 同步 DirectComposition 10-bit 子视觉层的物理像素几何视口与圆角裁剪。
  @override
  Future<void> setViewportRect({
    required int sessionId,
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  }) async {
    if (sessionId <= 0) return;
    try {
      await _channel.invokeMethod<void>('setViewportRect', <String, Object?>{
        'sessionId': sessionId,
        'leftPx': leftPx,
        'topPx': topPx,
        'rightPx': rightPx,
        'bottomPx': bottomPx,
        'cornerRadiusPx': cornerRadiusPx,
        'visible': visible,
      });
    } on MissingPluginException catch (error) {
  // 非桌面宿主环境跳过 DirectComposition 视口同步。
  developer.log('可恢复异常已记录', name: 'konata.d3d11_video_bridge', error: error);
} on PlatformException catch (error) {
  // 会话已释放时的瞬态通道异常静默放行。
  developer.log('可恢复异常已记录', name: 'konata.d3d11_video_bridge', error: error);
}
  }

  /// 查询指定渲染会话的原生 GPU 单帧渲染耗时统计。
  @override
  Future<NativeSessionMetrics?> getSessionMetrics(int sessionId) async {
    if (sessionId <= 0) return null;
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getSessionMetrics',
        <String, Object?>{'sessionId': sessionId},
      );
      if (result == null) return null;
      return NativeSessionMetrics(
        renderedFrames: (result['renderedFrames'] as num?)?.toInt() ?? 0,
        renderP50Us: (result['renderP50Us'] as num?)?.toInt() ?? 0,
        renderP99Us: (result['renderP99Us'] as num?)?.toInt() ?? 0,
        renderAvgUs: (result['renderAvgUs'] as num?)?.toInt() ?? 0,
        backend: result['backend']?.toString() ?? '',
        surfaceFormat: result['surfaceFormat']?.toString() ?? '',
        colorBitDepth: (result['colorBitDepth'] as num?)?.toInt() ?? 8,
        underlaySwapChainActive: result['dcompActive'] == true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 释放原生渲染上下文并注销纹理。
  @override
  Future<void> disposeSession(int sessionId) async {
    if (sessionId <= 0) return;
    try {
      await _channel.invokeMethod<void>('disposeSession', <String, Object?>{
        'sessionId': sessionId,
      });
    } on MissingPluginException catch (error) {
  // 非桌面宿主环境跳过释放。
  developer.log('可恢复异常已记录', name: 'konata.d3d11_video_bridge', error: error);
} on PlatformException catch (error) {
  // 桥接器已关闭或会话已被销毁。
  developer.log('可恢复异常已记录', name: 'konata.d3d11_video_bridge', error: error);
}
  }

  /// 查询当前 Windows 适配器可用性与显卡名称。
  @override
  Future<({bool available, String adapterName})> getAdapterInfo() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getAdapterInfo',
      );
      if (result == null) {
        return (available: false, adapterName: '');
      }
      return (
        available: result['available'] == true,
        adapterName: result['adapterName']?.toString() ?? '',
      );
    } on MissingPluginException {
      return (available: false, adapterName: '');
    } on PlatformException {
      return (available: false, adapterName: '');
    }
  }

  /// 查询当前 Windows 适配器完整高色深与 DirectComposition 10-bit 硬件能力。
  Future<
    ({
      bool available,
      String adapterName,
      bool supportsFp16,
      bool supports10Bit,
      bool supportsDcomp10Bit,
    })
  >
  getDetailedAdapterCapabilities() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getAdapterInfo',
      );
      if (result == null) {
        return (
          available: false,
          adapterName: '',
          supportsFp16: false,
          supports10Bit: false,
          supportsDcomp10Bit: false,
        );
      }
      return (
        available: result['available'] == true,
        adapterName: result['adapterName']?.toString() ?? '',
        supportsFp16: result['supportsFp16'] == true,
        supports10Bit: result['supports10Bit'] == true,
        supportsDcomp10Bit: result['supportsDcomp10Bit'] == true,
      );
    } on MissingPluginException {
      return (
        available: false,
        adapterName: '',
        supportsFp16: false,
        supports10Bit: false,
        supportsDcomp10Bit: false,
      );
    } on PlatformException {
      return (
        available: false,
        adapterName: '',
        supportsFp16: false,
        supports10Bit: false,
        supportsDcomp10Bit: false,
      );
    }
  }

  /// 关闭监听并清理流控制器。
  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    if (!_changesController.isClosed) {
      await _changesController.close();
    }
  }
}
