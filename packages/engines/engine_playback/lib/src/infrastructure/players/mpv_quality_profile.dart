import 'dart:io';
import 'dart:math' as math;

import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import '../../domain/playback/audiophile_safety_policy.dart';
import '../../domain/playback/hwdec_safety_policy.dart';
import '../../domain/playback/track_preferences.dart';
import '../playback_log_helper.dart';
import 'libmpv_ffi.dart';

part 'mpv_quality_profile_models.dart';

/// libmpv 容错属性/选项安全写入器。
///
/// 对 `MPV_ERROR_OPTION_NOT_FOUND (-5)`、`MPV_ERROR_PROPERTY_NOT_FOUND (-8)`、
/// `MPV_ERROR_PROPERTY_UNAVAILABLE (-10)` 等版本兼容差异做静默拦截并记入诊断日志，
/// 确保永不因局部参数版本差异导致播放启动崩溃。
class MpvSafePropertySetter {
  const MpvSafePropertySetter({this.logStore});

  final DiagnosticLogPort? logStore;

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
    PlaybackLogHelper.record(logStore, 
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
  static const String defaultAndroidCjkSubFontFamily = 'Noto Sans CJK SC';

  /// WebDAV / HTTP 本地流网桥回环重连与头部加速探测参数（按端分档控制解复用内存占用）。
  static const String remoteStreamLavfOptions =
      'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2';
  static const String remoteVideoProbesize = '2097152';
  static const String remoteAudioProbesize = '1048576';
  static const String remoteVideoAnalyzeDuration = '1.5';
  static const String remoteAudioAnalyzeDuration = '1.0';
  static const int remoteVideoDemuxerMaxBytesMiB = 48;
  static const int remoteVideoDemuxerMaxBackBytesMiB = 16;
  static const int remoteAndroidVideoDemuxerMaxBytesMiB = 32;
  static const int remoteAndroidVideoDemuxerMaxBackBytesMiB = 12;
  static const int localAudioDemuxerMaxBytesMiB = 16;
  static const int localAudioDemuxerMaxBackBytesMiB = 8;
  static const int remoteAudioDemuxerMaxBytesMiB = 24;
  static const int remoteAudioDemuxerMaxBackBytesMiB = 8;
  static const int defaultDemuxerReadaheadSecs = 15;
  static const int highSpeedDemuxerReadaheadSecs = 30;
  static const int androidDefaultDemuxerReadaheadSecs = 12;
  static const int androidHighSpeedDemuxerReadaheadSecs = 24;
  static const double highSpeedReadaheadThreshold = 1.5;

  /// 根据倍速与流类型动态计算 `demuxer-readahead-secs`，在远程 2x 倍速期提前拉大预读窗口防卡顿。
  static int resolveDemuxerReadaheadSecs({
    required double playbackSpeed,
    required bool isRemoteStream,
    required bool isAndroid,
  }) {
    final base = isAndroid
        ? androidDefaultDemuxerReadaheadSecs
        : defaultDemuxerReadaheadSecs;
    if (!isRemoteStream || playbackSpeed < highSpeedReadaheadThreshold) {
      return base;
    }
    return isAndroid
        ? androidHighSpeedDemuxerReadaheadSecs
        : highSpeedDemuxerReadaheadSecs;
  }

  /// 按媒体类型、是否远程流与运行平台计算精准的解复用前向/回溯内存环形缓冲上限（MiB）。
  static ({int maxBytesMiB, int backBytesMiB}) resolveDemuxerBufferMiB({
    required PlaybackQualityConfig config,
    required bool isRemoteStream,
    required bool isAudio,
    required bool isAndroid,
  }) {
    if (isAudio) {
      if (isRemoteStream) {
        return (
          maxBytesMiB: remoteAudioDemuxerMaxBytesMiB,
          backBytesMiB: remoteAudioDemuxerMaxBackBytesMiB,
        );
      }
      return (
        maxBytesMiB: localAudioDemuxerMaxBytesMiB,
        backBytesMiB: localAudioDemuxerMaxBackBytesMiB,
      );
    }
    if (isRemoteStream) {
      if (isAndroid) {
        final maxBytes =
            config.demuxerMaxBytesMiB ==
                PlaybackQualityConfig.defaultDemuxerMaxBytesMiB
            ? remoteAndroidVideoDemuxerMaxBytesMiB
            : config.demuxerMaxBytesMiB.clamp(
                16,
                remoteAndroidVideoDemuxerMaxBytesMiB,
              );
        final backBytes =
            config.demuxerMaxBackBytesMiB ==
                PlaybackQualityConfig.defaultDemuxerMaxBackBytesMiB
            ? remoteAndroidVideoDemuxerMaxBackBytesMiB
            : config.demuxerMaxBackBytesMiB.clamp(
                4,
                remoteAndroidVideoDemuxerMaxBackBytesMiB,
              );
        return (maxBytesMiB: maxBytes, backBytesMiB: backBytes);
      }
      return (
        maxBytesMiB: math.max(
          config.demuxerMaxBytesMiB,
          remoteVideoDemuxerMaxBytesMiB,
        ),
        backBytesMiB: math.max(
          config.demuxerMaxBackBytesMiB,
          remoteVideoDemuxerMaxBackBytesMiB,
        ),
      );
    }
    return (
      maxBytesMiB: config.demuxerMaxBytesMiB,
      backBytesMiB: config.demuxerMaxBackBytesMiB,
    );
  }

  /// 判定视频传输特性或信号峰值是否属于真 HDR 片源（PQ / HLG / 信号峰值 > 1.05）。
  static bool isHdrTransfer({String? gamma, double? sigPeak}) {
    final normalized = gamma?.trim().toLowerCase() ?? '';
    if (normalized == 'pq' ||
        normalized == 'hlg' ||
        normalized == 'st2084' ||
        normalized == 'arib-std-b67' ||
        normalized == 'dolby-vision') {
      return true;
    }
    return sigPeak != null && sigPeak.isFinite && sigPeak > 1.05;
  }

  /// 解析当前画质档位与片源动态范围是否启用动态 HDR 峰值计算（SDR 与省电/纯软解档关闭以省去逐帧 Compute Shader）。
  static bool shouldEnableHdrComputePeak(
    VideoQualityPreset preset, {
    bool isHdrSource = true,
  }) {
    if (!isHdrSource) return false;
    return preset == VideoQualityPreset.highFidelity ||
        preset == VideoQualityPreset.standard;
  }

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
      // Android 优先尝试零拷贝 MediaCodec Surface 直出，受限时平滑回退拷贝与安全自动路径。
      return 'mediacodec,mediacodec-copy,auto-safe';
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

  /// 解析当前画质预设对应的上下采样滤波器三元组（全面兼容 `vo=gpu-next` / `libplacebo`）。
  static ({String scale, String cscale, String dscale}) resolveScalers(
    VideoQualityPreset preset,
  ) {
    return switch (preset) {
      VideoQualityPreset.highFidelity => (
        scale: 'ewa_lanczossharp',
        cscale: 'ewa_lanczos',
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
      if (File(path).existsSync()) {
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
    Directory? gpuShaderCacheDir,
    Directory? iccCacheDir,
    bool isRemoteStream = false,
    bool? isWindowsOverride,
    bool? isAndroidOverride,
    int? desktopUnderlayHwnd,
    MpvPlatformProfileDelegate? desktopDelegate,
    List<String>? verifiedShaderPaths,
    DiagnosticLogPort? logStore,
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

    // 高精色彩管理、便携着色器/ICC 磁盘缓存、libplacebo 动态 HDR 色调映射与抖动
    if (gpuShaderCacheDir != null) {
      setter.setOption(client, 'gpu-shader-cache', 'yes');
      setter.setOption(client, 'gpu-shader-cache-dir', gpuShaderCacheDir.path);
    }
    // Android 内置 libplacebo 未编入 LittleCMS 2，显式关闭 icc-cache 避免每次起播触发无害报错日志。
    if (isAndroid) {
      setter.setOption(client, 'icc-cache', 'no');
    } else if (iccCacheDir != null) {
      setter.setOption(client, 'icc-cache', 'yes');
      setter.setOption(client, 'icc-cache-dir', iccCacheDir.path);
    }
    setter.setOption(client, 'tone-mapping', 'bt.2446a');
    // 启动前置默认关闭逐帧 HDR 峰值计算，待视频轨道就绪探测到真 HDR 信号后再动态开启。
    setter.setOption(client, 'hdr-compute-peak', 'no');
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

    // 解复用前向 / 回溯纯内存环形缓冲控制（WebDAV / SMB 零写盘极速回跳，按平台精准定额防内存虚高）
    setter.setOption(client, 'cache', 'yes');
    setter.setOption(client, 'cache-on-disk', 'no');
    final videoBuffer = resolveDemuxerBufferMiB(
      config: config,
      isRemoteStream: isRemoteStream,
      isAudio: false,
      isAndroid: isAndroid,
    );
    setter.setOption(
      client,
      'demuxer-max-bytes',
      '${videoBuffer.maxBytesMiB}MiB',
    );
    setter.setOption(
      client,
      'demuxer-max-back-bytes',
      '${videoBuffer.backBytesMiB}MiB',
    );
    setter.setOption(client, 'cache-secs', '${config.cacheSecs}');
    setter.setOption(client, 'cache-pause', 'no');
    setter.setOption(client, 'cache-pause-initial', 'no');
    setter.setOption(client, 'cache-pause-wait', '0.25');
    setter.setOption(
      client,
      'demuxer-readahead-secs',
      '${isAndroid ? androidDefaultDemuxerReadaheadSecs : defaultDemuxerReadaheadSecs}',
    );
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
    setter.setOption(client, 'sub-pos', subParams.subPos.toStringAsFixed(1));
    setter.setOption(
      client,
      'secondary-sub-pos',
      subParams.secondarySubPos.toStringAsFixed(1),
    );
    setter.setOption(
      client,
      'secondary-sub-ass-override',
      subParams.secondaryAssOverride,
    );
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
    } else if (isAndroid) {
      // Android 端关闭系统 fontconfig 后显式指定简体中文默认字族，优先命中 `NotoSansCJK` 简体字面。
      setter.setOption(client, 'sub-font', defaultAndroidCjkSubFontFamily);
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
    bool hasSecondarySubtitle = false,
    bool? isWindowsOverride,
    MpvPlatformProfileDelegate? desktopDelegate,
    void Function(String message)? onExclusiveFallbackNotice,
    DiagnosticLogPort? logStore,
  }) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final setter = MpvSafePropertySetter(logStore: logStore);

    setter.setDouble(client, 'speed', config.defaultSpeed);
    setter.setBool(client, 'audio-pitch-correction', config.keepPitch);
    _applySubtitleRuntimeProperties(
      client,
      config: config,
      hasSecondarySubtitle: hasSecondarySubtitle,
      setter: setter,
    );

    if (isWindows && desktopDelegate != null) {
      desktopDelegate.applyDesktopAudioExclusivePostInit(
        client,
        setter,
        config,
        onNotice: onExclusiveFallbackNotice,
      );
    }
  }

  /// 解析当前字幕配置对应的 `libmpv` 标准参数组合（区分 `no` / `scale` / `force`，并支持双语主上副下底部叠排）。
  static ({
    String assOverride,
    double fontSize,
    double scale,
    int marginY,
    double subPos,
    double secondarySubPos,
    String secondaryAssOverride,
  })
  resolveSubtitleParameters(
    PlaybackQualityConfig config, {
    bool hasSecondarySubtitle = false,
  }) {
    final clampedSize = config.subFontSize.clamp(24, 96);
    final clampedMargin = config.subBottomMargin.clamp(0, 120);
    final dynamicSubPos = (100.0 - clampedMargin * 0.20).clamp(70.0, 100.0);
    final baseBottomPos =
        config.subOverrideMode == SubtitleAssOverrideMode.preserveAss
        ? 100.0
        : dynamicSubPos;
    // 启用双语副字幕时，副字幕固定位于画面最下方基准位，主字幕按当前等效字号占高向上抬升一层，
    // 复刻常规单文件中日双语（主字幕在上、副字幕在下）的底部紧凑排布并避免两行重叠。
    final bilingualPrimaryLift = ((clampedSize / 720.0) * 100.0 * 1.25).clamp(
      6.0,
      16.0,
    );
    final effectivePrimarySubPos = hasSecondarySubtitle
        ? (baseBottomPos - bilingualPrimaryLift).clamp(50.0, 96.0)
        : baseBottomPos;
    return switch (config.subOverrideMode) {
      SubtitleAssOverrideMode.preserveAss => (
        assOverride: 'no',
        fontSize: clampedSize.toDouble(),
        scale: 1.0,
        marginY: clampedMargin,
        subPos: effectivePrimarySubPos,
        secondarySubPos: baseBottomPos,
        secondaryAssOverride: 'strip',
      ),
      SubtitleAssOverrideMode.scaleOnly => (
        assOverride: 'scale',
        fontSize: PlaybackQualityConfig.defaultSubFontSize.toDouble(),
        scale: clampedSize / PlaybackQualityConfig.defaultSubFontSize,
        marginY: clampedMargin,
        subPos: effectivePrimarySubPos,
        secondarySubPos: baseBottomPos,
        secondaryAssOverride: 'strip',
      ),
      SubtitleAssOverrideMode.forceStyle => (
        assOverride: 'force',
        fontSize: clampedSize.toDouble(),
        scale: 1.0,
        marginY: clampedMargin,
        subPos: effectivePrimarySubPos,
        secondarySubPos: baseBottomPos,
        secondaryAssOverride: 'strip',
      ),
    };
  }

  static void _applySubtitleRuntimeProperties(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    required MpvSafePropertySetter setter,
    bool hasSecondarySubtitle = false,
  }) {
    final subParams = resolveSubtitleParameters(
      config,
      hasSecondarySubtitle: hasSecondarySubtitle,
    );
    // 先写入字号、缩放倍率、垂直边距与主/副字幕垂直定位，再同步 ASS 样式覆写并刷新即时重绘。
    setter.setDouble(client, 'sub-font-size', subParams.fontSize);
    setter.setDouble(client, 'sub-scale', subParams.scale);
    setter.setInt(client, 'sub-margin-y', subParams.marginY);
    setter.setDouble(client, 'sub-pos', subParams.subPos);
    setter.setDouble(client, 'secondary-sub-pos', subParams.secondarySubPos);
    setter.setString(
      client,
      'secondary-sub-ass-override',
      subParams.secondaryAssOverride,
    );
    setter.setBool(client, 'sub-use-margins', true);
    final isForce = config.subOverrideMode == SubtitleAssOverrideMode.forceStyle;
    setter.setBool(client, 'sub-ass-force-margins', isForce);
    // 保持 sub-ass-style-overrides 为空，由 libmpv 自动按脚本 PlayResY 归一换算 sub-font-size 与 sub-margin-y，避免跨分辨率脚本字号畸变。
    setter.setString(client, 'sub-ass-style-overrides', '');
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

  /// 轻量同步热更新字幕字号、底部边距、双语底部排布与 ASS 样式覆写模式（零磁盘校验、绝不重置解码器/着色器/音频设备）。
  static void applyLiveSubtitleStyleUpdate(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    bool hasSecondarySubtitle = false,
    DiagnosticLogPort? logStore,
  }) => _applySubtitleRuntimeProperties(
    client,
    config: config,
    hasSecondarySubtitle: hasSecondarySubtitle,
    setter: MpvSafePropertySetter(logStore: logStore),
  );

  /// 在播放运行过程中热切换画质预设、去色带、着色器、硬解或字幕样式。
  static void applyLiveQualityUpdate(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    bool isHdrSource = false,
    bool hasSecondarySubtitle = false,
    bool? isWindowsOverride,
    bool? isAndroidOverride,
    MpvPlatformProfileDelegate? desktopDelegate,
    List<String>? verifiedShaderPaths,
    void Function(String message)? onExclusiveFallbackNotice,
    DiagnosticLogPort? logStore,
  }) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final isAndroid = isAndroidOverride ?? Platform.isAndroid;
    final setter = MpvSafePropertySetter(logStore: logStore);

    final scalers = resolveScalers(config.preset);
    setter.setString(client, 'scale', scalers.scale);
    setter.setString(client, 'cscale', scalers.cscale);
    setter.setString(client, 'dscale', scalers.dscale);
    setter.setBool(
      client,
      'hdr-compute-peak',
      shouldEnableHdrComputePeak(config.preset, isHdrSource: isHdrSource),
    );
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

    _applySubtitleRuntimeProperties(
      client,
      config: config,
      hasSecondarySubtitle: hasSecondarySubtitle,
      setter: setter,
    );

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
    DiagnosticLogPort? logStore,
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
    final audioBuffer = resolveDemuxerBufferMiB(
      config: config,
      isRemoteStream: isRemoteStream,
      isAudio: true,
      isAndroid: !isWindows,
    );
    setter.setOption(
      client,
      'demuxer-max-bytes',
      '${audioBuffer.maxBytesMiB}MiB',
    );
    setter.setOption(
      client,
      'demuxer-max-back-bytes',
      '${audioBuffer.backBytesMiB}MiB',
    );
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
    DiagnosticLogPort? logStore,
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
    DiagnosticLogPort? logStore,
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
    bool? isAndroidOverride,
    DiagnosticLogPort? logStore,
  }) {
    final isAndroid = isAndroidOverride ?? Platform.isAndroid;
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

    final buffer = resolveDemuxerBufferMiB(
      config: config,
      isRemoteStream: isRemoteStream,
      isAudio: isAudio,
      isAndroid: isAndroid,
    );
    if (isRemoteStream) {
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
    }
    setter.setString(client, 'demuxer-max-bytes', '${buffer.maxBytesMiB}MiB');
    setter.setString(
      client,
      'demuxer-max-back-bytes',
      '${buffer.backBytesMiB}MiB',
    );
  }

  /// 应用 `thumbfast` 级后台缩略图常驻会话前置选项（极致剥离远程重开销与微缓冲节流）。
  ///
  /// 强制屏蔽音轨、字幕、内封字体（严禁跨 WebDAV 拉取数十 MB ASS 内嵌字体）与着色器，
  /// 使用无精准寻址的关键帧快速跳跃与 512 KiB 微缓冲，确保悬停秒出帧且不抢占主视频带宽。
  static void applyPreInitThumbnailOptions(
    LibMpvClient client, {
    DiagnosticLogPort? logStore,
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

    // 极速关键帧解码与轻量化缩放管线（限制软解并发线程数防抢占主视频解码核心）
    setter.setOption(client, 'hr-seek', 'no');
    setter.setOption(client, 'vd-lavc-threads', '2');
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

  /// 扫描 `<Root>/userdata/shaders/` 下可用的 `.glsl` / `.hook` 着色器脚本。
  static Future<List<File>> discoverShaderFiles(Directory shadersDir) async {
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
    LibMpvClient Function({String? preferredLibraryPath})? clientFactory,
  }) async {
    if (preferredLibraryPath == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return const MpvRuntimeVersions(
        isAvailable: false,
        errorMessage: 'flutter_test environment',
      );
    }
    if (clientFactory == null) {
      return const MpvRuntimeVersions(
        isAvailable: false,
        errorMessage: '未注入统一播放内核客户端工厂',
      );
    }
    LibMpvClient? client;
    try {
      client = clientFactory(preferredLibraryPath: preferredLibraryPath);
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
