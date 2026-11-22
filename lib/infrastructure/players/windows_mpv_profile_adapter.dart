import 'libmpv_ffi.dart';
import 'mpv_quality_profile.dart';

/// Windows 桌面专属 `libmpv` 音画参数适配器（集中收口 D3D11 / DirectComposition / WASAPI 驱动符号，绝不进入 Android 入口）。
class WindowsMpvProfileDelegate implements MpvPlatformProfileDelegate {
  /// 创建 Windows 桌面参数适配器。
  const WindowsMpvProfileDelegate();

  @override
  String get desktopVideoDriver => 'libmpv';

  @override
  String get desktopGpuNextDriver => 'gpu-next';

  @override
  String get desktopAudioDriver => 'wasapi';

  @override
  String get desktopHwdecValue => 'd3d11va,d3d11va-copy,auto-safe';

  @override
  String normalizeLegacyOutputModeKey(String raw) {
    return switch (raw) {
      'dcomp_10bit' => VideoOutputPipelineMode.layered10Bit.bridgeKey,
      'dcomp_fp16' => VideoOutputPipelineMode.layeredFp16.bridgeKey,
      'd3d11_fp16' ||
      'd3d11Fp16' ||
      'd3d11_10bit' ||
      'd3d1110Bit' => VideoOutputPipelineMode.legacyTextureFallback.bridgeKey,
      _ => raw,
    };
  }

  @override
  Map<Object?, Object?> normalizeLegacyPreferenceMap(
    Map<Object?, Object?> raw,
  ) {
    final normalized = Map<Object?, Object?>.from(raw);
    if (normalized['defaultVideoEngine'] == 'externalPlayer') {
      normalized['defaultVideoEngine'] = 'desktopRelay';
    }
    if (normalized['defaultAudioEngine'] == 'externalPlayer') {
      normalized['defaultAudioEngine'] = 'desktopRelay';
    }
    if (!normalized.containsKey('preferredRelayKindKey') &&
        normalized.containsKey('preferredExternalVideoKind')) {
      normalized['preferredRelayKindKey'] =
          normalized['preferredExternalVideoKind'];
    }
    if (!normalized.containsKey('bitstreamPassthrough') &&
        normalized.containsKey('hdmiSpdifPassthrough')) {
      normalized['bitstreamPassthrough'] = normalized['hdmiSpdifPassthrough'];
    }
    if (!normalized.containsKey('exclusiveAudioOutput') &&
        normalized.containsKey('wasapiExclusive')) {
      normalized['exclusiveAudioOutput'] = normalized['wasapiExclusive'];
    }
    if (!normalized.containsKey('outputPipelineMode')) {
      final legacyMode =
          normalized['desktopOutputMode'] ?? normalized['windowsRenderBackend'];
      if (legacyMode != null) {
        normalized['outputPipelineMode'] = legacyMode;
      }
    }
    return normalized;
  }

  @override
  bool isDesktopHardwareDecodeWarning(String lowerCaseMessage) {
    return lowerCaseMessage.contains('d3d11va') ||
        lowerCaseMessage.contains('dxva2') ||
        lowerCaseMessage.contains('failed to create direct3d');
  }

  @override
  void applyDesktopVideoPreInitOptions(
    LibMpvClient client,
    MpvSafePropertySetter setter, {
    required PlaybackQualityConfig config,
    int? desktopUnderlayHwnd,
  }) {
    final useGpuNext =
        config.outputPipelineMode == VideoOutputPipelineMode.gpuNextUnderlay &&
        config.hardwareDecode &&
        config.preset != VideoQualityPreset.softwareFallback;
    if (useGpuNext) {
      if (desktopUnderlayHwnd != null && desktopUnderlayHwnd > 0) {
        setter.setOption(client, 'wid', '$desktopUnderlayHwnd');
      }
      setter.setOption(client, 'vo', desktopGpuNextDriver);
      setter.setOption(client, 'gpu-api', 'd3d11');
      setter.setOption(client, 'gpu-context', 'd3d11');
      setter.setOption(client, 'd3d11-output-format', 'rgb10_a2');
      setter.setOption(client, 'd3d11-flip', 'yes');
      setter.setOption(client, 'target-colorspace-hint', 'auto');
      setter.setOption(client, 'keepaspect', 'yes');
      setter.setOption(client, 'background-color', '#000000');
    } else {
      setter.setOption(client, 'vo', desktopVideoDriver);
      setter.setOption(client, 'gpu-api', 'd3d11');
      setter.setOption(client, 'target-colorspace-hint', 'auto');
    }
    final useFp16Fbo =
        useGpuNext ||
        config.outputPipelineMode == VideoOutputPipelineMode.layeredFp16;
    setter.setOption(client, 'fbo-format', useFp16Fbo ? 'rgba16hf' : 'rgb10_a2');
  }

  @override
  void applyDesktopAudioExclusivePreInit(
    LibMpvClient client,
    MpvSafePropertySetter setter,
    PlaybackQualityConfig config,
  ) {
    if (config.exclusiveAudioOutput) {
      setter.setOption(client, 'audio-exclusive', 'yes');
      // 独占模式显式保持源采样率与原生位深直出，杜绝意外强制软件重采样。
      setter.setOption(client, 'audio-samplerate', '0');
      setter.setOption(client, 'audio-format', 'no');
    }
  }

  @override
  void applyDesktopAudioExclusivePostInit(
    LibMpvClient client,
    MpvSafePropertySetter setter,
    PlaybackQualityConfig config, {
    void Function(String message)? onNotice,
  }) {
    if (!config.exclusiveAudioOutput) return;
    final ok = setter.setBool(client, 'audio-exclusive', true);
    if (!ok) {
      setter.setBool(client, 'audio-exclusive', false);
      onNotice?.call('WASAPI 独占模式初始化受限，已自动回退至共享混音输出');
    }
  }

  @override
  void applyDesktopAudioExclusiveLive(
    LibMpvClient client,
    MpvSafePropertySetter setter,
    PlaybackQualityConfig config, {
    void Function(String message)? onNotice,
  }) {
    final exclusiveOk = setter.setBool(
      client,
      'audio-exclusive',
      config.exclusiveAudioOutput,
    );
    if (config.exclusiveAudioOutput && exclusiveOk) {
      setter.setInt(client, 'audio-samplerate', 0);
      setter.setString(client, 'audio-format', 'no');
    } else if (config.exclusiveAudioOutput && !exclusiveOk) {
      setter.setBool(client, 'audio-exclusive', false);
      onNotice?.call('当前音频设备不支持 WASAPI 独占模式，已自动切回共享模式');
    }
  }
}
