import 'dart:async';
import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/mpv_thumbnail_service.dart';

/// 底部悬浮光学毛玻璃播控胶囊（进度条与时间标签直连叶子监听器，消除高频重绘）。
class VideoPlaybackCapsule extends StatefulWidget {
  /// 创建底部视频播控胶囊。
  const VideoPlaybackCapsule({
    super.key,
    required this.isPlaying,
    required this.hasPreviousEpisode,
    required this.hasNextEpisode,
    required this.speed,
    required this.volume,
    required this.isMuted,
    required this.isFullscreen,
    required this.positionListenable,
    required this.durationListenable,
    required this.bufferedListenable,
    required this.chapters,
    required this.onTogglePlayPause,
    required this.onSeek,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onSelectSpeed,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onOpenEpisodesSheet,
    required this.onOpenSubtitlesSheet,
    required this.onOpenAudioSheet,
    required this.onOpenVideoSheet,
    required this.onToggleFullscreen,
    this.thumbnailService,
    this.onVolumePopupActiveChanged,
    this.onUserInteraction,
    this.volumeRevealPulse = 0,
  });

  /// 当前是否正在播放。
  final bool isPlaying;

  /// 是否存在上一话可切分集。
  final bool hasPreviousEpisode;

  /// 是否存在下一话可切分集。
  final bool hasNextEpisode;

  /// 当前倍速倍率。
  final double speed;

  /// 当前音量百分比（0.0 到 100.0）。
  final double volume;

  /// 当前是否静音。
  final bool isMuted;

  /// 当前是否处于全屏模式。
  final bool isFullscreen;

  /// 高频播放进度叶子监听器。
  final ValueListenable<Duration> positionListenable;

  /// 视频总时长叶子监听器。
  final ValueListenable<Duration> durationListenable;

  /// 解复用前向缓冲时间位置叶子监听器。
  final ValueListenable<Duration> bufferedListenable;

  /// 章节节点列表（用于在进度轨道上方渲染可磁吸标记点）。
  final List<PlaybackChapter> chapters;

  /// 可选按需后台缩略图解码服务。
  final MpvThumbnailService? thumbnailService;

  /// 切换播放或暂停回调。
  final VoidCallback onTogglePlayPause;

  /// 拖动或点击进度条提交绝对跳转时间（秒）回调。
  final ValueChanged<double> onSeek;

  /// 切换上一话回调。
  final VoidCallback? onPreviousEpisode;

  /// 切换下一话回调。
  final VoidCallback? onNextEpisode;

  /// 调整倍速回调。
  final ValueChanged<double> onSelectSpeed;

  /// 音量调整回调（输入范围 0.0 到 100.0）。
  final ValueChanged<double> onVolumeChanged;

  /// 静音切换回调。
  final VoidCallback onToggleMute;

  /// 打开选集侧栏页签回调。
  final VoidCallback onOpenEpisodesSheet;

  /// 打开字幕侧栏页签回调。
  final VoidCallback onOpenSubtitlesSheet;

  /// 打开音轨侧栏页签回调。
  final VoidCallback onOpenAudioSheet;

  /// 打开画面与着色器侧栏页签回调。
  final VoidCallback onOpenVideoSheet;

  /// 切换全屏回调。
  final VoidCallback onToggleFullscreen;

  /// 音量竖条弹出交互锁回调。
  final ValueChanged<bool>? onVolumePopupActiveChanged;

  /// 播控组件操作发生时通知外层重置隐藏倒计时。
  final VoidCallback? onUserInteraction;

  /// 外部滚轮或按键触发的音量条显示脉冲信号。
  final int volumeRevealPulse;

  @override
  State<VideoPlaybackCapsule> createState() => _VideoPlaybackCapsuleState();
}

class _VideoPlaybackCapsuleState extends State<VideoPlaybackCapsule> {
  static const List<double> _speedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    2.5,
    3.0,
  ];

  bool _railHovered = false;
  bool _dragging = false;
  double? _hoverSeconds;
  double? _dragSeconds;

  double _resolveTargetSeconds(double localDx, double width, double durationSec) {
    if (width <= 0 || durationSec <= 0) return 0.0;
    final ratio = (localDx / width).clamp(0.0, 1.0);
    return ratio * durationSec;
  }

  Future<void> _showSpeedMenu(BuildContext anchorContext) async {
    widget.onUserInteraction?.call();
    final chosen = await showKonataGlassMenu<double>(
      anchorContext: anchorContext,
      minWidth: 132,
      items: <KonataGlassMenuItem<double>>[
        for (final spd in _speedOptions)
          KonataGlassMenuItem<double>(
            value: spd,
            label: '${spd.toStringAsFixed(spd == spd.roundToDouble() ? 1 : 2)}x'
                '${(spd - widget.speed).abs() < 0.01 ? ' ✓' : ''}',
          ),
      ],
    );
    if (chosen != null) {
      widget.onSelectSpeed(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = p.isDark ? KonataPlaybackTokens.osdTextPrimary : p.textPrimary;
    final subFg = p.isDark
        ? KonataPlaybackTokens.osdTextSecondary
        : p.textSecondary;

    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: KonataPlaybackTokens.capsuleMinWidth,
        maxWidth: KonataPlaybackTokens.capsuleMaxWidth,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          if (_hoverSeconds != null || _dragSeconds != null)
            Positioned(
              bottom: KonataPlaybackTokens.capsuleHoverBubbleBottomOffset,
              child: _ThumbnailHoverBubble(
                targetSeconds: _dragSeconds ?? _hoverSeconds ?? 0.0,
                thumbnailService: widget.thumbnailService,
                chapters: widget.chapters,
              ),
            ),
          KonataGlassCapsule(
            showShadow: true,
            enableBackdropBlur: false,
            solidBackdropColor: KonataPlaybackTokens.osdSurfaceDark,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: KonataPlaybackTokens.capsuleProgressHorizontalInset,
                  ),
                  child: ValueListenableBuilder<Duration>(
                    valueListenable: widget.durationListenable,
                    builder: (context, dur, _) {
                      final totalSec = dur.inMilliseconds / 1000.0;
                      return ValueListenableBuilder<Duration>(
                        valueListenable: widget.bufferedListenable,
                        builder: (context, buffered, _) {
                          final bufferedSec = buffered.inMilliseconds / 1000.0;
                          return ValueListenableBuilder<Duration>(
                            valueListenable: widget.positionListenable,
                            builder: (context, pos, _) {
                              final currentSec =
                                  _dragSeconds ?? (pos.inMilliseconds / 1000.0);
                              final ratio = totalSec > 0
                                  ? (currentSec / totalSec).clamp(0.0, 1.0)
                                  : 0.0;
                              final bufRatio = totalSec > 0
                                  ? (bufferedSec / totalSec).clamp(0.0, 1.0)
                                  : 0.0;
                              return LayoutBuilder(
                                builder: (context, constraints) {
                                  final w = constraints.maxWidth;
                                  return MouseRegion(
                                    cursor: totalSec > 0
                                        ? SystemMouseCursors.click
                                        : SystemMouseCursors.basic,
                                    onEnter: (_) =>
                                        setState(() => _railHovered = true),
                                    onHover: (event) {
                                      if (totalSec <= 0) return;
                                      final target = _resolveTargetSeconds(
                                        event.localPosition.dx,
                                        w,
                                        totalSec,
                                      );
                                      setState(() => _hoverSeconds = target);
                                      widget.thumbnailService?.requestPreview(
                                        target,
                                      );
                                    },
                                    onExit: (_) {
                                      setState(() {
                                        _railHovered = false;
                                        _hoverSeconds = null;
                                      });
                                      if (!_dragging) {
                                        widget.thumbnailService?.requestPreview(
                                          null,
                                        );
                                      }
                                    },
                                    child: GestureDetector(
                                      key: const ValueKey(
                                        'video_capsule_progress_rail',
                                      ),
                                      behavior: HitTestBehavior.opaque,
                                      onTapUp: (details) {
                                        if (totalSec <= 0) return;
                                        widget.onUserInteraction?.call();
                                        final target = _resolveTargetSeconds(
                                          details.localPosition.dx,
                                          w,
                                          totalSec,
                                        );
                                        widget.onSeek(target);
                                      },
                                      onHorizontalDragStart: (details) {
                                        if (totalSec <= 0) return;
                                        widget.onUserInteraction?.call();
                                        final target = _resolveTargetSeconds(
                                          details.localPosition.dx,
                                          w,
                                          totalSec,
                                        );
                                        setState(() {
                                          _dragging = true;
                                          _dragSeconds = target;
                                        });
                                        widget.thumbnailService?.requestPreview(
                                          target,
                                        );
                                      },
                                      onHorizontalDragUpdate: (details) {
                                        if (!_dragging || totalSec <= 0) return;
                                        widget.onUserInteraction?.call();
                                        final target = _resolveTargetSeconds(
                                          details.localPosition.dx,
                                          w,
                                          totalSec,
                                        );
                                        setState(() => _dragSeconds = target);
                                        widget.thumbnailService?.requestPreview(
                                          target,
                                        );
                                      },
                                      onHorizontalDragEnd: (_) {
                                        if (!_dragging) return;
                                        final target = _dragSeconds;
                                        setState(() {
                                          _dragging = false;
                                          _dragSeconds = null;
                                        });
                                        widget.thumbnailService?.requestPreview(
                                          null,
                                        );
                                        if (target != null) {
                                          widget.onSeek(target);
                                        }
                                      },
                                      child: SizedBox(
                                        height: KonataPlaybackTokens
                                            .capsuleProgressHitHeight,
                                        child: Align(
                                          alignment: Alignment.topCenter,
                                          child: AnimatedContainer(
                                            duration: KonataTheme.motionFast,
                                            height:
                                                (_railHovered || _dragging)
                                                ? KonataPlaybackTokens
                                                      .capsuleProgressHoverHeight
                                                : KonataPlaybackTokens
                                                      .capsuleProgressRestHeight,
                                            decoration: BoxDecoration(
                                              color: KonataPlaybackTokens
                                                  .capsuleProgressTrackFor(p),
                                              borderRadius: BorderRadius.circular(
                                                999,
                                              ),
                                            ),
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                FractionallySizedBox(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  widthFactor: bufRatio,
                                                  child: DecoratedBox(
                                                    decoration: BoxDecoration(
                                                      color: fg.withValues(
                                                        alpha: 0.22,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                                FractionallySizedBox(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  widthFactor: ratio,
                                                  child: DecoratedBox(
                                                    decoration: BoxDecoration(
                                                      color: KonataPlaybackTokens
                                                          .capsuleProgressFillFor(
                                                            p,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 14, 8),
                  child: Row(
                    children: [
                      KonataCapsuleIconButton(
                        key: const ValueKey('video_prev_episode_button'),
                        icon: Icons.skip_previous_rounded,
                        tooltip: '上一集',
                        color: fg,
                        onTap: widget.hasPreviousEpisode
                            ? () {
                                widget.onUserInteraction?.call();
                                widget.onPreviousEpisode?.call();
                              }
                            : null,
                      ),
                      const SizedBox(width: 2),
                      KonataCapsuleIconButton(
                        key: const ValueKey('video_play_pause_button'),
                        icon: widget.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: widget.isPlaying ? '暂停' : '播放',
                        size: 24,
                        color: fg,
                        onTap: () {
                          widget.onUserInteraction?.call();
                          widget.onTogglePlayPause();
                        },
                      ),
                      const SizedBox(width: 2),
                      KonataCapsuleIconButton(
                        key: const ValueKey('video_next_episode_button'),
                        icon: Icons.skip_next_rounded,
                        tooltip: '下一集',
                        color: fg,
                        onTap: widget.hasNextEpisode
                            ? () {
                                widget.onUserInteraction?.call();
                                widget.onNextEpisode?.call();
                              }
                            : null,
                      ),
                      const SizedBox(width: 10),
                      ValueListenableBuilder<Duration>(
                        valueListenable: widget.durationListenable,
                        builder: (context, dur, _) {
                          return ValueListenableBuilder<Duration>(
                            valueListenable: widget.positionListenable,
                            builder: (context, pos, _) {
                              final cur = _dragSeconds != null
                                  ? _dragSeconds!.round()
                                  : pos.inSeconds;
                              final tot = dur.inSeconds;
                              return Text(
                                '${PlaybackRecordHelper.formatClock(cur)} / '
                                '${PlaybackRecordHelper.formatClock(tot)}',
                                key: const ValueKey('video_capsule_time_text'),
                                style: TextStyle(
                                  color: subFg,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures:
                                      KonataPlaybackTokens.tabularNumbers,
                                ),
                              );
                            },
                          );
                        },
                      ),
                      const Spacer(),
                      Builder(
                        builder: (btnCtx) {
                          return GestureDetector(
                            key: const ValueKey('video_speed_button'),
                            onTap: () => _showSpeedMenu(btnCtx),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Text(
                                '${widget.speed.toStringAsFixed(widget.speed == widget.speed.roundToDouble() ? 1 : 2)}x',
                                style: TextStyle(
                                  color: fg,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures:
                                      KonataPlaybackTokens.tabularNumbers,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      KonataVolumeControl(
                        volume: (widget.volume / 100.0).clamp(0.0, 1.0),
                        isMuted: widget.isMuted,
                        onVolumeChanged: (norm) {
                          widget.onUserInteraction?.call();
                          widget.onVolumeChanged(norm * 100.0);
                        },
                        onToggleMute: () {
                          widget.onUserInteraction?.call();
                          widget.onToggleMute();
                        },
                        onPopupActiveChanged: widget.onVolumePopupActiveChanged,
                        externalRevealPulse: widget.volumeRevealPulse,
                      ),
                      KonataCapsuleIconButton(
                        key: const ValueKey('video_episodes_sheet_button'),
                        icon: Icons.view_list_rounded,
                        tooltip: '选集与章节',
                        color: fg,
                        onTap: () {
                          widget.onUserInteraction?.call();
                          widget.onOpenEpisodesSheet();
                        },
                      ),
                      KonataCapsuleIconButton(
                        key: const ValueKey('video_subtitles_sheet_button'),
                        icon: Icons.subtitles_outlined,
                        tooltip: '字幕设置',
                        color: fg,
                        onTap: () {
                          widget.onUserInteraction?.call();
                          widget.onOpenSubtitlesSheet();
                        },
                      ),
                      KonataCapsuleIconButton(
                        key: const ValueKey('video_audio_sheet_button'),
                        icon: Icons.audiotrack_rounded,
                        tooltip: '音轨设置',
                        color: fg,
                        onTap: () {
                          widget.onUserInteraction?.call();
                          widget.onOpenAudioSheet();
                        },
                      ),
                      KonataCapsuleIconButton(
                        key: const ValueKey('video_video_sheet_button'),
                        icon: Icons.tune_rounded,
                        tooltip: '画面与着色器',
                        color: fg,
                        onTap: () {
                          widget.onUserInteraction?.call();
                          widget.onOpenVideoSheet();
                        },
                      ),
                      KonataCapsuleIconButton(
                        key: const ValueKey('video_fullscreen_button'),
                        icon: widget.isFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        tooltip: widget.isFullscreen ? '退出全屏' : '全屏播放',
                        color: fg,
                        onTap: () {
                          widget.onUserInteraction?.call();
                          widget.onToggleFullscreen();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbnailHoverBubble extends StatelessWidget {
  const _ThumbnailHoverBubble({
    required this.targetSeconds,
    required this.thumbnailService,
    required this.chapters,
  });

  final double targetSeconds;
  final MpvThumbnailService? thumbnailService;
  final List<PlaybackChapter> chapters;

  PlaybackChapter? _resolveChapter() {
    PlaybackChapter? matched;
    for (final ch in chapters) {
      if (ch.startSeconds <= targetSeconds) {
        matched = ch;
      } else {
        break;
      }
    }
    return matched;
  }

  @override
  Widget build(BuildContext context) {
    final chapter = _resolveChapter();
    final frameBytes = thumbnailService?.resolvePreviewFrame(targetSeconds);
    final label = PlaybackRecordHelper.formatClock(
      math.max(0, targetSeconds.round()),
    );

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: KonataPlaybackTokens.osdSurfaceDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: KonataPlaybackTokens.osdBorderLight,
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (frameBytes != null && frameBytes.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(
                KonataPlaybackTokens.thumbnailPreviewRadius,
              ),
              child: Image.memory(
                frameBytes,
                width: KonataPlaybackTokens.thumbnailPreviewDisplayWidth,
                height: KonataPlaybackTokens.thumbnailPreviewDisplayHeight,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          if (frameBytes != null && frameBytes.isNotEmpty)
            const SizedBox(height: 4),
          Text(
            chapter != null && chapter.title.trim().isNotEmpty
                ? '$label · ${chapter.title}'
                : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: KonataPlaybackTokens.osdTextPrimary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              fontFeatures: KonataPlaybackTokens.tabularNumbers,
            ),
          ),
        ],
      ),
    );
  }
}
