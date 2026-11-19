import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../domain/playback/audiophile_safety_policy.dart';
import '../../domain/playback/hwdec_safety_policy.dart';
import '../../domain/playback/track_preferences.dart';
import '../logging/diagnostics_log_store.dart';
import 'libmpv_ffi.dart';

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
  /// 默认原生 `vo=gpu-next` (`libplacebo` 10-bit/HDR 翻转交换链 + 底层子窗口挖空直出)。
  gpuNextUnderlay('gpu_next', '10-bit/HDR 直通 (vo=gpu-next)'),

  /// 底层 10-bit 翻转模型交换链视觉层直出。
  layered10Bit('comp_10bit', '10-bit 底层合成交换链'),

  /// 底层 16-bit scRGB HDR 交换链视觉层直出。
  layeredFp16('comp_fp16', '16-bit HDR 底层合成交换链'),

  /// 老旧驱动兼容回退：高精内部 FBO 经 IGN 抖动解析至 8-bit 共享纹理。
  legacyTextureFallback('texture_fallback', '8-bit 兼容共享纹理回退');

  const VideoOutputPipelineMode(this.bridgeKey, this.label);

  /// 传递给原生桥接通道的后端标识符。
  final String bridgeKey;

  /// 简体中文界面展示名称。
  final String label;

  /// 按持久化键名或枚举名安全解析渲染后端（未知值回落默认真 10-bit 直通）。
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
    return VideoOutputPipelineMode.gpuNextUnderlay;
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
    this.outputPipelineMode = VideoOutputPipelineMode.gpuNextUnderlay,
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

  /// 默认前向解复用缓冲上限（64 MiB）。
  static const int defaultDemuxerMaxBytesMiB = 64;

  /// 默认回溯解复用缓冲上限（32 MiB）。
  static const int defaultDemuxerMaxBackBytesMiB = 32;

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

/// libmpv 容错属性/选项安全写入器。
///
/// 对 `MPV_ERROR_OPTION_NOT_FOUND (-5)`、`MPV_ERROR_PROPERTY_NOT_FOUND (-8)`、
/// `MPV_ERROR_PROPERTY_UNAVAILABLE (-10)` 等版本兼容差异做静默拦截并记入诊断日志，
/// 确保永不因局部参数版本差异导致播放启动崩溃。
class MpvSafePropertySetter {
  const MpvSafePropertySetter({this.logStore});

  final DiagnosticsLogStore? logStore;

  /// 在 `initialize()` 前写入配置项。
  bool setOption(LibMpvClient client, String name, String value) {
    final rc = client.setOptionString(name, value);
    return _handleResult(client, 'option:$name=$value', rc);
  }

  /// 运行时写入字符串属性。
  bool setString(LibMpvClient client, String name, String value) {
    final rc = client.setPropertyString(name, value);
    return _handleResult(client, 'prop:$name=$value', rc);
  }

  /// 运行时写入布尔属性。
  bool setBool(LibMpvClient client, String name, bool value) {
    final rc = client.setPropertyFlag(name, value);
    return _handleResult(client, 'prop:$name=$value', rc);
  }

  /// 运行时写入整数属性（若底层参数实际为浮点/字符串格式则自动回退字符串写入）。
  bool setInt(LibMpvClient client, String name, int value) {
    var rc = client.setPropertyInt64(name, value);
    if (rc == MpvError.propertyFormat) {
      rc = client.setPropertyString(name, '$value');
    }
    return _handleResult(client, 'prop:$name=$value', rc);
  }

  /// 运行时写入双精度浮点属性（若底层参数格式受限则自动回退字符串写入）。
  bool setDouble(LibMpvClient client, String name, double value) {
    var rc = client.setPropertyDouble(name, value);
    if (rc == MpvError.propertyFormat) {
      rc = client.setPropertyString(name, '$value');
    }
    return _handleResult(client, 'prop:$name=$value', rc);
  }

  bool _handleResult(LibMpvClient client, String label, int rc) {
    if (rc >= 0) return true;
    final ignoredCompatibilityError =
        rc == MpvError.optionNotFound ||
        rc == MpvError.propertyNotFound ||
        rc == MpvError.propertyUnavailable;
    final desc = client.errorString(rc);
    logStore?.record(
      'mpv-config',
      '[$label] skipped ($rc: $desc)',
      isError: !ignoredCompatibilityError,
    );
    return false;
  }
}

/// Konata 内置 libmpv 音画还原与容错参数配置中心。
class MpvQualityProfile {
  MpvQualityProfile._();

  static const String genericVideoDriver = 'libmpv';
  static const String androidVideoDriver = 'gpu-next';
  static const String androidLegacyVideoDriver = 'gpu';
  static const String androidAudioDriver = 'aaudio,audiotrack,opensles';

  /// WebDAV / HTTP 本地流网桥回环重连与大封面/高码率头部加速探测参数。
  static const String remoteStreamLavfOptions =
      'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2';
  static const String remoteVideoProbesize = '2097152';
  static const String remoteAudioProbesize = '8388608';
  static const String remoteVideoAnalyzeDuration = '1.5';
  static const String remoteAudioAnalyzeDuration = '2.0';
  static const int remoteVideoDemuxerMaxBytesMiB = 180;
  static const int remoteVideoDemuxerMaxBackBytesMiB = 120;
  static const int remoteAudioDemuxerMaxBytesMiB = 64;
  static const int remoteAudioDemuxerMaxBackBytesMiB = 48;

  /// 解析当前平台与预设对应的最优硬件解码策略。
  static String resolveHwdecValue({
    required PlaybackQualityConfig config,
    required bool isWindows,
    required bool isAndroid,
    MpvPlatformProfileDelegate? desktopDelegate,
  }) {
    if (!config.hardwareDecode ||
        config.preset == VideoQualityPreset.softwareFallback) {
      return 'no';
    }
    if (isWindows && desktopDelegate != null) {
      return desktopDelegate.desktopHwdecValue;
    }
    if (isAndroid) {
      // Android 优先尝试零拷贝硬解并在需要时自动回退至兼容拷贝路径
      return 'auto-safe';
    }
    return 'auto-safe';
  }

  /// 解析当前平台可用的音频重采样器参数。
  ///
  /// 桌面端内置动态库支持高精度重采样后端；移动端未编入对应组件，必须回退为
  /// 原生高精度重采样参数，防止不同采样率与多声道混缩时静音失败。
  static String resolveAudioResamplerOptions({
    required PlaybackQualityConfig config,
    required bool isWindows,
  }) {
    if (isWindows) {
      return 'resampler=soxr,precision=${config.audioResamplerPrecision}';
    }
    return 'resampler=swr,filter_size=32,phase_shift=10,cutoff=0.97';
  }

  /// 解析当前画质预设对应的上下采样滤波器三元组。
  static ({String scale, String cscale, String dscale}) resolveScalers(
    VideoQualityPreset preset,
  ) {
    return switch (preset) {
      VideoQualityPreset.highFidelity => (
        scale: 'ewa_lanczossharp',
        cscale: 'ewa_lanczossoft',
        dscale: 'mitchell',
      ),
      VideoQualityPreset.standard => (
        scale: 'spline36',
        cscale: 'spline36',
        dscale: 'mitchell',
      ),
      VideoQualityPreset.lightweight || VideoQualityPreset.softwareFallback => (
        scale: 'bilinear',
        cscale: 'bilinear',
        dscale: 'bilinear',
      ),
    };
  }

  /// 异步过滤磁盘上真实存在的 GLSL / HOOK 着色器路径（避免在主线程执行同步磁盘检测）。
  static Future<List<String>> filterExistingShaderPaths(
    List<String> shaderPaths,
  ) async {
    final valid = <String>[];
    for (final raw in shaderPaths) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      if (await File(path).exists()) {
        valid.add(path);
      }
    }
    return valid;
  }

  /// 拼装有效的 GLSL 着色器列表（已预先异步校验时跳过同步存在性检测，按平台分隔符连接）。
  static String encodeShaderPaths(
    List<String> shaderPaths, {
    required bool isWindows,
    bool alreadyVerified = false,
  }) {
    final valid = <String>[];
    for (final raw in shaderPaths) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      if (alreadyVerified || File(path).existsSync()) {
        valid.add(path);
      }
    }
    if (valid.isEmpty) return '';
    return valid.join(isWindows ? ';' : ':');
  }

  /// 应用内置视频播放前的全部 `mpv_initialize()` 前置选项。
  static void applyPreInitVideoOptions(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    required Directory mpvConfigDir,
    Directory? screenshotDir,
    bool isRemoteStream = false,
    bool? isWindowsOverride,
    bool? isAndroidOverride,
    int? desktopUnderlayHwnd,
    MpvPlatformProfileDelegate? desktopDelegate,
    List<String>? verifiedShaderPaths,
    DiagnosticsLogStore? logStore,
  }) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final isAndroid = isAndroidOverride ?? Platform.isAndroid;
    final setter = MpvSafePropertySetter(logStore: logStore);

    // 严格便携配置沙箱与截图落盘目录隔离
    setter.setOption(client, 'config', 'yes');
    setter.setOption(client, 'config-dir', mpvConfigDir.path);
    setter.setOption(client, 'idle', 'yes');
    setter.setOption(client, 'keep-open', 'yes');
    setter.setOption(client, 'terminal', 'no');
    setter.setOption(client, 'osc', 'no');
    setter.setOption(client, 'osd-level', '0');

    // 视频渲染后端与硬件解码策略：
    // - 桌面端交由平台参数委托注入底层 10-bit/HDR 翻转交换链或兼容外接纹理参数；
    // - Android 延迟至有效像素表面就绪后再切换至 `vo=gpu-next`，支持 libplacebo HDR/DoVi。
    if (isWindows && desktopDelegate != null) {
      desktopDelegate.applyDesktopVideoPreInitOptions(
        client,
        setter,
        config: config,
        desktopUnderlayHwnd: desktopUnderlayHwnd,
      );
    } else if (isAndroid) {
      setter.setOption(client, 'vo', 'null');
      setter.setOption(client, 'gpu-context', 'android');
      setter.setOption(client, 'gpu-api', 'opengl');
      setter.setOption(client, 'opengl-es', 'yes');
      setter.setOption(client, 'egl-output-format', 'rgb10_a2');
      setter.setOption(client, 'target-colorspace-hint', 'auto');
    } else {
      setter.setOption(client, 'vo', genericVideoDriver);
    }
    setter.setOption(
      client,
      'hwdec',
      resolveHwdecValue(
        config: config,
        isWindows: isWindows,
        isAndroid: isAndroid,
        desktopDelegate: desktopDelegate,
      ),
    );
    setter.setOption(
      client,
      'hwdec-codecs',
      isAndroid ? HwdecSafetyPolicy.safeAndroidHwdecCodecs : 'all',
    );
    // 自动按物理核数并发软解，保障 Hi10P / HEVC Rext 拦截回落时满帧流畅。
    setter.setOption(client, 'vd-lavc-threads', '0');

    // 高精色彩管理、libplacebo 动态 HDR 色调映射与抖动
    setter.setOption(client, 'tone-mapping', 'bt.2446a');
    setter.setOption(client, 'hdr-compute-peak', 'yes');
    setter.setOption(client, 'gamut-mapping-mode', 'perceptual');
    setter.setOption(client, 'dither-depth', 'auto');
    setter.setOption(client, 'dither', 'fruit');
    final scalers = resolveScalers(config.preset);
    setter.setOption(client, 'scale', scalers.scale);
    setter.setOption(client, 'cscale', scalers.cscale);
    setter.setOption(client, 'dscale', scalers.dscale);
    setter.setOption(client, 'correct-downscaling', 'yes');
    setter.setOption(client, 'linear-downscaling', 'yes');
    setter.setOption(client, 'sigmoid-upscaling', 'yes');
    setter.setOption(client, 'deband', config.debandEnabled ? 'yes' : 'no');

    // 着色器链
    final shaders = encodeShaderPaths(
      verifiedShaderPaths ?? config.activeShaderPaths,
      isWindows: isWindows,
      alreadyVerified: verifiedShaderPaths != null,
    );
    if (shaders.isNotEmpty) {
      setter.setOption(client, 'glsl-shaders', shaders);
    }

    // 解复用前向 / 回溯纯内存环形缓冲控制（WebDAV / SMB 零写盘极速回跳）
    setter.setOption(client, 'cache', 'yes');
    setter.setOption(client, 'cache-on-disk', 'no');
    final maxBytesMiB = isRemoteStream
        ? math.max(config.demuxerMaxBytesMiB, remoteVideoDemuxerMaxBytesMiB)
        : config.demuxerMaxBytesMiB;
    final backBytesMiB = isRemoteStream
        ? math.max(
            config.demuxerMaxBackBytesMiB,
            remoteVideoDemuxerMaxBackBytesMiB,
          )
        : config.demuxerMaxBackBytesMiB;
    setter.setOption(client, 'demuxer-max-bytes', '${maxBytesMiB}MiB');
    setter.setOption(client, 'demuxer-max-back-bytes', '${backBytesMiB}MiB');
    setter.setOption(client, 'cache-secs', '${config.cacheSecs}');
    setter.setOption(client, 'cache-pause', 'no');
    setter.setOption(client, 'cache-pause-initial', 'no');
    setter.setOption(client, 'cache-pause-wait', '0.25');
    setter.setOption(client, 'demuxer-readahead-secs', '20');
    if (isRemoteStream) {
      setter.setOption(client, 'http-proxy', '');
      setter.setOption(client, 'stream-lavf-o', remoteStreamLavfOptions);
      setter.setOption(client, 'demuxer-lavf-probesize', remoteVideoProbesize);
      setter.setOption(
        client,
        'demuxer-lavf-analyzeduration',
        remoteVideoAnalyzeDuration,
      );
    }

    // 高保真音频后端与跨平台自适应高精度重采样
    setter.setOption(
      client,
      'audio-swresample-o',
      resolveAudioResamplerOptions(config: config, isWindows: isWindows),
    );
    setter.setOption(
      client,
      'gapless-audio',
      AudiophileSafetyPolicy.unifiedGaplessMode,
    );
    if (isWindows && desktopDelegate != null) {
      setter.setOption(client, 'ao', desktopDelegate.desktopAudioDriver);
    } else if (isAndroid) {
      setter.setOption(client, 'ao', androidAudioDriver);
    }
    if (config.audioDevice.trim().isNotEmpty && config.audioDevice != 'auto') {
      setter.setOption(client, 'audio-device', config.audioDevice);
    }
    if (isWindows && desktopDelegate != null) {
      desktopDelegate.applyDesktopAudioExclusivePreInit(client, setter, config);
    }

    // 字幕统一交由上层 SubtitleMemoryEngine（Big5/GBK/Shift-JIS 自动探测归一 + memory:// cached）接管，
    // 禁止 libmpv 旁路直载未归一本地外挂文本字幕导致编码乱码或抢选轨。
    final subParams = resolveSubtitleParameters(config);
    setter.setOption(client, 'sub-auto', 'no');
    setter.setOption(client, 'audio-file-auto', 'fuzzy');
    if (isAndroid) {
      setter.setOption(client, 'sub-font-provider', 'none');
      setter.setOption(
        client,
        'sub-fonts-dir',
        p.join(mpvConfigDir.path, 'fonts'),
      );
      setter.setOption(client, 'sub-scale-with-window', 'yes');
    } else {
      setter.setOption(client, 'sub-font-provider', 'auto');
    }
    setter.setOption(client, 'sub-font-size', '${subParams.fontSize}');
    setter.setOption(client, 'sub-scale', subParams.scale.toStringAsFixed(4));
    setter.setOption(client, 'sub-margin-y', '${subParams.marginY}');
    setter.setOption(client, 'sub-pos', '${subParams.subPos}');
    setter.setOption(client, 'sub-use-margins', 'yes');
    setter.setOption(
      client,
      'sub-ass-force-margins',
      config.subOverrideMode == SubtitleAssOverrideMode.forceStyle
          ? 'yes'
          : 'no',
    );
    if (config.subFontName.trim().isNotEmpty) {
      setter.setOption(client, 'sub-font', config.subFontName.trim());
    }
    if (config.subColorHex.trim().isNotEmpty) {
      setter.setOption(client, 'sub-color', config.subColorHex.trim());
    }
    setter.setOption(client, 'sub-ass-override', subParams.assOverride);

    // 原画无 OSD 高精度 PNG 截图配置（直存作品目录）
    if (screenshotDir != null) {
      setter.setOption(client, 'screenshot-directory', screenshotDir.path);
    }
    setter.setOption(client, 'screenshot-format', 'png');
    setter.setOption(client, 'screenshot-high-bit-depth', 'yes');
    setter.setOption(client, 'screenshot-sw', 'no');
  }

  /// 初始化完成后同步动态运行态属性（含桌面音频独占失败自动退回共享模式提示）。
  static void applyPostInitVideoProperties(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    bool? isWindowsOverride,
    MpvPlatformProfileDelegate? desktopDelegate,
    void Function(String message)? onExclusiveFallbackNotice,
    DiagnosticsLogStore? logStore,
  }) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final setter = MpvSafePropertySetter(logStore: logStore);

    setter.setDouble(client, 'speed', config.defaultSpeed);
    setter.setBool(client, 'audio-pitch-correction', config.keepPitch);
    _applySubtitleRuntimeProperties(client, config: config, setter: setter);

    if (isWindows && desktopDelegate != null) {
      desktopDelegate.applyDesktopAudioExclusivePostInit(
        client,
        setter,
        config,
        onNotice: onExclusiveFallbackNotice,
      );
    }
  }

  /// 解析当前字幕配置对应的 `libmpv` 标准参数组合（区分 `no` / `scale` / `force`）。
  static ({
    String assOverride,
    double fontSize,
    double scale,
    int marginY,
    double subPos,
  })
  resolveSubtitleParameters(PlaybackQualityConfig config) {
    final clampedSize = config.subFontSize.clamp(24, 96);
    final clampedMargin = config.subBottomMargin.clamp(0, 120);
    return switch (config.subOverrideMode) {
      SubtitleAssOverrideMode.preserveAss => (
        assOverride: 'no',
        fontSize: clampedSize.toDouble(),
        scale: 1.0,
        marginY: clampedMargin,
        subPos: 100.0,
      ),
      SubtitleAssOverrideMode.scaleOnly => (
        assOverride: 'scale',
        fontSize: PlaybackQualityConfig.defaultSubFontSize.toDouble(),
        scale: clampedSize / PlaybackQualityConfig.defaultSubFontSize,
        marginY: clampedMargin,
        subPos: 100.0,
      ),
      SubtitleAssOverrideMode.forceStyle => (
        assOverride: 'force',
        fontSize: clampedSize.toDouble(),
        scale: 1.0,
        marginY: clampedMargin,
        subPos: 100.0,
      ),
    };
  }

  static void _applySubtitleRuntimeProperties(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    required MpvSafePropertySetter setter,
  }) {
    final subParams = resolveSubtitleParameters(config);
    // 先写入底层字号（double）、缩放倍率（sub-scale）、垂直边距与字体色彩，
    // 最后写入/刷新 sub-ass-override 以确保 sd_ass 立即重建 ASS 轨道样式缓存并重绘 OSD。
    setter.setDouble(client, 'sub-font-size', subParams.fontSize);
    setter.setDouble(client, 'sub-scale', subParams.scale);
    setter.setInt(client, 'sub-margin-y', subParams.marginY);
    setter.setDouble(client, 'sub-pos', subParams.subPos);
    setter.setBool(client, 'sub-use-margins', true);
    setter.setBool(
      client,
      'sub-ass-force-margins',
      config.subOverrideMode == SubtitleAssOverrideMode.forceStyle,
    );
    if (config.subFontName.trim().isNotEmpty) {
      setter.setString(client, 'sub-font', config.subFontName.trim());
    }
    if (config.subColorHex.trim().isNotEmpty) {
      setter.setString(client, 'sub-color', config.subColorHex.trim());
    }
    final previousOverride = client.getPropertyString('sub-ass-override');
    if (config.subOverrideMode != SubtitleAssOverrideMode.preserveAss &&
        previousOverride == subParams.assOverride) {
      setter.setString(client, 'sub-ass-override', 'no');
    }
    setter.setString(client, 'sub-ass-override', subParams.assOverride);
  }

  /// 在播放运行过程中热切换画质预设、去色带、着色器、硬解或字幕样式。
  static void applyLiveQualityUpdate(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    bool? isWindowsOverride,
    bool? isAndroidOverride,
    MpvPlatformProfileDelegate? desktopDelegate,
    List<String>? verifiedShaderPaths,
    void Function(String message)? onExclusiveFallbackNotice,
    DiagnosticsLogStore? logStore,
  }) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final isAndroid = isAndroidOverride ?? Platform.isAndroid;
    final setter = MpvSafePropertySetter(logStore: logStore);

    final scalers = resolveScalers(config.preset);
    setter.setString(client, 'scale', scalers.scale);
    setter.setString(client, 'cscale', scalers.cscale);
    setter.setString(client, 'dscale', scalers.dscale);
    setter.setBool(client, 'deband', config.debandEnabled);
    setter.setString(
      client,
      'hwdec',
      resolveHwdecValue(
        config: config,
        isWindows: isWindows,
        isAndroid: isAndroid,
        desktopDelegate: desktopDelegate,
      ),
    );

    final shaders = encodeShaderPaths(
      verifiedShaderPaths ?? config.activeShaderPaths,
      isWindows: isWindows,
      alreadyVerified: verifiedShaderPaths != null,
    );
    setter.setString(client, 'glsl-shaders', shaders);

    _applySubtitleRuntimeProperties(client, config: config, setter: setter);

    if (config.audioDevice.trim().isNotEmpty) {
      setter.setString(client, 'audio-device', config.audioDevice);
    }
    if (isWindows && desktopDelegate != null) {
      desktopDelegate.applyDesktopAudioExclusiveLive(
        client,
        setter,
        config,
        onNotice: onExclusiveFallbackNotice,
      );
    }
  }

  /// 应用纯音频（CD / 无损音轨）会话前置选项：`vid=no` + `vo=null` + `gapless-audio=yes`。
  static void applyPreInitAudioOptions(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    required Directory mpvConfigDir,
    bool isRemoteStream = false,
    bool? isWindowsOverride,
    MpvPlatformProfileDelegate? desktopDelegate,
    DiagnosticsLogStore? logStore,
  }) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final setter = MpvSafePropertySetter(logStore: logStore);

    setter.setOption(client, 'config', 'yes');
    setter.setOption(client, 'config-dir', mpvConfigDir.path);
    setter.setOption(client, 'idle', 'yes');
    setter.setOption(client, 'keep-open', 'no');
    setter.setOption(client, 'resume-playback', 'no');
    setter.setOption(client, 'save-position-on-quit', 'no');
    setter.setOption(client, 'loop-file', 'no');
    setter.setOption(client, 'loop-playlist', 'no');
    setter.setOption(client, 'aid', 'auto');
    setter.setOption(client, 'vid', 'no');
    setter.setOption(client, 'video', 'no');
    setter.setOption(client, 'sid', 'no');
    setter.setOption(client, 'vo', 'null');
    setter.setOption(client, 'audio-display', 'no');
    setter.setOption(client, 'cover-art-auto', 'no');
    setter.setOption(client, 'sub-auto', 'no');
    setter.setOption(client, 'audio-file-auto', 'no');
    setter.setOption(client, 'prefetch-playlist', 'yes');
    setter.setOption(
      client,
      'audio-swresample-o',
      resolveAudioResamplerOptions(config: config, isWindows: isWindows),
    );
    setter.setOption(
      client,
      'gapless-audio',
      AudiophileSafetyPolicy.unifiedGaplessMode,
    );
    if (isWindows && desktopDelegate != null) {
      setter.setOption(client, 'ao', desktopDelegate.desktopAudioDriver);
    } else if (!isWindows) {
      setter.setOption(client, 'ao', androidAudioDriver);
    }
    if (config.audioDevice.trim().isNotEmpty && config.audioDevice != 'auto') {
      setter.setOption(client, 'audio-device', config.audioDevice);
    }
    if (isWindows && desktopDelegate != null) {
      desktopDelegate.applyDesktopAudioExclusivePreInit(client, setter, config);
    }
    setter.setOption(client, 'cache', 'yes');
    setter.setOption(client, 'cache-on-disk', 'no');
    setter.setOption(client, 'cache-pause', 'no');
    setter.setOption(client, 'cache-pause-initial', 'no');
    setter.setOption(client, 'cache-pause-wait', '0.25');
    final audioMaxMiB = isRemoteStream
        ? math.max(config.demuxerMaxBytesMiB, remoteAudioDemuxerMaxBytesMiB)
        : config.demuxerMaxBytesMiB;
    final audioBackMiB = isRemoteStream
        ? math.max(
            config.demuxerMaxBackBytesMiB,
            remoteAudioDemuxerMaxBackBytesMiB,
          )
        : config.demuxerMaxBackBytesMiB;
    setter.setOption(client, 'demuxer-max-bytes', '${audioMaxMiB}MiB');
    setter.setOption(client, 'demuxer-max-back-bytes', '${audioBackMiB}MiB');
    if (isRemoteStream) {
      setter.setOption(client, 'http-proxy', '');
      setter.setOption(client, 'stream-lavf-o', remoteStreamLavfOptions);
      setter.setOption(client, 'demuxer-lavf-probesize', remoteAudioProbesize);
      setter.setOption(
        client,
        'demuxer-lavf-analyzeduration',
        remoteAudioAnalyzeDuration,
      );
    }
  }

  /// 原子清零单曲区间裁剪与循环端点属性（每次换曲、CUE 跨轨与停播必调，防止残留截断下一曲）。
  static void resetAudioRangeAndLoopProperties(
    LibMpvClient client, {
    DiagnosticsLogStore? logStore,
  }) {
    final setter = MpvSafePropertySetter(logStore: logStore);
    setter.setString(client, 'end', 'none');
    setter.setString(client, 'ab-loop-a', 'no');
    setter.setString(client, 'ab-loop-b', 'no');
  }

  /// 向运行中的 `libmpv` 实例下发发烧输出路由与末级 `-12 dBFS` 防炸耳滤镜链计划。
  ///
  /// 严格保持 HDMI `audio-spdif` 比特流透传与软件 DSP（`af`）绝对互斥。
  static void applyAudiophileSafetyChain(
    LibMpvClient client, {
    required AudioSafetyChainPlan plan,
    DiagnosticsLogStore? logStore,
  }) {
    final setter = MpvSafePropertySetter(logStore: logStore);
    setter.setString(client, 'gapless-audio', plan.gaplessAudioMode);
    if (plan.audioSpdifCodecs.isNotEmpty) {
      setter.setString(client, 'af', '');
      setter.setString(client, 'audio-spdif', plan.audioSpdifCodecs);
      return;
    }
    setter.setString(client, 'audio-spdif', '');
    setter.setString(client, 'af', plan.audioFilterString);
  }

  /// 在保活会话热切换媒体前同步更新远程/本地流探测与双向内存环形缓存属性。
  static void applyRuntimeStreamProfile(
    LibMpvClient client, {
    required bool isRemoteStream,
    required bool isAudio,
    required PlaybackQualityConfig config,
    DiagnosticsLogStore? logStore,
  }) {
    final setter = MpvSafePropertySetter(logStore: logStore);
    setter.setString(client, 'cache', 'yes');
    setter.setString(client, 'cache-on-disk', 'no');
    if (isAudio) {
      // 每次切曲前强制复位音视频与字幕流选择器及区间裁剪属性，防止跨曲目沿用旧轨道编号引发 -16 错误
      setter.setString(client, 'vid', 'no');
      setter.setString(client, 'sid', 'no');
      setter.setString(client, 'aid', 'auto');
      resetAudioRangeAndLoopProperties(client, logStore: logStore);
    }

    if (isRemoteStream) {
      final maxMiB = isAudio
          ? math.max(config.demuxerMaxBytesMiB, remoteAudioDemuxerMaxBytesMiB)
          : math.max(config.demuxerMaxBytesMiB, remoteVideoDemuxerMaxBytesMiB);
      final backMiB = isAudio
          ? math.max(
              config.demuxerMaxBackBytesMiB,
              remoteAudioDemuxerMaxBackBytesMiB,
            )
          : math.max(
              config.demuxerMaxBackBytesMiB,
              remoteVideoDemuxerMaxBackBytesMiB,
            );
      setter.setString(client, 'http-proxy', '');
      setter.setString(client, 'stream-lavf-o', remoteStreamLavfOptions);
      setter.setString(
        client,
        'demuxer-lavf-probesize',
        isAudio ? remoteAudioProbesize : remoteVideoProbesize,
      );
      setter.setString(
        client,
        'demuxer-lavf-analyzeduration',
        isAudio ? remoteAudioAnalyzeDuration : remoteVideoAnalyzeDuration,
      );
      setter.setString(client, 'demuxer-max-bytes', '${maxMiB}MiB');
      setter.setString(client, 'demuxer-max-back-bytes', '${backMiB}MiB');
    } else {
      setter.setString(
        client,
        'demuxer-max-bytes',
        '${config.demuxerMaxBytesMiB}MiB',
      );
      setter.setString(
        client,
        'demuxer-max-back-bytes',
        '${config.demuxerMaxBackBytesMiB}MiB',
      );
    }
  }

  /// 应用 `thumbfast` 级后台缩略图常驻会话前置选项（极致剥离远程重开销与微缓冲节流）。
  ///
  /// 强制屏蔽音轨、字幕、内封字体（严禁跨 WebDAV 拉取数十 MB ASS 内嵌字体）与着色器，
  /// 使用无精准寻址的关键帧快速跳跃与 512 KiB 微缓冲，确保悬停秒出帧且不抢占主视频带宽。
  static void applyPreInitThumbnailOptions(
    LibMpvClient client, {
    DiagnosticsLogStore? logStore,
  }) {
    final setter = MpvSafePropertySetter(logStore: logStore);

    setter.setOption(client, 'config', 'no');
    setter.setOption(client, 'terminal', 'no');
    setter.setOption(client, 'osc', 'no');
    setter.setOption(client, 'osd-level', '0');
    setter.setOption(client, 'idle', 'yes');
    setter.setOption(client, 'keep-open', 'yes');
    setter.setOption(client, 'pause', 'yes');

    setter.setOption(client, 'vo', 'libmpv');
    setter.setOption(client, 'ao', 'null');
    setter.setOption(client, 'hwdec', 'no');
    setter.setOption(client, 'keepaspect', 'no');
    setter.setOption(client, 'video-timing-offset', '0');

    // 剥离音轨、字幕与内封字体重开销
    setter.setOption(client, 'aid', 'no');
    setter.setOption(client, 'sid', 'no');
    setter.setOption(client, 'embeddedfonts', 'no');
    setter.setOption(client, 'sub-auto', 'no');
    setter.setOption(client, 'audio-file-auto', 'no');
    setter.setOption(client, 'cover-art-auto', 'no');

    // 极速关键帧解码与轻量化缩放管线
    setter.setOption(client, 'hr-seek', 'no');
    setter.setOption(client, 'vd-lavc-fast', 'yes');
    setter.setOption(client, 'vd-lavc-skiploopfilter', 'all');
    setter.setOption(client, 'glsl-shaders', '');
    setter.setOption(client, 'deband', 'no');
    setter.setOption(client, 'scale', 'bilinear');

    // 微量化缓冲节流（避免抢占主视频 WebDAV/SMB 连接池与带宽）
    setter.setOption(client, 'cache', 'no');
    setter.setOption(client, 'demuxer-readahead-secs', '0');
    setter.setOption(client, 'demuxer-max-bytes', '524288');
    setter.setOption(client, 'stream-buffer-size', '65536');
  }

  /// 扫描 `<Root>/userdata/mpv/shaders/` 下可用的 `.glsl` / `.hook` 着色器脚本。
  static Future<List<File>> discoverShaderFiles(Directory shadersDir) async {
    if (!await shadersDir.exists()) return const [];
    final files = <File>[];
    await for (final entity in shadersDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (ext == '.glsl' || ext == '.hook') {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return files;
  }

  /// 实时探测当前内嵌 `libmpv` 与 `FFmpeg` 版本号（无窗口开销，供设置中心实时展示）。
  static Future<MpvRuntimeVersions> probeRuntimeVersions({
    String? preferredLibraryPath,
  }) async {
    if (preferredLibraryPath == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return const MpvRuntimeVersions(
        isAvailable: false,
        errorMessage: 'flutter_test environment',
      );
    }
    FfiLibMpvClient? client;
    try {
      client = FfiLibMpvClient.create(
        preferredLibraryPath: preferredLibraryPath,
      );
      client.setOptionString('vo', 'null');
      client.setOptionString('ao', 'null');
      client.setOptionString('vid', 'no');
      client.setOptionString('aid', 'no');
      final rc = client.initialize();
      if (rc < 0) {
        return MpvRuntimeVersions(
          isAvailable: false,
          errorMessage: 'libmpv initialize failed ($rc)',
        );
      }
      final mpvVer = client.getPropertyString('mpv-version') ?? '';
      final ffVer = client.getPropertyString('ffmpeg-version') ?? '';
      return MpvRuntimeVersions(
        isAvailable: mpvVer.isNotEmpty || ffVer.isNotEmpty,
        mpvVersion: mpvVer,
        ffmpegVersion: ffVer,
      );
    } catch (e) {
      return MpvRuntimeVersions(isAvailable: false, errorMessage: '$e');
    } finally {
      if (client != null) {
        await client.dispose();
      }
    }
  }
}
