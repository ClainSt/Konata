import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/karaoke_clock_extrapolator.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../../domain/playback/mora_pace_estimator.dart';
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
    this.estimatedSecondsPerChar = LrcDocument.defaultSecondsPerChar,
    this.secondsPerMora,
    this.isJapaneseSong,
  });

  final int index;
  final LrcCueLine line;
  final bool compact;
  final bool userScrolling;

  /// 当前行是否位于滑动时间轴中央焦带（滚动定位时清晰高亮提示）。
  final bool isScrubFocused;

  /// 是否居中排版（手机竖屏对齐经典歌词布局，左右预留时间轴与小播放键空间）。
  final bool centerAligned;

  /// 可选外部独立解析的主唱/和声片段行（仅当 [line] 未自带原生 `words` 时兜底兼容）。
  final ActiveSpanLyricLine? activeSpanLine;

  /// 下一行歌词起点秒数（供整行 LRC 估算演唱时长与换气余量）。
  final double? nextLineStartSeconds;

  /// 传统每字估算秒数（兼容外部测试与未传 `secondsPerMora` 时的兜底参考）。
  final double estimatedSecondsPerChar;

  /// 曲目预计算音拍曲速（秒/音拍，由 `LrcDocument.secondsPerMora` 直接传入）。
  final double? secondsPerMora;

  /// 曲目是否属于日文语境（由 `LrcDocument.isJapaneseSong` 直接传入）。
  final bool? isJapaneseSong;

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

    // 优先直接使用解析期绑定于 LrcCueLine 的原生逐字/和声片段，零构建期过滤与线性查找。
    final List<TimedLyricSpan> leadSpans;
    final List<TimedLyricSpan> harmonySpans;
    if (line.hasWordTiming) {
      leadSpans = line.words;
      harmonySpans = line.harmonyWords;
    } else if (activeSpanLine != null) {
      leadSpans = activeSpanLine!.spans
          .where((s) => !s.isHarmony)
          .toList(growable: false);
      harmonySpans = activeSpanLine!.spans
          .where((s) => s.isHarmony)
          .toList(growable: false);
    } else {
      leadSpans = const <TimedLyricSpan>[];
      harmonySpans = const <TimedLyricSpan>[];
    }

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
      final docSnap = (secondsPerMora == null || isJapaneseSong == null)
          ? ref.read(audioPlaybackProvider).lrcDocument
          : null;
      final resolvedMoraPace =
          secondsPerMora ??
          docSnap?.secondsPerMora ??
          (estimatedSecondsPerChar * 0.78).clamp(0.10, 0.36);
      final resolvedIsJa = isJapaneseSong ?? docSnap?.isJapaneseSong;
      primaryBody = _ActiveKaraokeSweepLeaf(
        leadText: effectiveLeadText,
        romajiText: line.romajiText,
        lineStartSeconds: line.startSeconds,
        lineEndSeconds: line.endSeconds,
        nextLineStartSeconds: nextLineStartSeconds,
        secondsPerMora: resolvedMoraPace,
        isJapaneseSong: resolvedIsJa,
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

/// 仅挂载于当前激活歌词行的实时卡拉 OK 扫白叶子：
/// 使用单调时钟外推 `Ticker` + `<60ms` 柔性漂移纠偏驱动扫白，暂停、行结束或不可见时立即停钟。
class _ActiveKaraokeSweepLeaf extends ConsumerStatefulWidget {
  const _ActiveKaraokeSweepLeaf({
    required this.leadText,
    required this.romajiText,
    required this.lineStartSeconds,
    required this.lineEndSeconds,
    required this.nextLineStartSeconds,
    required this.secondsPerMora,
    required this.isJapaneseSong,
    required this.leadSpans,
    required this.harmonySpans,
    required this.activeFontSize,
    required this.palette,
    this.centerAligned = false,
  });

  final String leadText;
  final String romajiText;
  final double lineStartSeconds;
  final double? lineEndSeconds;
  final double? nextLineStartSeconds;
  final double secondsPerMora;
  final bool? isJapaneseSong;
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
  late final Ticker _ticker;
  late final ValueNotifier<double> _progressNotifier;
  final KaraokeClockExtrapolator _extrapolator = KaraokeClockExtrapolator();

  late double _windowStart;
  late double _windowEnd;
  double _lastTickClockSeconds = 0.0;
  double? _pendingMediaPosSeconds;
  bool _tickerVisible = true;
  AudioPlaybackNotifier? _boundNotifier;

  double _progressForPosition(double posSeconds) {
    final durSec = math.max(0.10, _windowEnd - _windowStart);
    return ((posSeconds - _windowStart) / durSec).clamp(0.0, 1.0);
  }

  void _startTickerIfNeeded(double posSeconds, bool isPlaying) {
    final shouldRun = isPlaying && _tickerVisible && posSeconds < _windowEnd;
    if (!shouldRun) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (!_ticker.isActive) {
      _lastTickClockSeconds = 0.0;
      _extrapolator.snapTo(posSeconds, clockSeconds: 0.0);
      _ticker.start();
    }
  }

  void _onTickerFrame(Duration elapsed) {
    if (!mounted) return;
    final clockSec = elapsed.inMicroseconds / 1000000.0;
    _lastTickClockSeconds = clockSec;

    final pendingMedia = _pendingMediaPosSeconds;
    _pendingMediaPosSeconds = null;
    final double pos;
    if (pendingMedia != null) {
      pos = _extrapolator.reconcileFromMediaClock(
        pendingMedia,
        clockSeconds: clockSec,
        isPlaying: true,
      );
    } else {
      pos = _extrapolator.advanceTo(clockSec);
    }

    final nextProgress = _progressForPosition(pos);
    if ((nextProgress - _progressNotifier.value).abs() > 1e-5) {
      _progressNotifier.value = nextProgress;
    }
    // 唱完本行立即停钟，严禁行结束后仍保持常驻空闲 Ticker。
    if (nextProgress >= 1.0 && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onPositionTick() {
    if (!mounted) return;
    final pos = _boundNotifier?.currentPositionSeconds ?? 0.0;
    final isPlaying = ref.read(audioPlaybackProvider.select((s) => s.isPlaying));
    _syncFromMediaClock(pos, isPlaying);
  }

  void _syncFromMediaClock(
    double posSeconds,
    bool isPlaying, {
    bool forceSnap = false,
  }) {
    if (!isPlaying || !_tickerVisible) {
      _pendingMediaPosSeconds = null;
      if (_ticker.isActive) _ticker.stop();
      _extrapolator.snapTo(posSeconds, clockSeconds: _lastTickClockSeconds);
      final target = _progressForPosition(posSeconds);
      if ((_progressNotifier.value - target).abs() > 1e-5) {
        _progressNotifier.value = target;
      }
      return;
    }

    if (posSeconds >= _windowEnd) {
      _pendingMediaPosSeconds = null;
      if (_ticker.isActive) _ticker.stop();
      _extrapolator.snapTo(posSeconds, clockSeconds: _lastTickClockSeconds);
      if (_progressNotifier.value < 1.0) {
        _progressNotifier.value = 1.0;
      }
      return;
    }

    if (_ticker.isActive && !forceSnap) {
      // 在途 VSync 帧内以同一单调时钟消费底层回报，小于 60ms 自动柔性收敛。
      _pendingMediaPosSeconds = posSeconds;
      return;
    }

    _pendingMediaPosSeconds = null;
    if (_ticker.isActive) _ticker.stop();
    _lastTickClockSeconds = 0.0;
    _extrapolator.snapTo(posSeconds, clockSeconds: 0.0);
    final target = _progressForPosition(posSeconds);
    if ((_progressNotifier.value - target).abs() > 1e-5) {
      _progressNotifier.value = target;
    }
    _startTickerIfNeeded(posSeconds, true);
  }

  @override
  void initState() {
    super.initState();
    _progressNotifier = ValueNotifier<double>(0.0);
    _ticker = createTicker(_onTickerFrame);
    _recomputeWindow();
    final notifier = ref.read(audioPlaybackProvider.notifier);
    _boundNotifier = notifier;
    notifier.positionListenable.addListener(_onPositionTick);
    final snap = ref.read(audioPlaybackProvider);
    _syncFromMediaClock(
      notifier.currentPositionSeconds,
      snap.isPlaying,
      forceSnap: true,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _tickerVisible) {
      _tickerVisible = visible;
      final pos =
          _boundNotifier?.currentPositionSeconds ??
          ref.read(audioPlaybackProvider.notifier).currentPositionSeconds;
      final isPlaying = ref.read(
        audioPlaybackProvider.select((s) => s.isPlaying),
      );
      _syncFromMediaClock(pos, isPlaying, forceSnap: true);
    }
  }

  @override
  void didUpdateWidget(covariant _ActiveKaraokeSweepLeaf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.leadText != widget.leadText ||
        oldWidget.romajiText != widget.romajiText ||
        oldWidget.lineStartSeconds != widget.lineStartSeconds ||
        oldWidget.lineEndSeconds != widget.lineEndSeconds ||
        oldWidget.nextLineStartSeconds != widget.nextLineStartSeconds ||
        oldWidget.secondsPerMora != widget.secondsPerMora ||
        oldWidget.isJapaneseSong != widget.isJapaneseSong ||
        oldWidget.leadSpans != widget.leadSpans ||
        oldWidget.harmonySpans != widget.harmonySpans) {
      _recomputeWindow();
      final notifier = ref.read(audioPlaybackProvider.notifier);
      final snap = ref.read(audioPlaybackProvider);
      _syncFromMediaClock(
        notifier.currentPositionSeconds,
        snap.isPlaying,
        forceSnap: true,
      );
    }
  }

  @override
  void dispose() {
    _boundNotifier?.positionListenable.removeListener(_onPositionTick);
    _boundNotifier = null;
    _ticker.dispose();
    _progressNotifier.dispose();
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
      _windowEnd = math.max(minStart + 0.10, maxEnd);
      return;
    }

    _windowStart = widget.lineStartSeconds;
    final rawNext = widget.nextLineStartSeconds ?? widget.lineEndSeconds;
    final vocalDur = MoraPaceEstimator.estimateVocalDurationSeconds(
      lineStartSeconds: _windowStart,
      nextLineStartSeconds: rawNext,
      text: widget.leadText,
      romajiText: widget.romajiText,
      secondsPerMora: widget.secondsPerMora,
      isJapaneseSong: widget.isJapaneseSong,
    );
    _windowEnd = _windowStart + vocalDur;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      audioPlaybackProvider.select((s) => s.isPlaying),
      (_, isPlaying) => _syncFromMediaClock(
        ref.read(audioPlaybackProvider.notifier).currentPositionSeconds,
        isPlaying,
        forceSnap: true,
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
            progress: _progressNotifier,
            windowStartSeconds: _windowStart,
            windowEndSeconds: _windowEnd,
            spans: widget.leadSpans,
            romajiText: widget.romajiText,
            isJapaneseSong: widget.isJapaneseSong,
            textAlign: widget.centerAligned ? TextAlign.center : TextAlign.start,
          ),
        if (harmonyText.isNotEmpty) ...[
          const SizedBox(height: 5),
          ImmersiveKaraokeSweepText(
            key: const ValueKey('active_harmony_spans'),
            text: harmonyText,
            baseStyle: harmonyBaseStyle,
            litStyle: harmonyLitStyle,
            progress: _progressNotifier,
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
