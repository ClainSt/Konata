import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import 'immersive_karaoke_sweep_text.dart';

/// 独立歌词行叶子组件：仅当自身高亮态、时间轴焦点态、邻近模糊阶梯或罗马音显隐变化时重建。
class ImmersiveLyricLineLeaf extends ConsumerWidget {
  /// 创建独立歌词行叶子。
  const ImmersiveLyricLineLeaf({
    super.key,
    required this.index,
    required this.line,
    required this.compact,
    required this.userScrolling,
    this.isScrubFocused = false,
    this.centerAligned = false,
    this.activeSpanLine,
    this.nextLineStartSeconds,
    this.estimatedSecondsPerChar = 0.24,
  });

  final int index;
  final LrcCueLine line;
  final bool compact;
  final bool userScrolling;

  /// 当前行是否位于滑动时间轴中央焦带（滚动定位时清晰高亮提示）。
  final bool isScrubFocused;

  /// 是否居中排版（手机竖屏对齐经典歌词布局，左右预留时间轴与小播放键空间）。
  final bool centerAligned;

  /// 可选主唱/和声并行逐字扫光片段行（仅高亮当前行挂载局部进度叶子，非当前行零订阅）。
  final ActiveSpanLyricLine? activeSpanLine;

  /// 下一行歌词起点秒数（供标准整行时间戳 LRC 计算精准匀速扫光时长）。
  final double? nextLineStartSeconds;

  /// 根据当前曲目中位语速估算的每字演唱秒数（避免间奏行按固定慢速滞后未走完）。
  final double estimatedSecondsPerChar;

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
          isIntroStandby: s.activeLyricIndex < 0 && index == 0,
          bucket: _distanceBucket(
            index,
            s.activeLyricIndex < 0 ? 0 : s.activeLyricIndex,
          ),
        ),
      ),
    );
    final showRomaji = ref.watch(
      playbackPreferencesProvider.select((s) => s.showLyricRomaji),
    );
    final romajiText = showRomaji ? line.romajiText.trim() : '';
    final isActive = status.isActive;
    final isIntroStandby = status.isIntroStandby;
    final isFocused = isActive || isIntroStandby;
    final blurSigma = userScrolling
        ? 0.0
        : switch (status.bucket) {
            0 => 0.0,
            1 => KonataPlaybackTokens.lyricBlurStep1,
            2 => KonataPlaybackTokens.lyricBlurStep2,
            _ => KonataPlaybackTokens.lyricBlurStepFar,
          };
    final lineOpacity = userScrolling
        ? ((isFocused || isScrubFocused) ? 1.0 : 0.78)
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
    final textAlign = centerAligned ? TextAlign.center : TextAlign.start;
    final columnAlign = centerAligned
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
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
        estimatedSecondsPerChar: estimatedSecondsPerChar,
        leadSpans: leadSpans,
        harmonySpans: harmonySpans,
        activeFontSize: activeSize,
        palette: p,
        centerAligned: centerAligned,
      );
    } else if (isIntroStandby) {
      // 前奏期第 0 句以与开唱首帧一致的大字号未扫白样式清晰就绪，进入演唱时间戳后再原位启动扫白，零尺寸与色阶跳变。
      final unlitAlpha = p.isDark
          ? KonataPlaybackTokens.lyricKaraokeUnlitAlphaDark
          : KonataPlaybackTokens.lyricKaraokeUnlitAlphaLight;
      final standbyLeadColor =
          (p.isDark ? KonataTheme.pureWhite : p.textPrimary).withValues(
            alpha: unlitAlpha,
          );
      final standbyHarmonyText = harmonySpans.map((s) => s.text).join();
      primaryBody = Column(
        key: const ValueKey('intro_standby_first_lyric'),
        crossAxisAlignment: columnAlign,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (effectiveLeadText.isNotEmpty)
            Text(
              effectiveLeadText,
              textAlign: textAlign,
              softWrap: true,
              style: TextStyle(
                color: isScrubFocused ? p.textPrimary : standbyLeadColor,
                fontSize: activeSize,
                fontWeight: FontWeight.w700,
                height: 1.36,
              ),
            ),
          if (standbyHarmonyText.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              standbyHarmonyText,
              textAlign: textAlign,
              softWrap: true,
              style: TextStyle(
                color: p.textMuted.withValues(alpha: p.isDark ? 0.45 : 0.42),
                fontSize: KonataPlaybackTokens.lyricSecondaryFontSize,
                fontWeight: FontWeight.w500,
                height: 1.28,
              ),
            ),
          ],
        ],
      );
    } else if (hasSpanData) {
      final inactiveHarmonyText = harmonySpans.map((s) => s.text).join();
      primaryBody = Column(
        crossAxisAlignment: columnAlign,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (effectiveLeadText.isNotEmpty)
            Text(
              effectiveLeadText,
              textAlign: textAlign,
              softWrap: true,
              style: TextStyle(
                color: isScrubFocused ? p.textPrimary : p.textSecondary,
                fontSize: inactiveSize,
                fontWeight: isScrubFocused ? FontWeight.w600 : FontWeight.w400,
                height: 1.38,
              ),
            ),
          if (inactiveHarmonyText.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              inactiveHarmonyText,
              textAlign: textAlign,
              softWrap: true,
              style: TextStyle(
                color: isScrubFocused ? p.textSecondary : p.textMuted,
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
        textAlign: textAlign,
        softWrap: true,
        style: TextStyle(
          color: isScrubFocused ? p.textPrimary : p.textSecondary,
          fontSize: inactiveSize,
          fontWeight: isScrubFocused ? FontWeight.w600 : FontWeight.w400,
          height: 1.38,
        ),
      );
    }

    final secondaryFontSize = isFocused
        ? (compact
              ? KonataPlaybackTokens.lyricSecondaryFontSize
              : KonataPlaybackTokens.lyricActiveSecondaryFontSize)
        : KonataPlaybackTokens.lyricSecondaryFontSize;

    final rowContent = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: KonataAdaptiveTokens.isAndroid
            ? KonataAdaptiveTokens.touchTarget
            : 0,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 8,
          vertical: isFocused ? (compact ? 9 : 13) : (compact ? 6 : 9),
        ),
        child: Column(
          crossAxisAlignment: columnAlign,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            primaryBody,
            if (romajiText.isNotEmpty) ...[
              SizedBox(height: isFocused ? 4 : 3),
              Text(
                romajiText,
                key: ValueKey('lyric_line_romaji_$index'),
                textAlign: textAlign,
                softWrap: true,
                style: TextStyle(
                  color: (isFocused || isScrubFocused)
                      ? p.textMuted.withValues(alpha: p.isDark ? 0.85 : 0.80)
                      : p.textMuted.withValues(alpha: p.isDark ? 0.65 : 0.62),
                  fontSize: KonataTheme.fontSizeCaption,
                  fontWeight: FontWeight.w400,
                  height: 1.28,
                ),
              ),
            ],
            for (final sec in filteredSecondary) ...[
              SizedBox(height: isFocused ? 6 : 4),
              Text(
                sec,
                textAlign: textAlign,
                softWrap: true,
                style: TextStyle(
                  color: (isFocused || isScrubFocused)
                      ? p.textSecondary
                      : p.textMuted,
                  fontSize: secondaryFontSize,
                  fontWeight: (isFocused || isScrubFocused)
                      ? FontWeight.w500
                      : FontWeight.w400,
                  height: 1.34,
                ),
              ),
            ],
          ],
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
    required this.estimatedSecondsPerChar,
    required this.leadSpans,
    required this.harmonySpans,
    required this.activeFontSize,
    required this.palette,
    this.centerAligned = false,
  });

  final String leadText;
  final double lineStartSeconds;
  final double? lineEndSeconds;
  final double? nextLineStartSeconds;
  final double estimatedSecondsPerChar;
  final List<TimedLyricSpan> leadSpans;
  final List<TimedLyricSpan> harmonySpans;
  final double activeFontSize;
  final KonataPalette palette;
  final bool centerAligned;

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
  AudioPlaybackNotifier? _boundNotifier;

  void _onPositionTick() {
    if (!mounted) return;
    final pos = _boundNotifier?.currentPositionSeconds ?? 0.0;
    final isPlaying = ref.read(audioPlaybackProvider.select((s) => s.isPlaying));
    _syncAnimation(pos, isPlaying);
  }

  @override
  void initState() {
    super.initState();
    _sweepController = AnimationController(vsync: this);
    _recomputeWindow();
    final notifier = ref.read(audioPlaybackProvider.notifier);
    _boundNotifier = notifier;
    notifier.positionListenable.addListener(_onPositionTick);
    final snap = ref.read(audioPlaybackProvider);
    _syncAnimation(notifier.currentPositionSeconds, snap.isPlaying);
  }

  @override
  void didUpdateWidget(covariant _ActiveKaraokeSweepLeaf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.leadText != widget.leadText ||
        oldWidget.lineStartSeconds != widget.lineStartSeconds ||
        oldWidget.lineEndSeconds != widget.lineEndSeconds ||
        oldWidget.nextLineStartSeconds != widget.nextLineStartSeconds ||
        oldWidget.estimatedSecondsPerChar != widget.estimatedSecondsPerChar ||
        oldWidget.leadSpans != widget.leadSpans ||
        oldWidget.harmonySpans != widget.harmonySpans) {
      _recomputeWindow();
      final notifier = ref.read(audioPlaybackProvider.notifier);
      final snap = ref.read(audioPlaybackProvider);
      _syncAnimation(notifier.currentPositionSeconds, snap.isPlaying);
    }
  }

  @override
  void dispose() {
    _boundNotifier?.positionListenable.removeListener(_onPositionTick);
    _boundNotifier = null;
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
    final compactCharCount = widget.leadText
        .replaceAll(RegExp(r'\s+'), '')
        .runes
        .length;
    final estVocal =
        (math.max(1, compactCharCount) * widget.estimatedSecondsPerChar)
            .clamp(1.6, 8.5);
    if (rawEnd == null || rawEnd <= _windowStart) {
      _windowEnd = _windowStart + estVocal;
      return;
    }
    final gap = rawEnd - _windowStart;
    if (gap <= 0.35) {
      _windowEnd = _windowStart + 0.35;
    } else if (gap > estVocal * 1.38) {
      // 句后接纯音乐间奏或长停顿：按当前曲目自身中位语速精确封顶，确保歌声停时纯白恰好铺满末字。
      _windowEnd = _windowStart + estVocal;
    } else {
      // 常规连续句预留 0.22s 句尾换气余量，防止最后一字在切句瞬间仍停留在半亮态。
      final effectiveDur = math.min(
        math.max(0.35, gap - 0.22),
        estVocal * 1.25,
      );
      _windowEnd = _windowStart + effectiveDur;
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
    ref.listen<bool>(
      audioPlaybackProvider.select((s) => s.isPlaying),
      (_, isPlaying) => _syncAnimation(
        ref.read(audioPlaybackProvider.notifier).currentPositionSeconds,
        isPlaying,
      ),
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
      crossAxisAlignment: widget.centerAligned
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
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
            textAlign: widget.centerAligned ? TextAlign.center : TextAlign.start,
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
            textAlign: widget.centerAligned ? TextAlign.center : TextAlign.start,
          ),
        ],
      ],
    );
  }
}
