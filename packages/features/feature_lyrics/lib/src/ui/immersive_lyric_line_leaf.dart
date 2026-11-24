import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../domain/karaoke_clock_extrapolator.dart';
import 'immersive_karaoke_sweep_text.dart';

/// 独立歌词行叶子组件：仅当自身高亮态、时间轴焦点态、邻近模糊阶梯或罗马音显隐变化时重建。
class ImmersiveLyricLineLeaf extends StatelessWidget {
  /// 创建独立歌词行叶子。
  const ImmersiveLyricLineLeaf({
    super.key,
    required this.index,
    required this.line,
    required this.activeLyricIndex,
    required this.positionListenable,
    required this.isPlayingListenable,
    required this.showRomaji,
    this.showTranslation = true,
    required this.compact,
    required this.userScrolling,
    this.lyricOffsetSeconds = 0.0,
    this.isScrubFocused = false,
    this.centerAligned = false,
    this.activeSpanLine,
    this.nextLineStartSeconds,
    this.estimatedSecondsPerChar = LrcDocument.defaultSecondsPerChar,
    this.secondsPerMora,
    this.isJapaneseSong,
  });

  /// 当前歌词行索引。
  final int index;

  /// 解析后的单行同步歌词模型。
  final LrcCueLine line;

  /// 当前播放激活行索引（前奏期为 `-1`）。
  final int activeLyricIndex;

  /// 外部直连播放进度可监听对象（高频时钟直达叶子组件）。
  final ValueListenable<Duration> positionListenable;

  /// 外部直连播放状态可监听对象（暂停时立即停止帧时钟）。
  final ValueListenable<bool> isPlayingListenable;

  /// 是否展示罗马音注音行。
  final bool showRomaji;

  /// 是否展示双语译文行。
  final bool showTranslation;

  /// 是否启用紧凑字号与内边距。
  final bool compact;

  /// 用户当前是否正在主动滚动定位时间轴。
  final bool userScrolling;

  /// 三级叠加总偏移（秒，正值歌词提前）。
  final double lyricOffsetSeconds;

  /// 当前行是否位于滑动时间轴中央焦带。
  final bool isScrubFocused;

  /// 是否居中排版。
  final bool centerAligned;

  /// 可选外部独立解析的主唱与和声片段行。
  final ActiveSpanLyricLine? activeSpanLine;

  /// 下一行歌词起点秒数（供整行模式估算演唱时长与换气余量）。
  final double? nextLineStartSeconds;

  /// 传统每字估算秒数兜底参数。
  final double estimatedSecondsPerChar;

  /// 曲目预计算音拍曲速（秒/音拍）。
  final double? secondsPerMora;

  /// 曲目是否属于日文语境。
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
  Widget build(BuildContext context) {
    const pureWhite = KonataTheme.pureWhite;
    final isActive = activeLyricIndex == index;
    final isIntroStandby = activeLyricIndex < 0 && index == 0;
    final bucket = _distanceBucket(
      index,
      activeLyricIndex < 0 ? 0 : activeLyricIndex,
    );
    final romajiText = showRomaji ? line.romajiText.trim() : '';
    final isFocused = isActive || isIntroStandby;

    final blurSigma = userScrolling
        ? 0.0
        : switch (bucket) {
            0 => 0.0,
            1 => 0.70,
            2 => 1.25,
            _ => 1.90,
          };
    final lineOpacity = userScrolling
        ? ((isFocused || isScrubFocused) ? 1.0 : 0.74)
        : switch (bucket) {
            0 => 1.0,
            1 => 0.44,
            2 => 0.25,
            _ => 0.14,
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
    if (showTranslation) {
      final seenSecondary = <String>{
        if (normalizedLead.isNotEmpty) normalizedLead,
      };
      for (final rawSec in line.secondaryLines) {
        final trimmed = rawSec.trim();
        if (trimmed.isEmpty) continue;
        if (harmonySpans.isNotEmpty && trimmed.startsWith('bg:')) continue;
        final norm = _normalizeCompare(trimmed);
        if (seenSecondary.add(norm)) {
          filteredSecondary.add(trimmed);
        }
      }
    }

    final Widget primaryBody;
    if (isActive) {
      final resolvedMoraPace =
          secondsPerMora ??
          (estimatedSecondsPerChar * 0.78).clamp(0.10, 0.36);
      primaryBody = _ActiveKaraokeSweepLeaf(
        leadText: effectiveLeadText,
        romajiText: line.romajiText,
        lineStartSeconds: line.startSeconds,
        lineEndSeconds: line.endSeconds,
        nextLineStartSeconds: nextLineStartSeconds,
        secondsPerMora: resolvedMoraPace,
        isJapaneseSong: isJapaneseSong,
        leadSpans: leadSpans,
        harmonySpans: harmonySpans,
        activeFontSize: activeSize,
        palette: KonataPalette.dark,
        positionListenable: positionListenable,
        isPlayingListenable: isPlayingListenable,
        lyricOffsetSeconds: lyricOffsetSeconds,
        centerAligned: centerAligned,
      );
    } else if (isIntroStandby) {
      // 前奏期第 0 句以大字号纯白未扫白样式清晰就绪，进入演唱时间戳后再原位启动扫白。
      final standbyLeadColor = pureWhite.withValues(alpha: 0.44);
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
                color: isScrubFocused
                    ? pureWhite.withValues(alpha: 0.96)
                    : standbyLeadColor,
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
                color: pureWhite.withValues(alpha: 0.42),
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
                color: pureWhite.withValues(
                  alpha: isScrubFocused ? 0.96 : 0.94,
                ),
                fontSize: inactiveSize,
                fontWeight: isScrubFocused ? FontWeight.w600 : FontWeight.w500,
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
                color: pureWhite.withValues(
                  alpha: isScrubFocused ? 0.72 : 0.68,
                ),
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
          color: pureWhite.withValues(alpha: isScrubFocused ? 0.96 : 0.94),
          fontSize: inactiveSize,
          fontWeight: isScrubFocused ? FontWeight.w600 : FontWeight.w500,
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
                  color: pureWhite.withValues(
                    alpha: (isFocused || isScrubFocused) ? 0.64 : 0.56,
                  ),
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
                  color: pureWhite.withValues(
                    alpha: (isFocused || isScrubFocused) ? 0.78 : 0.70,
                  ),
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
/// 直连外部播放进度与播放状态监听句柄，使用单调时钟外推加 60 毫秒内柔性纠偏，
/// 暂停、行结束或不可见时立即停钟，严禁空转。
class _ActiveKaraokeSweepLeaf extends StatefulWidget {
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
    required this.positionListenable,
    required this.isPlayingListenable,
    required this.lyricOffsetSeconds,
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
  final ValueListenable<Duration> positionListenable;
  final ValueListenable<bool> isPlayingListenable;
  final double lyricOffsetSeconds;
  final bool centerAligned;

  @override
  State<_ActiveKaraokeSweepLeaf> createState() =>
      _ActiveKaraokeSweepLeafState();
}

class _ActiveKaraokeSweepLeafState extends State<_ActiveKaraokeSweepLeaf>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final ValueNotifier<double> _progressNotifier;
  final KaraokeClockExtrapolator _extrapolator = KaraokeClockExtrapolator();

  late double _windowStart;
  late double _windowEnd;
  double _lastTickClockSeconds = 0.0;
  double? _pendingMediaPosSeconds;
  bool _tickerVisible = true;

  double _currentEffectivePosSeconds() =>
      (widget.positionListenable.value.inMicroseconds / 1000000.0) +
      widget.lyricOffsetSeconds;

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
    if (!widget.isPlayingListenable.value || !_tickerVisible) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
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
    // 唱完本行立即停钟，严禁行结束后仍保持常驻空闲时钟。
    if (nextProgress >= 1.0 && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onPositionTick() {
    if (!mounted) return;
    _syncFromMediaClock(
      _currentEffectivePosSeconds(),
      widget.isPlayingListenable.value,
    );
  }

  void _onPlayingStateChanged() {
    if (!mounted) return;
    _syncFromMediaClock(
      _currentEffectivePosSeconds(),
      widget.isPlayingListenable.value,
      forceSnap: true,
    );
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
      // 在途帧内以同一单调时钟消费底层回报，小于 60 毫秒自动柔性收敛。
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
    widget.positionListenable.addListener(_onPositionTick);
    widget.isPlayingListenable.addListener(_onPlayingStateChanged);
    _syncFromMediaClock(
      _currentEffectivePosSeconds(),
      widget.isPlayingListenable.value,
      forceSnap: true,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _tickerVisible) {
      _tickerVisible = visible;
      _syncFromMediaClock(
        _currentEffectivePosSeconds(),
        widget.isPlayingListenable.value,
        forceSnap: true,
      );
    }
  }

  @override
  void didUpdateWidget(covariant _ActiveKaraokeSweepLeaf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionListenable != widget.positionListenable) {
      oldWidget.positionListenable.removeListener(_onPositionTick);
      widget.positionListenable.addListener(_onPositionTick);
    }
    if (oldWidget.isPlayingListenable != widget.isPlayingListenable) {
      oldWidget.isPlayingListenable.removeListener(_onPlayingStateChanged);
      widget.isPlayingListenable.addListener(_onPlayingStateChanged);
    }

    final timingChanged =
        oldWidget.leadText != widget.leadText ||
        oldWidget.romajiText != widget.romajiText ||
        oldWidget.lineStartSeconds != widget.lineStartSeconds ||
        oldWidget.lineEndSeconds != widget.lineEndSeconds ||
        oldWidget.nextLineStartSeconds != widget.nextLineStartSeconds ||
        oldWidget.secondsPerMora != widget.secondsPerMora ||
        oldWidget.isJapaneseSong != widget.isJapaneseSong ||
        oldWidget.leadSpans != widget.leadSpans ||
        oldWidget.harmonySpans != widget.harmonySpans ||
        oldWidget.lyricOffsetSeconds != widget.lyricOffsetSeconds ||
        oldWidget.positionListenable != widget.positionListenable ||
        oldWidget.isPlayingListenable != widget.isPlayingListenable;

    if (timingChanged) {
      _recomputeWindow();
      _syncFromMediaClock(
        _currentEffectivePosSeconds(),
        widget.isPlayingListenable.value,
        forceSnap: true,
      );
    }
  }

  @override
  void dispose() {
    widget.positionListenable.removeListener(_onPositionTick);
    widget.isPlayingListenable.removeListener(_onPlayingStateChanged);
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
    const pureWhite = KonataTheme.pureWhite;
    final litLeadColor = pureWhite.withValues(alpha: 0.96);
    final baseLeadColor = pureWhite.withValues(alpha: 0.44);
    final leadBaseStyle = TextStyle(
      color: baseLeadColor,
      fontSize: widget.activeFontSize,
      fontWeight: FontWeight.w700,
      height: 1.36,
    );
    final leadLitStyle = leadBaseStyle.copyWith(
      color: litLeadColor,
      shadows: [
        Shadow(
          color: pureWhite.withValues(alpha: 0.34),
          blurRadius: KonataPlaybackTokens.lyricSweepGlowBlurRadius,
        ),
      ],
    );

    final hasLeadSpans = widget.leadSpans.isNotEmpty;
    final harmonyText = widget.harmonySpans.map((s) => s.text).join();
    final harmonyBaseStyle = TextStyle(
      color: pureWhite.withValues(alpha: 0.42),
      fontSize: KonataPlaybackTokens.lyricSecondaryFontSize,
      fontWeight: FontWeight.w500,
      height: 1.28,
    );
    final harmonyLitStyle = harmonyBaseStyle.copyWith(
      color: pureWhite.withValues(alpha: 0.78),
    );

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
