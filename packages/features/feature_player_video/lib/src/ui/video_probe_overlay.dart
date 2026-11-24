import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 播放器左上角纯文字黑边描边技术探针统计浮层。
class VideoProbeOverlay extends StatelessWidget {
  /// 创建音画技术探针浮层。
  const VideoProbeOverlay({
    super.key,
    required this.stats,
    this.renderBackend = '',
    this.adapterName = '',
    this.positionSeconds = 0.0,
    this.durationSeconds = 0.0,
    this.hwdecForcedReason,
  });

  /// 实时采集的音画、解码器、色域与缓存遥测快照。
  final PlaybackProbeStats stats;

  /// 当前激活图形渲染管线名称。
  final String renderBackend;

  /// 当前图形显卡或系统渲染设备说明。
  final String adapterName;

  /// 当前播放进度秒数（用于补充探针位置读数）。
  final double positionSeconds;

  /// 媒体总时长秒数。
  final double durationSeconds;

  /// 若当前流因高危编码回落多线程软件解码，展示提示摘要。
  final String? hwdecForcedReason;

  @override
  Widget build(BuildContext context) {
    final resText = (stats.videoWidth != null && stats.videoHeight != null)
        ? '${stats.videoWidth}x${stats.videoHeight}'
        : '--';
    final fpsText = stats.containerFps != null
        ? '${stats.containerFps!.toStringAsFixed(3)} fps'
        : '--';
    final estFpsText = stats.estimatedVfFps != null
        ? '${stats.estimatedVfFps!.toStringAsFixed(2)} fps'
        : '--';
    final hwdecText = stats.hwdecCurrent.trim().isEmpty
        ? 'software'
        : stats.hwdecCurrent.trim();
    final backendText = renderBackend.trim().isNotEmpty
        ? renderBackend.trim()
        : (stats.voBackend.isEmpty ? 'libmpv' : stats.voBackend);
    final codecLine = [
      if (stats.videoCodec.isNotEmpty) stats.videoCodec.toUpperCase(),
      if (stats.videoProfile.isNotEmpty) stats.videoProfile,
      if (stats.videoPixelFormat.isNotEmpty) stats.videoPixelFormat,
    ].join(' · ');
    final audioLine = [
      if (stats.audioCodec.isNotEmpty) stats.audioCodec.toUpperCase(),
      if (stats.audioSampleRateHz != null)
        '${(stats.audioSampleRateHz! / 1000).toStringAsFixed(1)} kHz',
      if (stats.audioChannelLayout.isNotEmpty) stats.audioChannelLayout,
      if (stats.audioOutBackend.isNotEmpty) stats.audioOutBackend,
    ].join(' · ');
    final cacheSec = stats.demuxerCacheSeconds != null
        ? '${stats.demuxerCacheSeconds!.toStringAsFixed(1)}s'
        : '--';
    final clockLine =
        '${PlaybackRecordHelper.formatClock(positionSeconds.round())} / '
        '${PlaybackRecordHelper.formatClock(durationSeconds.round())}';

    final lines = <String>[
      '播放器: ${stats.mpvVersion.isEmpty ? 'libmpv' : stats.mpvVersion} ($backendText)',
      if (adapterName.trim().isNotEmpty) '渲染设备: $adapterName',
      '解码路径: $hwdecText | GPU: ${stats.gpuApi.isEmpty ? '--' : stats.gpuApi}',
      if (hwdecForcedReason != null && hwdecForcedReason!.trim().isNotEmpty)
        '安全策略: $hwdecForcedReason',
      '视频流: ${codecLine.isEmpty ? '--' : codecLine} | $resText @ $fpsText (实测 $estFpsText)',
      '色彩映射: ${stats.colorPrimaries.isEmpty ? 'bt.709' : stats.colorPrimaries} / '
          '${stats.colorGamma.isEmpty ? '--' : stats.colorGamma} | '
          'Range: ${stats.colorRange.isEmpty ? '--' : stats.colorRange}',
      '音频流: ${audioLine.isEmpty ? '--' : audioLine} | 独占: ${stats.audioExclusive ? '是' : '否'}',
      '音画同步: ${stats.avSyncMs != null ? '${stats.avSyncMs!.toStringAsFixed(1)} ms' : '--'} | '
          '丢帧: ${stats.droppedFramesDecoder ?? 0}/${stats.droppedFramesVo ?? 0}',
      '缓存前瞻: $cacheSec | 进度: $clockLine | 倍速: ${stats.speed.toStringAsFixed(2)}x',
      if (stats.activeShaderNames.isNotEmpty)
        '着色器: ${stats.activeShaderNames.join(', ')}',
    ];

    return RepaintBoundary(
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('video_probe_overlay'),
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.osdSurfaceDark.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: KonataPlaybackTokens.osdBorderLight,
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1.5),
                  child: KonataOsdStrokedText(
                    line,
                    fontSize: 11.5,
                    color: KonataPlaybackTokens.osdProbeValueColor,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
