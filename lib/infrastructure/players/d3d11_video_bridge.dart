import 'dart:async';

import 'package:flutter/services.dart';

/// Windows D3D11 离屏共享纹理会话句柄。
class D3D11VideoSessionHandle {
  /// 创建会话句柄对象。
  const D3D11VideoSessionHandle({
    required this.sessionId,
    required this.textureId,
    required this.backend,
    required this.adapterName,
  });

  /// 原生端会话 ID。
  final int sessionId;

  /// Flutter `Texture(textureId: ...)` 绑定 ID。
  final int textureId;

  /// 实际启用的渲染后端（`d3d11` 或 `sw`）。
  final String backend;

  /// DXGI 显卡适配器名称或软解说明。
  final String adapterName;

  /// 是否正在运行软件渲染回退模式。
  bool get isSoftwareFallback => backend == 'sw';

  /// 复制并更新热切换后的纹理与后端信息。
  D3D11VideoSessionHandle copyWith({
    int? textureId,
    String? backend,
    String? adapterName,
  }) {
    return D3D11VideoSessionHandle(
      sessionId: sessionId,
      textureId: textureId ?? this.textureId,
      backend: backend ?? this.backend,
      adapterName: adapterName ?? this.adapterName,
    );
  }
}

/// D3D11 设备丢失自动重建/降级 SW 时从 C++ 原生端主动推送的纹理热切换事件。
class D3D11TextureChangedEvent {
  /// 创建纹理变更事件。
  const D3D11TextureChangedEvent({
    required this.sessionId,
    required this.textureId,
    required this.backend,
    required this.adapterName,
    required this.reason,
  });

  final int sessionId;
  final int textureId;
  final String backend;
  final String adapterName;
  final String reason;
}

/// `"konata/d3d11_video"` MethodChannel 的强类型 Dart 桥接封装。
class D3D11VideoBridge {
  /// 构造 D3D11 桥接客户端。
  D3D11VideoBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// 与 C++ `D3D11TextureBridge` 约定的唯一通道名。
  static const String channelName = 'konata/d3d11_video';

  final MethodChannel _channel;
  final StreamController<D3D11TextureChangedEvent> _changesController =
      StreamController<D3D11TextureChangedEvent>.broadcast();

  /// 原生设备丢失降级时触发的新纹理 ID 推送流。
  Stream<D3D11TextureChangedEvent> get textureChanges =>
      _changesController.stream;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onTextureChanged' && call.arguments is Map) {
      final raw = call.arguments as Map<Object?, Object?>;
      final sessionId = (raw['sessionId'] as num?)?.toInt() ?? 0;
      final textureId = (raw['textureId'] as num?)?.toInt() ?? -1;
      final backend = raw['backend']?.toString() ?? 'sw';
      final adapterName = raw['adapterName']?.toString() ?? '';
      final reason = raw['reason']?.toString() ?? '';
      if (!_changesController.isClosed) {
        _changesController.add(
          D3D11TextureChangedEvent(
            sessionId: sessionId,
            textureId: textureId,
            backend: backend,
            adapterName: adapterName,
            reason: reason,
          ),
        );
      }
    }
    return null;
  }

  /// 为指定 `mpv_handle*` 创建离屏三缓冲渲染会话并注册 Flutter 外接纹理。
  Future<D3D11VideoSessionHandle> createSession({
    required int mpvHandleAddress,
    int width = 1280,
    int height = 720,
    bool preferSoftware = false,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'createSession',
      <String, Object?>{
        'mpvHandle': mpvHandleAddress,
        'width': width,
        'height': height,
        'preferSoftware': preferSoftware,
      },
    );
    if (result == null) {
      throw StateError('konata/d3d11_video createSession returned null');
    }
    return D3D11VideoSessionHandle(
      sessionId: (result['sessionId'] as num?)?.toInt() ?? 0,
      textureId: (result['textureId'] as num?)?.toInt() ?? -1,
      backend: result['backend']?.toString() ?? 'd3d11',
      adapterName: result['adapterName']?.toString() ?? '',
    );
  }

  /// 通知原生渲染目标同步调整分辨率（最小节流至整数像素）。
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

  /// 释放原生渲染上下文并注销纹理。
  Future<void> disposeSession(int sessionId) async {
    if (sessionId <= 0) return;
    try {
      await _channel.invokeMethod<void>('disposeSession', <String, Object?>{
        'sessionId': sessionId,
      });
    } catch (_) {}
  }

  /// 查询当前 Windows 适配器可用性与显卡名称。
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
    } catch (_) {
      return (available: false, adapterName: '');
    }
  }

  /// 关闭监听并清理流控制器。
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    if (!_changesController.isClosed) {
      await _changesController.close();
    }
  }
}
