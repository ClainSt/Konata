import 'dart:async';
import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';

/// 仅直连控制器叶子 `ValueNotifier<Duration>` 的纯白流光音频进度条，拖动过程绝不重建外围舞台。
class AudioLeafDurationScrubber extends StatefulWidget {
  /// 构造叶子进度条组件。
  const AudioLeafDurationScrubber({
    super.key,
    required this.positionListenable,
    required this.durationListenable,
    required this.onSeekTo,
    this.compact = false,
  });

  /// 叶子当前逻辑播放位置。
  final ValueListenable<Duration> positionListenable;

  /// 叶子当前曲目总时长。
  final ValueListenable<Duration> durationListenable;

  /// 松手定位回调。
  final Future<void> Function(Duration position) onSeekTo;

  /// 是否使用紧凑视觉尺寸（适配手机端）。
  final bool compact;

  @override
  State<AudioLeafDurationScrubber> createState() =>
      _AudioLeafDurationScrubberState();
}

class _AudioLeafDurationScrubberState extends State<AudioLeafDurationScrubber> {
  double? _draggingSeconds;
  bool _hovering = false;

  void _updateDragFraction(double dx, double width, double totalSec) {
    if (totalSec <= 0.1 || width <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    setState(() => _draggingSeconds = ratio * totalSec);
  }

  void _commitDragFraction(double dx, double width, double totalSec) {
    if (totalSec <= 0.1 || width <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    final targetSec = ratio * totalSec;
    setState(() => _draggingSeconds = null);
    unawaited(
      widget.onSeekTo(Duration(milliseconds: (targetSec * 1000.0).round())),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: widget.durationListenable,
        builder: (context, duration, _) {
          final totalSec = duration.inMilliseconds > 0
              ? duration.inMilliseconds / 1000.0
              : 0.0;
          return ValueListenableBuilder<Duration>(
            valueListenable: widget.positionListenable,
            builder: (context, position, _) {
              final rawPosSec = position.inMilliseconds / 1000.0;
              final displaySec =
                  _draggingSeconds ??
                  (totalSec > 0 ? rawPosSec.clamp(0.0, totalSec) : 0.0);
              final fraction = totalSec > 0.1
                  ? (displaySec / totalSec).clamp(0.0, 1.0)
                  : 0.0;
              final isActive = _hovering || _draggingSeconds != null;
              final trackHeight = isActive ? 4.0 : (widget.compact ? 3.0 : 3.5);
              final thumbSize = isActive ? 12.0 : 9.0;
              final timeStyle = TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: widget.compact ? 11.0 : 11.5,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w500,
              );

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MouseRegion(
                    cursor: totalSec > 0.1
                        ? SystemMouseCursors.click
                        : MouseCursor.defer,
                    onEnter: (_) => setState(() => _hovering = true),
                    onExit: (_) => setState(() => _hovering = false),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final trackW = math.max(1.0, constraints.maxWidth);
                        final thumbLeft = (trackW * fraction - thumbSize * 0.5)
                            .clamp(0.0, math.max(0.0, trackW - thumbSize))
                            .toDouble();
                        return GestureDetector(
                          key: const ValueKey('audio_leaf_scrubber_track'),
                          behavior: HitTestBehavior.opaque,
                          onTapDown: totalSec > 0.1
                              ? (details) => _commitDragFraction(
                                  details.localPosition.dx,
                                  trackW,
                                  totalSec,
                                )
                              : null,
                          onHorizontalDragStart: totalSec > 0.1
                              ? (details) => _updateDragFraction(
                                  details.localPosition.dx,
                                  trackW,
                                  totalSec,
                                )
                              : null,
                          onHorizontalDragUpdate: totalSec > 0.1
                              ? (details) => _updateDragFraction(
                                  details.localPosition.dx,
                                  trackW,
                                  totalSec,
                                )
                              : null,
                          onHorizontalDragEnd: (_) {
                            final sec = _draggingSeconds;
                            if (sec == null) return;
                            setState(() => _draggingSeconds = null);
                            unawaited(
                              widget.onSeekTo(
                                Duration(milliseconds: (sec * 1000.0).round()),
                              ),
                            );
                          },
                          child: SizedBox(
                            height: 24,
                            child: Stack(
                              alignment: Alignment.centerLeft,
                              children: [
                                Container(
                                  height: trackHeight,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.20),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                FractionallySizedBox(
                                  widthFactor: fraction,
                                  child: Container(
                                    height: trackHeight,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.94,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.42,
                                          ),
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: thumbLeft,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 120),
                                    width: thumbSize,
                                    height: thumbSize,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.55,
                                          ),
                                          blurRadius: isActive ? 10 : 6,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          PlaybackRecordHelper.formatClock(displaySec.round()),
                          style: timeStyle,
                        ),
                        Text(
                          totalSec > 0
                              ? PlaybackRecordHelper.formatClock(
                                  totalSec.round(),
                                )
                              : '--:--',
                          style: timeStyle,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Salt 宽屏烟熏胶囊顶边细白发光进度线：点击或拖动顶边即可定位曲目进度。
class _TopEdgeGlowProgressBar extends StatefulWidget {
  const _TopEdgeGlowProgressBar({
    required this.positionListenable,
    required this.durationListenable,
    required this.onSeekTo,
  });

  final ValueListenable<Duration> positionListenable;
  final ValueListenable<Duration> durationListenable;
  final Future<void> Function(Duration position) onSeekTo;

  @override
  State<_TopEdgeGlowProgressBar> createState() =>
      _TopEdgeGlowProgressBarState();
}

class _TopEdgeGlowProgressBarState extends State<_TopEdgeGlowProgressBar> {
  double? _draggingSeconds;
  bool _hovering = false;

  void _updateDrag(double dx, double width, double totalSec) {
    if (totalSec <= 0.1 || width <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    setState(() => _draggingSeconds = ratio * totalSec);
  }

  void _commitSeek(double dx, double width, double totalSec) {
    if (totalSec <= 0.1 || width <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    final sec = ratio * totalSec;
    setState(() => _draggingSeconds = null);
    unawaited(widget.onSeekTo(Duration(milliseconds: (sec * 1000.0).round())));
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: widget.durationListenable,
        builder: (context, duration, _) {
          final totalSec = duration.inMilliseconds > 0
              ? duration.inMilliseconds / 1000.0
              : 0.0;
          return ValueListenableBuilder<Duration>(
            valueListenable: widget.positionListenable,
            builder: (context, position, _) {
              final rawPosSec = position.inMilliseconds / 1000.0;
              final displaySec =
                  _draggingSeconds ??
                  (totalSec > 0 ? rawPosSec.clamp(0.0, totalSec) : 0.0);
              final fraction = totalSec > 0.1
                  ? (displaySec / totalSec).clamp(0.0, 1.0)
                  : 0.0;
              final active = _hovering || _draggingSeconds != null;
              final barH = active ? 3.5 : 2.2;

              return MouseRegion(
                cursor: totalSec > 0.1
                    ? SystemMouseCursors.click
                    : MouseCursor.defer,
                onEnter: (_) => setState(() => _hovering = true),
                onExit: (_) => setState(() => _hovering = false),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final w = math.max(1.0, constraints.maxWidth);
                    final dotSize = active ? 8.0 : 0.0;
                    final dotLeft = (w * fraction - dotSize * 0.5)
                        .clamp(0.0, math.max(0.0, w - dotSize))
                        .toDouble();
                    return GestureDetector(
                      key: const ValueKey('salt_smoke_top_progress_line'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: totalSec > 0.1
                          ? (d) => _commitSeek(d.localPosition.dx, w, totalSec)
                          : null,
                      onHorizontalDragStart: totalSec > 0.1
                          ? (d) => _updateDrag(d.localPosition.dx, w, totalSec)
                          : null,
                      onHorizontalDragUpdate: totalSec > 0.1
                          ? (d) => _updateDrag(d.localPosition.dx, w, totalSec)
                          : null,
                      onHorizontalDragEnd: (_) {
                        final sec = _draggingSeconds;
                        if (sec == null) return;
                        setState(() => _draggingSeconds = null);
                        unawaited(
                          widget.onSeekTo(
                            Duration(milliseconds: (sec * 1000.0).round()),
                          ),
                        );
                      },
                      child: SizedBox(
                        height: 12,
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.topLeft,
                          children: [
                            Container(
                              height: barH,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: fraction,
                              child: Container(
                                height: barH,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.94),
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.white.withValues(
                                        alpha: 0.55,
                                      ),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (dotSize > 0)
                              Positioned(
                                left: dotLeft,
                                top: -(dotSize - barH) * 0.5,
                                child: Container(
                                  width: dotSize,
                                  height: dotSize,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.white.withValues(
                                          alpha: 0.65,
                                        ),
                                        blurRadius: 10,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 仅直连播放进度与总时长通知器的紧凑双时钟标签，避免父级胶囊随帧率重建。
class _LeafCapsuleClock extends StatelessWidget {
  const _LeafCapsuleClock({
    required this.positionListenable,
    required this.durationListenable,
  });

  final ValueListenable<Duration> positionListenable;
  final ValueListenable<Duration> durationListenable;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Colors.white.withValues(alpha: 0.66),
      fontSize: 11.5,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: durationListenable,
        builder: (context, duration, _) {
          final totalSec = duration.inMilliseconds > 0
              ? (duration.inMilliseconds / 1000.0).round()
              : 0;
          return ValueListenableBuilder<Duration>(
            valueListenable: positionListenable,
            builder: (context, position, _) {
              final posSec = math.max(
                0,
                (position.inMilliseconds / 1000.0).round(),
              );
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(PlaybackRecordHelper.formatClock(posSec), style: style),
                  Text(
                    ' / ',
                    style: style.copyWith(
                      color: Colors.white.withValues(alpha: 0.36),
                    ),
                  ),
                  Text(
                    totalSec > 0
                        ? PlaybackRecordHelper.formatClock(totalSec)
                        : '--:--',
                    style: style.copyWith(
                      color: Colors.white.withValues(alpha: 0.50),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// 沉浸式音频舞台底部 Salt 超轻烟熏玻璃隐形播控胶囊。
class AudioPlaybackCapsule extends StatelessWidget {
  /// 构造沉浸音频控制胶囊。
  const AudioPlaybackCapsule({
    super.key,
    required this.controller,
    required this.snapshot,
    required this.sidePanels,
    required this.onToggleQueue,

    required this.onOpenSidePanel,
    this.onRelayToDesktop,
    this.onToggleDesktopMini,
    this.isQueueOpen = false,
    this.activeSidePanelId,
    this.compact = false,
  });

  /// 音频播放控制器。
  final AudioPlaybackController controller;

  /// 低频不可变会话快照。
  final AudioPlaybackSnapshot snapshot;

  /// 按 `PlayerMediaMode.audio` 过滤后的声明式扩展侧栏按钮。
  final List<PlayerSidePanelContribution> sidePanels;

  /// 开关队列侧栏或底部队列弹窗回调。
  final VoidCallback onToggleQueue;

  /// 点击打开外部扩展侧栏回调。
  final ValueChanged<PlayerSidePanelContribution> onOpenSidePanel;

  /// 桌面端外发接力回调（非空时显示接力按钮）。
  final VoidCallback? onRelayToDesktop;

  /// 桌面端切换顶置迷你窗回调。
  final VoidCallback? onToggleDesktopMini;

  /// 当前是否正展开队列面板。
  final bool isQueueOpen;

  /// 当前正打开的扩展侧栏标识。
  final String? activeSidePanelId;

  /// 紧凑宽度模式（适配独立紧凑视图）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final loopIcon = switch (snapshot.loopMode) {
      AudioLoopMode.sequence => Icons.trending_flat_rounded,
      AudioLoopMode.loopAll => Icons.repeat_rounded,
      AudioLoopMode.loopOne => Icons.repeat_one_rounded,
      AudioLoopMode.shuffle => Icons.shuffle_rounded,
    };
    final loopTooltip = switch (snapshot.loopMode) {
      AudioLoopMode.sequence => '顺序播放',
      AudioLoopMode.loopAll => '列表循环',
      AudioLoopMode.loopOne => '单曲循环',
      AudioLoopMode.shuffle => '随机播放',
    };
    final loopActive = snapshot.loopMode != AudioLoopMode.sequence;
    final quickSidePanels = sidePanels
        .where((panel) => panel.id != 'lyrics_control')
        .toList(growable: false);

    if (compact) {
      return Theme(
        data: KonataTheme.darkTheme(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: KonataAdaptiveBackdropBlur(
            filter: KonataTheme.blurFilterOverlay,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.085),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AudioLeafDurationScrubber(
                    positionListenable: controller.positionListenable,
                    durationListenable: controller.durationListenable,
                    onSeekTo: controller.seekToTrackPosition,
                    compact: true,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      KonataCapsuleIconButton(
                        icon: loopIcon,
                        tooltip: loopTooltip,
                        color: Colors.white.withValues(alpha: 0.80),
                        highlighted: loopActive,
                        onTap: controller.cycleLoopMode,
                        size: 18,
                        fixedSize: 34.0,
                      ),
                      KonataCapsuleIconButton(
                        icon: Icons.skip_previous_rounded,
                        tooltip: '上一曲',
                        color: Colors.white.withValues(alpha: 0.92),
                        onTap: () => unawaited(controller.previous()),
                        size: 24,
                        fixedSize: 40.0,
                      ),
                      _FrostedPlayPauseCircle(
                        playingListenable: controller.playingListenable,
                        onTap: () => unawaited(controller.togglePlayPause()),
                        diameter: 46,
                        iconSize: 26,
                      ),
                      KonataCapsuleIconButton(
                        icon: Icons.skip_next_rounded,
                        tooltip: '下一曲',
                        color: Colors.white.withValues(alpha: 0.92),
                        onTap: () => unawaited(controller.next(manual: true)),
                        size: 24,
                        fixedSize: 40.0,
                      ),
                      KonataCapsuleIconButton(
                        icon: isQueueOpen
                            ? Icons.lyrics_outlined
                            : Icons.queue_music_rounded,
                        tooltip: isQueueOpen ? '歌词' : '播放队列',
                        color: Colors.white.withValues(alpha: 0.84),
                        onTap: onToggleQueue,
                        size: 18,
                        fixedSize: 34.0,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final currentTitle = snapshot.currentItem?.title ?? '未在播放';
    return Theme(
      data: KonataTheme.darkTheme(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 880.0;
          final showVolume = maxW >= 600.0;
          final showSpecPill =
              maxW >= 680.0 && snapshot.formattedAudioSpec.isNotEmpty;

          return Container(
            key: const ValueKey('salt_smoke_playback_capsule'),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.34),
                  blurRadius: 34,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: KonataAdaptiveBackdropBlur(
                filter: KonataTheme.blurFilterOverlay,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.30),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                      width: 1.0,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 18, 10),
                        child: Row(
                          children: [
                            // 左侧：精简曲名 + 叶子实时进度时钟。
                            Expanded(
                              flex: 3,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    currentTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.94,
                                      ),
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  _LeafCapsuleClock(
                                    positionListenable:
                                        controller.positionListenable,
                                    durationListenable:
                                        controller.durationListenable,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 居中：通透播控簇（播放模式、上一曲、磨砂播放/暂停、下一曲）。
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                KonataCapsuleIconButton(
                                  icon: loopIcon,
                                  tooltip: loopTooltip,
                                  color: Colors.white.withValues(
                                    alpha: loopActive ? 0.96 : 0.68,
                                  ),
                                  highlighted: false,
                                  onTap: controller.cycleLoopMode,
                                  size: 18,
                                  fixedSize: 34.0,
                                ),
                                const SizedBox(width: 4),
                                KonataCapsuleIconButton(
                                  icon: Icons.skip_previous_rounded,
                                  tooltip: '上一曲',
                                  color: Colors.white.withValues(alpha: 0.92),
                                  onTap: () => unawaited(controller.previous()),
                                  size: 22,
                                  fixedSize: 38.0,
                                ),
                                const SizedBox(width: 6),
                                ValueListenableBuilder<bool>(
                                  valueListenable: controller.playingListenable,
                                  builder: (context, playing, _) =>
                                      KonataCapsuleIconButton(
                                        icon: playing
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        tooltip: playing ? '暂停' : '播放',
                                        color: Colors.white,
                                        fixedSize: 40,
                                        size: 24,
                                        onTap: () => unawaited(
                                          controller.togglePlayPause(),
                                        ),
                                      ),
                                ),
                                const SizedBox(width: 6),
                                KonataCapsuleIconButton(
                                  icon: Icons.skip_next_rounded,
                                  tooltip: '下一曲',
                                  color: Colors.white.withValues(alpha: 0.92),
                                  onTap: () =>
                                      unawaited(controller.next(manual: true)),
                                  size: 22,
                                  fixedSize: 38.0,
                                ),
                                KonataCapsuleIconButton(
                                  key: const ValueKey(
                                    'audio_desktop_queue_button',
                                  ),
                                  icon: isQueueOpen
                                      ? Icons.lyrics_outlined
                                      : Icons.queue_music_rounded,
                                  tooltip: isQueueOpen ? '歌词' : '播放队列',
                                  color: Colors.white,
                                  fixedSize: 34,
                                  size: 19,
                                  onTap: onToggleQueue,
                                ),
                              ],
                            ),
                            const SizedBox(width: 12),
                            // 右侧：音频规格、扩展侧栏按钮与音量滑块。
                            Expanded(
                              flex: 3,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (final panel in quickSidePanels) ...[
                                        KonataCapsuleIconButton(
                                          icon: KonataIconRegistry.resolve(
                                            panel.iconKey,
                                          ),
                                          tooltip: panel.label,
                                          color: Colors.white.withValues(
                                            alpha: 0.86,
                                          ),
                                          highlighted:
                                              activeSidePanelId == panel.id,
                                          size: 18,
                                          fixedSize: 34.0,
                                          onTap: () => onOpenSidePanel(panel),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      if (showSpecPill) ...[
                                        KonataSpecBadge(
                                          key: const ValueKey(
                                            'audio_format_badge',
                                          ),
                                          label: snapshot.formattedAudioSpec,
                                          highlighted: snapshot
                                              .audiophilePlan
                                              .safetyLimiterEngaged,
                                          darkOverlay: true,
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      if (onRelayToDesktop != null) ...[
                                        KonataCapsuleIconButton(
                                          icon: Icons.open_in_new_rounded,
                                          tooltip: '外部播放器',
                                          color: Colors.white.withValues(
                                            alpha: 0.82,
                                          ),
                                          size: 18,
                                          fixedSize: 34.0,
                                          onTap: onRelayToDesktop,
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      if (onToggleDesktopMini != null) ...[
                                        KonataCapsuleIconButton(
                                          icon: snapshot.isDesktopMiniWindow
                                              ? Icons.open_in_full_rounded
                                              : Icons
                                                    .picture_in_picture_alt_rounded,
                                          tooltip: snapshot.isDesktopMiniWindow
                                              ? '恢复窗口'
                                              : '桌面小窗',
                                          color: Colors.white.withValues(
                                            alpha: 0.82,
                                          ),
                                          highlighted:
                                              snapshot.isDesktopMiniWindow,
                                          size: 18,
                                          fixedSize: 34.0,
                                          onTap: onToggleDesktopMini,
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      if (showVolume)
                                        KonataVolumeControl(
                                          volume: snapshot.volume / 100.0,
                                          isMuted: snapshot.isMuted,
                                          onVolumeChanged: (v) => unawaited(
                                            controller.setVolume(v * 100.0),
                                          ),
                                          onToggleMute: () => unawaited(
                                            controller.toggleMute(),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 顶边细白发光进度线。
                      Positioned(
                        left: 30,
                        right: 30,
                        top: 0,
                        child: _TopEdgeGlowProgressBar(
                          positionListenable: controller.positionListenable,
                          durationListenable: controller.durationListenable,
                          onSeekTo: controller.seekToTrackPosition,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 烟熏玻璃胶囊内居中纯白磨砂圆形播放/暂停键。
class _FrostedPlayPauseCircle extends StatelessWidget {
  const _FrostedPlayPauseCircle({
    required this.playingListenable,
    required this.onTap,
    required this.diameter,
    required this.iconSize,
  });

  final ValueListenable<bool> playingListenable;
  final VoidCallback onTap;
  final double diameter;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: playingListenable,
      builder: (context, isPlaying, _) {
        return Semantics(
          button: true,
          label: isPlaying ? '暂停 (Space)' : '继续播放 (Space)',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                    width: 1.0,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: iconSize,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
