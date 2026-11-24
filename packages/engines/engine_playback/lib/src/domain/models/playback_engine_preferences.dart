import '../../infrastructure/players/mpv_quality_profile.dart';

/// 全局默认音视频播放引擎路由偏好。
enum PreferredPlaybackEngine {
  /// 默认使用内置高保真 `libmpv`（底层高色深表面 / 纯音频 `vid=no`）。
  builtinLibmpv('内置高保真引擎 (libmpv)'),

  /// 默认拉起桌面已配置的外部程序接力。
  desktopRelay('外部播放器');

  const PreferredPlaybackEngine(this.label);

  /// 界面展示名称。
  final String label;
}

/// 发烧音频路由协调所需的轻量只读偏好配置。
class AudiophileAudioPreferences {
  /// 创建发烧音频路由偏好快照。
  const AudiophileAudioPreferences({
    this.qualityConfig = const PlaybackQualityConfig(),
    this.bitstreamPassthrough = false,
    this.androidBitPerfectUsb = false,
  });

  /// 内置 `libmpv` 画质与音频配置参数。
  final PlaybackQualityConfig qualityConfig;

  /// Windows HDMI / S/PDIF 压缩源码透传开关（启用后跳过内部音量链并互斥独占）。
  final bool bitstreamPassthrough;

  /// Android 14+ USB DAC 逐位直通协商开关（开启后优先尝试原生直通并与源码模式协调）。
  final bool androidBitPerfectUsb;

  /// 复制并按需替换字段。
  AudiophileAudioPreferences copyWith({
    PlaybackQualityConfig? qualityConfig,
    bool? bitstreamPassthrough,
    bool? androidBitPerfectUsb,
  }) {
    return AudiophileAudioPreferences(
      qualityConfig: qualityConfig ?? this.qualityConfig,
      bitstreamPassthrough: bitstreamPassthrough ?? this.bitstreamPassthrough,
      androidBitPerfectUsb: androidBitPerfectUsb ?? this.androidBitPerfectUsb,
    );
  }
}
