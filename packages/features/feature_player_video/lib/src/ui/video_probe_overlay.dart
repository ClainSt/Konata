import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 直接叠于视频画面的透明详细信息浮层，全部指标来自播放器遥测。
class VideoProbeOverlay extends StatelessWidget {
  const VideoProbeOverlay({
    super.key,
    required this.stats,
    this.renderBackend = '',
    this.adapterName = '',
    this.positionSeconds = 0,
    this.durationSeconds = 0,
    this.hwdecForcedReason,
  });

  final PlaybackProbeStats stats;
  final String renderBackend;
  final String adapterName;
  final double positionSeconds;
  final double durationSeconds;
  final String? hwdecForcedReason;

  static String _fields(Iterable<String> fields) {
    final values = fields.where((value) => value.trim().isNotEmpty).toList();
    return values.isEmpty ? '—' : values.join(' · ');
  }

  static String _number(num? value, {int precision = 1, String unit = ''}) =>
      value == null ? '—' : '${value.toStringAsFixed(precision)}$unit';

  static String _resolution(int? width, int? height) =>
      width == null || height == null ? '—' : '$width×$height';

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final backend = renderBackend.trim().isNotEmpty ? renderBackend : s.gpuApi;
    final sections = <({String title, List<(String, String)> rows})>[
      (
        title: 'File / System',
        rows: [
          ('引擎', _fields([s.mpvVersion, s.ffmpegVersion])),
          (
            '硬解与输出',
            _fields([s.voBackend, s.hwdecCurrent, s.hwdecInterop, s.gpuApi]),
          ),
          if (hwdecForcedReason?.trim().isNotEmpty == true)
            ('解码策略', hwdecForcedReason!),
          (
            '封装与编码',
            _fields([
              s.containerFormat,
              s.videoCodec.toUpperCase(),
              s.videoProfile,
              PlaybackFormatters.formatVideoBitDepthLabel(
                s.videoHwPixelFormat.isNotEmpty
                    ? s.videoHwPixelFormat
                    : s.videoPixelFormat,
              ),
            ]),
          ),
        ],
      ),
      (
        title: 'Video',
        rows: [
          (
            '分辨率',
            '${_resolution(s.videoWidth, s.videoHeight)} → ${_resolution(s.targetWidth ?? s.displayWidth, s.targetHeight ?? s.displayHeight)} · ${PlaybackFormatters.formatBitrate(s.videoBitrateBps)}',
          ),
          (
            '像素格式',
            _fields([
              s.videoPixelFormat,
              if (s.videoHwPixelFormat.isNotEmpty) 'HW ${s.videoHwPixelFormat}',
            ]),
          ),
          (
            '帧率',
            '源 ${_number(s.containerFps, precision: 3)} · 滤镜 ${_number(s.estimatedVfFps, precision: 2)} · 屏 ${_number(s.displayFps, precision: 2)}',
          ),
          (
            '同步与丢帧',
            '${_number(s.avSyncMs, precision: 2, unit: " ms")} · 解码 ${s.droppedFramesDecoder ?? "—"} / VO ${s.droppedFramesVo ?? "—"} / 延迟 ${s.delayedFrames ?? "—"} / 错拍 ${s.mistimedFrames ?? "—"}',
          ),
          (
            '色彩管线',
            _fields([
              s.colorPrimaries,
              s.colorGamma,
              s.colorMatrix,
              s.colorRange,
              s.colorLevels,
            ]),
          ),
          (
            '动态范围',
            _fields([
              if (s.hdrPeakNits != null)
                _number(s.hdrPeakNits, precision: 0, unit: ' nits'),
              if (s.sigPeak != null) 'sig ${_number(s.sigPeak, precision: 2)}',
              s.toneMapping,
            ]),
          ),
          (
            '缩放与抖动',
            _fields([
              s.scaleFilter,
              s.cscaleFilter,
              s.dscaleFilter,
              if (s.debandEnabled) '去色带',
              if (s.ditherDepth.isNotEmpty) 'Dither ${s.ditherDepth}',
            ]),
          ),
          (
            '着色器链',
            s.activeShaderNames.isEmpty ? '无' : s.activeShaderNames.join(', '),
          ),
        ],
      ),
      (
        title: 'Audio',
        rows: [
          (
            '音频规格',
            _fields([
              PlaybackFormatters.formatAudioSpecSummary(
                codec: s.audioCodec,
                sampleRateHz: s.audioSampleRateHz,
                channelCount: s.audioChannelCount,
                channelLayout: s.audioChannelLayout,
                audioFormat: s.audioFormat,
              ),
              PlaybackFormatters.formatBitrate(s.audioBitrateBps),
            ]),
          ),
          (
            '音频输出',
            _fields([
              s.audioOutBackend,
              if (s.audioOutBackend.isNotEmpty) s.audioExclusive ? '独占' : '共享',
            ]),
          ),
        ],
      ),
      (
        title: 'Cache / Sync',
        rows: [
          (
            '缓存',
            _fields([
              _number(s.demuxerCacheSeconds, unit: 's'),
              PlaybackFormatters.formatCacheBytes(s.demuxerCacheBytes),
              PlaybackFormatters.formatByteSpeed(s.cacheSpeedBps),
              if (s.cachePercent != null) '${s.cachePercent}%',
            ]),
          ),
          (
            '延迟',
            '字幕 ${s.subtitleDelaySeconds.toStringAsFixed(2)}s / 音频 ${s.audioDelaySeconds.toStringAsFixed(2)}s',
          ),
          (
            '进度',
            '${PlaybackFormatters.formatMediaDuration(positionSeconds)} / ${PlaybackFormatters.formatMediaDuration(durationSeconds)} · ${s.speed.toStringAsFixed(2)}x',
          ),
        ],
      ),
    ];

    return RepaintBoundary(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) => FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: const ValueKey('video_probe_overlay'),
              width: math.min(520.0, constraints.maxWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KonataOsdStrokedText(
                    'Player · ${_fields([backend.toUpperCase(), adapterName])}',
                    fontSize: KonataTheme.fontSizeBodyXs,
                    fontWeight: FontWeight.w600,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  for (final section in sections) ...[
                    const SizedBox(height: 3),
                    KonataOsdStrokedText(
                      '${section.title}:',
                      fontSize: KonataTheme.fontSizeCaptionSm,
                      fontWeight: FontWeight.w600,
                      color: KonataPlaybackTokens.osdProbeLabelColor,
                      height: 1.28,
                    ),
                    for (final (label, value) in section.rows)
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 72,
                              child: KonataOsdStrokedText(
                                label,
                                fontSize: KonataTheme.fontSizeCaptionXs,
                                color: KonataPlaybackTokens.osdProbeLabelColor,
                                height: 1.28,
                              ),
                            ),
                            Expanded(
                              child: KonataOsdStrokedText(
                                value,
                                fontSize: KonataTheme.fontSizeCaptionXs,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                height: 1.28,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
