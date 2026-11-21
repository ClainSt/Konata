import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../../domain/playback/playback_formatters.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_pill_button.dart';
import 'immersive_audio_sub_widgets.dart';

/// 独立自托管滚动歌词视口组件（全端共享）。
///
/// 每次挂载独立持有专属 [ScrollController]、行 [GlobalKey] 列表与滚动定时器，
/// 彻底隔离 `AnimatedSwitcher` / 面板切换淡出期间新旧双实例并存导致的
/// `GlobalKey` 冲突与 `ScrollController` 多附着异常；同时在首次挂载、切歌、
/// 歌词晚到与长距离跳转时自动执行多轮收敛精确居中至当前播放句。
class ImmersiveLyricsViewport extends ConsumerStatefulWidget {
  /// 创建独立自托管歌词视口。
  const ImmersiveLyricsViewport({
    super.key,
    required this.itemId,
    required this.lrc,
    required this.notifier,
    this.compact = false,
    this.centerAligned = false,
    this.onTapEmptyArea,
  });

  /// 当前曲目唯一标识（切歌时重置拖拽态并重新对齐当前句）。
  final String itemId;

  /// 已解析的同步歌词文档（为空时展示克制空态或移动网络 AMLL 确认入口）。
  final LrcDocument? lrc;

  /// 音频播放控制器。
  final AudioPlaybackNotifier notifier;

  /// 是否启用紧凑字号与锚点比例（手机横屏等矮视口）。
  final bool compact;

  /// 是否居中排版（手机竖屏对齐经典歌词布局）。
  final bool centerAligned;

  /// 点击歌词区回调（手机竖屏用于切回封面）。
  final VoidCallback? onTapEmptyArea;

  @override
  ConsumerState<ImmersiveLyricsViewport> createState() =>
      _ImmersiveLyricsViewportState();
}

class _ImmersiveLyricsViewportState
    extends ConsumerState<ImmersiveLyricsViewport> {
  final ScrollController _scrollCtrl = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  List<GlobalKey> _lineKeys = const [];

  bool _isUserScrolling = false;
  bool _activelyDragging = false;
  bool _programmaticScroll = false;
  int? _scrubTargetIndex;
  int _lastActiveLyricIndex = -1;
  int _centerGeneration = 0;
  double _lastAnchorY = 200.0;

  Timer? _scrollResetTimer;
  Timer? _scrollIdleTimer;
  Timer? _programmaticScrollTimer;

  @override
  void initState() {
    super.initState();
    _syncLineKeys(widget.lrc);
    _lastActiveLyricIndex = ref.read(audioPlaybackProvider).activeLyricIndex;
    _scheduleCenterActiveLyric(animated: false, refineAttemptsLeft: 3);
  }

  @override
  void didUpdateWidget(covariant ImmersiveLyricsViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final itemChanged = oldWidget.itemId != widget.itemId;
    final lrcChanged = !identical(oldWidget.lrc, widget.lrc);
    if (lrcChanged) {
      _syncLineKeys(widget.lrc);
    }
    if (itemChanged || lrcChanged) {
      _scrollResetTimer?.cancel();
      _scrollIdleTimer?.cancel();
      _isUserScrolling = false;
      _activelyDragging = false;
      _scrubTargetIndex = null;
      _lastActiveLyricIndex = ref.read(audioPlaybackProvider).activeLyricIndex;
      _scheduleCenterActiveLyric(animated: false, refineAttemptsLeft: 3);
    }
  }

  @override
  void dispose() {
    _centerGeneration++;
    _scrollResetTimer?.cancel();
    _scrollIdleTimer?.cancel();
    _programmaticScrollTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _syncLineKeys(LrcDocument? doc) {
    final len = doc?.lines.length ?? 0;
    if (_lineKeys.length != len) {
      _lineKeys = List<GlobalKey>.generate(len, (_) => GlobalKey());
    }
  }

  double _resolveAnchorY(double viewportH) {
    final anchorRatio = widget.compact
        ? KonataPlaybackTokens.lyricCompactViewportAnchorRatio
        : KonataPlaybackTokens.lyricViewportAnchorRatio;
    final minAnchor = math.min(viewportH * 0.5, widget.compact ? 44.0 : 84.0);
    final maxAnchor = math.max(
      minAnchor,
      viewportH - (widget.compact ? 48.0 : 88.0),
    );
    return (viewportH * anchorRatio).clamp(minAnchor, maxAnchor);
  }

  /// 计算当前最接近中央时间轴基准线 [anchorY] 的歌词行索引。
  int _resolveCenterLyricIndex(LrcDocument lrc, double anchorY) {
    final total = lrc.lines.length;
    if (total == 0) return 0;
    final vpObj = _viewportKey.currentContext?.findRenderObject();
    if (vpObj is RenderBox && vpObj.hasSize && vpObj.size.height > 1.0) {
      var bestIdx = -1;
      var bestDist = double.infinity;
      final limit = math.min(total, _lineKeys.length);
      for (var i = 0; i < limit; i++) {
        final ctx = _lineKeys[i].currentContext;
        if (ctx == null) continue;
        final box = ctx.findRenderObject();
        if (box is! RenderBox || !box.hasSize) continue;
        final centerY = box
            .localToGlobal(Offset(0, box.size.height * 0.5), ancestor: vpObj)
            .dy;
        final dist = (centerY - anchorY).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestIdx = i;
        }
      }
      if (bestIdx >= 0) return bestIdx;
    }
    if (_scrollCtrl.positions.length == 1) {
      final maxExtent = _scrollCtrl.position.maxScrollExtent;
      if (maxExtent > 1.0) {
        final ratio = (_scrollCtrl.offset / maxExtent).clamp(0.0, 1.0);
        return (ratio * (total - 1)).round().clamp(0, total - 1);
      }
    }
    return (_lastActiveLyricIndex >= 0 ? _lastActiveLyricIndex : 0).clamp(
      0,
      total - 1,
    );
  }

  void _scheduleLyricScrollResetTimer() {
    _scrollResetTimer?.cancel();
    _scrollResetTimer = Timer(
      KonataPlaybackTokens.lyricUserScrollResetDelay,
      () {
        if (!mounted) return;
        setState(() {
          _isUserScrolling = false;
          _activelyDragging = false;
          _scrubTargetIndex = null;
        });
        _scheduleCenterActiveLyric(animated: true, refineAttemptsLeft: 2);
      },
    );
  }

  void _onUserLyricScrollActivity(
    LrcDocument lrc,
    double anchorY, {
    required bool activeDrag,
  }) {
    final targetIdx = _resolveCenterLyricIndex(lrc, anchorY);
    if (!_isUserScrolling ||
        _activelyDragging != activeDrag ||
        _scrubTargetIndex != targetIdx) {
      setState(() {
        _isUserScrolling = true;
        _activelyDragging = activeDrag;
        _scrubTargetIndex = targetIdx;
      });
    }
    _scrollIdleTimer?.cancel();
    _scrollResetTimer?.cancel();
    if (activeDrag) {
      _scrollIdleTimer = Timer(
        KonataPlaybackTokens.lyricScrollIdleSettleDelay,
        () {
          if (!mounted || !_isUserScrolling) return;
          final settledIdx = _resolveCenterLyricIndex(lrc, anchorY);
          if (_activelyDragging || _scrubTargetIndex != settledIdx) {
            setState(() {
              _activelyDragging = false;
              _scrubTargetIndex = settledIdx;
            });
          }
          _scheduleLyricScrollResetTimer();
        },
      );
    } else {
      _scheduleLyricScrollResetTimer();
    }
  }

  void _onUserLyricScrollEnded(LrcDocument lrc, double anchorY) {
    if (!_isUserScrolling) return;
    _scrollIdleTimer?.cancel();
    final targetIdx = _resolveCenterLyricIndex(lrc, anchorY);
    if (_activelyDragging || _scrubTargetIndex != targetIdx) {
      setState(() {
        _activelyDragging = false;
        _scrubTargetIndex = targetIdx;
      });
    }
    _scheduleLyricScrollResetTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isUserScrolling) return;
      final refined = _resolveCenterLyricIndex(lrc, anchorY);
      if (_scrubTargetIndex != refined) {
        setState(() => _scrubTargetIndex = refined);
      }
    });
  }

  void _cancelUserLyricScrub() {
    _scrollResetTimer?.cancel();
    _scrollIdleTimer?.cancel();
    if (_isUserScrolling || _activelyDragging || _scrubTargetIndex != null) {
      setState(() {
        _isUserScrolling = false;
        _activelyDragging = false;
        _scrubTargetIndex = null;
      });
    }
  }

  void _commitScrubSeek(LrcDocument lrc) {
    final idx = _scrubTargetIndex;
    if (idx == null || idx < 0 || idx >= lrc.lines.length) return;
    final targetSec = lrc.lines[idx].startSeconds;
    _scrollResetTimer?.cancel();
    _scrollIdleTimer?.cancel();
    setState(() {
      _isUserScrolling = false;
      _activelyDragging = false;
      _scrubTargetIndex = null;
    });
    widget.notifier.seekRelativeTrackSeconds(targetSec);
    if (!ref.read(audioPlaybackProvider).isPlaying) {
      widget.notifier.togglePlayPause();
    }
  }

  void _beginProgrammaticScroll({required bool animated}) {
    _programmaticScroll = true;
    _programmaticScrollTimer?.cancel();
    if (animated) {
      _programmaticScrollTimer = Timer(
        KonataPlaybackTokens.lyricProgrammaticScrollSettleDelay,
        () {
          _programmaticScroll = false;
        },
      );
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _programmaticScroll = false;
      });
    }
  }

  void _scheduleCenterActiveLyric({
    required bool animated,
    int refineAttemptsLeft = 2,
  }) {
    final gen = ++_centerGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || gen != _centerGeneration || _isUserScrolling) return;
      _centerActiveLyric(
        animated: animated,
        refineAttemptsLeft: refineAttemptsLeft,
        gen: gen,
      );
    });
  }

  /// 将当前激活歌词句精确收敛对齐至视口锚点。
  ///
  /// 懒加载 `ListView.builder` 在切回歌词页或跨段跳转时目标行尚未构建，
  /// 本方法先基于已构建邻近行实测均高快速跃迁使目标行落入视口，再于下一帧微调至 0px 精准居中。
  void _centerActiveLyric({
    required bool animated,
    required int refineAttemptsLeft,
    required int gen,
  }) {
    if (!mounted || gen != _centerGeneration || _isUserScrolling) return;
    if (_scrollCtrl.positions.length != 1) return;
    final total = _lineKeys.length;
    if (total == 0) return;

    final pos = _scrollCtrl.position;
    final idx = _lastActiveLyricIndex;
    if (idx < 0) {
      if (pos.pixels > 1.0) {
        _beginProgrammaticScroll(animated: animated);
        if (animated) {
          unawaited(
            _scrollCtrl.animateTo(
              0.0,
              duration: KonataTheme.motionEmphasis,
              curve: Curves.easeOutCubic,
            ),
          );
        } else {
          _scrollCtrl.jumpTo(0.0);
        }
      }
      return;
    }

    final clampedIdx = idx.clamp(0, total - 1);
    final vpObj = _viewportKey.currentContext?.findRenderObject();
    final hasVp = vpObj is RenderBox && vpObj.hasSize && vpObj.size.height > 1;
    final anchorY = hasVp ? _resolveAnchorY(vpObj.size.height) : _lastAnchorY;

    // 1. 目标行已构建：按实测渲染盒中心与锚点差值直接对齐。
    final targetCtx = _lineKeys[clampedIdx].currentContext;
    if (targetCtx != null && hasVp) {
      final box = targetCtx.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final centerY = box
            .localToGlobal(Offset(0, box.size.height * 0.5), ancestor: vpObj)
            .dy;
        final delta = centerY - anchorY;
        if (delta.abs() > 1.5) {
          final targetOffset = (_scrollCtrl.offset + delta).clamp(
            0.0,
            pos.maxScrollExtent,
          );
          _beginProgrammaticScroll(animated: animated);
          if (animated) {
            unawaited(
              _scrollCtrl.animateTo(
                targetOffset,
                duration: KonataTheme.motionEmphasis,
                curve: Curves.easeOutCubic,
              ),
            );
          } else {
            _scrollCtrl.jumpTo(targetOffset);
          }
        }
        return;
      }
    }

    // 2. 目标行尚未进入懒构建窗口：基于当前已挂载行均高估算位移先跳转，下一帧再做像素精校。
    var builtCount = 0;
    var heightSum = 0.0;
    var nearestIdx = -1;
    var nearestDist = total + 1;
    var nearestCenterY = anchorY;
    if (hasVp) {
      for (var i = 0; i < total; i++) {
        final ctx = _lineKeys[i].currentContext;
        if (ctx == null) continue;
        final box = ctx.findRenderObject();
        if (box is! RenderBox || !box.hasSize) continue;
        builtCount++;
        heightSum += box.size.height;
        final d = (i - clampedIdx).abs();
        if (d < nearestDist) {
          nearestDist = d;
          nearestIdx = i;
          nearestCenterY = box
              .localToGlobal(Offset(0, box.size.height * 0.5), ancestor: vpObj)
              .dy;
        }
      }
    }

    final double targetOffset;
    if (nearestIdx >= 0 && builtCount > 0) {
      final avgHeight = (heightSum / builtCount).clamp(32.0, 200.0);
      final estDelta =
          (nearestCenterY - anchorY) + (clampedIdx - nearestIdx) * avgHeight;
      targetOffset = (_scrollCtrl.offset + estDelta).clamp(
        0.0,
        pos.maxScrollExtent,
      );
    } else {
      final estRatio = total <= 1 ? 0.0 : clampedIdx / (total - 1);
      targetOffset = (estRatio * pos.maxScrollExtent).clamp(
        0.0,
        pos.maxScrollExtent,
      );
    }

    if ((targetOffset - pos.pixels).abs() > 1.0) {
      _beginProgrammaticScroll(animated: false);
      _scrollCtrl.jumpTo(targetOffset);
    }

    if (refineAttemptsLeft > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || gen != _centerGeneration || _isUserScrolling) return;
        _centerActiveLyric(
          animated: false,
          refineAttemptsLeft: refineAttemptsLeft - 1,
          gen: gen,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      audioPlaybackProvider.select((s) => s.activeLyricIndex),
      (prev, next) {
        if (next == _lastActiveLyricIndex) return;
        _lastActiveLyricIndex = next;
        if (!_isUserScrolling) {
          _scheduleCenterActiveLyric(animated: true, refineAttemptsLeft: 2);
        }
      },
    );

    final p = context.palette;
    final lrc = widget.lrc;
    if (lrc == null || lrc.lines.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTapEmptyArea,
        child: Center(
          child: Consumer(
            builder: (ctx, cRef, _) {
              final needsAmllConfirm = cRef.watch(
                audioPlaybackProvider.select(
                  (s) => s.needsMobileAmllLyricConfirmation,
                ),
              );
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lyrics_outlined, size: 40, color: p.textMuted),
                  const SizedBox(height: 12),
                  Text(
                    needsAmllConfirm
                        ? '当前处于移动计量网络，拉取 AMLL 逐字歌词索引需消耗流量'
                        : '当前曲目暂无同步歌词',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeBodyMd,
                    ),
                  ),
                  if (needsAmllConfirm) ...[
                    const SizedBox(height: 12),
                    KonataPillButton.primary(
                      key: const ValueKey('confirm_mobile_amll_lyric_button'),
                      label: '允许加载 AMLL 歌词',
                      icon: Icons.cloud_download_outlined,
                      compact: true,
                      onPressed: () => unawaited(
                        widget.notifier.confirmMobileAmllLyricLookup(),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      );
    }

    _syncLineKeys(lrc);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 480.0;
        final guideH = widget.compact
            ? KonataPlaybackTokens.lyricScrubCompactGuideHeight
            : KonataPlaybackTokens.lyricScrubGuideHeight;
        final anchorY = _resolveAnchorY(viewportH);
        _lastAnchorY = anchorY;
        final topSpacer = math.max(12.0, anchorY - guideH * 0.5);
        final bottomSpacer = math.max(24.0, viewportH - anchorY - guideH * 0.5);
        final scrubIdx = _isUserScrolling
            ? (_scrubTargetIndex ??
                      (_lastActiveLyricIndex >= 0 ? _lastActiveLyricIndex : 0))
                  .clamp(0, lrc.lines.length - 1)
            : null;
        final scrubLine = scrubIdx != null ? lrc.lines[scrubIdx] : null;
        final scrubSettled = scrubLine != null && !_activelyDragging;
        final isAndroid = KonataAdaptiveTokens.isAndroid;
        final playButtonSize = isAndroid
            ? KonataAdaptiveTokens.touchTarget
            : 36.0;
        final listPadLeft = widget.compact ? 48.0 : 54.0;
        final listPadRight = isAndroid ? 50.0 : 42.0;
        final viewportW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 480.0;
        final middleTrackWidth = math.max(
          0.0,
          viewportW -
              KonataPlaybackTokens.lyricScrubTimeWidth -
              playButtonSize,
        );

        // 测量焦点句实际文本宽度，将中央虚线精确避开歌词文本区域，绝不穿过或遮挡任何文字。
        var textExcludeLeft = 0.0;
        var textExcludeRight = 0.0;
        if (scrubLine != null && middleTrackWidth > 16.0) {
          final isFocusActive = scrubIdx == _lastActiveLyricIndex;
          final fontSize = isFocusActive
              ? (widget.compact
                    ? KonataPlaybackTokens.lyricCompactActiveFontSize
                    : KonataPlaybackTokens.lyricActiveFontSize)
              : (widget.compact
                    ? KonataPlaybackTokens.lyricCompactInactiveFontSize
                    : KonataPlaybackTokens.lyricInactiveFontSize);
          final textMaxW = math.max(
            0.0,
            viewportW - listPadLeft - listPadRight - 16.0,
          );
          final painter = TextPainter(
            text: TextSpan(
              text: scrubLine.primaryText,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: isFocusActive ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: textMaxW);
          final measuredW = math.min(painter.width, textMaxW);
          painter.dispose();
          final textRegionStart =
              (listPadLeft + 8.0) - KonataPlaybackTokens.lyricScrubTimeWidth;
          final textRegionWidth = textMaxW;
          if (widget.centerAligned) {
            final centerX = textRegionStart + textRegionWidth * 0.5;
            textExcludeLeft = (centerX - measuredW * 0.5 - 10.0).clamp(
              0.0,
              middleTrackWidth,
            );
            textExcludeRight = (centerX + measuredW * 0.5 + 10.0).clamp(
              0.0,
              middleTrackWidth,
            );
          } else {
            textExcludeLeft = math.max(0.0, textRegionStart - 8.0);
            textExcludeRight = (textRegionStart + measuredW + 12.0).clamp(
              0.0,
              middleTrackWidth,
            );
          }
        }

        return SizedBox(
          key: _viewportKey,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 三端统一隐藏歌词滚动条，禁止直接点击单句跳播；改为上下滚动唤出中央时间轴定位跳转。
              Positioned.fill(
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      _onUserLyricScrollActivity(
                        lrc,
                        anchorY,
                        activeDrag: true,
                      );
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: widget.onTapEmptyArea == null
                        ? null
                        : () {
                            if (_isUserScrolling) {
                              _cancelUserLyricScrub();
                            }
                            widget.onTapEmptyArea!();
                          },
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollStartNotification) {
                          if (notification.dragDetails != null ||
                              !_programmaticScroll) {
                            _onUserLyricScrollActivity(
                              lrc,
                              anchorY,
                              activeDrag: true,
                            );
                          }
                        } else if (notification is UserScrollNotification) {
                          if (notification.direction != ScrollDirection.idle) {
                            _onUserLyricScrollActivity(
                              lrc,
                              anchorY,
                              activeDrag: true,
                            );
                          }
                        } else if (notification is ScrollUpdateNotification) {
                          if (!_programmaticScroll &&
                              (notification.dragDetails != null ||
                                  _isUserScrolling)) {
                            _onUserLyricScrollActivity(
                              lrc,
                              anchorY,
                              activeDrag: true,
                            );
                          }
                        } else if (notification is ScrollEndNotification) {
                          if (_isUserScrolling) {
                            _onUserLyricScrollEnded(lrc, anchorY);
                          }
                        }
                        return false;
                      },
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              KonataTheme.pureWhite,
                              KonataTheme.pureWhite,
                              Colors.transparent,
                            ],
                            stops: [0.0, 0.10, 0.88, 1.0],
                          ).createShader(bounds),
                          blendMode: BlendMode.dstIn,
                          child: ListView.builder(
                            key: const ValueKey('immersive_lyrics_list'),
                            controller: _scrollCtrl,
                            padding: EdgeInsets.fromLTRB(
                              listPadLeft,
                              topSpacer,
                              listPadRight,
                              bottomSpacer,
                            ),
                            itemCount: lrc.lines.length,
                            itemBuilder: (context, index) {
                              final line = lrc.lines[index];
                              final nextStart = index + 1 < lrc.lines.length
                                  ? lrc.lines[index + 1].startSeconds
                                  : null;
                              final songPaceSecPerChar =
                                  lrc.estimatedSecondsPerChar;
                              final spanLines = ref
                                  .read(audioPlaybackProvider)
                                  .activeSpanLines;
                              final activeSpanLine =
                                  LyricVersionMatcher.matchLineForTimestamp(
                                    spanLines,
                                    line.startSeconds,
                                  );
                              return KeyedSubtree(
                                key: _lineKeys[index],
                                child: ImmersiveLyricLineLeaf(
                                  index: index,
                                  line: line,
                                  activeSpanLine: activeSpanLine,
                                  nextLineStartSeconds: nextStart,
                                  estimatedSecondsPerChar: songPaceSecPerChar,
                                  compact: widget.compact,
                                  centerAligned: widget.centerAligned,
                                  userScrolling: _isUserScrolling,
                                  isScrubFocused: scrubIdx == index,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 中央时间轴虚线定位层：去大框背景，仅在歌词文字外的空白区间绘制轻盈虚线，绝不遮挡歌词文字。
              if (scrubLine != null)
                Positioned(
                  key: const ValueKey('lyric_timeline_scrub_guide'),
                  left: 0,
                  right: 0,
                  top: (anchorY - guideH * 0.5).clamp(
                    0.0,
                    math.max(0.0, viewportH - guideH),
                  ),
                  height: guideH,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      IgnorePointer(
                        child: SizedBox(
                          width: KonataPlaybackTokens.lyricScrubTimeWidth,
                          child: Text(
                            PlaybackFormatters.formatMediaDuration(
                              scrubLine.startSeconds,
                            ),
                            key: const ValueKey(
                              'lyric_timeline_scrub_timestamp',
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: p.textSecondary.withValues(alpha: 0.9),
                              fontSize: KonataTheme.fontSizeCaption,
                              fontWeight: FontWeight.w500,
                              fontFeatures: KonataPlaybackTokens.tabularNumbers,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            IgnorePointer(
                              child: CustomPaint(
                                key: const ValueKey(
                                  'lyric_timeline_dashed_line',
                                ),
                                painter: _LyricScrubDashedLinePainter(
                                  color: p.textPrimary.withValues(
                                    alpha: p.isDark ? 0.28 : 0.24,
                                  ),
                                  excludeLeft: textExcludeLeft,
                                  excludeRight: textExcludeRight,
                                ),
                              ),
                            ),
                            if (scrubSettled)
                              GestureDetector(
                                key: const ValueKey('lyric_timeline_seek_band'),
                                behavior: HitTestBehavior.translucent,
                                onTap: () => _commitScrubSeek(lrc),
                                child: const SizedBox.expand(),
                              ),
                          ],
                        ),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          key: const ValueKey(
                            'lyric_timeline_seek_play_button',
                          ),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _commitScrubSeek(lrc),
                          child: SizedBox.square(
                            dimension: playButtonSize,
                            child: Center(
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                                color: p.textPrimary.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 歌词拖拽定位中央虚线绘制器：自动跳过当前焦点句文本占用区间 `[excludeLeft, excludeRight]`，
/// 仅在两侧空白处绘出轻盈虚线，保证歌词清晰无遮挡。
class _LyricScrubDashedLinePainter extends CustomPainter {
  const _LyricScrubDashedLinePainter({
    required this.color,
    required this.excludeLeft,
    required this.excludeRight,
  });

  final Color color;
  final double excludeLeft;
  final double excludeRight;

  static const double _dashWidth = 4.5;
  static const double _dashGap = 4.0;

  void _drawDashedSpan(
    Canvas canvas,
    Paint paint,
    double y,
    double startX,
    double endX,
  ) {
    if (endX - startX < _dashWidth) return;
    var x = startX;
    while (x < endX) {
      final segEnd = math.min(x + _dashWidth, endX);
      canvas.drawLine(Offset(x, y), Offset(segEnd, y), paint);
      x += _dashWidth + _dashGap;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final y = size.height * 0.5;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;

    const edgeInset = 4.0;
    final maxX = size.width - edgeInset;
    final exLeft = excludeLeft.clamp(edgeInset, maxX);
    final exRight = excludeRight.clamp(exLeft, maxX);

    _drawDashedSpan(canvas, paint, y, edgeInset, exLeft);
    _drawDashedSpan(canvas, paint, y, exRight, maxX);
  }

  @override
  bool shouldRepaint(covariant _LyricScrubDashedLinePainter oldDelegate) {
    return oldDelegate.color != color ||
        (oldDelegate.excludeLeft - excludeLeft).abs() > 0.5 ||
        (oldDelegate.excludeRight - excludeRight).abs() > 0.5;
  }
}
