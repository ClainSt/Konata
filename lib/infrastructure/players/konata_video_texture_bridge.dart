/// 跨平台外接视频纹理桥接句柄（屏蔽桌面 D3D11 实现细节以支撑 Android 入口零桌面残留裁剪）。
class D3D11VideoSessionHandle {
  /// 创建会话句柄对象。
  const D3D11VideoSessionHandle({
    required this.sessionId,
    required this.textureId,
    required this.backend,
    required this.adapterName,
  });

  /// 原生端会话编号。
  final int sessionId;

  /// Flutter 外接纹理绑定编号。
  final int textureId;

  /// 实际启用的渲染后端名称（如 `d3d11`、`dcomp` 或 `sw`）。
  final String backend;

  /// 图形适配器名称或软件渲染说明。
  final String adapterName;

  /// 当前是否运行于软件渲染回退模式。
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

/// 原生图形设备丢失重建或切换后端时推送的纹理变更事件。
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

/// 跨平台桌面外接视频纹理桥接抽象契约。
abstract interface class KonataVideoTextureBridge {
  /// 原生设备丢失重建或后端降级时推送的新纹理通知流。
  Stream<D3D11TextureChangedEvent> get textureChanges;

  /// 为指定原生 `mpv_handle*` 创建渲染会话并注册外部纹理。
  Future<D3D11VideoSessionHandle> createSession({
    required int mpvHandleAddress,
    int width = 1280,
    int height = 720,
    bool preferSoftware = false,
  });

  /// 通知原生渲染目标同步调整分辨率。
  Future<void> resize({
    required int sessionId,
    required int width,
    required int height,
  });

  /// 释放原生渲染上下文并注销外部纹理。
  Future<void> disposeSession(int sessionId);

  /// 查询图形适配器可用性与名称。
  Future<({bool available, String adapterName})> getAdapterInfo();

  /// 关闭通道监听与流控制器。
  Future<void> dispose();
}
