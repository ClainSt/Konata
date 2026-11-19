import 'dart:math' as math;

/// 发烧音频输出路由模式。
enum AudioOutputRouteMode {
  /// 共享混音输出（桌面共享 + libsoxr 28-bit 高精重采样 / Android AAudio）。
  sharedResampled,

  /// 桌面端音频独占源格式直通。
  exclusiveAudioOutput,

  /// 比特流源码直通（`audio-spdif`，与任何软件 DSP 严格互斥）。
  bitstreamPassthrough,

  /// Android 14+ 原生 `MIXER_BEHAVIOR_BIT_PERFECT` USB DAC 逐位直通。
  androidBitPerfectUsb,
}

/// 外设防炸耳会话安全状态（追踪新插外设自动复位安全衰减与物理硬件电平仪实证门锁）。
class AudioDeviceSafetyState {
  /// 创建外设安全状态快照。
  const AudioDeviceSafetyState({
    this.deviceFingerprint = 'default',
    this.isBackendMeterVerified = false,
    this.sessionFullScaleUnlocked = false,
  });

  /// 当前音频输出外设指纹标识（外设插拔变更时自动重置安全衰减门锁）。
  final String deviceFingerprint;

  /// 当前后端是否已完成物理硬件电平仪实证（未实证后端强制锁定关闭满幅档）。
  final bool isBackendMeterVerified;

  /// 当前外设在本次会话中是否已经用户显式确认解锁满幅输出。
  final bool sessionFullScaleUnlocked;

  /// 是否允许解除 `-12 dBFS` 末级安全上限进入满幅旁路（未实证后端永远为 `false`）。
  bool get allowFullScaleBypass =>
      isBackendMeterVerified && sessionFullScaleUnlocked;

  /// 当检测到新插入或切换音频外设时，强制恢复安全衰减起步，必须当次会话重新确认后才解锁。
  AudioDeviceSafetyState onDeviceChanged(
    String nextDeviceFingerprint, {
    bool? nextBackendMeterVerified,
  }) {
    final normalized = nextDeviceFingerprint.trim().isEmpty
        ? 'default'
        : nextDeviceFingerprint.trim();
    if (normalized == deviceFingerprint &&
        (nextBackendMeterVerified == null ||
            nextBackendMeterVerified == isBackendMeterVerified)) {
      return this;
    }
    return AudioDeviceSafetyState(
      deviceFingerprint: normalized,
      isBackendMeterVerified:
          nextBackendMeterVerified ?? isBackendMeterVerified,
      sessionFullScaleUnlocked: false,
    );
  }

  /// 尝试为当前已实证外设解锁当次会话满幅输出；未经物理电平仪实证的后端强制拒绝解锁。
  AudioDeviceSafetyState confirmSessionFullScaleUnlock() {
    if (!isBackendMeterVerified) {
      return this;
    }
    return AudioDeviceSafetyState(
      deviceFingerprint: deviceFingerprint,
      isBackendMeterVerified: true,
      sessionFullScaleUnlocked: true,
    );
  }
}

/// 音频输出路由与防炸耳滤镜链最终编译计划。
class AudioSafetyChainPlan {
  /// 创建音频安全链路计划。
  const AudioSafetyChainPlan({
    required this.routeMode,
    required this.gaplessAudioMode,
    required this.prefetchPlaylist,
    required this.audioFilterString,
    required this.audioSpdifCodecs,
    required this.safetyLimiterEngaged,
    required this.microFadeInDurationMs,
    this.fullScaleLockNotice,
  });

  /// 实际生效的输出路由模式。
  final AudioOutputRouteMode routeMode;

  /// 传递给 `libmpv` 的 `gapless-audio` 策略（统一采用 `weak`，同格式采样级无缝且跨采样率允许时钟重握手）。
  final String gaplessAudioMode;

  /// 是否启用 `prefetch-playlist=yes` 后台预缓冲下一曲。
  final bool prefetchPlaylist;

  /// 传递给 `libmpv` `af` 的完整滤镜链（比特流直通模式强制清空）。
  final String audioFilterString;

  /// 传递给 `libmpv` `audio-spdif` 的透传编解码清单（非 HDMI 直通时为空）。
  final String audioSpdifCodecs;

  /// 末级 `-12 dBFS` 安全限幅器是否已生效。
  final bool safetyLimiterEngaged;

  /// 启播/恢复/Seek 时应用的 S 型微淡入斜坡时长（毫秒，直通模式为 0）。
  final int microFadeInDurationMs;

  /// 若满幅直通档位因未获物理硬件电平仪实证而被默认锁定，则给出明确中文说明。
  final String? fullScaleLockNotice;
}

/// 发烧级无损音频路由、末级 `-12 dBFS` 防炸耳上限与 S 型微淡入斜坡策略引擎（纯领域算法）。
class AudiophileSafetyPolicy {
  AudiophileSafetyPolicy._();

  /// 非逐位直通路径末级安全限幅上限（`-12 dBFS`）。
  static const double safetyCeilingDbfs = -12.0;

  /// `-12 dBFS` 对应的线性幅值上限（`10^(-12/20) ≈ 0.2511886`）。
  static const double safetyCeilingLinear = 0.251;

  /// 非直通路径启播、恢复与跳转默认施加的 S 型微淡入时长（150 ms，位于 120~200 ms 区间）。
  static const int defaultMicroFadeInMs = 150;

  /// 微淡入允许配置的最短与最长边界（毫秒）。
  static const int minMicroFadeInMs = 120;
  static const int maxMicroFadeInMs = 200;

  /// 统一无损分轨队列无缝模式：同格式采样级无缝，逐位跨采样率允许硬件时钟重握手。
  static const String unifiedGaplessMode = 'weak';

  /// HDMI `audio-spdif` 源码透传编解码白名单（与软件 DSP 严格互斥）。
  static const String defaultSpdifCodecs = 'ac3,eac3,dts,dts-hd,truehd';

  /// 末级防炸耳安全限幅滤镜表达式（强制排在所有正向增益 DSP 之后）。
  static const String postDspSafetyLimiterFilter =
      'lavfi=[alimiter=limit=0.251:attack=2:release=50:level=disabled]';

  /// 未获 P4 物理硬件电平仪实证时的满幅旁路默认锁定提示。
  static const String unverifiedFullScaleLockReason =
      '当前音频后端尚未完成物理硬件电平仪实证，满幅旁路档位默认锁定关闭，持续启用 -12 dBFS 末级安全上限';

  /// 计算 S 型微淡入余弦斜坡增益系数（范围 `[0.0, 1.0]`，起止一阶导数均为 0，消除直流台阶爆音）。
  static double sCurveFadeGain({
    required double elapsedMs,
    int durationMs = defaultMicroFadeInMs,
  }) {
    final safeDur = durationMs.clamp(minMicroFadeInMs, maxMicroFadeInMs);
    if (elapsedMs <= 0.0) return 0.0;
    if (elapsedMs >= safeDur) return 1.0;
    final t = elapsedMs / safeDur;
    return 0.5 - 0.5 * math.cos(math.pi * t);
  }

  /// 编译音频输出路由与防炸耳末级滤镜链计划。
  ///
  /// 规则铁律：
  /// 1. HDMI `audio-spdif` 与任何软件 DSP 严格互斥（直通启用时强制清空 `af`）；
  /// 2. 逐位独占直通模式仅在硬件实证且当次会话显式解锁时允许满幅旁路；否则维持末级 `-12 dBFS` 限幅；
  /// 3. 非直通路径中，末级 `-12 dBFS` 安全限幅器必须位于一切用户正向增益 DSP 之后。
  static AudioSafetyChainPlan buildPlan({
    required AudioOutputRouteMode requestedMode,
    required AudioDeviceSafetyState safetyState,
    List<String> upstreamDspFilters = const [],
    int microFadeInMs = defaultMicroFadeInMs,
  }) {
    final clampedFadeMs = microFadeInMs.clamp(
      minMicroFadeInMs,
      maxMicroFadeInMs,
    );

    // 1. 比特流源码透传：与软件 DSP 严格互斥，严禁串联任何重采样或软滤镜。
    if (requestedMode == AudioOutputRouteMode.bitstreamPassthrough) {
      return const AudioSafetyChainPlan(
        routeMode: AudioOutputRouteMode.bitstreamPassthrough,
        gaplessAudioMode: unifiedGaplessMode,
        prefetchPlaylist: true,
        audioFilterString: '',
        audioSpdifCodecs: defaultSpdifCodecs,
        safetyLimiterEngaged: false,
        microFadeInDurationMs: 0,
      );
    }

    // 2. 逐位直通请求（桌面独占直通或 Android 14+ BIT_PERFECT）：
    //    仅当后端已通过物理硬件电平仪实证且当前外设本会话已显式确认解锁，方允许满幅零 DSP 直通；
    //    否则保持末级 -12 dBFS 安全上限并给出清晰待验锁定说明。
    final isBitPerfectRequested =
        requestedMode == AudioOutputRouteMode.exclusiveAudioOutput ||
        requestedMode == AudioOutputRouteMode.androidBitPerfectUsb;
    if (isBitPerfectRequested && safetyState.allowFullScaleBypass) {
      return AudioSafetyChainPlan(
        routeMode: requestedMode,
        gaplessAudioMode: unifiedGaplessMode,
        prefetchPlaylist: true,
        audioFilterString: '',
        audioSpdifCodecs: '',
        safetyLimiterEngaged: false,
        microFadeInDurationMs: 0,
      );
    }

    // 3. 非直通或未解锁满幅路径：一切正增益用户 DSP 在前，-12 dBFS 安全上限稳居最末级。
    final cleanUpstream = upstreamDspFilters
        .map((f) => f.trim())
        .where((f) => f.isNotEmpty)
        .toList();
    final filterChain = <String>[
      ...cleanUpstream,
      postDspSafetyLimiterFilter,
    ].join(',');

    final lockNotice = !safetyState.isBackendMeterVerified
        ? unverifiedFullScaleLockReason
        : (isBitPerfectRequested ? '新接入外设默认以 -12 dBFS 安全衰减起步，确认后可解锁本次会话满幅直通' : null);

    return AudioSafetyChainPlan(
      routeMode: requestedMode,
      gaplessAudioMode: unifiedGaplessMode,
      prefetchPlaylist: true,
      audioFilterString: filterChain,
      audioSpdifCodecs: '',
      safetyLimiterEngaged: true,
      microFadeInDurationMs: clampedFadeMs,
      fullScaleLockNotice: lockNotice,
    );
  }
}
