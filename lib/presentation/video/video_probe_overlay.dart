import 'package:flutter/material.dart';

import '../../domain/playback/playback_formatters.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/playback/konata_osd_stroked_text.dart';

/// 播放器左上角原生 `mpv` 纯文字描边技术探针浮层（Tab 键或顶栏按钮开关，展示 40+ 项核心指标）。
///
/// 全程无背景框、无圆角边框、无模糊遮罩，并通过 [IgnorePointer] 让鼠标点击、双击与滚轮事件 100% 穿透至视频画布。
class VideoProbeOverlay extends StatelessWidget {
  /// 创建纯文字描边实时技术探针浮层。
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

    final engineHead = [
      stats.mpvVersion.isEmpty ? 'libmpv' : stats.mpvVersion,
      if (stats.ffmpegVersion.isNotEmpty) stats.ffmpegVersion,
    ].join(' · ');
    final hwLabel =
        'VO ${stats.voBackend.isEmpty ? '-' : stats.voBackend} · HW ${stats.hwdecCurrent.isEmpty ? 'no' : stats.hwdecCurrent}${stats.hwdecInterop.isNotEmpty ? ' (${stats.hwdecInterop})' : ''}';
    final codecLabel =
        '${stats.containerFormat.isEmpty ? '-' : stats.containerFormat} · ${PlaybackFormatters.formatCodecShortLabel(stats.videoCodec)} ${stats.videoProfile}${bitDepth.isNotEmpty ? ' · $bitDepth' : ''}'
            .trim();

    return IgnorePointer(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            KonataOsdStrokedText(
              'Player · $backendLabel${adapterName.isNotEmpty ? ' · $adapterName' : ''}',
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: KonataPlaybackTokens.osdProbeValueColor,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            const _ProbeSectionHeader('File / System'),
            _ProbeIndentedRow('引擎', engineHead),
            _ProbeIndentedRow('硬解与输出', hwLabel),
            _ProbeIndentedRow('封装与编码', codecLabel),
            const SizedBox(height: 3),
            const _ProbeSectionHeader('Video'),
            _ProbeIndentedRow(
              '分辨率',
              '$resSource -> $resTarget · ${PlaybackFormatters.formatBitrate(stats.videoBitrateBps)}',
            ),
            _ProbeIndentedRow(
              '像素格式',
              '${stats.videoPixelFormat.isEmpty ? '-' : stats.videoPixelFormat}${stats.videoHwPixelFormat.isNotEmpty ? ' (HW ${stats.videoHwPixelFormat})' : ''}',
            ),
            _ProbeIndentedRow('帧率 (FPS)', fpsLine.isEmpty ? '-' : fpsLine),
            _ProbeIndentedRow(
              '同步与丢帧',
              '${stats.avSyncMs != null ? '${stats.avSyncMs!.toStringAsFixed(2)} ms' : '-'} · $dropLine',
            ),
            _ProbeIndentedRow('色彩管线', colorLine.isEmpty ? '-' : colorLine),
            _ProbeIndentedRow('动态范围', hdrLine),
            _ProbeIndentedRow('缩放与抖动', filterLine),
            _ProbeIndentedRow(
              '着色器链',
              stats.activeShaderNames.isEmpty
                  ? '无激活 GLSL 着色器'
                  : stats.activeShaderNames.join(', '),
            ),
            const SizedBox(height: 3),
            const _ProbeSectionHeader('Audio'),
            _ProbeIndentedRow(
              '音频规格',
              '${audioSummary.isEmpty ? '-' : audioSummary} · ${PlaybackFormatters.formatBitrate(stats.audioBitrateBps)}',
            ),
            _ProbeIndentedRow(
              '音频输出',
              '${stats.audioOutBackend.isEmpty ? '-' : stats.audioOutBackend}${stats.audioExclusive ? ' (独占)' : ' (共享)'}',
            ),
            const SizedBox(height: 3),
            const _ProbeSectionHeader('Cache / Sync'),
            _ProbeIndentedRow(
              '缓冲与延迟',
              '$cacheLine · 字幕 ${stats.subtitleDelaySeconds.toStringAsFixed(1)}s / 音 ${stats.audioDelaySeconds.toStringAsFixed(1)}s',
            ),
          ],
        ),
      ),
    );
  }
}

class _ProbeSectionHeader extends StatelessWidget {
  const _ProbeSectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return KonataOsdStrokedText(
      '$title:',
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: KonataPlaybackTokens.osdProbeLabelColor,
      height: 1.28,
    );
  }
}

class _ProbeIndentedRow extends StatelessWidget {
  const _ProbeIndentedRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final normalized = value.trim().isEmpty ? '-' : value.trim();
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: KonataOsdStrokedText(
              label,
              fontSize: 11.0,
              fontWeight: FontWeight.w500,
              color: KonataPlaybackTokens.osdProbeLabelColor,
              height: 1.28,
            ),
          ),
          Expanded(
            child: KonataOsdStrokedText(
              normalized,
              fontSize: 11.0,
              fontWeight: FontWeight.w500,
              color: KonataPlaybackTokens.osdProbeValueColor,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              height: 1.28,
            ),
          ),
        ],
      ),
    );
  }
}
