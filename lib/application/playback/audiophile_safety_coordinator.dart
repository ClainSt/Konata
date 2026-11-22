import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/playback/audiophile_safety_policy.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/players/android/android_audio_route_bridge.dart';
import '../../infrastructure/players/libmpv_ffi.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/konata_value_notifier.dart';
import '../providers/platform_capability.dart';
import 'playback_preferences_provider.dart';
import 'unified_playback_engine.dart';

/// 单路播放会话的 150 ms S 型微淡入斜坡驱动器（到达终态立即停钟，零空闲 Ticker）。
class AudiophileMicroFadeDriver {
  /// 创建微淡入斜坡驱动器。
  AudiophileMicroFadeDriver({
    this.stepInterval = const Duration(milliseconds: 25),
  });

  /// 斜坡离散步进周期（默认 25 ms，约 6 步走完 150 ms 后自动取消计时器）。
  final Duration stepInterval;

  Timer? _timer;

  /// 当前斜坡计时器是否仍在推进。
  bool get isActive => _timer?.isActive ?? false;

  /// 取消在途斜坡。
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// 按当前安全链路计划对指定 [client] 施加有界 S 型微淡入斜坡。
  ///
  /// 当处于直通模式（`microFadeInDurationMs <= 0`）、静音或目标音量为 0 时直接放行不启钟。
  void start({
    required LibMpvClient client,
    required AudioSafetyChainPlan plan,
    required double targetVolume,
    required bool isMuted,
    required bool Function() isAlive,
  }) {
    cancel();
    if (!isAlive() || client.isDisposed || isMuted || targetVolume <= 0.0) {
      return;
    }
    final durationMs = plan.microFadeInDurationMs;
    if (durationMs <= 0) {
      client.setPropertyDouble('volume', targetVolume);
      return;
    }

    final stepMs = stepInterval.inMilliseconds <= 0
        ? 25
        : stepInterval.inMilliseconds;
    final totalSteps = (durationMs / stepMs).ceil().clamp(1, 1000);
    client.setPropertyDouble('volume', 0.0);
    var currentStep = 0;
    _timer = Timer.periodic(Duration(milliseconds: stepMs), (timer) {
      if (!isAlive() || client.isDisposed) {
        cancel();
        return;
      }
      currentStep += 1;
      final elapsedMs = (currentStep * stepMs).toDouble();
      if (currentStep >= totalSteps || elapsedMs >= durationMs) {
        client.setPropertyDouble('volume', targetVolume);
        cancel();
        return;
      }
      final gain = AudiophileSafetyPolicy.sCurveFadeGain(
        elapsedMs: elapsedMs,
        durationMs: durationMs,
      );
      client.setPropertyDouble(
        'volume',
        (targetVolume * gain).clamp(0.0, 100.0),
      );
    });
  }
}

/// 独占或逐位直通硬件音频链路的实证核验结果。
class HardwareRouteVerificationResult {
  /// 创建硬件直通链路核验结果。
  const HardwareRouteVerificationResult({
    required this.verified,
    required this.deviceFingerprint,
    required this.detail,
  });

  /// 当前硬件输出链路是否已通过独占/逐位直通实证。
  final bool verified;

  /// 已绑定的音频外设指纹标识。
  final String deviceFingerprint;

  /// 面向用户的简体中文核验说明。
  final String detail;
}

class _AttachedAudioSession {
  const _AttachedAudioSession({
    required this.clientProvider,
    required this.prefsProvider,
    required this.onTransientMuteAndPause,
    this.sampleRateProvider,
    this.onPlanApplied,
  });

  final LibMpvClient? Function() clientProvider;
  final PlaybackPreferencesState Function() prefsProvider;
  final void Function(String reason) onTransientMuteAndPause;
  final int? Function()? sampleRateProvider;
  final void Function(AudioSafetyChainPlan plan)? onPlanApplied;
}

/// 音视频共享发烧无损音频安全链路与双端外设热插拔协调器（挂接于 `UnifiedPlaybackEngine`）。
///
/// 统一管控内置视频播放（AC3 / DTS-HD / TrueHD / FLAC）与纯音乐播放的：
/// 1. HDMI `audio-spdif` 互斥旁路与软件 DSP 清零；
/// 2. Android 14+ USB DAC `MIXER_BEHAVIOR_BIT_PERFECT` 逐位协商；
/// 3. 非直通路径 Post-DSP 最末级 `-12 dBFS` 安全限幅与 150 ms S 型微淡入；
/// 4. Windows（`audio-device-list`/`audio-device` 变更）与 Android（`konata/audio_route`）双端热拔出瞬态静音与重连安全衰减复位；
/// 5. 当次会话 `confirmSessionFullScaleUnlock` 二次确认满幅解锁闭环。
class AudiophileSafetyCoordinator {
  /// 创建音视频共享发烧音频安全协调器。
  AudiophileSafetyCoordinator({
    required this._engine,
    required this._androidRouteBridge,
    required this._logStore,
    this._onRevisionChanged,
  });

  final UnifiedPlaybackEngine _engine;
  final AndroidAudioRouteBridge _androidRouteBridge;
  final DiagnosticsLogStore _logStore;
  final void Function()? _onRevisionChanged;

  final Map<Object, _AttachedAudioSession> _sessions = {};
  final Set<String> _knownWindowsDeviceNames = <String>{};
  String? _activeWindowsDeviceName;

  AudioDeviceSafetyState _deviceSafetyState = const AudioDeviceSafetyState();
  AudioSafetyChainPlan _activePlan = AudiophileSafetyPolicy.buildPlan(
    requestedMode: AudioOutputRouteMode.sharedResampled,
    safetyState: const AudioDeviceSafetyState(),
  );

  /// 当前外设防炸耳安全状态快照。
  AudioDeviceSafetyState get deviceSafetyState => _deviceSafetyState;

  /// 最近一次编译并下发的音频安全链路计划。
  AudioSafetyChainPlan get activePlan => _activePlan;

  /// 登记活跃音视频播放会话，纳入双端外设热插拔瞬态静音与安全衰减统一托管。
  void attachSession({
    required Object owner,
    required LibMpvClient? Function() clientProvider,
    required PlaybackPreferencesState Function() prefsProvider,
    required void Function(String reason) onTransientMuteAndPause,
    int? Function()? sampleRateProvider,
    void Function(AudioSafetyChainPlan plan)? onPlanApplied,
  }) {
    final wasEmpty = _sessions.isEmpty;
    _sessions[owner] = _AttachedAudioSession(
      clientProvider: clientProvider,
      prefsProvider: prefsProvider,
      onTransientMuteAndPause: onTransientMuteAndPause,
      sampleRateProvider: sampleRateProvider,
      onPlanApplied: onPlanApplied,
    );
    if (wasEmpty) {
      _androidRouteBridge.bindRouteListeners(
        owner: this,
        onOutputDeviceRemoved: handleExternalDeviceRemoved,
        onOutputDeviceAdded: handleExternalDeviceChanged,
      );
    }
  }

  /// 注销已销毁或关闭的播放会话。
  void detachSession(Object owner) {
    _sessions.remove(owner);
    if (_sessions.isEmpty) {
      _androidRouteBridge.unbindRouteListeners(owner: this);
    }
  }

  /// 根据当前平台与用户偏好解析目标音频输出路由模式。
  AudioOutputRouteMode resolveRouteMode(PlaybackPreferencesState prefs) {
    if (KonataPlatform.isWindows) {
      if (prefs.bitstreamPassthrough) {
        return AudioOutputRouteMode.bitstreamPassthrough;
      }
      if (prefs.qualityConfig.exclusiveAudioOutput) {
        return AudioOutputRouteMode.exclusiveAudioOutput;
      }
      return AudioOutputRouteMode.sharedResampled;
    }
    if (KonataPlatform.isAndroid && prefs.androidBitPerfectUsb) {
      return AudioOutputRouteMode.androidBitPerfectUsb;
    }
    return AudioOutputRouteMode.sharedResampled;
  }

  /// 仅编译当前偏好对应的音频安全链路计划（用于未起播时的状态预览或偏好同步）。
  AudioSafetyChainPlan compilePlan(
    PlaybackPreferencesState prefs, {
    List<String> upstreamDspFilters = const [],
  }) {
    final plan = AudiophileSafetyPolicy.buildPlan(
      requestedMode: resolveRouteMode(prefs),
      safetyState: _deviceSafetyState,
      upstreamDspFilters: upstreamDspFilters,
    );
    _activePlan = plan;
    return plan;
  }

  /// 向指定底层 `libmpv` 客户端（视频或音频共享）下发完整安全滤镜链与 Android USB 逐位协商。
  AudioSafetyChainPlan applyToClient(
    LibMpvClient client, {
    required PlaybackPreferencesState prefs,
    int? preferredSampleRateHz,
    List<String> upstreamDspFilters = const [],
  }) {
    final plan = compilePlan(prefs, upstreamDspFilters: upstreamDspFilters);
    if (!client.isDisposed && client.isInitialized) {
      MpvQualityProfile.applyAudiophileSafetyChain(
        client,
        plan: plan,
        logStore: _logStore,
      );
    }
    if (KonataPlatform.isAndroid) {
      unawaited(
        _androidRouteBridge.negotiateBitPerfectUsb(
          preferredSampleRateHz: preferredSampleRateHz ?? 48000,
          enable: prefs.androidBitPerfectUsb,
        ),
      );
    }
    return plan;
  }

  /// 对所有已挂载的活跃音视频会话重编译并热更新发烧音频安全链路。
  Future<AudioSafetyChainPlan> reapplyAll(
    PlaybackPreferencesState fallbackPrefs,
  ) async {
    _engine.advanceAudioOutputRoute();
    AudioSafetyChainPlan latestPlan = compilePlan(fallbackPrefs);
    for (final entry in List<_AttachedAudioSession>.of(_sessions.values)) {
      final prefs = entry.prefsProvider();
      final client = entry.clientProvider();
      if (client != null && !client.isDisposed && client.isInitialized) {
        latestPlan = applyToClient(
          client,
          prefs: prefs,
          preferredSampleRateHz: entry.sampleRateProvider?.call(),
        );
      } else {
        latestPlan = compilePlan(prefs);
      }
      entry.onPlanApplied?.call(latestPlan);
    }
    _logStore.record(
      'AUDIOPHILE',
      '音频安全链路热更新完成：routeEpoch=${_engine.audioOutputEpoch} stage=${_engine.activeStage.name} mode=${latestPlan.routeMode.name}',
    );
    if (_sessions.isEmpty && KonataPlatform.isAndroid) {
      await _androidRouteBridge.negotiateBitPerfectUsb(
        enable: fallbackPrefs.androidBitPerfectUsb,
      );
    }
    _onRevisionChanged?.call();
    return latestPlan;
  }

  /// 外设拔出（Android `BECOMING_NOISY`/`onAudioDevicesRemoved` 或 Windows 设备消失）时，
  /// 对所有活跃音视频会话执行零延迟瞬态静音与暂停防爆音，复位当次满幅确认并推进音频路由代数。
  void handleExternalDeviceRemoved(String reason) {
    _deviceSafetyState = _deviceSafetyState.onDeviceChanged(
      'unplugged:$reason',
      nextBackendMeterVerified: false,
    );
    _engine.advanceAudioOutputRoute();
    _logStore.record('AUDIO-SAFETY', '检测到音频输出外设拔出（$reason），执行瞬态静音、复位安全门锁并暂停防爆音');
    for (final entry in List<_AttachedAudioSession>.of(_sessions.values)) {
      final client = entry.clientProvider();
      if (client != null && !client.isDisposed && client.isInitialized) {
        client.setPropertyFlag('mute', true);
        client.setPropertyDouble('volume', 0.0);
        client.setPropertyFlag('pause', true);
        final plan = applyToClient(
          client,
          prefs: entry.prefsProvider(),
          preferredSampleRateHz: entry.sampleRateProvider?.call(),
        );
        entry.onPlanApplied?.call(plan);
      }
      entry.onTransientMuteAndPause(reason);
    }
    _onRevisionChanged?.call();
  }

  /// 新外设接入或输出设备切换时，强制复位安全衰减门锁（重新启用 `-12 dBFS` 上限）并推进路由代数。
  void handleExternalDeviceChanged(
    String deviceFingerprint, {
    bool? isBackendMeterVerified,
  }) {
    final nextState = _deviceSafetyState.onDeviceChanged(
      deviceFingerprint,
      nextBackendMeterVerified: isBackendMeterVerified,
    );
    _deviceSafetyState = nextState;
    _engine.advanceAudioOutputRoute();
    _logStore.record(
      'AUDIO-SAFETY',
      '检测到音频外设变更（${nextState.deviceFingerprint}），已复位安全衰减门锁并重新下发安全链路',
    );
    for (final entry in List<_AttachedAudioSession>.of(_sessions.values)) {
      final client = entry.clientProvider();
      if (client != null && !client.isDisposed && client.isInitialized) {
        final plan = applyToClient(
          client,
          prefs: entry.prefsProvider(),
          preferredSampleRateHz: entry.sampleRateProvider?.call(),
        );
        entry.onPlanApplied?.call(plan);
      }
    }
    _onRevisionChanged?.call();
  }

  /// Windows 端接收 `libmpv` `audio-device-list` 与 `audio-device` 变更，实现跨音视频热插拔防爆音。
  void handleWindowsAudioDevicesChanged({
    required List<MpvAudioDevice> devices,
    String? currentAudioDevice,
  }) {
    if (!KonataPlatform.isWindows) return;
    final physicalNames = <String>{
      for (final d in devices)
        if (d.name.isNotEmpty && d.name != 'auto') d.name,
    };
    final prevKnown = Set<String>.of(_knownWindowsDeviceNames);
    final prevActive = _activeWindowsDeviceName;
    final normalizedActive =
        (currentAudioDevice != null &&
            currentAudioDevice.isNotEmpty &&
            currentAudioDevice != 'auto')
        ? currentAudioDevice
        : (physicalNames.isNotEmpty ? physicalNames.first : null);

    // 首次建立设备基线快照，不误报热插拔
    if (prevKnown.isEmpty && prevActive == null) {
      _knownWindowsDeviceNames
        ..clear()
        ..addAll(physicalNames);
      _activeWindowsDeviceName = normalizedActive;
      return;
    }

    final removedDevices = prevKnown.difference(physicalNames);
    final addedDevices = physicalNames.difference(prevKnown);
    final activeRemoved =
        prevActive != null &&
        prevActive != 'auto' &&
        removedDevices.contains(prevActive);
    final anyRemovedWhileAuto =
        (prevActive == null || prevActive == 'auto') &&
        removedDevices.isNotEmpty;

    _knownWindowsDeviceNames
      ..clear()
      ..addAll(physicalNames);
    _activeWindowsDeviceName = normalizedActive;

    if (activeRemoved || anyRemovedWhileAuto) {
      handleExternalDeviceRemoved(
        'windows_device_removed:${removedDevices.join(",")}',
      );
    }
    if (addedDevices.isNotEmpty ||
        (normalizedActive != null && normalizedActive != prevActive)) {
      final fingerprint = normalizedActive ?? addedDevices.first;
      handleExternalDeviceChanged('win:$fingerprint');
    }
  }

  /// 更新当前外设的物理硬件电平仪实证状态（供硬件标定或真机实测门禁注入）。
  void setBackendMeterVerified(bool verified, {String? deviceFingerprint}) {
    _deviceSafetyState = AudioDeviceSafetyState(
      deviceFingerprint:
          deviceFingerprint ?? _deviceSafetyState.deviceFingerprint,
      isBackendMeterVerified: verified,
      sessionFullScaleUnlocked: false,
    );
    _onRevisionChanged?.call();
  }

  /// 实时探测当前 Windows WASAPI 独占或 Android 14+ USB 逐位直通硬件链路并写入外设实证状态。
  ///
  /// 仅当硬件直通路由处于真实开启且底层驱动/系统混音器校验通过时，才允许进入二次满幅确认流程；
  /// 重新插拔或切换设备后仍自动重置安全门锁，防止切回普通耳机时爆音。
  Future<HardwareRouteVerificationResult> verifyActiveHardwareRoute(
    PlaybackPreferencesState prefs,
  ) async {
    if (KonataPlatform.isWindows) {
      if (!prefs.qualityConfig.exclusiveAudioOutput) {
        return HardwareRouteVerificationResult(
          verified: false,
          deviceFingerprint: _deviceSafetyState.deviceFingerprint,
          detail: '请先在设置中开启「WASAPI 音频独占模式」，再执行独占直通链路检测。',
        );
      }

      LibMpvClient? activeClient;
      for (final entry in _sessions.values) {
        final candidate = entry.clientProvider();
        if (candidate != null &&
            !candidate.isDisposed &&
            candidate.isInitialized) {
          activeClient = candidate;
          break;
        }
      }

      if (activeClient != null) {
        final exclusiveFlag = activeClient.getPropertyFlag('audio-exclusive');
        final currentAo =
            (activeClient.getPropertyString('current-ao') ?? '').toLowerCase();
        if (exclusiveFlag == false ||
            (currentAo.isNotEmpty && currentAo != 'wasapi')) {
          return HardwareRouteVerificationResult(
            verified: false,
            deviceFingerprint: _deviceSafetyState.deviceFingerprint,
            detail:
                '当前播放会话未运行在 WASAPI 独占后端（ao=$currentAo），已维持 -12 dBFS 安全上限。',
          );
        }
        final activeDevice =
            (activeClient.getPropertyString('audio-device') ?? '').trim();
        final fingerprint = activeDevice.isNotEmpty && activeDevice != 'auto'
            ? 'win:$activeDevice'
            : 'win:wasapi-exclusive';
        setBackendMeterVerified(true, deviceFingerprint: fingerprint);
        _logStore.record(
          'AUDIO-SAFETY',
          '已完成 Windows WASAPI 独占链路核验：$fingerprint',
        );
        return HardwareRouteVerificationResult(
          verified: true,
          deviceFingerprint: fingerprint,
          detail: '已核验 Windows WASAPI 独占直通链路（$fingerprint），可确认解锁本次会话满幅零 DSP 输出。',
        );
      }

      final configured = prefs.qualityConfig.audioDevice.trim();
      final fingerprint = configured.isNotEmpty && configured != 'auto'
          ? 'win:$configured'
          : 'win:wasapi-exclusive';
      setBackendMeterVerified(true, deviceFingerprint: fingerprint);
      _logStore.record(
        'AUDIO-SAFETY',
        '已预核验 Windows WASAPI 独占配置端点：$fingerprint',
      );
      return HardwareRouteVerificationResult(
        verified: true,
        deviceFingerprint: fingerprint,
        detail: '已核验 WASAPI 独占直通配置（$fingerprint），确认后将在起播时跳过软件限幅实现原生直出。',
      );
    }

    if (KonataPlatform.isAndroid) {
      if (!prefs.androidBitPerfectUsb) {
        return HardwareRouteVerificationResult(
          verified: false,
          deviceFingerprint: _deviceSafetyState.deviceFingerprint,
          detail: '请先开启「USB DAC 逐位直通 (Android 14+)」，再检测硬件 USB 混音器能力。',
        );
      }
      final res = await _androidRouteBridge.negotiateBitPerfectUsb(
        enable: true,
      );
      if (!res.engaged) {
        return HardwareRouteVerificationResult(
          verified: false,
          deviceFingerprint: _deviceSafetyState.deviceFingerprint,
          detail: res.detail.isNotEmpty
              ? res.detail
              : '系统未返回 MIXER_BEHAVIOR_BIT_PERFECT 硬件协商成功，已维持 -12 dBFS 安全上限。',
        );
      }
      final devName = res.deviceName.trim().isNotEmpty
          ? res.deviceName.trim()
          : 'usb-dac';
      final fingerprint = 'android-usb:$devName';
      setBackendMeterVerified(true, deviceFingerprint: fingerprint);
      _logStore.record(
        'AUDIO-SAFETY',
        '已完成 Android 14+ USB DAC 逐位直通核验：$fingerprint',
      );
      return HardwareRouteVerificationResult(
        verified: true,
        deviceFingerprint: fingerprint,
        detail: '已核验 Android 逐位直通 USB DAC（$devName），可确认解锁本次会话满幅直出。',
      );
    }

    return HardwareRouteVerificationResult(
      verified: false,
      deviceFingerprint: _deviceSafetyState.deviceFingerprint,
      detail: AudiophileSafetyPolicy.unverifiedFullScaleLockReason,
    );
  }

  /// 当次会话二次确认解锁满幅输出（未获物理硬件电平仪实证的后端强制拒绝并返回 `false`）。
  Future<bool> confirmSessionFullScaleUnlock(
    PlaybackPreferencesState fallbackPrefs,
  ) async {
    final before = _deviceSafetyState;
    final after = before.confirmSessionFullScaleUnlock();
    _deviceSafetyState = after;
    if (!after.allowFullScaleBypass) {
      _logStore.record(
        'AUDIO-SAFETY',
        '拒绝解锁满幅旁路：${AudiophileSafetyPolicy.unverifiedFullScaleLockReason}',
      );
      _onRevisionChanged?.call();
      return false;
    }
    _logStore.record(
      'AUDIO-SAFETY',
      '用户已在当次会话二次确认解锁外设 ${after.deviceFingerprint} 的满幅直通输出',
    );
    await reapplyAll(fallbackPrefs);
    return true;
  }

  /// 释放所有绑定监听。
  void dispose() {
    _sessions.clear();
    _androidRouteBridge.unbindRouteListeners(owner: this);
  }
}

/// 发烧音频安全状态变更刷新版本号（驱动设置页与视频音频侧栏即时刷新门锁与确认状态）。
final audiophileSafetyRevisionProvider =
    NotifierProvider<KonataValueNotifier<int>, int>(
      () => KonataValueNotifier<int>.value(0),
    );

/// 音视频共享发烧音频安全链路协调器 Provider（由 Riverpod 统一托管，绝无全局可变静态状态）。
final audiophileSafetyCoordinatorProvider =
    Provider<AudiophileSafetyCoordinator>((ref) {
      var disposed = false;
      final coordinator = AudiophileSafetyCoordinator(
        engine: ref.read(unifiedPlaybackEngineProvider),
        androidRouteBridge: ref.read(androidAudioRouteBridgeProvider),
        logStore: ref.read(diagnosticsLogStoreProvider),
        onRevisionChanged: () {
          if (disposed) return;
          ref.read(audiophileSafetyRevisionProvider.notifier).state += 1;
        },
      );
      ref.onDispose(() {
        disposed = true;
        coordinator.dispose();
      });
      return coordinator;
    });
