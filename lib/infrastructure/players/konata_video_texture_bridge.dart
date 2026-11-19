/// 跨平台外接视频纹理与底层 10-bit 渲染宿主桥接句柄（屏蔽平台渲染细节以支撑 Android 入口零桌面残留裁剪）。
class D3D11VideoSessionHandle {
  /// 创建会话句柄对象。
  const D3D11VideoSessionHandle({
    required this.sessionId,
    required this.textureId,
    required this.backend,
    required this.adapterName,
    this.surfaceFormat = 'DXGI_FORMAT_R10G10B10A2_UNORM',
    this.colorBitDepth = 10,
    this.dcompActive = false,
    this.nativeWindowHandle = 0,
  });

  /// 原生端会话编号。
  final int sessionId;

  /// Flutter 外接纹理绑定编号（底层 10-bit/HDR 挖空模式为 `-1`）。
  final int textureId;

  /// 实际启用的渲染后端名称（如 `gpu_next`、`dcomp_10bit`、`dcomp_fp16`、`d3d11_fp16` 或 `sw`）。
  final String backend;

  /// 实际使用的像素格式名称。
  final String surfaceFormat;

  /// 实际激活的通道位深（16 / 10 / 8）。
  final int colorBitDepth;

  /// 当前是否运行于底层 10-bit/HDR 视口挖空直出模式。
  final bool dcompActive;

  /// 原生底层子窗口句柄（`gpu_next` 模式下透传至 `libmpv` `wid` 选项）。
  final int nativeWindowHandle;

  /// 图形适配器名称或软件渲染说明。
  final String adapterName;

  /// 当前是否运行于软件渲染回退模式。
  bool get isSoftwareFallback => backend == 'sw';

  /// 当前是否运行于底层挖空硬件直出模式（需由上层 `BlendMode.clear` 挖空同步视口）。
  bool get isUnderlayMode => !isSoftwareFallback && (dcompActive || textureId < 0);

  /// 复制并更新热切换后的纹理与后端信息。
  D3D11VideoSessionHandle copyWith({
    int? textureId,
    String? backend,
    String? surfaceFormat,
    int? colorBitDepth,
    bool? dcompActive,
    int? nativeWindowHandle,
    String? adapterName,
  }) {
    return D3D11VideoSessionHandle(
      sessionId: sessionId,
      textureId: textureId ?? this.textureId,
      backend: backend ?? this.backend,
      surfaceFormat: surfaceFormat ?? this.surfaceFormat,
      colorBitDepth: colorBitDepth ?? this.colorBitDepth,
      dcompActive: dcompActive ?? this.dcompActive,
      nativeWindowHandle: nativeWindowHandle ?? this.nativeWindowHandle,
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
    this.surfaceFormat = '',
    this.colorBitDepth = 8,
  });

  final int sessionId;
  final int textureId;
  final String backend;
  final String surfaceFormat;
  final int colorBitDepth;
  final String adapterName;
  final String reason;
}

/// 原生 Windows GPU 渲染管线实测指标快照（供真机 A/B 对比与诊断叠加层使用）。
class D3D11SessionMetrics {
  /// 创建原生渲染指标快照。
  const D3D11SessionMetrics({
    required this.renderedFrames,
    required this.renderP50Us,
    required this.renderP99Us,
    required this.renderAvgUs,
    required this.backend,
    required this.surfaceFormat,
    required this.colorBitDepth,
    required this.dcompActive,
  });

  /// 累计已渲染视频帧总数。
  final int renderedFrames;

  /// 单帧原生 GPU 渲染耗时中位数（微秒）。
  final int renderP50Us;

  /// 单帧原生 GPU 渲染耗时 P99（微秒）。
  final int renderP99Us;

  /// 单帧原生 GPU 渲染平均耗时（微秒）。
  final int renderAvgUs;

  /// 实际渲染后端标识。
  final String backend;

  /// 实际表面像素格式名称。
  final String surfaceFormat;

  /// 实际激活位深（16 / 10 / 8）。
  final int colorBitDepth;

  /// 是否启用 DirectComposition 独立子视觉层。
  final bool dcompActive;
}

/// 跨平台桌面外接视频纹理桥接抽象契约。
abstract interface class KonataVideoTextureBridge {
  /// 原生设备丢失重建或后端降级时推送的新纹理通知流。
  Stream<D3D11TextureChangedEvent> get textureChanges;

  /// 为指定原生 `mpv_handle*`（或 `gpu_next` 预建底层子窗口时为 `0`）创建高色深渲染会话。
  Future<D3D11VideoSessionHandle> createSession({
    required int mpvHandleAddress,
    int width = 1280,
    int height = 720,
    bool preferSoftware = false,
    String renderBackend = 'gpu_next',
  });

  /// 通知原生渲染目标同步调整分辨率。
  Future<void> resize({
    required int sessionId,
    required int width,
    required int height,
  });

  /// 同步 DirectComposition 10-bit 子视觉层的物理像素几何视口与圆角裁剪。
  Future<void> setViewportRect({
    required int sessionId,
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  });

  /// 查询指定会话的原生 GPU 单帧渲染耗时统计（P50 / P99 / 平均微秒及格式位深）。
  Future<D3D11SessionMetrics?> getSessionMetrics(int sessionId);

  /// 释放原生渲染上下文并注销外部纹理。
  Future<void> disposeSession(int sessionId);

  /// 查询图形适配器可用性、名称及高色深/DirectComposition 能力。
  Future<({bool available, String adapterName})> getAdapterInfo();

  /// 关闭通道监听与流控制器。
  Future<void> dispose();
}
