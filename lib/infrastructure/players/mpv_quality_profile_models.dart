part of 'mpv_quality_profile.dart';

/// 内置 `libmpv` 画质与缩放滤镜预设档位。
enum VideoQualityPreset {
  /// 高保真动漫原盘档：`ewa_lanczossharp` + `ewa_lanczossoft` + `rgba16f` + `fruit` 抖动。
  highFidelity('高保真 · EWA Lanczos'),

  /// 标准均衡档：`spline36` 锐化平衡性能与清晰度。
  standard('标准均衡 · Spline36'),

  /// 轻量省电档：`bilinear` 快速缩放以降低 GPU 负载。
  lightweight('轻量省电 · Bilinear'),

  /// 纯软解容错档：关闭硬件解码，专注兼容性与老旧驱动兜底。
  softwareFallback('纯软解容错 · CPU');

  const VideoQualityPreset(this.label);

  /// 界面展示名称。
  final String label;
}

/// 高色深桌面视频渲染后端模式（默认优先真 10-bit/HDR 底层硬件直通，保留兼容纹理回退）。
///
/// 使用跨端中性的配置键，避免 Android AOT 产物残留平台专属后端符号。
enum VideoOutputPipelineMode {
  /// 原生 `vo=gpu-next` (`libplacebo` 10-bit/HDR 翻转交换链独立子窗口)。
  gpuNextUnderlay('gpu_next', '10-bit/HDR 子窗口直通 (vo=gpu-next)'),

  /// 底层 10-bit 翻转模型交换链视觉层直出。
  layered10Bit('comp_10bit', '10-bit 底层合成交换链'),

  /// 底层 16-bit scRGB HDR 交换链视觉层直出。
  layeredFp16('comp_fp16', '16-bit HDR 底层合成交换链'),

  /// 默认高精共享纹理合成：SDR 使用 10-bit FBO 经 IGN 抖动与 Flutter 场景树同层合成（零遮挡、圆角抗锯齿），遇 HDR 视频自动升档 16-bit FP16。
  legacyTextureFallback('texture_fallback', '10-bit 共享纹理合成（推荐，HDR 自动升档）');

  const VideoOutputPipelineMode(this.bridgeKey, this.label);

  /// 传递给原生桥接通道的后端标识符。
  final String bridgeKey;

  /// 简体中文界面展示名称。
  final String label;

  /// 按持久化键名或枚举名安全解析渲染后端（未知值回落默认 16-bit 共享纹理合成）。
  static VideoOutputPipelineMode parse(
    Object? raw, {
    MpvPlatformProfileDelegate? delegate,
  }) {
    if (raw is String) {
      final normalized = delegate?.normalizeLegacyOutputModeKey(raw) ?? raw;
      for (final mode in values) {
        if (mode.name == normalized || mode.bridgeKey == normalized) {
          return mode;
        }
      }
    }
    return VideoOutputPipelineMode.legacyTextureFallback;
  }
}

/// 桌面端专属 `libmpv` 驱动与后端参数委托（仅桌面组装根实现并注入，Android 端为 `null`）。
abstract interface class MpvPlatformProfileDelegate {
  /// 桌面端兼容外接纹理渲染驱动标识。
  String get desktopVideoDriver;

  /// 桌面端高色深直通渲染驱动标识。
  String get desktopGpuNextDriver;

  /// 桌面端默认音频输出驱动标识。
  String get desktopAudioDriver;

  /// 桌面端默认硬件解码管线列表。
  String get desktopHwdecValue;

  /// 将历史持久化后端键名规整为中立跨端键名。
  String normalizeLegacyOutputModeKey(String raw);

  /// 将桌面历史播放偏好 JSON 键无损迁移至跨端中立键名。
  Map<Object?, Object?> normalizeLegacyPreferenceMap(
    Map<Object?, Object?> raw,
  );

  /// 识别桌面端硬件解码异常告警日志。
  bool isDesktopHardwareDecodeWarning(String lowerCaseMessage);

  /// 写入桌面端视频初始化前置渲染管线选项。
  void applyDesktopVideoPreInitOptions(
    LibMpvClient client,
    MpvSafePropertySetter setter, {
    required PlaybackQualityConfig config,
    int? desktopUnderlayHwnd,
  });

  /// 写入桌面端初始化前置音频独占参数。
  void applyDesktopAudioExclusivePreInit(
    LibMpvClient client,
    MpvSafePropertySetter setter,
    PlaybackQualityConfig config,
  );

  /// 初始化完成后同步桌面端音频独占状态并处理回退提示。
  void applyDesktopAudioExclusivePostInit(
    LibMpvClient client,
    MpvSafePropertySetter setter,
    PlaybackQualityConfig config, {
    void Function(String message)? onNotice,
  });

  /// 播放期间热切换桌面端音频独占模式并处理回退提示。
  void applyDesktopAudioExclusiveLive(
    LibMpvClient client,
    MpvSafePropertySetter setter,
    PlaybackQualityConfig config, {
    void Function(String message)? onNotice,
  });
}

/// 音视频播放画质、音频后端与缓存持久化配置模型（强类型，严禁跨层 Map）。
class PlaybackQualityConfig {
  /// 创建画质与音画偏好配置。
  const PlaybackQualityConfig({
    this.preset = VideoQualityPreset.highFidelity,
    this.outputPipelineMode = VideoOutputPipelineMode.legacyTextureFallback,
    this.hardwareDecode = true,
    this.debandEnabled = false,
    this.demuxerMaxBytesMiB = defaultDemuxerMaxBytesMiB,
    this.demuxerMaxBackBytesMiB = defaultDemuxerMaxBackBytesMiB,
    this.cacheSecs = defaultCacheSecs,
    this.audioResamplerPrecision = defaultSoxrPrecision,
    this.exclusiveAudioOutput = false,
    this.audioDevice = defaultAudioDevice,
    this.activeShaderPaths = const [],
    this.defaultSpeed = 1.0,
    this.keepPitch = true,
    this.subFontSize = defaultSubFontSize,
    this.subFontName = '',
    this.subBottomMargin = defaultSubBottomMargin,
    this.subOverrideMode = SubtitleAssOverrideMode.preserveAss,
    this.subColorHex = defaultSubColorHex,
  });

  /// 默认本地前向解复用缓冲上限（24 MiB）。
  static const int defaultDemuxerMaxBytesMiB = 24;

  /// 默认本地回溯解复用缓冲上限（8 MiB）。
  static const int defaultDemuxerMaxBackBytesMiB = 8;

  /// 默认流媒体预缓存秒数（120 秒）。
  static const int defaultCacheSecs = 120;

  /// 默认 libsoxr 重采样精度（28-bit 线性相位高精度）。
  static const int defaultSoxrPrecision = 28;

  /// 默认音频输出设备标识符。
  static const String defaultAudioDevice = 'auto';

  /// 默认字幕字号与底部边距。
  static const int defaultSubFontSize = 52;
  static const int defaultSubBottomMargin = 28;
  static const String defaultSubColorHex = '#FFFFFFFF';

  /// 智能章节跳过提示浮窗默认显示时长（4 秒）。
  static const Duration skipPillAutoFadeDuration = Duration(milliseconds: 4000);

  /// 自动连播下一集顶部轻提示显示时长（3 秒）。
  static const Duration autoNextEpisodeToastDuration = Duration(
    milliseconds: 3000,
  );

  final VideoQualityPreset preset;
  final VideoOutputPipelineMode outputPipelineMode;
  final bool hardwareDecode;
  final bool debandEnabled;
  final int demuxerMaxBytesMiB;
  final int demuxerMaxBackBytesMiB;
  final int cacheSecs;
  final int audioResamplerPrecision;
  final bool exclusiveAudioOutput;
  final String audioDevice;
  final List<String> activeShaderPaths;
  final double defaultSpeed;
  final bool keepPitch;
  final int subFontSize;
  final String subFontName;
  final int subBottomMargin;
  final SubtitleAssOverrideMode subOverrideMode;
  final String subColorHex;

  /// 复制更新局部画质或音频设置。
  PlaybackQualityConfig copyWith({
    VideoQualityPreset? preset,
    VideoOutputPipelineMode? outputPipelineMode,
    bool? hardwareDecode,
    bool? debandEnabled,
    int? demuxerMaxBytesMiB,
    int? demuxerMaxBackBytesMiB,
    int? cacheSecs,
    int? audioResamplerPrecision,
    bool? exclusiveAudioOutput,
    String? audioDevice,
    List<String>? activeShaderPaths,
    double? defaultSpeed,
    bool? keepPitch,
    int? subFontSize,
    String? subFontName,
    int? subBottomMargin,
    SubtitleAssOverrideMode? subOverrideMode,
    String? subColorHex,
  }) {
    return PlaybackQualityConfig(
      preset: preset ?? this.preset,
      outputPipelineMode: outputPipelineMode ?? this.outputPipelineMode,
      hardwareDecode: hardwareDecode ?? this.hardwareDecode,
      debandEnabled: debandEnabled ?? this.debandEnabled,
      demuxerMaxBytesMiB: demuxerMaxBytesMiB ?? this.demuxerMaxBytesMiB,
      demuxerMaxBackBytesMiB:
          demuxerMaxBackBytesMiB ?? this.demuxerMaxBackBytesMiB,
      cacheSecs: cacheSecs ?? this.cacheSecs,
      audioResamplerPrecision:
          audioResamplerPrecision ?? this.audioResamplerPrecision,
      exclusiveAudioOutput: exclusiveAudioOutput ?? this.exclusiveAudioOutput,
      audioDevice: audioDevice ?? this.audioDevice,
      activeShaderPaths: activeShaderPaths ?? this.activeShaderPaths,
      defaultSpeed: defaultSpeed ?? this.defaultSpeed,
      keepPitch: keepPitch ?? this.keepPitch,
      subFontSize: subFontSize ?? this.subFontSize,
      subFontName: subFontName ?? this.subFontName,
      subBottomMargin: subBottomMargin ?? this.subBottomMargin,
      subOverrideMode: subOverrideMode ?? this.subOverrideMode,
      subColorHex: subColorHex ?? this.subColorHex,
    );
  }
}

/// 探测到的内嵌 libmpv 与 FFmpeg 运行时真实版本号。
class MpvRuntimeVersions {
  /// 创建运行时版本信息。
  const MpvRuntimeVersions({
    required this.isAvailable,
    this.mpvVersion = '',
    this.ffmpegVersion = '',
    this.errorMessage,
  });

  final bool isAvailable;
  final String mpvVersion;
  final String ffmpegVersion;
  final String? errorMessage;
}
