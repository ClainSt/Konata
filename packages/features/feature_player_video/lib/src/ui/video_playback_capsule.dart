import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/mpv_thumbnail_service.dart';

typedef _ScrubPreviewSnapshot = ({
  double targetSeconds,
  double anchorRatio,
  int? snappedChapterIndex,
});

/// 底部悬浮单层 `52px` 光学毛玻璃播控胶囊（顶边连续光轨、严格居中播放头圆点与顶边平齐内指倒三角章节点）。
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
    this.onCaptureScreenshot,
    this.thumbnailService,
    this.onVolumePopupActiveChanged,
    this.onUserInteraction,
    this.volumeRevealPulse = 0,
    this.showDesktopControls = true,
    this.enableBackdropBlur = true,
    this.isTouchPlatform = false,
  });

  /// 胶囊主体固定高度（单层 `52px` 悬浮圆角胶囊）。
  static const double capsuleHeight = KonataPlaybackTokens.capsuleHeight;

  /// 顶边进度条水平内缩距离（严格对齐 `52px` 胶囊 `26px` 半圆角切点）。
  static const double progressHorizontalInset = 26.0;

  /// 顶边进度条常态高度。
  static const double railRestHeight = 3.0;

  /// 顶边进度条悬停/拖拽增粗高度。
  static const double railHoverHeight = 4.5;

  /// 顶边进度条透明命中热区高度。
  static const double railHitHeight = 16.0;

  /// 悬停播放头圆点直径（含描边约 `10.5px` 视觉、圆心严格对齐轨道中心线）。
  static const double playheadThumbSize = 10.5;

  /// 顶边平齐（`y = 0`）内指圆角倒三角章节点宽度与高度。
  static const double chapterTriangleWidth = 10.0;
  static const double chapterTriangleHeight = 7.5;

  /// 悬停靠近章节点时的倒三角放大倍率与磁吸判定像素半径。
  static const double chapterTriangleHoverScale = 1.28;
  static const double chapterSnapRadiusPx = 10.0;
  static const double chapterMinSpacingPx = 12.0;

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

  /// 章节节点列表（用于在顶边进度轨道渲染顶边平齐可磁吸倒三角标记）。
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

  /// 可选原画截图回调。
  final VoidCallback? onCaptureScreenshot;

  /// 音量竖条弹出交互锁回调。
  final ValueChanged<bool>? onVolumePopupActiveChanged;

  /// 播控组件操作发生时通知外层重置隐藏倒计时。
  final VoidCallback? onUserInteraction;

  /// 外部滚轮或按键触发的音量条显示脉冲信号。
  final int volumeRevealPulse;

  /// 是否显示桌面专属音量竖条与全屏按钮。
  final bool showDesktopControls;

  /// 是否启用底层实时毛玻璃模糊（Android 硬件视频前景可关闭避免双影）。
  final bool enableBackdropBlur;

  /// 当前是否按触屏平台尺寸收敛间距。
  final bool isTouchPlatform;

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

  final ValueNotifier<double?> _dragSecondsNotifier = ValueNotifier<double?>(
    null,
  );
  final ValueNotifier<_ScrubPreviewSnapshot?> _previewNotifier =
      ValueNotifier<_ScrubPreviewSnapshot?>(null);

  @override
  void dispose() {
    _dragSecondsNotifier.dispose();
    _previewNotifier.dispose();
    super.dispose();
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
            label:
                '${spd.toStringAsFixed(spd == spd.roundToDouble() ? 1 : 2)}x'
                '${(spd - widget.speed).abs() < 0.01 ? ' ✓' : ''}',
          ),
      ],
    );
    if (chosen != null) {
      widget.onSelectSpeed(chosen);
    }
  }

  String _formatSpeedLabel(double speed) {
    final fixed = speed == speed.roundToDouble()
        ? speed.toStringAsFixed(1)
        : speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
    return '${fixed}x';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = p.textPrimary;
    final subFg = p.isDark
        ? KonataPlaybackTokens.osdTextSecondary
        : p.textSecondary;
    final maxWidth = widget.isTouchPlatform
        ? 650.0
        : KonataPlaybackTokens.capsuleMaxWidth;
    final transportButtonSize = widget.isTouchPlatform ? 36.0 : 32.0;
    final playButtonSize = widget.isTouchPlatform ? 42.0 : 38.0;
    final actionButtonSize = widget.isTouchPlatform ? 34.0 : 32.0;

    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 280.0, maxWidth: maxWidth),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final capsuleWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : maxWidth;

          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              SizedBox(
                height: VideoPlaybackCapsule.capsuleHeight,
                child: ValueListenableBuilder<Duration>(
                  valueListenable: widget.durationListenable,
                  builder: (context, dur, _) {
                    final totalSec = dur.inMilliseconds / 1000.0;
                    final hasProgressRail = totalSec > 0;

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: KonataGlassCapsule(
                            radius: KonataPlaybackTokens.capsuleRadius,
                            showShadow: true,
                            showBorder: false,
                            enableBackdropBlur: widget.enableBackdropBlur,
                            solidBackdropColor: p.isDark
                                ? KonataPlaybackTokens.osdSurfaceDark
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                              child: _buildThreeZoneControls(
                                context: context,
                                capsuleWidth: capsuleWidth,
                                fg: fg,
                                subFg: subFg,
                                transportButtonSize: transportButtonSize,
                                playButtonSize: playButtonSize,
                                actionButtonSize: actionButtonSize,
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _VideoCapsuleBorderPainter(
                                borderColor: KonataPlaybackTokens.glassBorder(
                                  p,
                                ),
                                omitTopRailSpan: hasProgressRail,
                                railHorizontalInset: VideoPlaybackCapsule
                                    .progressHorizontalInset,
                              ),
                            ),
                          ),
                        ),
                        if (hasProgressRail)
                          Positioned(
                            left: VideoPlaybackCapsule.progressHorizontalInset,
                            right: VideoPlaybackCapsule.progressHorizontalInset,
                            top: 0,
                            height: VideoPlaybackCapsule.railHitHeight,
                            child: RepaintBoundary(
                              child: _VideoTopProgressRail(
                                totalSeconds: totalSec,
                                positionListenable: widget.positionListenable,
                                bufferedListenable: widget.bufferedListenable,
                                dragSecondsNotifier: _dragSecondsNotifier,
                                previewNotifier: _previewNotifier,
                                chapters: widget.chapters,
                                thumbnailService: widget.thumbnailService,
                                isDark: p.isDark,
                                trackColor:
                                    KonataPlaybackTokens.capsuleProgressTrackFor(
                                      p,
                                    ),
                                fillColor:
                                    KonataPlaybackTokens.capsuleProgressFillFor(
                                      p,
                                    ),
                                bufferedColor: fg.withValues(alpha: 0.22),
                                onUserInteraction: widget.onUserInteraction,
                                onSeek: widget.onSeek,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              ValueListenableBuilder<_ScrubPreviewSnapshot?>(
                valueListenable: _previewNotifier,
                builder: (context, preview, _) {
                  if (preview == null) return const SizedBox.shrink();
                  const bubbleCardWidth =
                      KonataPlaybackTokens.thumbnailPreviewDisplayWidth + 14.0;
                  final railSpan = math.max(
                    1.0,
                    capsuleWidth -
                        VideoPlaybackCapsule.progressHorizontalInset * 2,
                  );
                  final anchorX =
                      VideoPlaybackCapsule.progressHorizontalInset +
                      preview.anchorRatio.clamp(0.0, 1.0) * railSpan;
                  final maxLeft = math.max(
                    4.0,
                    capsuleWidth - bubbleCardWidth - 4.0,
                  );
                  final bubbleLeft = (anchorX - bubbleCardWidth / 2).clamp(
                    4.0,
                    maxLeft,
                  );

                  return Positioned(
                    left: bubbleLeft,
                    bottom: VideoPlaybackCapsule.capsuleHeight + 10.0,
                    child: IgnorePointer(
                      child: _ThumbnailHoverBubble(
                        key: const ValueKey('video_thumbnail_preview_bubble'),
                        targetSeconds: preview.targetSeconds,
                        snappedChapterIndex: preview.snappedChapterIndex,
                        thumbnailService: widget.thumbnailService,
                        chapters: widget.chapters,
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildThreeZoneControls({
    required BuildContext context,
    required double capsuleWidth,
    required Color fg,
    required Color subFg,
    required double transportButtonSize,
    required double playButtonSize,
    required double actionButtonSize,
  }) {
    final prevButton = KonataCapsuleIconButton(
      key: const ValueKey('video_prev_episode_button'),
      icon: Icons.skip_previous_rounded,
      tooltip: '上一集',
      color: fg,
      size: 20,
      fixedSize: transportButtonSize,
      padding: EdgeInsets.zero,
      onTap: widget.hasPreviousEpisode
          ? () {
              widget.onUserInteraction?.call();
              widget.onPreviousEpisode?.call();
            }
          : null,
    );
    final playPauseButton = KonataCapsuleIconButton(
      key: const ValueKey('video_play_pause_button'),
      icon: widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      tooltip: widget.isPlaying ? '暂停' : '播放',
      size: 24,
      fixedSize: playButtonSize,
      padding: EdgeInsets.zero,
      color: fg,
      onTap: () {
        widget.onUserInteraction?.call();
        widget.onTogglePlayPause();
      },
    );
    final nextButton = KonataCapsuleIconButton(
      key: const ValueKey('video_next_episode_button'),
      icon: Icons.skip_next_rounded,
      tooltip: '下一集',
      color: fg,
      size: 20,
      fixedSize: transportButtonSize,
      padding: EdgeInsets.zero,
      onTap: widget.hasNextEpisode
          ? () {
              widget.onUserInteraction?.call();
              widget.onNextEpisode?.call();
            }
          : null,
    );

    final timeLeaf = _CapsuleTimeTextLeaf(
      positionListenable: widget.positionListenable,
      durationListenable: widget.durationListenable,
      dragSecondsNotifier: _dragSecondsNotifier,
      style: TextStyle(
        color: subFg,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        fontFeatures: KonataPlaybackTokens.tabularNumbers,
      ),
    );

    final rightControls = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (btnCtx) {
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: const ValueKey('video_speed_button'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _showSpeedMenu(btnCtx),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 6,
                    ),
                    child: Text(
                      _formatSpeedLabel(widget.speed),
                      style: TextStyle(
                        color: fg,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: KonataPlaybackTokens.tabularNumbers,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          KonataCapsuleIconButton(
            key: const ValueKey('video_episodes_sheet_button'),
            icon: Icons.view_list_rounded,
            tooltip: '选集与章节',
            color: fg,
            size: 19,
            fixedSize: actionButtonSize,
            padding: EdgeInsets.zero,
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
            size: 19,
            fixedSize: actionButtonSize,
            padding: EdgeInsets.zero,
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
            size: 19,
            fixedSize: actionButtonSize,
            padding: EdgeInsets.zero,
            onTap: () {
              widget.onUserInteraction?.call();
              widget.onOpenAudioSheet();
            },
          ),
          KonataCapsuleIconButton(
            key: const ValueKey('video_capsule_screenshot_button'),
            icon: Icons.camera_alt_outlined,
            tooltip: '原画截图',
            color: fg,
            size: 18,
            fixedSize: actionButtonSize,
            padding: EdgeInsets.zero,
            onTap: widget.onCaptureScreenshot != null
                ? () {
                    widget.onUserInteraction?.call();
                    widget.onCaptureScreenshot!();
                  }
                : () {
                    widget.onUserInteraction?.call();
                    widget.onOpenVideoSheet();
                  },
          ),
          if (widget.showDesktopControls) ...[
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
              key: const ValueKey('video_fullscreen_button'),
              icon: widget.isFullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              tooltip: widget.isFullscreen ? '退出全屏' : '全屏播放',
              color: fg,
              size: 20,
              fixedSize: actionButtonSize,
              padding: EdgeInsets.zero,
              onTap: () {
                widget.onUserInteraction?.call();
                widget.onToggleFullscreen();
              },
            ),
          ],
        ],
      ),
    );

    final useSymmetricCenter =
        capsuleWidth >= KonataPlaybackTokens.capsuleCenterSymmetricBreakpoint;
    final centerGroup = Row(
      key: const ValueKey('video_capsule_center_transport'),
      mainAxisSize: MainAxisSize.min,
      children: [
        prevButton,
        const SizedBox(width: 4),
        playPauseButton,
        const SizedBox(width: 4),
        nextButton,
      ],
    );

    if (useSymmetricCenter) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: timeLeaf),
          ),
          const SizedBox(width: 8),
          centerGroup,
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: rightControls,
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        timeLeaf,
        const SizedBox(width: 8),
        centerGroup,
        const SizedBox(width: 6),
        Expanded(
          child: Align(alignment: Alignment.centerRight, child: rightControls),
        ),
      ],
    );
  }
}

class _CapsuleTimeTextLeaf extends StatefulWidget {
  const _CapsuleTimeTextLeaf({
    required this.positionListenable,
    required this.durationListenable,
    required this.dragSecondsNotifier,
    required this.style,
  });

  final ValueListenable<Duration> positionListenable;
  final ValueListenable<Duration> durationListenable;
  final ValueListenable<double?> dragSecondsNotifier;
  final TextStyle style;

  @override
  State<_CapsuleTimeTextLeaf> createState() => _CapsuleTimeTextLeafState();
}

class _CapsuleTimeTextLeafState extends State<_CapsuleTimeTextLeaf> {
  late int _lastWholeSeconds;

  @override
  void initState() {
    super.initState();
    _lastWholeSeconds = widget.positionListenable.value.inSeconds;
    widget.positionListenable.addListener(_onPositionTick);
    widget.dragSecondsNotifier.addListener(_onDragTick);
  }

  @override
  void didUpdateWidget(covariant _CapsuleTimeTextLeaf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.positionListenable, widget.positionListenable)) {
      oldWidget.positionListenable.removeListener(_onPositionTick);
      widget.positionListenable.addListener(_onPositionTick);
      _lastWholeSeconds = widget.positionListenable.value.inSeconds;
    }
    if (!identical(oldWidget.dragSecondsNotifier, widget.dragSecondsNotifier)) {
      oldWidget.dragSecondsNotifier.removeListener(_onDragTick);
      widget.dragSecondsNotifier.addListener(_onDragTick);
    }
  }

  @override
  void dispose() {
    widget.positionListenable.removeListener(_onPositionTick);
    widget.dragSecondsNotifier.removeListener(_onDragTick);
    super.dispose();
  }

  void _onPositionTick() {
    if (!mounted || widget.dragSecondsNotifier.value != null) return;
    final nextSec = widget.positionListenable.value.inSeconds;
    if (nextSec == _lastWholeSeconds) return;
    setState(() => _lastWholeSeconds = nextSec);
  }

  void _onDragTick() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.durationListenable,
      builder: (context, dur, _) {
        final dragSec = widget.dragSecondsNotifier.value;
        final cur = dragSec != null
            ? dragSec.round()
            : widget.positionListenable.value.inSeconds;
        final tot = dur.inSeconds;
        return Text(
          '${PlaybackRecordHelper.formatClock(cur)} / '
          '${PlaybackRecordHelper.formatClock(tot)}',
          key: const ValueKey('video_capsule_time_text'),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        );
      },
    );
  }
}

class _VideoTopProgressRail extends StatefulWidget {
  const _VideoTopProgressRail({
    required this.totalSeconds,
    required this.positionListenable,
    required this.bufferedListenable,
    required this.dragSecondsNotifier,
    required this.previewNotifier,
    required this.chapters,
    required this.thumbnailService,
    required this.isDark,
    required this.trackColor,
    required this.fillColor,
    required this.bufferedColor,
    required this.onUserInteraction,
    required this.onSeek,
  });

  final double totalSeconds;
  final ValueListenable<Duration> positionListenable;
  final ValueListenable<Duration> bufferedListenable;
  final ValueNotifier<double?> dragSecondsNotifier;
  final ValueNotifier<_ScrubPreviewSnapshot?> previewNotifier;
  final List<PlaybackChapter> chapters;
  final MpvThumbnailService? thumbnailService;
  final bool isDark;
  final Color trackColor;
  final Color fillColor;
  final Color bufferedColor;
  final VoidCallback? onUserInteraction;
  final ValueChanged<double> onSeek;

  @override
  State<_VideoTopProgressRail> createState() => _VideoTopProgressRailState();
}

class _VideoTopProgressRailState extends State<_VideoTopProgressRail> {
  bool _hovered = false;
  bool _dragging = false;
  int? _snappedChapterIndex;

  List<int> _resolveVisibleChapterIndices(double railWidth) {
    if (widget.chapters.isEmpty || widget.totalSeconds <= 0 || railWidth <= 0) {
      return const <int>[];
    }
    const halfTri = VideoPlaybackCapsule.chapterTriangleWidth * 0.5;
    final minX = math.min(halfTri, railWidth * 0.5);
    final maxX = math.max(minX, railWidth - halfTri);

    double centerXFor(int index) {
      final ratio = (widget.chapters[index].startSeconds / widget.totalSeconds)
          .clamp(0.0, 1.0);
      return (ratio * railWidth).clamp(minX, maxX);
    }

    final candidates = <int>[];
    for (var i = 0; i < widget.chapters.length; i++) {
      final start = widget.chapters[i].startSeconds;
      if (start > 0 && start < widget.totalSeconds) {
        candidates.add(i);
      }
    }

    final acceptedCenters = <double>[];
    final visible = <int>[];
    final activeSnap = _snappedChapterIndex;
    if (activeSnap != null && candidates.contains(activeSnap)) {
      visible.add(activeSnap);
      acceptedCenters.add(centerXFor(activeSnap));
    }

    for (final idx in candidates) {
      if (visible.contains(idx)) continue;
      final cx = centerXFor(idx);
      var overlaps = false;
      for (final existing in acceptedCenters) {
        if ((cx - existing).abs() < VideoPlaybackCapsule.chapterMinSpacingPx) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) {
        visible.add(idx);
        acceptedCenters.add(cx);
      }
    }

    visible.sort((a, b) {
      if (a == activeSnap) return 1;
      if (b == activeSnap) return -1;
      return a.compareTo(b);
    });
    return visible;
  }

  ({double targetSeconds, double anchorRatio, int? snappedChapterIndex})
  _resolvePointerTarget(
    double localDx,
    double railWidth,
    List<int> visibleChapters,
  ) {
    if (railWidth <= 0 || widget.totalSeconds <= 0) {
      return (targetSeconds: 0.0, anchorRatio: 0.0, snappedChapterIndex: null);
    }
    final rawRatio = (localDx / railWidth).clamp(0.0, 1.0);
    final hoverX = rawRatio * railWidth;

    if (visibleChapters.isNotEmpty) {
      var bestIdx = -1;
      var bestX = 0.0;
      var bestDist = double.infinity;
      final positions = <(int index, double x)>[];
      for (final idx in visibleChapters) {
        final cx =
            ((widget.chapters[idx].startSeconds / widget.totalSeconds).clamp(
              0.0,
              1.0,
            )) *
            railWidth;
        positions.add((idx, cx));
        final dist = (hoverX - cx).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestIdx = idx;
          bestX = cx;
        }
      }
      if (bestIdx >= 0) {
        var nearestNeighbor = double.infinity;
        for (final entry in positions) {
          if (entry.$1 == bestIdx) continue;
          final d = (entry.$2 - bestX).abs();
          if (d < nearestNeighbor) nearestNeighbor = d;
        }
        final snapRadius = math.min(
          VideoPlaybackCapsule.chapterSnapRadiusPx,
          nearestNeighbor * 0.45,
        );
        if (bestDist <= snapRadius) {
          final startSec = widget.chapters[bestIdx].startSeconds;
          return (
            targetSeconds: startSec,
            anchorRatio: (startSec / widget.totalSeconds).clamp(0.0, 1.0),
            snappedChapterIndex: bestIdx,
          );
        }
      }
    }

    return (
      targetSeconds: rawRatio * widget.totalSeconds,
      anchorRatio: rawRatio,
      snappedChapterIndex: null,
    );
  }

  void _updateHoverOrScrub(
    double localDx,
    double railWidth,
    List<int> visibleChapters, {
    required bool isDrag,
  }) {
    final resolved = _resolvePointerTarget(localDx, railWidth, visibleChapters);
    if (_snappedChapterIndex != resolved.snappedChapterIndex) {
      setState(() => _snappedChapterIndex = resolved.snappedChapterIndex);
    }
    if (isDrag) {
      widget.dragSecondsNotifier.value = resolved.targetSeconds;
    }
    widget.previewNotifier.value = resolved;
    widget.thumbnailService?.requestPreview(resolved.targetSeconds);
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _hovered || _dragging;

    return LayoutBuilder(
      builder: (context, constraints) {
        final railWidth = constraints.maxWidth > 0 ? constraints.maxWidth : 1.0;
        final visibleChapters = _resolveVisibleChapterIndices(railWidth);

        return MouseRegion(
          cursor: widget.totalSeconds > 0
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (e) {
            if (!_hovered) {
              setState(() => _hovered = true);
            }
            _updateHoverOrScrub(
              e.localPosition.dx,
              railWidth,
              visibleChapters,
              isDrag: false,
            );
          },
          onHover: (e) {
            _updateHoverOrScrub(
              e.localPosition.dx,
              railWidth,
              visibleChapters,
              isDrag: false,
            );
          },
          onExit: (_) {
            setState(() {
              _hovered = false;
              if (!_dragging) {
                _snappedChapterIndex = null;
              }
            });
            if (!_dragging) {
              widget.previewNotifier.value = null;
              widget.thumbnailService?.requestPreview(null);
            }
          },
          child: GestureDetector(
            key: const ValueKey('video_capsule_progress_rail'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              widget.onUserInteraction?.call();
              final resolved = _resolvePointerTarget(
                d.localPosition.dx,
                railWidth,
                visibleChapters,
              );
              widget.onSeek(resolved.targetSeconds);
            },
            onHorizontalDragStart: (d) {
              widget.onUserInteraction?.call();
              setState(() => _dragging = true);
              _updateHoverOrScrub(
                d.localPosition.dx,
                railWidth,
                visibleChapters,
                isDrag: true,
              );
            },
            onHorizontalDragUpdate: (d) {
              if (!_dragging) return;
              widget.onUserInteraction?.call();
              _updateHoverOrScrub(
                d.localPosition.dx,
                railWidth,
                visibleChapters,
                isDrag: true,
              );
            },
            onHorizontalDragEnd: (_) {
              if (!_dragging) return;
              final target = widget.dragSecondsNotifier.value;
              setState(() {
                _dragging = false;
                if (!_hovered) {
                  _snappedChapterIndex = null;
                }
              });
              widget.dragSecondsNotifier.value = null;
              if (!_hovered) {
                widget.previewNotifier.value = null;
                widget.thumbnailService?.requestPreview(null);
              }
              if (target != null) {
                widget.onSeek(target);
              }
            },
            onHorizontalDragCancel: () {
              if (!_dragging) return;
              setState(() {
                _dragging = false;
                if (!_hovered) {
                  _snappedChapterIndex = null;
                }
              });
              widget.dragSecondsNotifier.value = null;
              if (!_hovered) {
                widget.previewNotifier.value = null;
                widget.thumbnailService?.requestPreview(null);
              }
            },
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(
                end: isActive
                    ? VideoPlaybackCapsule.railHoverHeight
                    : VideoPlaybackCapsule.railRestHeight,
              ),
              duration: KonataTheme.motionFast,
              curve: Curves.easeOutCubic,
              builder: (context, animatedRailHeight, _) {
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 1. 紧贴胶囊平直顶边（y = 0）的连续完整底轨、缓冲条与已播填充条。
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: animatedRailHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.trackColor,
                          borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(animatedRailHeight),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(animatedRailHeight),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ValueListenableBuilder<Duration>(
                                valueListenable: widget.bufferedListenable,
                                builder: (context, buffered, _) {
                                  final bufRatio =
                                      ((buffered.inMilliseconds / 1000.0) /
                                              widget.totalSeconds)
                                          .clamp(0.0, 1.0);
                                  return Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: bufRatio,
                                      heightFactor: 1.0,
                                      child: ColoredBox(
                                        color: widget.bufferedColor,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              _LiveRatioBuilder(
                                totalSeconds: widget.totalSeconds,
                                positionListenable: widget.positionListenable,
                                dragSecondsNotifier: widget.dragSecondsNotifier,
                                builder: (ratio, _) {
                                  return Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: ratio,
                                      heightFactor: 1.0,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: widget.fillColor,
                                          borderRadius: BorderRadius.horizontal(
                                            right: Radius.circular(
                                              animatedRailHeight,
                                            ),
                                          ),
                                          boxShadow: widget.isDark
                                              ? [
                                                  BoxShadow(
                                                    color: widget.fillColor
                                                        .withValues(
                                                          alpha: isActive
                                                              ? 0.56
                                                              : 0.36,
                                                        ),
                                                    blurRadius: isActive
                                                        ? 8
                                                        : 4,
                                                  ),
                                                ]
                                              : null,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 2. 顶边 100% 平齐（y = 0）内指圆角倒三角章节点：已播实心融合，未播柔和弱化，磁吸放大 1.28x。
                    if (visibleChapters.isNotEmpty)
                      _LiveRatioBuilder(
                        totalSeconds: widget.totalSeconds,
                        positionListenable: widget.positionListenable,
                        dragSecondsNotifier: widget.dragSecondsNotifier,
                        builder: (_, currentSec) {
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (final idx in visibleChapters)
                                _buildChapterTriangleMarker(
                                  chapter: widget.chapters[idx],
                                  railWidth: railWidth,
                                  passed:
                                      currentSec >=
                                      widget.chapters[idx].startSeconds,
                                  snapped: idx == _snappedChapterIndex,
                                ),
                            ],
                          );
                        },
                      ),
                    // 3. 悬停/拖拽显示的圆形播放头：圆心严格垂直居中对齐轨道中心线（dy = railHeight / 2）。
                    if (isActive)
                      _LiveRatioBuilder(
                        totalSeconds: widget.totalSeconds,
                        positionListenable: widget.positionListenable,
                        dragSecondsNotifier: widget.dragSecondsNotifier,
                        builder: (ratio, _) {
                          const thumbSize =
                              VideoPlaybackCapsule.playheadThumbSize;
                          final thumbLeft = (ratio * railWidth - thumbSize / 2)
                              .clamp(
                                -thumbSize * 0.5,
                                railWidth - thumbSize * 0.5,
                              );
                          final thumbTop =
                              animatedRailHeight * 0.5 - thumbSize * 0.5;
                          return Positioned(
                            left: thumbLeft,
                            top: thumbTop,
                            child: IgnorePointer(
                              child: Container(
                                key: const ValueKey(
                                  'video_capsule_playhead_thumb',
                                ),
                                width: thumbSize,
                                height: thumbSize,
                                decoration: BoxDecoration(
                                  color: widget.fillColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: widget.isDark
                                        ? const Color(0xFF141822)
                                        : KonataTheme.pureWhite,
                                    width: 1.5,
                                  ),
                                  boxShadow: const <BoxShadow>[
                                    BoxShadow(
                                      color: Color(0x59000000),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildChapterTriangleMarker({
    required PlaybackChapter chapter,
    required double railWidth,
    required bool passed,
    required bool snapped,
  }) {
    const triW = VideoPlaybackCapsule.chapterTriangleWidth;
    const triH = VideoPlaybackCapsule.chapterTriangleHeight;
    final ratio = (chapter.startSeconds / widget.totalSeconds).clamp(0.0, 1.0);
    final maxCenter = math.max(triW * 0.5, railWidth - triW * 0.5);
    final centerX = (ratio * railWidth).clamp(triW * 0.5, maxCenter);
    final color = passed
        ? widget.fillColor
        : widget.fillColor.withValues(alpha: widget.isDark ? 0.42 : 0.40);

    return Positioned(
      left: centerX - triW * 0.5,
      top: 0.0,
      child: IgnorePointer(
        child: AnimatedScale(
          scale: snapped ? VideoPlaybackCapsule.chapterTriangleHoverScale : 1.0,
          alignment: Alignment.topCenter,
          duration: KonataTheme.motionFast,
          curve: Curves.easeOutCubic,
          child: SizedBox(
            key: ValueKey('video_chapter_marker_${chapter.index}'),
            width: triW,
            height: triH,
            child: CustomPaint(
              painter: _ChapterInvertedTrianglePainter(color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveRatioBuilder extends StatelessWidget {
  const _LiveRatioBuilder({
    required this.totalSeconds,
    required this.positionListenable,
    required this.dragSecondsNotifier,
    required this.builder,
  });

  final double totalSeconds;
  final ValueListenable<Duration> positionListenable;
  final ValueListenable<double?> dragSecondsNotifier;
  final Widget Function(double ratio, double currentSeconds) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: dragSecondsNotifier,
      builder: (context, dragSec, _) {
        if (dragSec != null) {
          final ratio = totalSeconds > 0
              ? (dragSec / totalSeconds).clamp(0.0, 1.0)
              : 0.0;
          return builder(ratio, dragSec);
        }
        return ValueListenableBuilder<Duration>(
          valueListenable: positionListenable,
          builder: (context, pos, _) {
            final sec = pos.inMilliseconds / 1000.0;
            final ratio = totalSeconds > 0
                ? (sec / totalSeconds).clamp(0.0, 1.0)
                : 0.0;
            return builder(ratio, sec);
          },
        );
      },
    );
  }
}

/// 顶边平齐（`y = 0`）、向胶囊内部微指的圆角倒三角章节点画笔（`10×7.5px` 比例）。
class _ChapterInvertedTrianglePainter extends CustomPainter {
  const _ChapterInvertedTrianglePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final path = Path()
      ..moveTo(w * 0.03, 0.0)
      ..lineTo(w * 0.97, 0.0)
      ..lineTo(w * 0.585, h * 0.84)
      ..quadraticBezierTo(w * 0.5, h * 0.987, w * 0.415, h * 0.84)
      ..close();
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ChapterInvertedTrianglePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

/// 胶囊外轮廓描边画笔：有活跃顶沿进度条时让出平直顶段，避免双层白线夹缝。
class _VideoCapsuleBorderPainter extends CustomPainter {
  const _VideoCapsuleBorderPainter({
    required this.borderColor,
    required this.omitTopRailSpan,
    required this.railHorizontalInset,
  });

  final Color borderColor;
  final bool omitTopRailSpan;
  final double railHorizontalInset;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const strokeWidth = 1.0;
    const half = strokeWidth * 0.5;
    final r = (size.height - strokeWidth) * 0.5;
    if (r <= 0) return;

    final paint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;

    if (!omitTopRailSpan || size.width <= railHorizontalInset * 2 + 2) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            half,
            half,
            size.width - strokeWidth,
            size.height - strokeWidth,
          ),
          Radius.circular(r),
        ),
        paint,
      );
      return;
    }

    final rightArcRect = Rect.fromLTWH(
      size.width - half - r * 2,
      half,
      r * 2,
      r * 2,
    );
    final leftArcRect = Rect.fromLTWH(half, half, r * 2, r * 2);

    final path = Path()
      ..moveTo(size.width - half - r, half)
      ..arcTo(rightArcRect, -math.pi / 2, math.pi, false)
      ..lineTo(half + r, size.height - half)
      ..arcTo(leftArcRect, math.pi / 2, math.pi, false);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _VideoCapsuleBorderPainter oldDelegate) {
    return oldDelegate.borderColor != borderColor ||
        oldDelegate.omitTopRailSpan != omitTopRailSpan ||
        oldDelegate.railHorizontalInset != railHorizontalInset;
  }
}

class _ThumbnailHoverBubble extends StatelessWidget {
  const _ThumbnailHoverBubble({
    super.key,
    required this.targetSeconds,
    required this.snappedChapterIndex,
    required this.thumbnailService,
    required this.chapters,
  });

  final double targetSeconds;
  final int? snappedChapterIndex;
  final MpvThumbnailService? thumbnailService;
  final List<PlaybackChapter> chapters;

  PlaybackChapter? _resolveChapter() {
    final snapIdx = snappedChapterIndex;
    if (snapIdx != null && snapIdx >= 0 && snapIdx < chapters.length) {
      return chapters[snapIdx];
    }
    PlaybackChapter? matched;
    for (final ch in chapters) {
      if (ch.startSeconds <= targetSeconds + 0.25) {
        matched = ch;
      } else {
        break;
      }
    }
    return matched;
  }

  Widget _buildFrameSlot(Uint8List? frameBytes, Color secondaryFg) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        KonataPlaybackTokens.thumbnailPreviewRadius,
      ),
      child: Container(
        width: KonataPlaybackTokens.thumbnailPreviewDisplayWidth,
        height: KonataPlaybackTokens.thumbnailPreviewDisplayHeight,
        color: KonataTheme.scrimBlackStrong,
        child: frameBytes != null && frameBytes.isNotEmpty
            ? Image.memory(
                frameBytes,
                width: KonataPlaybackTokens.thumbnailPreviewDisplayWidth,
                height: KonataPlaybackTokens.thumbnailPreviewDisplayHeight,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    Icons.movie_outlined,
                    size: 22,
                    color: secondaryFg,
                  ),
                ),
              )
            : Center(
                child: Icon(Icons.movie_outlined, size: 22, color: secondaryFg),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final chapter = _resolveChapter();
    final timeLabel = PlaybackRecordHelper.formatClock(
      math.max(0, targetSeconds.round()),
    );
    final chapterTitle = chapter?.title.trim();

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: KonataPlaybackTokens.popoverSurface(p),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: KonataPlaybackTokens.glassBorder(p),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: KonataPlaybackTokens.shadowColor(p),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (thumbnailService != null)
            ListenableBuilder(
              listenable: thumbnailService!,
              builder: (context, _) {
                final bytes = thumbnailService!.resolvePreviewFrame(
                  targetSeconds,
                );
                return _buildFrameSlot(bytes, p.textSecondary);
              },
            )
          else
            _buildFrameSlot(null, p.textSecondary),
          const SizedBox(height: 5),
          SizedBox(
            width: KonataPlaybackTokens.thumbnailPreviewDisplayWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (chapterTitle != null && chapterTitle.isNotEmpty) ...[
                  Flexible(
                    child: Text(
                      chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: 11.0,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  timeLabel,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: KonataPlaybackTokens.tabularNumbers,
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
