/// Android 14+ 原生 `MIXER_BEHAVIOR_BIT_PERFECT` USB 协商结果快照。
class AndroidBitPerfectNegotiationResult {
  /// 创建协商结果。
  const AndroidBitPerfectNegotiationResult({
    required this.supported,
    required this.engaged,
    this.deviceName = '',
    this.sampleRateHz = 0,
    this.detail = '',
  });

  /// 当前设备及已连接 USB DAC 是否支持逐位混音器属性。
  final bool supported;

  /// 是否已成功向系统设置 `MIXER_BEHAVIOR_BIT_PERFECT` 优先属性。
  final bool engaged;

  /// 命中的外接 USB 音频设备名称。
  final String deviceName;

  /// 协商命中的源采样率（Hz）。
  final int sampleRateHz;

  /// 供诊断显示的补充状态说明。
  final String detail;
}

/// Android 原生音频路由与外设拔出瞬态静音端口（纯 Dart 抽象，由上层注入原生平台实现）。
abstract interface class AndroidAudioRoutePort {
  /// 按调用方令牌绑定外设拔出瞬态静音与新外设接入重置安全衰减的实时监听回调。
  void bindRouteListeners({
    required Object owner,
    void Function(String reason)? onOutputDeviceRemoved,
    void Function(String deviceFingerprint)? onOutputDeviceAdded,
  });

  /// 按调用方令牌解绑路由事件回调，不影响其他同时活跃的播放通道。
  void unbindRouteListeners({required Object owner});

  /// 在 Android 14+ 上主动请求或取消 USB DAC 逐位直通混音器属性。
  Future<AndroidBitPerfectNegotiationResult> negotiateBitPerfectUsb({
    required bool enable,
    int? preferredSampleRateHz,
  });

  /// 释放监听器注册表资源。
  void dispose();
}
