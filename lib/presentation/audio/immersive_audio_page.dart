import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../composition/platform_composition.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../../domain/playback/playback_formatters.dart';
import '../shell/adaptive_capsule_layout.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/playback/konata_cached_artwork_backdrop.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_stage_morph_frame.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'immersive_audio_sub_widgets.dart';

part 'immersive_audio_stages.dart';

/// 手机竖屏全屏音频页内嵌播放队列底部抽屉开关状态（供根返回键拦截器优先收起抽屉）。
final immersivePortraitQueueSheetOpenProvider = StateProvider<bool>(
  (ref) => false,
);

enum _ImmersiveRightPane { lyrics, queue }

/// 全屏流光音频播放器页面（覆盖桌面双栏、Android 平板底部居中控制坞双栏、手机竖屏三段单列与手机矮横屏 44:56 双栏）。
class ImmersiveAudioPage extends ConsumerStatefulWidget {
  /// 创建全屏流光音频页。
  const ImmersiveAudioPage({super.key});

  @override
  ConsumerState<ImmersiveAudioPage> createState() => _ImmersiveAudioPageState();
}

class _ImmersiveAudioPageState extends ConsumerState<ImmersiveAudioPage> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'immersive_audio_focus');
  final ScrollController _lyricScrollCtrl = ScrollController();
  final ScrollController _queueScrollCtrl = ScrollController();

  _ImmersiveRightPane _pane = _ImmersiveRightPane.lyrics;
  bool _userPinnedPane = false;
  bool _portraitShowLyricsInPlace = false;
  bool _isUserScrollingLyrics = false;
  bool _lyricScrollActivelyDragging = false;
  bool _programmaticLyricScroll = false;
  int? _scrubTargetLyricIndex;
  double _pullDownDy = 0.0;
  BuildContext? _activeQueueSheetContext;
  Timer? _scrollResetTimer;
  Timer? _scrollIdleTimer;
  Timer? _programmaticScrollTimer;
  final GlobalKey _activeQueueItemKey = GlobalKey();
  final GlobalKey _lyricViewportKey = GlobalKey();
  List<GlobalKey> _lyricKeys = const [];
  String? _lastItemId;
  int _lastActiveLyricIndex = -1;
  _ImmersiveRightPane? _lastEffectivePane;
  bool _amllConfirmDialogShowing = false;
  String? _amllPromptedItemId;

  @override
  void initState() {
    super.initState();
    _lastActiveLyricIndex = ref.read(audioPlaybackProvider).activeLyricIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _scrollToActiveQueueItem(animated: false);
      if (_lastActiveLyricIndex >= 0) {
        _scrollToActiveLyric(animated: false);
      }
    });
  }

  void _scheduleQueueCentering({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToActiveQueueItem(animated: animated);
    });
  }

  void _scrollToActiveQueueItem({required bool animated}) {
    if (!_queueScrollCtrl.hasClients) return;
    final state = ref.read(audioPlaybackProvider);
    final rows = state.buildDisplayRows();
    if (rows.isEmpty) return;
    var rowIdx = rows.indexWhere((r) => r.isActiveTrack);
    if (rowIdx < 0) {
      rowIdx = rows.indexWhere((r) => r.isExpandedParent);
    }
    if (rowIdx < 0) return;

    final pos = _queueScrollCtrl.position;
    if (pos.maxScrollExtent <= 1.0) return;

    final targetRow = rows[rowIdx];
    final hasSub = targetRow.subtitle.trim().isNotEmpty;
    final estRowHeight = hasSub ? 56.0 : 40.0;
    final estStride = estRowHeight + 6.0;
    const topPad = 20.0;
    final estCenter = topPad + rowIdx * estStride + estRowHeight / 2.0;
    final viewportH = pos.viewportDimension;

    if (estCenter <= viewportH * 0.5 && pos.pixels <= 1.0) {
      return;
    }

    final targetOffset = (estCenter - viewportH / 2.0).clamp(
      0.0,
      pos.maxScrollExtent,
    );

    if ((pos.pixels - targetOffset).abs() > 2.0) {
      if (animated) {
        _queueScrollCtrl.animateTo(
          targetOffset,
          duration: KonataTheme.navSliderDuration,
          curve: Curves.easeOutCubic,
        );
      } else {
        _queueScrollCtrl.jumpTo(targetOffset);
      }
    }

    if (!animated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_queueScrollCtrl.hasClients) return;
        final ctx = _activeQueueItemKey.currentContext;
        if (ctx == null) return;
        final box = ctx.findRenderObject();
        final vpBox = _queueScrollCtrl.position.context.storageContext
            .findRenderObject();
        if (box is RenderBox &&
            vpBox is RenderBox &&
            box.hasSize &&
            vpBox.hasSize) {
          final local = box.localToGlobal(Offset.zero, ancestor: vpBox);
          final actualCenter = local.dy + box.size.height / 2.0;
          final delta = actualCenter - vpBox.size.height / 2.0;
          if (delta.abs() > 2.0) {
            final refined = (_queueScrollCtrl.offset + delta).clamp(
              0.0,
              _queueScrollCtrl.position.maxScrollExtent,
            );
            _queueScrollCtrl.jumpTo(refined);
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollResetTimer?.cancel();
    _scrollIdleTimer?.cancel();
    _programmaticScrollTimer?.cancel();
    _focusNode.dispose();
    _lyricScrollCtrl.dispose();
    _queueScrollCtrl.dispose();
    super.dispose();
  }

  void _closePortraitQueueSheet() {
    final sheetCtx = _activeQueueSheetContext;
    _activeQueueSheetContext = null;
    if (sheetCtx != null && sheetCtx.mounted) {
      final nav = Navigator.maybeOf(sheetCtx);
      if (nav != null && nav.canPop()) {
        nav.pop();
      }
    }
    if (ref.read(immersivePortraitQueueSheetOpenProvider)) {
      ref.read(immersivePortraitQueueSheetOpenProvider.notifier).state = false;
    }
  }

  void _collapseToMiniBar({double releaseVelocityPxPerSec = 0.0}) {
    _closePortraitQueueSheet();
    ref.read(stageMorphReleaseVelocityProvider.notifier).state =
        releaseVelocityPxPerSec;
    ref.read(immersiveAudioExpandedProvider.notifier).state = false;
  }

  /// 移动计量网络触发 AMLL 逐字歌词索引确认时，弹出全站统一毛玻璃确认框（确保竖屏封面态立即可见）。
  Future<void> _promptMobileAmllConfirmationDialog(
    AudioPlaybackNotifier notifier,
  ) async {
    final currentState = ref.read(audioPlaybackProvider);
    final currentItemId = currentState.currentItem?.id;
    if (!mounted ||
        _amllConfirmDialogShowing ||
        !currentState.needsMobileAmllLyricConfirmation ||
        currentItemId == null ||
        _amllPromptedItemId == currentItemId) {
      return;
    }
    _amllConfirmDialogShowing = true;
    _amllPromptedItemId = currentItemId;
    try {
      final approved = await showKonataGlassDialog<bool>(
        context: context,
        builder: (dialogCtx) {
          final dp = dialogCtx.palette;
          return KonataGlassDialog(
            key: const ValueKey('mobile_amll_confirm_glass_dialog'),
            title: '移动网络歌词流量提示',
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前处于移动计量网络，拉取 AMLL 逐字歌词开源索引需消耗额外移动流量，是否允许继续加载？',
                  style: KonataTheme.bodyLabelStyle(
                    dp,
                    fontSize: KonataTheme.fontSizeBodySm,
                    color: dp.textSecondary,
                  ).copyWith(height: 1.5),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    KonataPillButton.secondary(
                      key: const ValueKey('mobile_amll_dialog_cancel'),
                      label: '暂不加载',
                      compact: true,
                      onPressed: () => Navigator.of(dialogCtx).pop(false),
                    ),
                    const SizedBox(width: 10),
                    KonataPillButton.primary(
                      key: const ValueKey('mobile_amll_dialog_confirm'),
                      label: '允许加载',
                      icon: Icons.cloud_download_outlined,
                      compact: true,
                      onPressed: () => Navigator.of(dialogCtx).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
      if (approved == true && mounted) {
        await notifier.confirmMobileAmllLyricLookup();
      }
    } finally {
      _amllConfirmDialogShowing = false;
    }
  }

  void _syncLyricKeys(LrcDocument? doc) {
    final len = doc?.lines.length ?? 0;
    if (_lyricKeys.length != len) {
      _lyricKeys = List<GlobalKey>.generate(len, (_) => GlobalKey());
    }
  }

  /// 计算当前最接近中央时间轴基准线的歌词行索引。
  int _resolveCenterLyricIndex(LrcDocument lrc, double anchorRatio) {
    final total = lrc.lines.length;
    if (total == 0) return 0;
    final vpObj = _lyricViewportKey.currentContext?.findRenderObject();
    if (vpObj is RenderBox && vpObj.hasSize && vpObj.size.height > 1.0) {
      final targetY = vpObj.size.height * anchorRatio;
      var bestIdx = -1;
      var bestDist = double.infinity;
      final limit = math.min(total, _lyricKeys.length);
      for (var i = 0; i < limit; i++) {
        final ctx = _lyricKeys[i].currentContext;
        if (ctx == null) continue;
        final box = ctx.findRenderObject();
        if (box is! RenderBox || !box.hasSize) continue;
        final centerY = box
            .localToGlobal(Offset(0, box.size.height * 0.5), ancestor: vpObj)
            .dy;
        final dist = (centerY - targetY).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestIdx = i;
        }
      }
      if (bestIdx >= 0) return bestIdx;
    }
    if (_lyricScrollCtrl.hasClients) {
      final maxExtent = _lyricScrollCtrl.position.maxScrollExtent;
      if (maxExtent > 1.0) {
        final ratio = (_lyricScrollCtrl.offset / maxExtent).clamp(0.0, 1.0);
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
          _isUserScrollingLyrics = false;
          _lyricScrollActivelyDragging = false;
          _scrubTargetLyricIndex = null;
        });
        _scrollToActiveLyric(animated: true);
      },
    );
  }

  void _onUserLyricScrollActivity(
    LrcDocument lrc,
    double anchorRatio, {
    required bool activeDrag,
  }) {
    final targetIdx = _resolveCenterLyricIndex(lrc, anchorRatio);
    if (!_isUserScrollingLyrics ||
        _lyricScrollActivelyDragging != activeDrag ||
        _scrubTargetLyricIndex != targetIdx) {
      setState(() {
        _isUserScrollingLyrics = true;
        _lyricScrollActivelyDragging = activeDrag;
        _scrubTargetLyricIndex = targetIdx;
      });
    }
    _scrollIdleTimer?.cancel();
    _scrollResetTimer?.cancel();
    if (activeDrag) {
      _scrollIdleTimer = Timer(
        KonataPlaybackTokens.lyricScrollIdleSettleDelay,
        () {
          if (!mounted || !_isUserScrollingLyrics) return;
          final settledIdx = _resolveCenterLyricIndex(lrc, anchorRatio);
          if (_lyricScrollActivelyDragging ||
              _scrubTargetLyricIndex != settledIdx) {
            setState(() {
              _lyricScrollActivelyDragging = false;
              _scrubTargetLyricIndex = settledIdx;
            });
          }
          _scheduleLyricScrollResetTimer();
        },
      );
    } else {
      _scheduleLyricScrollResetTimer();
    }
  }

  void _onUserLyricScrollEnded(LrcDocument lrc, double anchorRatio) {
    if (!_isUserScrollingLyrics) return;
    _scrollIdleTimer?.cancel();
    final targetIdx = _resolveCenterLyricIndex(lrc, anchorRatio);
    if (_lyricScrollActivelyDragging || _scrubTargetLyricIndex != targetIdx) {
      setState(() {
        _lyricScrollActivelyDragging = false;
        _scrubTargetLyricIndex = targetIdx;
      });
    }
    _scheduleLyricScrollResetTimer();
  }

  void _cancelUserLyricScrub() {
    _scrollResetTimer?.cancel();
    _scrollIdleTimer?.cancel();
    if (_isUserScrollingLyrics ||
        _lyricScrollActivelyDragging ||
        _scrubTargetLyricIndex != null) {
      setState(() {
        _isUserScrollingLyrics = false;
        _lyricScrollActivelyDragging = false;
        _scrubTargetLyricIndex = null;
      });
    }
  }

  void _commitScrubSeek(LrcDocument lrc, AudioPlaybackNotifier notifier) {
    final idx = _scrubTargetLyricIndex;
    if (idx == null || idx < 0 || idx >= lrc.lines.length) return;
    final targetSec = lrc.lines[idx].startSeconds;
    _scrollResetTimer?.cancel();
    _scrollIdleTimer?.cancel();
    setState(() {
      _isUserScrollingLyrics = false;
      _lyricScrollActivelyDragging = false;
      _scrubTargetLyricIndex = null;
    });
    notifier.seekRelativeTrackSeconds(targetSec);
    if (!ref.read(audioPlaybackProvider).isPlaying) {
      notifier.togglePlayPause();
    }
  }

  void _beginProgrammaticLyricScroll({required bool animated}) {
    _programmaticLyricScroll = true;
    _programmaticScrollTimer?.cancel();
    if (animated) {
      _programmaticScrollTimer = Timer(
        KonataPlaybackTokens.lyricProgrammaticScrollSettleDelay,
        () {
          _programmaticLyricScroll = false;
        },
      );
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _programmaticLyricScroll = false;
      });
    }
  }

  void _scrollToActiveLyric({bool animated = true}) {
    final idx = _lastActiveLyricIndex;
    if (idx < 0 || idx >= _lyricKeys.length) return;
    final ctx = _lyricKeys[idx].currentContext;
    if (ctx != null) {
      _beginProgrammaticLyricScroll(animated: animated);
      Scrollable.ensureVisible(
        ctx,
        alignment: KonataPlaybackTokens.lyricViewportAnchorRatio,
        duration: animated ? KonataTheme.motionEmphasis : Duration.zero,
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (_lyricScrollCtrl.hasClients && _lyricKeys.isNotEmpty) {
      final estRatio = idx / _lyricKeys.length;
      final targetOffset =
          (estRatio * _lyricScrollCtrl.position.maxScrollExtent).clamp(
            0.0,
            _lyricScrollCtrl.position.maxScrollExtent,
          );
      _beginProgrammaticLyricScroll(animated: animated);
      if (animated) {
        _lyricScrollCtrl.animateTo(
          targetOffset,
          duration: KonataTheme.motionEmphasis,
          curve: Curves.easeOutCubic,
        );
      } else {
        _lyricScrollCtrl.jumpTo(targetOffset);
      }
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final state = ref.read(audioPlaybackProvider);

    if (key == LogicalKeyboardKey.escape) {
      if (ref.read(immersivePortraitQueueSheetOpenProvider)) {
        _closePortraitQueueSheet();
      } else {
        _collapseToMiniBar();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      notifier.togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      notifier.seekRelativeTrackSeconds(state.positionSeconds - 5.0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      notifier.seekRelativeTrackSeconds(state.positionSeconds + 5.0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      notifier.toggleMute();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openPortraitQueueSheet() {
    if (_activeQueueSheetContext != null) return;
    ref.read(immersivePortraitQueueSheetOpenProvider.notifier).state = true;
    _scheduleQueueCentering(animated: false);
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      barrierColor: KonataTheme.glassModalBarrier(isDark),
      builder: (sheetCtx) {
        _activeQueueSheetContext = sheetCtx;
        final size = MediaQuery.sizeOf(sheetCtx);
        final safe = MediaQuery.paddingOf(sheetCtx);
        final sheetHeight = (size.height * 0.68).clamp(260.0, 620.0);
        return Consumer(
          builder: (ctx, sheetRef, _) {
            final p = ctx.palette;
            final liveState = sheetRef.watch(audioPlaybackProvider);
            return KonataFollowFingerSheetSurface(
              surfaceKey: const ValueKey('portrait_queue_sheet_overlay'),
              height: sheetHeight,
              topRadius: 24.0,
              blurSigma: KonataPlaybackTokens.capsuleBlurSigma,
              surfaceColor: KonataPlaybackTokens.popoverSurface(p),
              borderColor: KonataPlaybackTokens.glassBorder(p),
              applyBottomSafeArea: false,
              dragHandleKey: const ValueKey('portrait_queue_drag_handle'),
              onDismiss: () => Navigator.of(sheetCtx).maybePop(),
              headerBuilder: (_) => Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 10, 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.queue_music_rounded,
                      size: 18,
                      color: p.progressFill,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '播放队列 (${liveState.queue.length})',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: KonataTheme.fontSizeTitleSm,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    KonataCapsuleIconButton(
                      key: const ValueKey('portrait_close_queue_button'),
                      icon: Icons.close_rounded,
                      tooltip: '关闭队列抽屉',
                      color: p.textSecondary,
                      size: 18,
                      fixedSize: KonataAdaptiveTokens.touchTarget,
                      onTap: () => Navigator.of(sheetCtx).maybePop(),
                    ),
                  ],
                ),
              ),
              body: Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: safe.bottom + 8),
                  child: _buildQueueViewport(
                    liveState,
                    notifier,
                    onPicked: () => Navigator.of(sheetCtx).maybePop(),
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _activeQueueSheetContext = null;
      if (mounted && ref.read(immersivePortraitQueueSheetOpenProvider)) {
        ref.read(immersivePortraitQueueSheetOpenProvider.notifier).state =
            false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 严格隔离高频进度与歌词跳变：顶层仅订阅低频曲目与控制状态，绝不订阅 positionSeconds 或 activeLyricIndex
    final snap = ref.watch(
      audioPlaybackProvider.select(
        (s) => (
          item: s.currentItem,
          lrc: s.lrcDocument,
          activeSpanLines: s.activeSpanLines,
          cover: s.cover,
          isPlaying: s.isPlaying,
          loopMode: s.loopMode,
          volume: s.volume,
          isMuted: s.isMuted,
          codecLabel: s.audioCodecLabel,
          rateDepthLabel: s.sampleRateAndBitDepthLabel,
          bitrateLabel: s.bitrateLabel,
          currentIndex: s.currentIndex,
          queue: s.queue,
        ),
      ),
    );
    ref.listen<bool>(immersivePortraitQueueSheetOpenProvider, (prev, next) {
      if (!next && _activeQueueSheetContext != null) {
        _closePortraitQueueSheet();
      }
    });
    ref.listen<int>(
      audioPlaybackProvider.select((s) => s.activeLyricIndex),
      (prev, next) {
        if (next == _lastActiveLyricIndex) return;
        _lastActiveLyricIndex = next;
        if (!_isUserScrollingLyrics) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_isUserScrollingLyrics) {
              _scrollToActiveLyric(animated: true);
            }
          });
        }
      },
    );

    final notifier = ref.read(audioPlaybackProvider.notifier);
    ref.listen<bool>(
      audioPlaybackProvider.select((s) => s.needsMobileAmllLyricConfirmation),
      (prev, next) {
        if (next && prev != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              unawaited(_promptMobileAmllConfirmationDialog(notifier));
            }
          });
        }
      },
    );
    final item = snap.item;
    if (item == null) return const SizedBox.shrink();
    if (ref.read(audioPlaybackProvider).needsMobileAmllLyricConfirmation &&
        !_amllConfirmDialogShowing &&
        _amllPromptedItemId != item.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_promptMobileAmllConfirmationDialog(notifier));
        }
      });
    }

    final lrc = snap.lrc;
    final hasLyrics = lrc != null && lrc.lines.isNotEmpty;
    final itemChanged = _lastItemId != item.id;
    if (itemChanged) {
      final hadPrev = _lastItemId != null;
      _lastItemId = item.id;
      _isUserScrollingLyrics = false;
      _lyricScrollActivelyDragging = false;
      _scrubTargetLyricIndex = null;
      _scrollResetTimer?.cancel();
      _scrollIdleTimer?.cancel();
      if (hadPrev) {
        _scheduleQueueCentering(animated: true);
      }
    }
    final effectivePane = _userPinnedPane
        ? _pane
        : (hasLyrics ? _ImmersiveRightPane.lyrics : _ImmersiveRightPane.queue);
    if (_lastEffectivePane != effectivePane) {
      _lastEffectivePane = effectivePane;
      if (effectivePane == _ImmersiveRightPane.queue) {
        _scheduleQueueCentering(animated: false);
      }
    }

    _syncLyricKeys(lrc);

    final specLabel = snap.codecLabel.isNotEmpty
        ? (snap.rateDepthLabel.isNotEmpty
              ? '${snap.codecLabel} · ${snap.rateDepthLabel}'
              : snap.codecLabel)
        : (snap.bitrateLabel.isNotEmpty ? snap.bitrateLabel : '');

    final size = MediaQuery.sizeOf(context);
    final safe = AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context);
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final isTablet =
        isAndroid && size.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint;
    final isShortPhone =
        isAndroid &&
        !isTablet &&
        size.height < KonataAdaptiveTokens.shortViewportHeight;
    final isPortraitPhone = isAndroid && !isTablet && !isShortPhone;
    final p = context.palette;

    Widget stageContent;
    if (!isAndroid) {
      stageContent = _buildDesktopStage(
        context: context,
        item: item,
        lrc: lrc,
        cover: snap.cover,
        isPlaying: snap.isPlaying,
        loopMode: snap.loopMode,
        volume: snap.volume,
        isMuted: snap.isMuted,
        specLabel: specLabel,
        effectivePane: effectivePane,
        notifier: notifier,
      );
    } else if (isTablet) {
      stageContent = _buildAndroidTabletStage(
        context: context,
        safe: safe,
        item: item,
        lrc: lrc,
        cover: snap.cover,
        isPlaying: snap.isPlaying,
        loopMode: snap.loopMode,
        volume: snap.volume,
        isMuted: snap.isMuted,
        specLabel: specLabel,
        effectivePane: effectivePane,
        notifier: notifier,
      );
    } else if (isShortPhone) {
      stageContent = _buildAndroidShortPhoneStage(
        context: context,
        safe: safe,
        item: item,
        lrc: lrc,
        cover: snap.cover,
        isPlaying: snap.isPlaying,
        loopMode: snap.loopMode,
        volume: snap.volume,
        isMuted: snap.isMuted,
        specLabel: specLabel,
        effectivePane: effectivePane,
        notifier: notifier,
      );
    } else {
      stageContent = _buildAndroidPortraitPhoneStage(
        context: context,
        item: item,
        lrc: lrc,
        cover: snap.cover,
        isPlaying: snap.isPlaying,
        loopMode: snap.loopMode,
        specLabel: specLabel,
        notifier: notifier,
      );
    }

    if (!isPortraitPhone && _activeQueueSheetContext != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _activeQueueSheetContext != null) {
          _closePortraitQueueSheet();
        }
      });
    }

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Material(
        color: KonataPlaybackTokens.auroraCanvas(p),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 全端同源静态缓存三层封面背景（铺满系统安全区，绝不随进度重绘）
            KonataCachedArtworkBackdrop(cover: snap.cover),
            stageContent,
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopStage({
    required BuildContext context,
    required AudioQueueItem item,
    required LrcDocument? lrc,
    required AudioCoverSource cover,
    required bool isPlaying,
    required AudioLoopMode loopMode,
    required double volume,
    required bool isMuted,
    required String specLabel,
    required _ImmersiveRightPane effectivePane,
    required AudioPlaybackNotifier notifier,
  }) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = screenWidth >= 820;
    final p = context.palette;
    final snapshotState = ref.read(audioPlaybackProvider);

    final rightPaneBody = KonataSmoothSectionSwitcher(
      switchKey: effectivePane,
      alignment: Alignment.center,
      child: effectivePane == _ImmersiveRightPane.lyrics
          ? KeyedSubtree(
              key: const ValueKey('immersive_lyrics_pane'),
              child: _buildLyricsViewport(lrc, notifier),
            )
          : KeyedSubtree(
              key: const ValueKey('immersive_queue_pane'),
              child: _buildQueueViewport(snapshotState, notifier),
            ),
    );

    final togglePaneButton = KonataCapsuleIconButton(
      key: const ValueKey('immersive_toggle_pane_button'),
      icon: effectivePane == _ImmersiveRightPane.queue
          ? Icons.lyrics_rounded
          : Icons.queue_music_rounded,
      tooltip: effectivePane == _ImmersiveRightPane.queue
          ? '切换至同步歌词'
          : '切换至专辑曲目列表',
      color: p.textPrimary,
      size: 19,
      fixedSize: KonataPlaybackTokens.immersiveSwitchButtonSize,
      borderRadius: KonataPlaybackTokens.immersiveSwitchButtonRadius,
      padding: EdgeInsets.zero,
      highlighted: effectivePane == _ImmersiveRightPane.queue,
      highlightColor: p.textPrimary,
      highlightBgColor: KonataPlaybackTokens.activePillBg(p),
      showHighlightBorder: false,
      onTap: () {
        setState(() {
          _pane = effectivePane == _ImmersiveRightPane.queue
              ? _ImmersiveRightPane.lyrics
              : _ImmersiveRightPane.queue;
          _userPinnedPane = true;
        });
      },
    );

    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(topPadding: 0),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                isWide ? 56 : 24,
                4,
                isWide ? 56 : 24,
                8,
              ),
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Align(
                            alignment: const Alignment(0, -0.06),
                            child: ImmersiveCoverWithReflection(
                              cover: cover,
                              maxCoverSize: KonataPlaybackTokens.albumCoverSize,
                            ),
                          ),
                        ),
                        const SizedBox(width: 48),
                        Expanded(flex: 6, child: rightPaneBody),
                      ],
                    )
                  : rightPaneBody,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: 24,
              right: 24,
              bottom: KonataPlaybackTokens.capsuleBottomOffset,
            ),
            child: Center(
              child: ImmersiveAudioCapsuleDockLeaf(
                maxWidth: KonataPlaybackTokens.capsuleAudioMaxWidth,
                title: item.title,
                isPlaying: isPlaying,
                loopMode: loopMode,
                notifier: notifier,
                trailingCenterPrimaryButton: togglePaneButton,
                rightSlot: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (specLabel.isNotEmpty &&
                        screenWidth >=
                            KonataPlaybackTokens
                                .miniBarHideBadgeBreakpoint) ...[
                      Flexible(child: KonataSpecBadge(label: specLabel)),
                      const SizedBox(width: 6),
                    ],
                    KonataVolumeControl(
                      volume: (volume / 100.0).clamp(0.0, 1.0),
                      isMuted: isMuted,
                      onVolumeChanged: (v) => notifier.setVolume(v * 100.0),
                      onToggleMute: notifier.toggleMute,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidTabletStage({
    required BuildContext context,
    required EdgeInsets safe,
    required AudioQueueItem item,
    required LrcDocument? lrc,
    required AudioCoverSource cover,
    required bool isPlaying,
    required AudioLoopMode loopMode,
    required double volume,
    required bool isMuted,
    required String specLabel,
    required _ImmersiveRightPane effectivePane,
    required AudioPlaybackNotifier notifier,
  }) {
    final p = context.palette;
    final snapshotState = ref.read(audioPlaybackProvider);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final topSafe = math.max(safe.top, KonataAdaptiveTokens.tabletTopSafeMin);
    final bottomSafe =
        safe.bottom + KonataAdaptiveTokens.tabletBottomInset;

    final togglePaneButton = KonataCapsuleIconButton(
      key: const ValueKey('immersive_toggle_pane_button'),
      icon: effectivePane == _ImmersiveRightPane.queue
          ? Icons.lyrics_rounded
          : Icons.queue_music_rounded,
      tooltip: effectivePane == _ImmersiveRightPane.queue
          ? '切换至同步歌词'
          : '切换至专辑曲目列表',
      color: p.textPrimary,
      size: 20,
      fixedSize: KonataAdaptiveTokens.touchTarget,
      borderRadius: KonataPlaybackTokens.immersiveSwitchButtonRadius,
      padding: EdgeInsets.zero,
      highlighted: effectivePane == _ImmersiveRightPane.queue,
      highlightColor: p.textPrimary,
      highlightBgColor: KonataPlaybackTokens.activePillBg(p),
      showHighlightBorder: false,
      onTap: () {
        setState(() {
          _pane = effectivePane == _ImmersiveRightPane.queue
              ? _ImmersiveRightPane.lyrics
              : _ImmersiveRightPane.queue;
          _userPinnedPane = true;
        });
      },
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        math.max(safe.left, 24),
        topSafe,
        math.max(safe.right, 24),
        bottomSafe,
      ),
      child: Column(
        children: [
          _buildTopBar(topPadding: 0),
          const SizedBox(height: 4),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 左栏：垂直居中专辑封面（上限 396dp）及底部柔雾镜像倒影
                Expanded(
                  flex: 5,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: ImmersiveCoverWithReflection(
                        cover: cover,
                        maxCoverSize:
                            KonataPlaybackTokens.tabletAlbumCoverMaxSize,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 32),
                // 右栏：无顶栏杂质的纯全高歌词与队列流光舞台（由底坞五键最右侧图标一键切换）
                Expanded(
                  flex: 6,
                  child: KonataSmoothSectionSwitcher(
                    switchKey: effectivePane,
                    alignment: Alignment.center,
                    child: effectivePane == _ImmersiveRightPane.lyrics
                        ? KeyedSubtree(
                            key: const ValueKey('tablet_lyrics_pane'),
                            child: _buildLyricsViewport(lrc, notifier),
                          )
                        : KeyedSubtree(
                            key: const ValueKey('tablet_queue_pane'),
                            child: _buildQueueViewport(snapshotState, notifier),
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 平板底部正中光学控制坞：中央等距五键（循环、上一首、播放暂停、下一首、歌词/队列），右侧规格与音量
          Center(
            child: ImmersiveAudioCapsuleDockLeaf(
              maxWidth: KonataAdaptiveTokens.tabletPlayerMaxWidth,
              title: item.title,
              isPlaying: isPlaying,
              loopMode: loopMode,
              notifier: notifier,
              trailingCenterPrimaryButton: togglePaneButton,
              rightSlot: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (specLabel.isNotEmpty &&
                      screenWidth >=
                          KonataPlaybackTokens.miniBarHideBadgeBreakpoint) ...[
                    KonataSpecBadge(label: specLabel),
                    const SizedBox(width: 6),
                  ],
                  KonataVolumeControl(
                    volume: (volume / 100.0).clamp(0.0, 1.0),
                    isMuted: isMuted,
                    onVolumeChanged: (v) => notifier.setVolume(v * 100.0),
                    onToggleMute: notifier.toggleMute,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _mutateState(VoidCallback fn) => setState(fn);
}
