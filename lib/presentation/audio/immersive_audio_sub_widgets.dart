import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/providers/artwork_provider.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/playback_formatters.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import 'smart_cover_framing.dart';

/// 独立歌词行叶子组件：仅当自身高亮态或邻近模糊阶梯变化时重建。
class ImmersiveLyricLineLeaf extends ConsumerWidget {
  /// 创建独立歌词行叶子。
  const ImmersiveLyricLineLeaf({
    super.key,
    required this.index,
    required this.line,
    required this.compact,
    required this.userScrolling,
    required this.onSeekLine,
  });

  final int index;
  final LrcCueLine line;
  final bool compact;
  final bool userScrolling;
  final VoidCallback onSeekLine;

  static int _distanceBucket(int lineIdx, int activeIdx) {
    if (activeIdx < 0) return 0;
    final d = (lineIdx - activeIdx).abs();
    if (d == 0) return 0;
    if (d == 1) return 1;
    if (d == 2) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final status = ref.watch(
      audioPlaybackProvider.select(
        (s) => (
          isActive: s.activeLyricIndex == index,
          bucket: _distanceBucket(index, s.activeLyricIndex),
        ),
      ),
    );
    final isActive = status.isActive;
    final blurSigma = userScrolling
        ? 0.0
        : switch (status.bucket) {
            0 => 0.0,
            1 => KonataPlaybackTokens.lyricBlurStep1,
            2 => KonataPlaybackTokens.lyricBlurStep2,
            _ => KonataPlaybackTokens.lyricBlurStepFar,
          };

    final activeSize = compact
        ? 18.0
        : KonataPlaybackTokens.lyricActiveFontSize;
    final inactiveSize = compact
        ? 14.5
        : KonataPlaybackTokens.lyricInactiveFontSize;

    final rowContent = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSeekLine,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: KonataAdaptiveTokens.isAndroid
              ? KonataAdaptiveTokens.touchTarget
              : 0,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: compact ? 7 : 10,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  color: isActive ? p.textPrimary : p.textSecondary,
                  fontSize: isActive ? activeSize : inactiveSize,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  height: 1.35,
                  shadows: isActive
                      ? [
                          Shadow(
                            color: p.isDark
                                ? Colors.white.withValues(alpha: 0.32)
                                : Colors.black.withValues(alpha: 0.10),
                            blurRadius: 16,
                          ),
                        ]
                      : null,
                ),
                child: Text(line.primaryText),
              ),
              for (final sec in line.secondaryLines) ...[
                const SizedBox(height: 4),
                Text(
                  sec,
                  style: TextStyle(
                    color: isActive ? p.textSecondary : p.textMuted,
                    fontSize: KonataPlaybackTokens.lyricSecondaryFontSize,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return RepaintBoundary(
      child: blurSigma > 0.05
          ? ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
              ),
              child: rowContent,
            )
          : rowContent,
    );
  }
}

/// 手机竖屏中段两行实时歌词预览叶子（重绘隔离，无同步歌词时不渲染冗余提示文案）。
class ImmersiveTwoLineLyricPreviewLeaf extends ConsumerWidget {
  /// 创建两行实时歌词预览叶子。
  const ImmersiveTwoLineLyricPreviewLeaf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final snap = ref.watch(
      audioPlaybackProvider.select(
        (s) => (lrc: s.lrcDocument, idx: s.activeLyricIndex),
      ),
    );
    final lines = snap.lrc?.lines ?? const <LrcCueLine>[];
    if (lines.isEmpty) {
      return const SizedBox.shrink();
    }

    final activeIdx = snap.idx >= 0 && snap.idx < lines.length ? snap.idx : 0;
    final primary = lines[activeIdx].primaryText;
    final secondary = lines[activeIdx].secondaryLines.isNotEmpty
        ? lines[activeIdx].secondaryLines.first
        : (activeIdx + 1 < lines.length
              ? lines[activeIdx + 1].primaryText
              : '');

    return RepaintBoundary(
      child: SizedBox(
        height: 42,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              primary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (secondary.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                secondary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textSecondary, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 桌面与平板底部播控胶囊进度隔离叶子：仅该叶子订阅 `positionSeconds` 与 `durationSeconds`。
class ImmersiveAudioCapsuleDockLeaf extends ConsumerWidget {
  /// 创建底部播控胶囊进度隔离叶子。
  const ImmersiveAudioCapsuleDockLeaf({
    super.key,
    required this.isPlaying,
    required this.loopMode,
    required this.notifier,
    this.leading,
    this.title,
    this.trailingCenterButtons = const [],
    this.rightSlot,
    this.maxWidth,
  });

  final Widget? leading;
  final String? title;
  final bool isPlaying;
  final AudioLoopMode loopMode;
  final AudioPlaybackNotifier notifier;
  final List<Widget> trailingCenterButtons;
  final Widget? rightSlot;
  final double? maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timing = ref.watch(
      audioPlaybackProvider.select(
        (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
      ),
    );
    return RepaintBoundary(
      child: KonataPlaybackCapsule(
        maxWidth: maxWidth,
        leading: leading,
        title: title,
        positionSeconds: timing.pos,
        durationSeconds: timing.dur,
        isPlaying: isPlaying,
        onTogglePlayPause: notifier.togglePlayPause,
        onSeek: notifier.seekRelativeTrackSeconds,
        onPrevious: notifier.previous,
        onNext: notifier.next,
        leadingCenterButton: KonataAudioLoopButton(
          icon: switch (loopMode) {
            AudioLoopMode.sequence => Icons.trending_flat_rounded,
            AudioLoopMode.loopAll => Icons.repeat_rounded,
            AudioLoopMode.loopOne => Icons.repeat_one_rounded,
          },
          tooltip: '循环模式：${loopMode.label}',
          highlighted: loopMode != AudioLoopMode.sequence,
          onTap: notifier.cycleLoopMode,
        ),
        trailingCenterButtons: trailingCenterButtons,
        rightSlot: rightSlot,
      ),
    );
  }
}

/// 手机端独立进度滑轨与等宽时间叶子控件（重绘隔离）。
class ImmersiveTouchAudioScrubberLeaf extends ConsumerStatefulWidget {
  /// 创建手机端进度滑轨叶子。
  const ImmersiveTouchAudioScrubberLeaf({
    super.key,
    required this.notifier,
    this.compact = false,
  });

  final AudioPlaybackNotifier notifier;
  final bool compact;

  @override
  ConsumerState<ImmersiveTouchAudioScrubberLeaf> createState() =>
      _ImmersiveTouchAudioScrubberLeafState();
}

class _ImmersiveTouchAudioScrubberLeafState
    extends ConsumerState<ImmersiveTouchAudioScrubberLeaf> {
  double? _dragSeconds;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final timing = ref.watch(
      audioPlaybackProvider.select(
        (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
      ),
    );
    final total = timing.dur > 0 ? timing.dur : 0.0;
    final effective = (_dragSeconds ?? timing.pos).clamp(
      0.0,
      total > 0 ? total : 1.0,
    );
    final showHours = total >= 3600;
    final posText = PlaybackFormatters.formatMediaDuration(
      total > 0 ? effective : 0.0,
      alwaysShowHours: showHours,
    );
    final durText = PlaybackFormatters.formatMediaDuration(
      total,
      alwaysShowHours: showHours,
    );

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: p.progressFill,
              inactiveTrackColor: p.progressTrack,
              thumbColor: p.textPrimary,
            ),
            child: SizedBox(
              height: widget.compact ? 26 : 34,
              child: Slider(
                value: total > 0 ? (effective / total).clamp(0.0, 1.0) : 0.0,
                onChangeStart: total > 0
                    ? (v) => setState(() => _dragSeconds = v * total)
                    : null,
                onChanged: total > 0
                    ? (v) => setState(() => _dragSeconds = v * total)
                    : null,
                onChangeEnd: total > 0
                    ? (v) {
                        final target = v * total;
                        setState(() => _dragSeconds = null);
                        widget.notifier.seekRelativeTrackSeconds(target);
                      }
                    : null,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  posText,
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: 11.5,
                    fontFeatures: KonataPlaybackTokens.tabularNumbers,
                  ),
                ),
                Text(
                  durText,
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: 11.5,
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

/// 沉浸页无边框播放队列行。
class ImmersiveBorderlessQueueRow extends StatefulWidget {
  /// 创建无边框播放队列行。
  const ImmersiveBorderlessQueueRow({
    super.key,
    required this.row,
    required this.isPlaying,
    required this.onTap,
  });

  final AudioQueueDisplayRow row;
  final bool isPlaying;
  final VoidCallback onTap;

  @override
  State<ImmersiveBorderlessQueueRow> createState() =>
      _ImmersiveBorderlessQueueRowState();
}

class _ImmersiveBorderlessQueueRowState
    extends State<ImmersiveBorderlessQueueRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final row = widget.row;
    final active = row.isActiveTrack;
    final isSubTrack = row.kind == AudioQueueDisplayRowKind.cueSubTrack;
    final isExpandedParent = row.isExpandedParent;

    final color = (active || isExpandedParent)
        ? p.textPrimary
        : (_hovered ? p.textPrimary.withValues(alpha: 0.92) : p.textSecondary);
    final durationText = row.duration > Duration.zero
        ? PlaybackFormatters.formatMediaDuration(
            row.duration.inMilliseconds / 1000.0,
          )
        : '';
    final subtitleText = row.subtitle.trim();

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.touchTarget
                : 0,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              isSubTrack ? 30 : 10,
              isSubTrack ? 7 : 9,
              10,
              isSubTrack ? 7 : 9,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: isSubTrack ? 24 : 30,
                  child: active
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: _AnimatedPlayingEqualizer(
                            isPlaying: widget.isPlaying,
                            color: p.textPrimary,
                          ),
                        )
                      : (row.trackPrefix.isEmpty
                            ? const SizedBox.shrink()
                            : Text(
                                row.trackPrefix,
                                style: TextStyle(
                                  color: isExpandedParent
                                      ? p.textPrimary
                                      : (_hovered
                                            ? p.textSecondary
                                            : p.textMuted),
                                  fontSize: 12.5,
                                  fontWeight: isExpandedParent
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  fontFeatures:
                                      KonataPlaybackTokens.tabularNumbers,
                                ),
                              )),
                ),
                SizedBox(width: isSubTrack ? 6 : 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 140),
                        curve: Curves.easeOutCubic,
                        style: TextStyle(
                          color: color,
                          fontSize: active
                              ? (isSubTrack ? 15.0 : 16.0)
                              : (isSubTrack ? 13.8 : 14.5),
                          fontWeight: (active || isExpandedParent)
                              ? FontWeight.w600
                              : FontWeight.w400,
                          shadows: active
                              ? [
                                  Shadow(
                                    color: p.isDark
                                        ? Colors.white.withValues(alpha: 0.42)
                                        : Colors.black.withValues(alpha: 0.10),
                                    blurRadius: 14,
                                  ),
                                ]
                              : null,
                        ),
                        child: EllipsisTextWithTooltip(
                          text: row.title,
                          maxLines: 1,
                          style: const TextStyle(),
                        ),
                      ),
                      if (subtitleText.isNotEmpty) ...[
                        const SizedBox(height: 2.5),
                        EllipsisTextWithTooltip(
                          text: subtitleText,
                          maxLines: 1,
                          style: TextStyle(
                            color: (active || isExpandedParent)
                                ? p.textSecondary
                                : (_hovered ? p.textSecondary : p.textMuted),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (durationText.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Text(
                    durationText,
                    style: TextStyle(
                      color: (active || isExpandedParent)
                          ? p.textPrimary
                          : (_hovered ? p.textSecondary : p.textMuted),
                      fontSize: 12,
                      fontFeatures: KonataPlaybackTokens.tabularNumbers,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedPlayingEqualizer extends StatefulWidget {
  const _AnimatedPlayingEqualizer({
    required this.isPlaying,
    required this.color,
  });

  final bool isPlaying;
  final Color color;

  @override
  State<_AnimatedPlayingEqualizer> createState() =>
      _AnimatedPlayingEqualizerState();
}

class _AnimatedPlayingEqualizerState extends State<_AnimatedPlayingEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  bool get _isWidgetTestBinding => WidgetsBinding.instance.runtimeType
      .toString()
      .contains('TestWidgetsFlutterBinding');

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    );
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _AnimatedPlayingEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncTicker();
    }
  }

  void _syncTicker() {
    if (widget.isPlaying && !_isWidgetTestBinding) {
      if (!_ctrl.isAnimating) {
        _ctrl.repeat();
      }
    } else {
      if (_ctrl.isAnimating) {
        _ctrl.stop();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: 18,
        height: 16,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            const phases = <double>[0.0, 1.35, 2.55, 0.75];
            const speeds = <double>[1.0, 2.0, 1.0, 2.0];
            const pausedHeights = <double>[0.32, 0.62, 0.44, 0.28];
            final t = _ctrl.value * 2 * math.pi;

            return Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(width: 2.2),
                  Builder(
                    builder: (_) {
                      final ratio = widget.isPlaying
                          ? (0.24 +
                                0.76 *
                                    (0.5 +
                                        0.5 *
                                            math.sin(
                                              t * speeds[i] + phases[i],
                                            )))
                          : pausedHeights[i];
                      return Container(
                        width: 2.6,
                        height: (15.0 * ratio).clamp(3.2, 15.0),
                        decoration: BoxDecoration(
                          color: widget.color,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      );
                    },
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 三端共用的专辑封面 + 底部镜像渐变倒影组件（自动按父容器宽高自适应，零纵向溢出）。
class ImmersiveCoverWithReflection extends ConsumerWidget {
  /// 创建带镜像倒影的专辑封面。
  const ImmersiveCoverWithReflection({
    super.key,
    required this.cover,
    required this.maxCoverSize,
    this.borderRadius = KonataPlaybackTokens.albumCoverRadius,
    this.reflectionRatio = 0.21,
  });

  final AudioCoverSource cover;
  final double maxCoverSize;
  final double borderRadius;
  final double reflectionRatio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final loader = ref.watch(tmdbImageLoaderProvider);

    Widget buildArtwork(double size, Alignment coverAlignment) {
      switch (cover) {
        case MemoryAudioCover(:final bytes):
          return Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            alignment: coverAlignment,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          );
        case ManagedPosterAudioCover(
          :final url,
          :final workId,
          :final revision,
        ):
          return ManagedImage(
            url,
            key: ValueKey('imm_cov_${workId}_${url}_$revision'),
            loader: loader,
            owner: workId,
            width: size,
            height: size,
            decodeWidth: 800,
            fit: BoxFit.cover,
            alignment: coverAlignment,
            errorBuilder: (_, _, _) => _emptyArt(p, size),
          );
        case EmptyAudioCover():
          return _emptyArt(p, size);
      }
    }

    return SmartCoverAlignmentBuilder(
      cover: cover,
      loader: loader,
      builder: (context, coverAlignment) => LayoutBuilder(
        builder: (context, constraints) {
          final safeRatio = reflectionRatio.clamp(0.10, 0.30);
          final maxByWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : maxCoverSize;
          final maxByHeight = constraints.maxHeight.isFinite
              ? constraints.maxHeight / (1.0 + safeRatio)
              : maxCoverSize;
          final rawSide = math.min(
            maxCoverSize,
            math.min(maxByWidth, maxByHeight),
          );
          final minSide = math.min(44.0, maxCoverSize);
          if (rawSide < 24.0) {
            return const SizedBox.shrink();
          }
          final coverSize = rawSide.clamp(minSide, maxCoverSize);
          final reflectionHeight = math
              .min(
                KonataPlaybackTokens.albumReflectionHeight,
                coverSize * safeRatio,
              )
              .clamp(8.0, KonataPlaybackTokens.albumReflectionHeight);

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Hero(
                tag: 'konata_audio_cover_hero',
                child: Container(
                  width: coverSize,
                  height: coverSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(borderRadius),
                    boxShadow: [
                      BoxShadow(
                        color: KonataPlaybackTokens.shadowColor(p),
                        blurRadius: 34,
                        offset: const Offset(0, 16),
                      ),
                    ],
                    border: Border.all(
                      color: KonataPlaybackTokens.glassBorder(p),
                      width: 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(borderRadius),
                    child: buildArtwork(coverSize, coverAlignment),
                  ),
                ),
              ),
              SizedBox(
                key: const ValueKey('immersive_cover_reflection'),
                width: coverSize,
                height: reflectionHeight,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    maxHeight: coverSize,
                    child: ShaderMask(
                      shaderCallback: (bounds) =>
                          const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors:
                                KonataPlaybackTokens.albumReflectionMaskColors,
                            stops: [0.0, 0.38, 0.94],
                          ).createShader(
                            Rect.fromLTWH(0, 0, coverSize, reflectionHeight),
                          ),
                      blendMode: BlendMode.dstIn,
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.diagonal3Values(1.0, -1.0, 1.0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(borderRadius),
                          child: buildArtwork(coverSize, coverAlignment),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _emptyArt(KonataPalette p, double size) {
    return Container(
      width: size,
      height: size,
      color: KonataPlaybackTokens.softFill(p),
      alignment: Alignment.center,
      child: Icon(
        Icons.album_rounded,
        size: size * 0.34,
        color: p.textMuted.withValues(alpha: 0.56),
      ),
    );
  }
}

/// 底部控制胶囊左侧微缩圆角封面。
class ImmersiveMicroCover extends ConsumerWidget {
  /// 创建底部胶囊微缩封面。
  const ImmersiveMicroCover({super.key, required this.cover});

  final AudioCoverSource cover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final loader = ref.watch(tmdbImageLoaderProvider);
    const size = 38.0;

    return SmartCoverAlignmentBuilder(
      cover: cover,
      loader: loader,
      builder: (context, coverAlignment) {
        Widget art;
        switch (cover) {
          case MemoryAudioCover(:final bytes):
            art = Image.memory(
              bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: coverAlignment,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            );
          case ManagedPosterAudioCover(
            :final url,
            :final workId,
            :final revision,
          ):
            art = ManagedImage(
              url,
              key: ValueKey('imm_micro_${workId}_${url}_$revision'),
              loader: loader,
              owner: workId,
              width: size,
              height: size,
              decodeWidth: 160,
              fit: BoxFit.cover,
              alignment: coverAlignment,
              errorBuilder: (_, _, _) => _fallback(p, size),
            );
          case EmptyAudioCover():
            art = _fallback(p, size);
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(width: size, height: size, child: art),
        );
      },
    );
  }

  Widget _fallback(KonataPalette p, double size) {
    return Container(
      width: size,
      height: size,
      color: KonataPlaybackTokens.softFill(p),
      alignment: Alignment.center,
      child: Icon(Icons.music_note_rounded, size: 18, color: p.textSecondary),
    );
  }
}
