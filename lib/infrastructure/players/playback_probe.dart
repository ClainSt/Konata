import '../../domain/playback/playback_probe_stats.dart';
import 'libmpv_ffi.dart';

/// libmpv 实时音画与缓存遥测采集器（60+ 属性采集至强类型 [PlaybackProbeStats]）。
class PlaybackProbeCollector {
  const PlaybackProbeCollector();

  /// 轻量采集顶栏角标与画幅比所需的 5 项核心属性（探针面板关闭时替代全量 65+ 项 FFI 读取）。
  PlaybackProbeStats collectLight(
    LibMpvClient client, {
    String gpuApiOverride = '',
    String? mpvVersionCache,
    String? ffmpegVersionCache,
    PlaybackProbeStats? previous,
  }) {
    if (client.isDisposed || !client.isInitialized) {
      return previous ?? const PlaybackProbeStats();
    }
    final width = client.getPropertyInt64('video-params/w');
    final height = client.getPropertyInt64('video-params/h');
    final codec =
        client.getPropertyString('video-codec') ??
        (client.getPropertyString('video-format') ?? '');
    final pixFmt = client.getPropertyString('video-params/pixelformat') ?? '';
    final hwdec = client.getPropertyString('hwdec-current') ?? 'no';
    return PlaybackProbeStats(
      mpvVersion: mpvVersionCache ?? (previous?.mpvVersion ?? ''),
      ffmpegVersion: ffmpegVersionCache ?? (previous?.ffmpegVersion ?? ''),
      gpuApi: gpuApiOverride.isNotEmpty
          ? gpuApiOverride
          : (previous?.gpuApi ?? ''),
      hwdecCurrent: hwdec,
      videoCodec: codec,
      videoPixelFormat: pixFmt,
      videoWidth: width,
      videoHeight: height,
    );
  }

  /// 从活跃的 [LibMpvClient] 采集当前瞬时遥测指标。
  PlaybackProbeStats collect(
    LibMpvClient client, {
    String gpuApiOverride = '',
    String? mpvVersionCache,
    String? ffmpegVersionCache,
  }) {
    if (client.isDisposed || !client.isInitialized) {
      return const PlaybackProbeStats();
    }

    final rawPos = client.getPropertyDouble('time-pos') ?? 0.0;
    final rawDuration = client.getPropertyDouble('duration') ?? 0.0;
    final shadersRaw = client.getPropertyString('glsl-shaders') ?? '';
    final shaderNames = shadersRaw
        .split(RegExp(r'[;:]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => s.replaceAll('\\', '/').split('/').last)
        .toList();

    final avSyncSeconds = client.getPropertyDouble('avsync');
    final chapterIdx = client.getPropertyInt64('chapter');
    final chapterCount = client.getPropertyInt64('chapters') ?? 0;

    return PlaybackProbeStats(
      mpvVersion:
          mpvVersionCache ?? (client.getPropertyString('mpv-version') ?? ''),
      ffmpegVersion:
          ffmpegVersionCache ??
          (client.getPropertyString('ffmpeg-version') ?? ''),
      voBackend: client.getPropertyString('current-vo') ?? '',
      hwdecCurrent: client.getPropertyString('hwdec-current') ?? 'no',
      hwdecInterop: client.getPropertyString('hwdec-interop') ?? '',
      gpuApi: gpuApiOverride.isNotEmpty
          ? gpuApiOverride
          : (client.getPropertyString('gpu-api') ?? ''),
      videoCodec:
          client.getPropertyString('video-codec') ??
          (client.getPropertyString('video-format') ?? ''),
      videoProfile:
          client.getPropertyString('current-tracks/video/codec-profile') ??
          client.getPropertyString('video-params/profile') ??
          '',
      videoPixelFormat:
          client.getPropertyString('video-params/pixelformat') ?? '',
      videoHwPixelFormat:
          client.getPropertyString('video-params/hw-pixelformat') ?? '',
      videoBitrateBps: client.getPropertyInt64('video-bitrate'),
      containerFormat: client.getPropertyString('file-format') ?? '',
      videoWidth: client.getPropertyInt64('video-params/w'),
      videoHeight: client.getPropertyInt64('video-params/h'),
      displayWidth: client.getPropertyInt64('video-params/dw'),
      displayHeight: client.getPropertyInt64('video-params/dh'),
      targetWidth: client.getPropertyInt64('osd-width'),
      targetHeight: client.getPropertyInt64('osd-height'),
      pixelAspect: client.getPropertyDouble('video-params/aspect'),
      rotationDegrees: client.getPropertyInt64('video-params/rotate'),
      containerFps: client.getPropertyDouble('container-fps'),
      estimatedVfFps: client.getPropertyDouble('estimated-vf-fps'),
      displayFps: client.getPropertyDouble('display-fps'),
      avSyncMs: avSyncSeconds == null ? null : avSyncSeconds * 1000.0,
      droppedFramesDecoder: client.getPropertyInt64('decoder-frame-drop-count'),
      droppedFramesVo: client.getPropertyInt64('frame-drop-count'),
      delayedFrames: client.getPropertyInt64('vo-delayed-frame-count'),
      mistimedFrames: client.getPropertyInt64('mistimed-frame-count'),
      colorPrimaries: client.getPropertyString('video-params/primaries') ?? '',
      colorGamma: client.getPropertyString('video-params/gamma') ?? '',
      colorMatrix: client.getPropertyString('video-params/colormatrix') ?? '',
      colorRange: client.getPropertyString('video-params/colorlevels') ?? '',
      colorLevels: client.getPropertyString('video-params/colorlevels') ?? '',
      hdrPeakNits: _estimateHdrNits(client),
      sigPeak: client.getPropertyDouble('video-params/sig-peak'),
      toneMapping: client.getPropertyString('tone-mapping') ?? '',
      debandEnabled: client.getPropertyFlag('deband') ?? false,
      scaleFilter: client.getPropertyString('scale') ?? '',
      cscaleFilter: client.getPropertyString('cscale') ?? '',
      dscaleFilter: client.getPropertyString('dscale') ?? '',
      ditherDepth: client.getPropertyString('dither-depth') ?? '',
      activeShaderNames: shaderNames,
      audioCodec:
          client.getPropertyString('audio-codec-name') ??
          (client.getPropertyString('audio-codec') ?? ''),
      audioSampleRateHz: client.getPropertyInt64('audio-params/samplerate'),
      audioChannelCount: client.getPropertyInt64('audio-params/channel-count'),
      audioChannelLayout: client.getPropertyString('audio-params/channels') ?? '',
      audioBitrateBps: client.getPropertyInt64('audio-bitrate'),
      audioFormat: client.getPropertyString('audio-params/format') ?? '',
      audioOutBackend: client.getPropertyString('current-ao') ?? '',
      audioDeviceName: client.getPropertyString('audio-device') ?? '',
      audioExclusive: client.getPropertyFlag('audio-exclusive') ?? false,
      demuxerCacheSeconds: client.getPropertyDouble('demuxer-cache-duration'),
      demuxerCacheBytes:
          client.getPropertyInt64('demuxer-cache-state/fw-bytes') ??
          client.getPropertyInt64('demuxer-cache-state/total-bytes'),
      cacheSpeedBps: client.getPropertyInt64('cache-speed'),
      cachePercent: client.getPropertyInt64('cache-buffering-state'),
      pausedForCache: client.getPropertyFlag('paused-for-cache') ?? false,
      isSeeking: client.getPropertyFlag('seeking') ?? false,
      positionSeconds: PlaybackProbeStats.clampChapterZeroPts(rawPos),
      durationSeconds: rawDuration.isFinite && rawDuration > 0
          ? rawDuration
          : 0.0,
      speed: client.getPropertyDouble('speed') ?? 1.0,
      chapterIndex: chapterIdx,
      chapterCount: chapterCount,
      subtitleDelaySeconds: client.getPropertyDouble('sub-delay') ?? 0.0,
      audioDelaySeconds: client.getPropertyDouble('audio-delay') ?? 0.0,
    );
  }

  static double? _estimateHdrNits(LibMpvClient client) {
    final maxCll = client.getPropertyDouble('video-params/max-cll');
    if (maxCll != null && maxCll > 0) return maxCll;
    final sigPeak = client.getPropertyDouble('video-params/sig-peak');
    if (sigPeak != null && sigPeak > 1.0) {
      return sigPeak * 203.0;
    }
    return null;
  }
}
