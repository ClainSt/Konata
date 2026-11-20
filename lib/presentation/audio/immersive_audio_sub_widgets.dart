import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/providers/artwork_provider.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../../domain/playback/playback_formatters.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_cd_disc_placeholder.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import 'immersive_karaoke_sweep_text.dart';
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
    this.activeSpanLine,
    this.nextLineStartSeconds,
  });

  final int index;
  final LrcCueLine line;
  final bool compact;
  final bool userScrolling;
  final VoidCallback onSeekLine;

  /// 可选主唱/和声并行逐字扫光片段行（仅高亮当前行挂载局部进度叶子，非当前行零订阅）。
  final ActiveSpanLyricLine? activeSpanLine;

  /// 下一行歌词起点秒数（供标准整行时间戳 LRC 计算精准匀速扫光时长）。
  final double? nextLineStartSeconds;

  static int _distanceBucket(int lineIdx, int activeIdx) {
    final d = (lineIdx - activeIdx).abs();
    if (d == 0) return 0;
    if (d == 1) return 1;
    if (d == 2) return 2;
    return 3;
  }

  static String _normalizeCompare(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ');

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
    final lineOpacity = userScrolling
        ? (isActive ? 1.0 : 0.72)
        : switch (status.bucket) {
            0 => 1.0,
            1 => 0.56,
            2 => 0.36,
            _ => 0.24,
          };

    final activeSize = compact
        ? KonataPlaybackTokens.lyricCompactActiveFontSize
        : KonataPlaybackTokens.lyricActiveFontSize;
    final inactiveSize = compact
        ? KonataPlaybackTokens.lyricCompactInactiveFontSize
        : KonataPlaybackTokens.lyricInactiveFontSize;
    final spanLine = activeSpanLine;
    final leadSpans = spanLine == null
        ? const <TimedLyricSpan>[]
        : spanLine.spans.where((s) => !s.isHarmony).toList(growable: false);
    final harmonySpans = spanLine == null
        ? const <TimedLyricSpan>[]
        : spanLine.spans.where((s) => s.isHarmony).toList(growable: false);
    final hasSpanData = leadSpans.isNotEmpty || harmonySpans.isNotEmpty;
    final effectiveLeadText = leadSpans.isNotEmpty
        ? leadSpans.map((s) => s.text).join()
        : line.primaryText;
    final normalizedLead = _normalizeCompare(effectiveLeadText);
    final filteredSecondary = <String>[];
    final seenSecondary = <String>{if (normalizedLead.isNotEmpty) normalizedLead};
    for (final rawSec in line.secondaryLines) {
      final trimmed = rawSec.trim();
      if (trimmed.isEmpty) continue;
      if (harmonySpans.isNotEmpty && trimmed.startsWith('bg:')) continue;
      final norm = _normalizeCompare(trimmed);
      if (seenSecondary.add(norm)) {
        filteredSecondary.add(trimmed);
      }
    }

    final Widget primaryBody;
    if (isActive) {
      primaryBody = _ActiveKaraokeSweepLeaf(
        leadText: effectiveLeadText,
        lineStartSeconds: line.startSeconds,
        lineEndSeconds: line.endSeconds,
        nextLineStartSeconds: nextLineStartSeconds,
        leadSpans: leadSpans,
        harmonySpans: harmonySpans,
        activeFontSize: activeSize,
        palette: p,
      );
    } else if (hasSpanData) {
      final inactiveHarmonyText = harmonySpans.map((s) => s.text).join();
      primaryBody = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (effectiveLeadText.isNotEmpty)
            Text(
              effectiveLeadText,
              softWrap: true,
              style: TextStyle(
                color: p.textSecondary,
                fontSize: inactiveSize,
                fontWeight: FontWeight.w400,
                height: 1.38,
              ),
            ),
          if (inactiveHarmonyText.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              inactiveHarmonyText,
              softWrap: true,
              style: TextStyle(
                color: p.textMuted,
                fontSize: KonataPlaybackTokens.lyricSecondaryFontSize,
                height: 1.28,
              ),
            ),
          ],
        ],
      );
    } else {
      primaryBody = Text(
        line.primaryText,
        softWrap: true,
        style: TextStyle(
          color: p.textSecondary,
          fontSize: inactiveSize,
          fontWeight: FontWeight.w400,
          height: 1.38,
        ),
      );
    }

    final secondaryFontSize = isActive
        ? (compact
              ? KonataPlaybackTokens.lyricSecondaryFontSize
              : KonataPlaybackTokens.lyricActiveSecondaryFontSize)
        : KonataPlaybackTokens.lyricSecondaryFontSize;

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
            vertical: isActive ? (compact ? 10 : 14) : (compact ? 7 : 10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              primaryBody,
              for (final sec in filteredSecondary) ...[
                SizedBox(height: isActive ? 6 : 4),
                Text(
                  sec,
                  softWrap: true,
                  style: TextStyle(
                    color: isActive ? p.textSecondary : p.textMuted,
                    fontSize: secondaryFontSize,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
                    height: 1.34,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    final fadedContent = AnimatedOpacity(
      duration: KonataPlaybackTokens.lyricStyleTransitionDuration,
      curve: Curves.easeOutCubic,
      opacity: lineOpacity,
      child: rowContent,
    );

    return RepaintBoundary(
      child: blurSigma > 0.05
          ? ImageFiltered(
              imageFilter: KonataTheme.blurFilterOf(blurSigma),
              child: fadedContent,
            )
          : fadedContent,
    );
  }
}

/// 仅挂载于当前激活歌词行的实时卡拉 OK 扫白叶子（支持逐字片段与整行匀速双模式，零父级重建）。
class _ActiveKaraokeSweepLeaf extends ConsumerStatefulWidget {
  const _ActiveKaraokeSweepLeaf({
    required this.leadText,
    required this.lineStartSeconds,
    required this.lineEndSeconds,
    required this.nextLineStartSeconds,
    required this.leadSpans,
    required this.harmonySpans,
    required this.activeFontSize,
    required this.palette,
  });

  final String leadText;
  final double lineStartSeconds;
  final double? lineEndSeconds;
  final double? nextLineStartSeconds;
  final List<TimedLyricSpan> leadSpans;
  final List<TimedLyricSpan> harmonySpans;
  final double activeFontSize;
  final KonataPalette palette;

  @override
  ConsumerState<_ActiveKaraokeSweepLeaf> createState() =>
      _ActiveKaraokeSweepLeafState();
}

class _ActiveKaraokeSweepLeafState
    extends ConsumerState<_ActiveKaraokeSweepLeaf>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweepController;
  late double _windowStart;
  late double _windowEnd;

  @override
  void initState() {
    super.initState();
    _sweepController = AnimationController(vsync: this);
    _recomputeWindow();
    final snap = ref.read(audioPlaybackProvider);
    _syncAnimation(snap.positionSeconds, snap.isPlaying);
  }

  @override
  void didUpdateWidget(covariant _ActiveKaraokeSweepLeaf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.leadText != widget.leadText ||
        oldWidget.lineStartSeconds != widget.lineStartSeconds ||
        oldWidget.lineEndSeconds != widget.lineEndSeconds ||
        oldWidget.nextLineStartSeconds != widget.nextLineStartSeconds ||
        oldWidget.leadSpans != widget.leadSpans ||
        oldWidget.harmonySpans != widget.harmonySpans) {
      _recomputeWindow();
      final snap = ref.read(audioPlaybackProvider);
      _syncAnimation(snap.positionSeconds, snap.isPlaying);
    }
  }

  @override
  void dispose() {
    _sweepController.dispose();
    super.dispose();
  }

  void _recomputeWindow() {
    final allSpans = <TimedLyricSpan>[
      ...widget.leadSpans,
      ...widget.harmonySpans,
    ];
    if (allSpans.isNotEmpty) {
      var minStart = allSpans.first.startSeconds;
      var maxEnd = allSpans.first.endSeconds;
      for (final s in allSpans) {
        if (s.startSeconds < minStart) minStart = s.startSeconds;
        if (s.endSeconds > maxEnd) maxEnd = s.endSeconds;
      }
      _windowStart = minStart;
      _windowEnd = math.max(minStart + 0.25, maxEnd);
      return;
    }

    _windowStart = widget.lineStartSeconds;
    final rawEnd = widget.lineEndSeconds ?? widget.nextLineStartSeconds;
    final estVocal = (widget.leadText.runes.length * 0.34).clamp(2.4, 9.5);
    if (rawEnd == null || rawEnd <= _windowStart) {
      _windowEnd = _windowStart + estVocal;
      return;
    }
    final gap = rawEnd - _windowStart;
    if (gap <= 0.35) {
      _windowEnd = _windowStart + 0.35;
    } else if (gap <= 11.0) {
      _windowEnd = rawEnd;
    } else {
      _windowEnd = _windowStart + estVocal.clamp(3.0, math.min(gap, 10.5));
    }
  }

  void _syncAnimation(double posSeconds, bool isPlaying) {
    final durSec = math.max(0.25, _windowEnd - _windowStart);
    final target = ((posSeconds - _windowStart) / durSec).clamp(0.0, 1.0);
    if (!isPlaying || target >= 1.0) {
      _sweepController.stop();
      if ((_sweepController.value - target).abs() > 0.001) {
        _sweepController.value = target;
      }
      return;
    }
    final targetDuration = KonataPlaybackTokens.lyricKaraokeWindowDuration(
      durSec,
    );
    final currentEstPos = _windowStart + _sweepController.value * durSec;
    if (!_sweepController.isAnimating ||
        _sweepController.duration != targetDuration ||
        (currentEstPos - posSeconds).abs() > 0.14) {
      _sweepController.duration = targetDuration;
      _sweepController.forward(from: target);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<({double pos, bool isPlaying})>(
      audioPlaybackProvider.select(
        (s) => (pos: s.positionSeconds, isPlaying: s.isPlaying),
      ),
      (_, next) => _syncAnimation(next.pos, next.isPlaying),
    );

    final p = widget.palette;
    final unlitAlpha = p.isDark
        ? KonataPlaybackTokens.lyricKaraokeUnlitAlphaDark
        : KonataPlaybackTokens.lyricKaraokeUnlitAlphaLight;
    final litLeadColor = p.isDark ? KonataTheme.pureWhite : p.textPrimary;
    final baseLeadColor = litLeadColor.withValues(alpha: unlitAlpha);
    final leadBaseStyle = TextStyle(
      color: baseLeadColor,
      fontSize: widget.activeFontSize,
      fontWeight: FontWeight.w700,
      height: 1.36,
    );
    final leadLitStyle = leadBaseStyle.copyWith(
      color: litLeadColor,
      shadows: KonataPlaybackTokens.lyricGlowShadow(
        p,
        blurRadius: KonataPlaybackTokens.lyricSweepGlowBlurRadius,
      ),
    );

    final hasLeadSpans = widget.leadSpans.isNotEmpty;
    final harmonyText = widget.harmonySpans.map((s) => s.text).join();
    final harmonyBaseStyle = TextStyle(
      color: p.textMuted.withValues(alpha: p.isDark ? 0.45 : 0.42),
      fontSize: KonataPlaybackTokens.lyricSecondaryFontSize,
      fontWeight: FontWeight.w500,
      height: 1.28,
    );
    final harmonyLitStyle = harmonyBaseStyle.copyWith(color: p.textSecondary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.leadText.isNotEmpty)
          ImmersiveKaraokeSweepText(
            key: ValueKey(
              hasLeadSpans ? 'active_lead_spans' : 'active_line_karaoke',
            ),
            text: widget.leadText,
            baseStyle: leadBaseStyle,
            litStyle: leadLitStyle,
            progress: _sweepController,
            windowStartSeconds: _windowStart,
            windowEndSeconds: _windowEnd,
            spans: widget.leadSpans,
          ),
        if (harmonyText.isNotEmpty) ...[
          const SizedBox(height: 5),
          ImmersiveKaraokeSweepText(
            key: const ValueKey('active_harmony_spans'),
            text: harmonyText,
            baseStyle: harmonyBaseStyle,
            litStyle: harmonyLitStyle,
            progress: _sweepController,
            windowStartSeconds: _windowStart,
            windowEndSeconds: _windowEnd,
            spans: widget.harmonySpans,
          ),
        ],
      ],
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
    this.trailingCenterPrimaryButton,
    this.trailingCenterButtons = const [],
    this.rightSlot,
    this.maxWidth,
  });

  final Widget? leading;
  final String? title;
  final bool isPlaying;
  final AudioLoopMode loopMode;
  final AudioPlaybackNotifier notifier;
  final Widget? trailingCenterPrimaryButton;
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
        trailingCenterPrimaryButton: trailingCenterPrimaryButton,
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
              trackHeight: KonataPlaybackTokens.touchScrubberTrackHeight,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius:
                    KonataPlaybackTokens.touchScrubberThumbRadius,
              ),
              overlayShape: const RoundSliderOverlayShape(
                overlayRadius: KonataPlaybackTokens.touchScrubberOverlayRadius,
              ),
              activeTrackColor: p.progressFill,
              inactiveTrackColor: p.progressTrack,
              thumbColor: p.textPrimary,
            ),
            child: SizedBox(
              height: widget.compact
                  ? KonataPlaybackTokens.touchScrubberCompactHeight
                  : KonataPlaybackTokens.touchScrubberHeight,
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
                    fontSize: KonataPlaybackTokens.touchScrubberTimeFontSize,
                    fontFeatures: KonataPlaybackTokens.tabularNumbers,
                  ),
                ),
                Text(
                  durText,
                  style: TextStyle(
                    color: p.textSecondary,
                    fontSize: KonataPlaybackTokens.touchScrubberTimeFontSize,
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
                                  fontSize:
                                      KonataPlaybackTokens.queueRowPrefixFontSize,
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
                        duration:
                            KonataPlaybackTokens.queueRowTransitionDuration,
                        curve: Curves.easeOutCubic,
                        style: TextStyle(
                          color: color,
                          fontSize: active
                              ? (isSubTrack
                                    ? KonataPlaybackTokens
                                          .queueSubTrackTitleActiveFontSize
                                    : KonataPlaybackTokens
                                          .queueRowTitleActiveFontSize)
                              : (isSubTrack
                                    ? KonataPlaybackTokens
                                          .queueSubTrackTitleInactiveFontSize
                                    : KonataPlaybackTokens
                                          .queueRowTitleInactiveFontSize),
                          fontWeight: (active || isExpandedParent)
                              ? FontWeight.w600
                              : FontWeight.w400,
                          shadows: active
                              ? KonataPlaybackTokens.lyricGlowShadow(
                                  p,
                                  blurRadius: KonataPlaybackTokens
                                      .lyricSweepGlowBlurRadius,
                                )
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
                            fontSize:
                                KonataPlaybackTokens.queueRowSubtitleFontSize,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (durationText.isNotEmpty) ...[
                  const SizedBox(width: KonataAdaptiveTokens.horizontalInset),
                  Text(
                    durationText,
                    style: TextStyle(
                      color: (active || isExpandedParent)
                          ? p.textPrimary
                          : (_hovered ? p.textSecondary : p.textMuted),
                      fontSize: KonataPlaybackTokens.queueRowMetaFontSize,
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
      duration: KonataPlaybackTokens.equalizerCycleDuration,
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
                          borderRadius: BorderRadius.circular(
                            KonataTheme.radiusPill,
                          ),
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

/// 三端共用的专辑封面 + 柔雾镜像倒影组件（自动按父容器宽高自适应，零纵向溢出）。
class ImmersiveCoverWithReflection extends ConsumerWidget {
  /// 创建带柔雾镜像倒影的专辑封面。
  const ImmersiveCoverWithReflection({
    super.key,
    required this.cover,
    required this.maxCoverSize,
    this.borderRadius = KonataPlaybackTokens.albumCoverRadius,
    this.reflectionRatio = 0.28,
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
            decodeWidth: KonataPlaybackTokens.albumCoverDecodeWidth,
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
                        blurRadius: KonataPlaybackTokens.albumCoverShadowBlur,
                        offset: KonataPlaybackTokens.albumCoverShadowOffset,
                      ),
                    ],
                    border: Border.all(
                      color: KonataPlaybackTokens.glassBorder(p),
                      width: KonataAdaptiveTokens.borderWidth,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(borderRadius),
                    child: buildArtwork(coverSize, coverAlignment),
                  ),
                ),
              ),
              RepaintBoundary(
                child: SizedBox(
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
                              colors: KonataPlaybackTokens
                                  .albumReflectionMaskColors,
                              stops: [0.0, 0.34, 0.92],
                            ).createShader(
                              Rect.fromLTWH(0, 0, coverSize, reflectionHeight),
                            ),
                        blendMode: BlendMode.dstIn,
                        child: ImageFiltered(
                          imageFilter: KonataTheme.blurFilterOf(
                            KonataPlaybackTokens.albumReflectionBlurSigma,
                          ),
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
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _emptyArt(KonataPalette p, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: const KonataCdDiscPlaceholder(discScale: 0.78),
    );
  }
}

/// 悬浮胶囊与小窗复用的微缩专辑封面（支持圆角方形或正圆形态）。
class ImmersiveMicroCover extends ConsumerWidget {
  /// 创建微缩专辑封面。
  const ImmersiveMicroCover({
    super.key,
    required this.cover,
    this.size = KonataPlaybackTokens.microCoverSize,
    this.circular = false,
  });

  final AudioCoverSource cover;
  final double size;
  final bool circular;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final loader = ref.watch(tmdbImageLoaderProvider);

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
              decodeWidth: KonataPlaybackTokens.microCoverDecodeWidth,
              fit: BoxFit.cover,
              alignment: coverAlignment,
              errorBuilder: (_, _, _) => _fallback(p, size),
            );
          case EmptyAudioCover():
            art = _fallback(p, size);
        }

        if (circular) {
          return ClipOval(
            child: SizedBox(width: size, height: size, child: art),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(
            KonataPlaybackTokens.microCoverRadius,
          ),
          child: SizedBox(width: size, height: size, child: art),
        );
      },
    );
  }

  Widget _fallback(KonataPalette p, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: KonataCdDiscPlaceholder(discScale: circular ? 0.92 : 0.80),
    );
  }
}
