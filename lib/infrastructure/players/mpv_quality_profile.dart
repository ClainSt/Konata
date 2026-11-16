import 'dart:io';

import 'package:path/path.dart' as p;

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

/// 音视频播放画质、音频后端与缓存持久化配置模型（强类型，严禁跨层 Map）。
class PlaybackQualityConfig {
  /// 创建画质与音画偏好配置。
  const PlaybackQualityConfig({
    this.preset = VideoQualityPreset.highFidelity,
    this.hardwareDecode = true,
    this.debandEnabled = false,
    this.demuxerMaxBytesMiB = defaultDemuxerMaxBytesMiB,
    this.demuxerMaxBackBytesMiB = defaultDemuxerMaxBackBytesMiB,
    this.cacheSecs = defaultCacheSecs,
    this.audioResamplerPrecision = defaultSoxrPrecision,
    this.wasapiExclusive = false,
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
  static const Duration skipPillAutoFadeDuration = Duration(
    milliseconds: 4000,
  );

  /// 自动连播下一集顶部轻提示显示时长（3 秒）。
  static const Duration autoNextEpisodeToastDuration = Duration(
    milliseconds: 3000,
  );

  final VideoQualityPreset preset;
  final bool hardwareDecode;
  final bool debandEnabled;
  final int demuxerMaxBytesMiB;
  final int demuxerMaxBackBytesMiB;
  final int cacheSecs;
  final int audioResamplerPrecision;
  final bool wasapiExclusive;
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
    bool? hardwareDecode,
    bool? debandEnabled,
    int? demuxerMaxBytesMiB,
    int? demuxerMaxBackBytesMiB,
    int? cacheSecs,
    int? audioResamplerPrecision,
    bool? wasapiExclusive,
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
      hardwareDecode: hardwareDecode ?? this.hardwareDecode,
      debandEnabled: debandEnabled ?? this.debandEnabled,
      demuxerMaxBytesMiB: demuxerMaxBytesMiB ?? this.demuxerMaxBytesMiB,
      demuxerMaxBackBytesMiB:
          demuxerMaxBackBytesMiB ?? this.demuxerMaxBackBytesMiB,
      cacheSecs: cacheSecs ?? this.cacheSecs,
      audioResamplerPrecision:
          audioResamplerPrecision ?? this.audioResamplerPrecision,
      wasapiExclusive: wasapiExclusive ?? this.wasapiExclusive,
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

  /// 运行时写入整数属性。
  bool setInt(LibMpvClient client, String name, int value) {
    final rc = client.setPropertyInt64(name, value);
    return _handleResult(client, 'prop:$name=$value', rc);
  }

  /// 运行时写入双精度浮点属性。
  bool setDouble(LibMpvClient client, String name, double value) {
    final rc = client.setPropertyDouble(name, value);
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

  static const String windowsVideoDriver = 'libmpv';
  static const String androidVideoDriver = 'gpu';
  static const String windowsAudioDriver = 'wasapi';
  static const String androidAudioDriver = 'aaudio,audiotrack,opensles';

  /// 解析当前平台与预设对应的最优硬件解码策略。
  static String resolveHwdecValue({
    required PlaybackQualityConfig config,
    required bool isWindows,
    required bool isAndroid,
  }) {
    if (!config.hardwareDecode ||
        config.preset == VideoQualityPreset.softwareFallback) {
      return 'no';
    }
    if (isWindows) {
      return 'd3d11va,d3d11va-copy,auto-safe';
    }
    if (isAndroid) {
      return 'mediacodec,auto-safe';
    }
    return 'auto-safe';
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
      VideoQualityPreset.lightweight ||
      VideoQualityPreset.softwareFallback => (
        scale: 'bilinear',
        cscale: 'bilinear',
        dscale: 'bilinear',
      ),
    };
  }

  /// 拼装有效的 GLSL 着色器列表（过滤磁盘上已不存在的条目，按平台分隔符连接）。
  static String encodeShaderPaths(
    List<String> shaderPaths, {
    required bool isWindows,
  }) {
    final valid = <String>[];
    for (final raw in shaderPaths) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      if (File(path).existsSync()) {
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
    bool? isWindowsOverride,
    bool? isAndroidOverride,
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

    // 视频渲染后端与硬件解码策略
    if (isWindows) {
      setter.setOption(client, 'vo', windowsVideoDriver);
    } else if (isAndroid) {
      setter.setOption(client, 'vo', androidVideoDriver);
      setter.setOption(client, 'gpu-context', 'android');
    } else {
      setter.setOption(client, 'vo', windowsVideoDriver);
    }
    setter.setOption(
      client,
      'hwdec',
      resolveHwdecValue(
        config: config,
        isWindows: isWindows,
        isAndroid: isAndroid,
      ),
    );
    setter.setOption(client, 'hwdec-codecs', 'all');

    // 高精色彩管理与抖动（Windows D3D11 使用 rgba16hf 防止触发 dumb mode，其余平台使用 rgba16f）
    setter.setOption(client, 'fbo-format', isWindows ? 'rgba16hf' : 'rgba16f');
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
      config.activeShaderPaths,
      isWindows: isWindows,
    );
    if (shaders.isNotEmpty) {
      setter.setOption(client, 'glsl-shaders', shaders);
    }

    // 解复用前向 / 回溯缓冲控制（WebDAV / SMB 流畅拖放）
    setter.setOption(client, 'cache', 'yes');
    setter.setOption(
      client,
      'demuxer-max-bytes',
      '${config.demuxerMaxBytesMiB}MiB',
    );
    setter.setOption(
      client,
      'demuxer-max-back-bytes',
      '${config.demuxerMaxBackBytesMiB}MiB',
    );
    setter.setOption(client, 'cache-secs', '${config.cacheSecs}');
    setter.setOption(client, 'cache-pause', 'no');
    setter.setOption(client, 'cache-pause-initial', 'no');
    setter.setOption(client, 'cache-pause-wait', '0.25');
    setter.setOption(client, 'demuxer-readahead-secs', '20');

    // 高保真音频后端与 libsoxr 28-bit 重采样
    setter.setOption(
      client,
      'audio-swresample-o',
      'resampler=soxr,precision=${config.audioResamplerPrecision}',
    );
    setter.setOption(client, 'gapless-audio', 'yes');
    setter.setOption(client, 'ao', isWindows ? windowsAudioDriver : androidAudioDriver);
    if (config.audioDevice.trim().isNotEmpty && config.audioDevice != 'auto') {
      setter.setOption(client, 'audio-device', config.audioDevice);
    }
    if (isWindows && config.wasapiExclusive) {
      setter.setOption(client, 'audio-exclusive', 'yes');
    }

    // 字幕与外挂音轨策略
    setter.setOption(client, 'sub-auto', 'fuzzy');
    setter.setOption(client, 'audio-file-auto', 'fuzzy');
    setter.setOption(client, 'sub-font-provider', 'auto');
    setter.setOption(client, 'sub-ass-override', config.subOverrideMode.mpvValue);
    setter.setOption(client, 'sub-font-size', '${config.subFontSize}');
    setter.setOption(client, 'sub-margin-y', '${config.subBottomMargin}');
    if (config.subFontName.trim().isNotEmpty) {
      setter.setOption(client, 'sub-font', config.subFontName.trim());
    }
    if (config.subColorHex.trim().isNotEmpty) {
      setter.setOption(client, 'sub-color', config.subColorHex.trim());
    }

    // 原画无 OSD 高精度 PNG 截图配置（直存作品目录）
    if (screenshotDir != null) {
      setter.setOption(client, 'screenshot-directory', screenshotDir.path);
    }
    setter.setOption(client, 'screenshot-format', 'png');
    setter.setOption(client, 'screenshot-high-bit-depth', 'yes');
    setter.setOption(client, 'screenshot-sw', 'no');
  }

  /// 初始化完成后同步动态运行态属性（含 WASAPI 独占失败自动退回共享模式提示）。
  static void applyPostInitVideoProperties(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    bool? isWindowsOverride,
    void Function(String message)? onWasapiFallbackNotice,
    DiagnosticsLogStore? logStore,
  }) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final setter = MpvSafePropertySetter(logStore: logStore);

    setter.setDouble(client, 'speed', config.defaultSpeed);
    setter.setBool(client, 'audio-pitch-correction', config.keepPitch);

    if (isWindows && config.wasapiExclusive) {
      final ok = setter.setBool(client, 'audio-exclusive', true);
      if (!ok) {
        setter.setBool(client, 'audio-exclusive', false);
        onWasapiFallbackNotice?.call('WASAPI 独占模式初始化受限，已自动回退至共享混音输出');
      }
    }
  }

  /// 在播放运行过程中热切换画质预设、去色带、着色器、硬解或字幕样式。
  static void applyLiveQualityUpdate(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    bool? isWindowsOverride,
    bool? isAndroidOverride,
    void Function(String message)? onWasapiFallbackNotice,
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
      ),
    );

    final shaders = encodeShaderPaths(
      config.activeShaderPaths,
      isWindows: isWindows,
    );
    setter.setString(client, 'glsl-shaders', shaders);

    setter.setString(client, 'sub-ass-override', config.subOverrideMode.mpvValue);
    setter.setInt(client, 'sub-font-size', config.subFontSize);
    setter.setInt(client, 'sub-margin-y', config.subBottomMargin);
    if (config.subFontName.trim().isNotEmpty) {
      setter.setString(client, 'sub-font', config.subFontName.trim());
    }
    if (config.subColorHex.trim().isNotEmpty) {
      setter.setString(client, 'sub-color', config.subColorHex.trim());
    }

    if (config.audioDevice.trim().isNotEmpty) {
      setter.setString(client, 'audio-device', config.audioDevice);
    }
    if (isWindows) {
      final exclusiveOk = setter.setBool(
        client,
        'audio-exclusive',
        config.wasapiExclusive,
      );
      if (config.wasapiExclusive && !exclusiveOk) {
        setter.setBool(client, 'audio-exclusive', false);
        onWasapiFallbackNotice?.call('当前音频设备不支持 WASAPI 独占模式，已自动切回共享模式');
      }
    }
  }

  /// 应用纯音频（CD / 无损音轨）会话前置选项：`vid=no` + `vo=null` + `gapless-audio=yes`。
  static void applyPreInitAudioOptions(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    required Directory mpvConfigDir,
    bool? isWindowsOverride,
    DiagnosticsLogStore? logStore,
  }) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final setter = MpvSafePropertySetter(logStore: logStore);

    setter.setOption(client, 'config', 'yes');
    setter.setOption(client, 'config-dir', mpvConfigDir.path);
    setter.setOption(client, 'idle', 'yes');
    setter.setOption(client, 'keep-open', 'yes');
    setter.setOption(client, 'vid', 'no');
    setter.setOption(client, 'vo', 'null');
    setter.setOption(client, 'audio-display', 'no');
    setter.setOption(
      client,
      'audio-swresample-o',
      'resampler=soxr,precision=${config.audioResamplerPrecision}',
    );
    setter.setOption(client, 'gapless-audio', 'yes');
    setter.setOption(
      client,
      'ao',
      isWindows ? windowsAudioDriver : androidAudioDriver,
    );
    if (config.audioDevice.trim().isNotEmpty && config.audioDevice != 'auto') {
      setter.setOption(client, 'audio-device', config.audioDevice);
    }
    if (isWindows && config.wasapiExclusive) {
      setter.setOption(client, 'audio-exclusive', 'yes');
    }
    setter.setOption(client, 'cache', 'yes');
    setter.setOption(client, 'cache-pause', 'no');
    setter.setOption(client, 'cache-pause-initial', 'no');
    setter.setOption(client, 'cache-pause-wait', '0.25');
    setter.setOption(
      client,
      'demuxer-max-bytes',
      '${config.demuxerMaxBytesMiB}MiB',
    );
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

  /// 同步只读扫描 `<Root>/userdata/shaders/` 下可用的 `.glsl` / `.hook` 着色器脚本。
  static List<File> discoverShaderFilesSync(Directory shadersDir) {
    if (!shadersDir.existsSync()) return const [];
    final files = <File>[];
    for (final entity in shadersDir.listSync(followLinks: false)) {
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
