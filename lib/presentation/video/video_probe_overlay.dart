import 'dart:ui';

import 'package:flutter/material.dart';

import '../../domain/playback/playback_formatters.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../theme/konata_playback_tokens.dart';

/// 播放器左上角实时音画技术探针浮层（Tab 键或顶栏按钮开关，展示 40+ 项核心指标）。
class VideoProbeOverlay extends StatelessWidget {
  /// 创建实时技术探针浮层。
  const VideoProbeOverlay({
    super.key,
    required this.stats,
    this.adapterName = '',
    this.renderBackend = '',
  });

  /// 采集到的实时遥测快照。
  final PlaybackProbeStats stats;

  /// DXGI 显卡适配器或平台后端说明。
  final String adapterName;

  /// 当前实际渲染后端（`d3d11` / `sw` / `gpu`）。
  final String renderBackend;

  @override
  Widget build(BuildContext context) {
    final backendLabel = renderBackend.isNotEmpty
        ? renderBackend.toUpperCase()
        : (stats.gpuApi.isNotEmpty ? stats.gpuApi.toUpperCase() : 'LIBMPV');
    final resSource = (stats.videoWidth != null && stats.videoHeight != null)
        ? '${stats.videoWidth}×${stats.videoHeight}'
        : '-';
    final resTarget = (stats.targetWidth != null && stats.targetHeight != null)
        ? '${stats.targetWidth}×${stats.targetHeight}'
        : '-';
    final bitDepth = PlaybackFormatters.formatVideoBitDepthLabel(
      stats.videoPixelFormat,
    );
    final fpsLine = [
      if (stats.containerFps != null)
        '源 ${stats.containerFps!.toStringAsFixed(3)}',
      if (stats.estimatedVfFps != null)
        '滤镜 ${stats.estimatedVfFps!.toStringAsFixed(2)}',
      if (stats.displayFps != null && stats.displayFps! > 0)
        '屏 ${stats.displayFps!.toStringAsFixed(2)}',
    ].join(' · ');

    final dropLine =
        '解码 ${stats.droppedFramesDecoder ?? 0} / VO ${stats.droppedFramesVo ?? 0} / 延迟 ${stats.delayedFrames ?? 0} / 错拍 ${stats.mistimedFrames ?? 0}';

    final colorLine = [
      if (stats.colorPrimaries.isNotEmpty) stats.colorPrimaries,
      if (stats.colorGamma.isNotEmpty) stats.colorGamma,
      if (stats.colorMatrix.isNotEmpty) stats.colorMatrix,
      if (stats.colorRange.isNotEmpty) stats.colorRange,
    ].join(' · ');

    final hdrLine = (stats.hdrPeakNits != null || stats.sigPeak != null)
        ? '${stats.hdrPeakNits?.round() ?? '-'} nits (sig ${stats.sigPeak?.toStringAsFixed(2) ?? '-'}) ${stats.toneMapping}'
        : (stats.toneMapping.isNotEmpty ? stats.toneMapping : 'SDR');

    final filterLine = [
      stats.scaleFilter.isNotEmpty ? stats.scaleFilter : 'default',
      stats.cscaleFilter.isNotEmpty ? stats.cscaleFilter : 'default',
      if (stats.debandEnabled) 'Deband 开',
      if (stats.ditherDepth.isNotEmpty) 'Dither ${stats.ditherDepth}',
    ].join(' · ');

    final audioSummary = PlaybackFormatters.formatAudioSpecSummary(
      codec: stats.audioCodec,
      sampleRateHz: stats.audioSampleRateHz,
      channelCount: stats.audioChannelCount,
      channelLayout: stats.audioChannelLayout,
      audioFormat: stats.audioFormat,
    );

    final cacheLine = [
      if (stats.demuxerCacheSeconds != null)
        '${stats.demuxerCacheSeconds!.toStringAsFixed(1)}s',
      PlaybackFormatters.formatCacheBytes(stats.demuxerCacheBytes),
      PlaybackFormatters.formatByteSpeed(stats.cacheSpeedBps),
      if (stats.cachePercent != null) '${stats.cachePercent}%',
    ].join(' · ');

    return IgnorePointer(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: KonataPlaybackTokens.osdSurfaceDark.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: KonataPlaybackTokens.osdBorderLight,
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.analytics_outlined,
                        size: 14,
                        color: KonataPlaybackTokens.osdAccent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '技术探针 · $backendLabel',
                        style: const TextStyle(
                          color: KonataPlaybackTokens.osdTextPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (adapterName.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            adapterName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: KonataPlaybackTokens.osdTextSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ProbeRow(
                    '引擎与前端',
                    '${stats.mpvVersion.isEmpty ? 'libmpv' : stats.mpvVersion} · ${stats.ffmpegVersion}',
                  ),
                  _ProbeRow(
                    '渲染与硬解',
                    'VO ${stats.voBackend.isEmpty ? '-' : stats.voBackend} · HW ${stats.hwdecCurrent.isEmpty ? 'no' : stats.hwdecCurrent}${stats.hwdecInterop.isNotEmpty ? ' (${stats.hwdecInterop})' : ''}',
                  ),
                  _ProbeRow(
                    '封装与编码',
                    '${stats.containerFormat.isEmpty ? '-' : stats.containerFormat} · ${PlaybackFormatters.formatCodecShortLabel(stats.videoCodec)} ${stats.videoProfile} ${bitDepth.isNotEmpty ? '· $bitDepth' : ''}',
                  ),
                  _ProbeRow(
                    '分辨率映射',
                    '$resSource -> $resTarget · ${PlaybackFormatters.formatBitrate(stats.videoBitrateBps)}',
                  ),
                  _ProbeRow(
                    '像素格式',
                    '${stats.videoPixelFormat.isEmpty ? '-' : stats.videoPixelFormat}${stats.videoHwPixelFormat.isNotEmpty ? ' (HW ${stats.videoHwPixelFormat})' : ''}',
                  ),
                  _ProbeRow('帧率 (FPS)', fpsLine.isEmpty ? '-' : fpsLine),
                  _ProbeRow(
                    'A-V 同步与丢帧',
                    '${stats.avSyncMs != null ? '${stats.avSyncMs!.toStringAsFixed(2)} ms' : '-'} · $dropLine',
                  ),
                  _ProbeRow('色彩管线', colorLine.isEmpty ? '-' : colorLine),
                  _ProbeRow('动态范围', hdrLine),
                  _ProbeRow('缩放与抖动', filterLine),
                  _ProbeRow(
                    '着色器链',
                    stats.activeShaderNames.isEmpty
                        ? '无激活 GLSL 着色器'
                        : stats.activeShaderNames.join(', '),
                  ),
                  _ProbeRow(
                    '音频规格',
                    '${audioSummary.isEmpty ? '-' : audioSummary} · ${PlaybackFormatters.formatBitrate(stats.audioBitrateBps)}',
                  ),
                  _ProbeRow(
                    '音频输出',
                    '${stats.audioOutBackend.isEmpty ? '-' : stats.audioOutBackend}${stats.audioExclusive ? ' (独占)' : ' (共享)'}',
                  ),
                  _ProbeRow(
                    '缓冲与进度',
                    '$cacheLine · 延迟 字幕 ${stats.subtitleDelaySeconds.toStringAsFixed(1)}s / 音 ${stats.audioDelaySeconds.toStringAsFixed(1)}s',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProbeRow extends StatelessWidget {
  const _ProbeRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(
                color: KonataPlaybackTokens.osdTextSecondary,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.trim().isEmpty ? '-' : value.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: KonataPlaybackTokens.osdTextPrimary,
                fontSize: 11,
                fontFeatures: KonataPlaybackTokens.tabularNumbers,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
