import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../shell/adaptive_capsule_layout.dart';
import '../shell/window_controls.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_capsule.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/playback/konata_cached_artwork_backdrop.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'immersive_audio_sub_widgets.dart';

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
  double _pullDownDy = 0.0;
  double _sheetDragDy = 0.0;
  Timer? _scrollResetTimer;
  final GlobalKey _activeQueueItemKey = GlobalKey();
  List<GlobalKey> _lyricKeys = const [];
  String? _lastItemId;
  int _lastActiveLyricIndex = -1;
  _ImmersiveRightPane? _lastEffectivePane;

  @override
  void initState() {
    super.initState();
    _lastActiveLyricIndex = ref.read(audioPlaybackProvider).activeLyricIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _scrollToActiveQueueItem(animated: false);
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
          duration: const Duration(milliseconds: 220),
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
    _focusNode.dispose();
    _lyricScrollCtrl.dispose();
    _queueScrollCtrl.dispose();
    super.dispose();
  }

  void _closePortraitQueueSheet() {
    if (ref.read(immersivePortraitQueueSheetOpenProvider)) {
      ref.read(immersivePortraitQueueSheetOpenProvider.notifier).state = false;
    }
  }

  void _collapseToMiniBar() {
    _closePortraitQueueSheet();
    ref.read(immersiveAudioExpandedProvider.notifier).state = false;
  }

  void _syncLyricKeys(LrcDocument? doc) {
    final len = doc?.lines.length ?? 0;
    if (_lyricKeys.length != len) {
      _lyricKeys = List<GlobalKey>.generate(len, (_) => GlobalKey());
    }
  }

  void _onUserLyricScrollActivity() {
    if (!_isUserScrollingLyrics) {
      setState(() => _isUserScrollingLyrics = true);
    }
    _scrollResetTimer?.cancel();
    _scrollResetTimer = Timer(
      KonataPlaybackTokens.lyricUserScrollResetDelay,
      () {
        if (!mounted) return;
        setState(() => _isUserScrollingLyrics = false);
        _scrollToActiveLyric(animated: true);
      },
    );
  }

  void _scrollToActiveLyric({bool animated = true}) {
    final idx = _lastActiveLyricIndex;
    if (idx < 0 || idx >= _lyricKeys.length) return;
    final ctx = _lyricKeys[idx].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.38,
        duration: animated ? const Duration(milliseconds: 260) : Duration.zero,
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
      if (animated) {
        _lyricScrollCtrl.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 260),
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
    ref.read(immersivePortraitQueueSheetOpenProvider.notifier).state = true;
    _scheduleQueueCentering(animated: false);
  }

  @override
  Widget build(BuildContext context) {
    // 严格隔离高频进度与歌词跳变：顶层仅订阅低频曲目与控制状态，绝不订阅 positionSeconds 或 activeLyricIndex
    final snap = ref.watch(
      audioPlaybackProvider.select(
        (s) => (
          item: s.currentItem,
          lrc: s.lrcDocument,
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
    final portraitQueueOpen = ref.watch(immersivePortraitQueueSheetOpenProvider);
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
    final item = snap.item;
    if (item == null) return const SizedBox.shrink();

    final lrc = snap.lrc;
    final hasLyrics = lrc != null && lrc.lines.isNotEmpty;
    final itemChanged = _lastItemId != item.id;
    if (itemChanged) {
      final hadPrev = _lastItemId != null;
      _lastItemId = item.id;
      _isUserScrollingLyrics = false;
      _scrollResetTimer?.cancel();
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

    if (!isPortraitPhone && portraitQueueOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closePortraitQueueSheet();
      });
    }

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
        item: item,
        lrc: lrc,
        cover: snap.cover,
        isPlaying: snap.isPlaying,
        loopMode: snap.loopMode,
        specLabel: specLabel,
        effectivePane: effectivePane,
        notifier: notifier,
      );
    } else {
      stageContent = _buildAndroidPortraitPhoneStage(
        context: context,
        item: item,
        lrc: lrc,
        hasLyrics: hasLyrics,
        cover: snap.cover,
        isPlaying: snap.isPlaying,
        loopMode: snap.loopMode,
        isMuted: snap.isMuted,
        specLabel: specLabel,
        notifier: notifier,
      );
    }

    Widget content = Focus(
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
            if (isPortraitPhone)
              _buildPortraitQueueSheetOverlay(
                context: context,
                size: size,
                safe: safe,
                open: portraitQueueOpen,
                notifier: notifier,
              ),
          ],
        ),
      ),
    );

    if (Navigator.maybeOf(context) != null && portraitQueueOpen) {
      content = PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _closePortraitQueueSheet();
          }
        },
        child: content,
      );
    }
    return content;
  }

  Widget _buildPortraitQueueSheetOverlay({
    required BuildContext context,
    required Size size,
    required EdgeInsets safe,
    required bool open,
    required AudioPlaybackNotifier notifier,
  }) {
    final p = context.palette;
    final sheetHeight = (size.height * 0.68).clamp(260.0, 620.0);
    final snapshotState = ref.read(audioPlaybackProvider);

    return IgnorePointer(
      ignoring: !open,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closePortraitQueueSheet,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 110),
              opacity: open ? 1.0 : 0.0,
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            bottom: open ? 0 : -(sheetHeight + 32),
            height: sheetHeight,
            child: open
                ? KeyedSubtree(
                    key: const ValueKey('portrait_queue_sheet_overlay'),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: KonataPlaybackTokens.capsuleBlurSigma,
                          sigmaY: KonataPlaybackTokens.capsuleBlurSigma,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: KonataPlaybackTokens.popoverSurface(p),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(24),
                            ),
                            border: Border.all(
                              color: KonataPlaybackTokens.glassBorder(p),
                            ),
                          ),
                          child: Column(
                            children: [
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragStart: (_) => _sheetDragDy = 0.0,
                                onVerticalDragUpdate: (d) {
                                  if (d.delta.dy > 0) {
                                    _sheetDragDy += d.delta.dy;
                                  }
                                },
                                onVerticalDragEnd: (d) {
                                  if (_sheetDragDy > 44.0 ||
                                      (d.primaryVelocity ?? 0) > 360.0) {
                                    _closePortraitQueueSheet();
                                  }
                                  _sheetDragDy = 0.0;
                                },
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(height: 8),
                                    Container(
                                      width: 36,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: p.textMuted.withValues(
                                          alpha: 0.45,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        18,
                                        6,
                                        10,
                                        6,
                                      ),
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
                                              '播放队列 (${snapshotState.queue.length})',
                                              style: TextStyle(
                                                color: p.textPrimary,
                                                fontSize: 15,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          KonataCapsuleIconButton(
                                            key: const ValueKey(
                                              'portrait_close_queue_button',
                                            ),
                                            icon: Icons.close_rounded,
                                            tooltip: '关闭队列抽屉',
                                            color: p.textSecondary,
                                            size: 18,
                                            fixedSize: KonataAdaptiveTokens
                                                .touchTarget,
                                            onTap: _closePortraitQueueSheet,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Divider(
                                height: 1,
                                color: KonataPlaybackTokens.glassBorder(p),
                              ),
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    bottom: safe.bottom + 8,
                                  ),
                                  child: _buildQueueViewport(
                                    snapshotState,
                                    notifier,
                                    onPicked: _closePortraitQueueSheet,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
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

    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(item: item, topPadding: 0),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                isWide ? 48 : 20,
                8,
                isWide ? 48 : 20,
                10,
              ),
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Align(
                            alignment: const Alignment(0, -0.10),
                            child: ImmersiveCoverWithReflection(
                              cover: cover,
                              maxCoverSize: KonataPlaybackTokens.albumCoverSize,
                            ),
                          ),
                        ),
                        const SizedBox(width: 44),
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
            child: ImmersiveAudioCapsuleDockLeaf(
              leading: ImmersiveMicroCover(cover: cover),
              title: item.title,
              isPlaying: isPlaying,
              loopMode: loopMode,
              notifier: notifier,
              trailingCenterButtons: [
                KonataCapsuleIconButton(
                  icon: Icons.queue_music_rounded,
                  tooltip: '专辑曲目列表',
                  color: p.textPrimary,
                  size: 19,
                  fixedSize: KonataPlaybackTokens.immersiveSwitchButtonSize,
                  borderRadius:
                      KonataPlaybackTokens.immersiveSwitchButtonRadius,
                  padding: EdgeInsets.zero,
                  highlighted: effectivePane == _ImmersiveRightPane.queue,
                  highlightColor: p.textPrimary,
                  highlightBgColor: KonataPlaybackTokens.activePillBg(p),
                  showHighlightBorder: false,
                  onTap: () {
                    setState(() {
                      _pane = _ImmersiveRightPane.queue;
                      _userPinnedPane = true;
                    });
                  },
                ),
                const SizedBox(width: 2),
                KonataCapsuleIconButton(
                  icon: Icons.lyrics_rounded,
                  tooltip: '同步歌词',
                  color: p.textPrimary,
                  size: 18,
                  fixedSize: KonataPlaybackTokens.immersiveSwitchButtonSize,
                  borderRadius:
                      KonataPlaybackTokens.immersiveSwitchButtonRadius,
                  padding: EdgeInsets.zero,
                  highlighted: effectivePane == _ImmersiveRightPane.lyrics,
                  highlightColor: p.textPrimary,
                  highlightBgColor: KonataPlaybackTokens.activePillBg(p),
                  showHighlightBorder: false,
                  onTap: () {
                    setState(() {
                      _pane = _ImmersiveRightPane.lyrics;
                      _userPinnedPane = true;
                    });
                  },
                ),
              ],
              rightSlot: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (specLabel.isNotEmpty &&
                      screenWidth >=
                          KonataPlaybackTokens.miniBarHideBadgeBreakpoint) ...[
                    Flexible(child: KonataSpecBadge(label: specLabel)),
                    const SizedBox(width: 4),
                  ],
                  KonataVolumeControl(
                    volume: (volume / 100.0).clamp(0.0, 1.0),
                    isMuted: isMuted,
                    onVolumeChanged: (v) => notifier.setVolume(v * 100.0),
                    onToggleMute: notifier.toggleMute,
                  ),
                  KonataCapsuleIconButton(
                    icon: Icons.keyboard_arrow_down_rounded,
                    tooltip: '收起为迷你底栏 (Esc)',
                    color: p.textPrimary,
                    size: 20,
                    onTap: _collapseToMiniBar,
                  ),
                ],
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
    final snapshotState = ref.read(audioPlaybackProvider);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final topSafe = math.max(safe.top, KonataAdaptiveTokens.tabletTopSafeMin);
    final bottomSafe =
        safe.bottom + KonataAdaptiveTokens.tabletBottomInset;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        math.max(safe.left, 24),
        topSafe,
        math.max(safe.right, 24),
        bottomSafe,
      ),
      child: Column(
        children: [
          _buildTopBar(item: item, topPadding: 0),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 左栏：垂直居中专辑封面（上限 396dp）及底部镜像渐变倒影
                Expanded(
                  flex: 5,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: ImmersiveCoverWithReflection(
                        cover: cover,
                        maxCoverSize:
                            KonataPlaybackTokens.tabletAlbumCoverMaxSize,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 28),
                // 右栏：常驻大字号歌词与队列胶囊切换面板
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: KonataSegmentedCapsule<_ImmersiveRightPane>(
                          options: const [
                            KonataSegmentOption(
                              value: _ImmersiveRightPane.lyrics,
                              label: '同步歌词',
                              icon: Icons.lyrics_rounded,
                            ),
                            KonataSegmentOption(
                              value: _ImmersiveRightPane.queue,
                              label: '播放队列',
                              icon: Icons.queue_music_rounded,
                            ),
                          ],
                          selected: effectivePane,
                          onChanged: (next) => setState(() {
                            _pane = next;
                            _userPinnedPane = true;
                          }),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
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
                                  child: _buildQueueViewport(
                                    snapshotState,
                                    notifier,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 整个平板播放器界面底部水平正中央：全套完整控制坞（进度/时间、循环、上一首、播放暂停、下一首、音量/静音）
          Center(
            child: ImmersiveAudioCapsuleDockLeaf(
              maxWidth: KonataPlaybackTokens.capsuleMaxWidth,
              leading: ImmersiveMicroCover(cover: cover),
              title: item.title,
              isPlaying: isPlaying,
              loopMode: loopMode,
              notifier: notifier,
              rightSlot: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (specLabel.isNotEmpty &&
                      screenWidth >=
                          KonataPlaybackTokens.miniBarHideBadgeBreakpoint) ...[
                    Flexible(child: KonataSpecBadge(label: specLabel)),
                    const SizedBox(width: 4),
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

  Widget _buildAndroidShortPhoneStage({
    required BuildContext context,
    required AudioQueueItem item,
    required LrcDocument? lrc,
    required AudioCoverSource cover,
    required bool isPlaying,
    required AudioLoopMode loopMode,
    required String specLabel,
    required _ImmersiveRightPane effectivePane,
    required AudioPlaybackNotifier notifier,
  }) {
    final p = context.palette;
    final snapshotState = ref.read(audioPlaybackProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
        child: Column(
          children: [
            // 首行整体上提紧贴状态栏下方：下箭头、作品名、「歌词 / 队列」胶囊与编码徽章严格单行垂直居中对齐
            SizedBox(
              key: const ValueKey('short_phone_audio_top_bar'),
              height: KonataAdaptiveTokens.touchTarget,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    flex: 44,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        KonataCapsuleIconButton(
                          key: const ValueKey('immersive_collapse_button'),
                          icon: Icons.keyboard_arrow_down_rounded,
                          tooltip: '收起全屏播放页',
                          color: p.textPrimary,
                          size: 24,
                          fixedSize: KonataAdaptiveTokens.touchTarget,
                          onTap: _collapseToMiniBar,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.work.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 56,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: KonataSegmentedCapsule<_ImmersiveRightPane>(
                            expand: true,
                            options: const [
                              KonataSegmentOption(
                                value: _ImmersiveRightPane.lyrics,
                                label: '歌词',
                                icon: Icons.lyrics_rounded,
                              ),
                              KonataSegmentOption(
                                value: _ImmersiveRightPane.queue,
                                label: '队列',
                                icon: Icons.queue_music_rounded,
                              ),
                            ],
                            selected: effectivePane,
                            onChanged: (next) => setState(() {
                              _pane = next;
                              _userPinnedPane = true;
                            }),
                          ),
                        ),
                        if (specLabel.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          KonataSpecBadge(label: specLabel),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Row(
                children: [
                  // 左 44%：带镜像倒影的专辑封面、仅保留当前单曲名称、进度与主控（严禁纵向溢出）
                  Expanded(
                    flex: 44,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Center(
                            child: ImmersiveCoverWithReflection(
                              cover: cover,
                              maxCoverSize: 148,
                              borderRadius: 14,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        ImmersiveTouchAudioScrubberLeaf(
                          notifier: notifier,
                          compact: true,
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            KonataCapsuleIconButton(
                              icon: switch (loopMode) {
                                AudioLoopMode.sequence =>
                                  Icons.trending_flat_rounded,
                                AudioLoopMode.loopAll => Icons.repeat_rounded,
                                AudioLoopMode.loopOne =>
                                  Icons.repeat_one_rounded,
                              },
                              tooltip: '循环模式：${loopMode.label}',
                              color: p.textPrimary,
                              size: 20,
                              fixedSize: KonataAdaptiveTokens.touchTarget,
                              onTap: notifier.cycleLoopMode,
                            ),
                            KonataCapsuleIconButton(
                              icon: Icons.skip_previous_rounded,
                              tooltip: '上一曲',
                              color: p.textPrimary,
                              size: 24,
                              fixedSize: KonataAdaptiveTokens.touchTarget,
                              onTap: notifier.previous,
                            ),
                            KonataCapsuleIconButton(
                              icon: isPlaying
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_fill_rounded,
                              tooltip: isPlaying ? '暂停' : '播放',
                              color: p.textPrimary,
                              size: 34,
                              fixedSize: KonataAdaptiveTokens.touchTarget,
                              onTap: notifier.togglePlayPause,
                            ),
                            KonataCapsuleIconButton(
                              icon: Icons.skip_next_rounded,
                              tooltip: '下一曲',
                              color: p.textPrimary,
                              size: 24,
                              fixedSize: KonataAdaptiveTokens.touchTarget,
                              onTap: notifier.next,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  // 右 56%：全高歌词与队列（带上下渐隐）
                  Expanded(
                    flex: 56,
                    child: effectivePane == _ImmersiveRightPane.lyrics
                        ? _buildLyricsViewport(lrc, notifier, compact: true)
                        : _buildQueueViewport(snapshotState, notifier),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAndroidPortraitPhoneStage({
    required BuildContext context,
    required AudioQueueItem item,
    required LrcDocument? lrc,
    required bool hasLyrics,
    required AudioCoverSource cover,
    required bool isPlaying,
    required AudioLoopMode loopMode,
    required bool isMuted,
    required String specLabel,
    required AudioPlaybackNotifier notifier,
  }) {
    final p = context.palette;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部：支持下拉收起与左上 48dp 收起按钮
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => _pullDownDy = 0.0,
            onVerticalDragUpdate: (details) {
              if (details.delta.dy > 0) {
                _pullDownDy += details.delta.dy;
              }
            },
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0.0;
              if (_pullDownDy > 48.0 || velocity > 420.0) {
                _collapseToMiniBar();
              }
              _pullDownDy = 0.0;
            },
            child: _buildTopBar(item: item, topPadding: 2),
          ),
          // 第一段：带镜像渐变倒影的专辑封面 ↔ 滚动歌词原位淡入淡出切换
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 140),
                child: _portraitShowLyricsInPlace
                    ? KeyedSubtree(
                        key: const ValueKey('portrait_lyrics_stage'),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: _buildLyricsViewport(
                                lrc,
                                notifier,
                                onTapEmptyArea: () => setState(
                                  () => _portraitShowLyricsInPlace = false,
                                ),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: KonataCapsuleIconButton(
                                key: const ValueKey('portrait_back_to_cover'),
                                icon: Icons.album_rounded,
                                tooltip: '返回专辑封面',
                                color: p.textSecondary,
                                size: 20,
                                fixedSize: KonataAdaptiveTokens.touchTarget,
                                onTap: () => setState(
                                  () => _portraitShowLyricsInPlace = false,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('portrait_cover_stage'),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(
                            () => _portraitShowLyricsInPlace = true,
                          ),
                          onVerticalDragStart: (_) => _pullDownDy = 0.0,
                          onVerticalDragUpdate: (d) {
                            if (d.delta.dy > 0) _pullDownDy += d.delta.dy;
                          },
                          onVerticalDragEnd: (d) {
                            if (_pullDownDy > 54.0 ||
                                (d.primaryVelocity ?? 0) > 460.0) {
                              _collapseToMiniBar();
                            }
                            _pullDownDy = 0.0;
                          },
                          child: Center(
                            child: ImmersiveCoverWithReflection(
                              cover: cover,
                              maxCoverSize: 340,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          // 第二段：中段左对齐曲目名、音质徽章及两行实时歌词预览（不重复显示顶部已有的目录副标题）
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (specLabel.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      KonataSpecBadge(label: specLabel),
                    ],
                  ],
                ),
                if (!_portraitShowLyricsInPlace && hasLyrics) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _portraitShowLyricsInPlace = true),
                    child: const ImmersiveTwoLineLyricPreviewLeaf(),
                  ),
                ],
              ],
            ),
          ),
          // 第三段：底部进度、主控及至少 48dp 工具行（支持点击或上拉弹出播放队列抽屉）
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) < -240.0) {
                _openPortraitQueueSheet();
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
              child: KonataGlassCapsule(
                radius: 26,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ImmersiveTouchAudioScrubberLeaf(notifier: notifier),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        KonataCapsuleIconButton(
                          icon: Icons.skip_previous_rounded,
                          tooltip: '上一曲',
                          color: p.textPrimary,
                          size: 28,
                          fixedSize: 52,
                          onTap: notifier.previous,
                        ),
                        KonataCapsuleIconButton(
                          key: const ValueKey('portrait_audio_play_pause'),
                          icon: isPlaying
                              ? Icons.pause_circle_filled_rounded
                              : Icons.play_circle_fill_rounded,
                          tooltip: isPlaying ? '暂停' : '播放',
                          color: p.textPrimary,
                          size: 42,
                          fixedSize: 56,
                          onTap: notifier.togglePlayPause,
                        ),
                        KonataCapsuleIconButton(
                          icon: Icons.skip_next_rounded,
                          tooltip: '下一曲',
                          color: p.textPrimary,
                          size: 28,
                          fixedSize: 52,
                          onTap: notifier.next,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: KonataAdaptiveTokens.touchTarget,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          KonataCapsuleIconButton(
                            key: const ValueKey('portrait_audio_loop_button'),
                            icon: switch (loopMode) {
                              AudioLoopMode.sequence =>
                                Icons.trending_flat_rounded,
                              AudioLoopMode.loopAll => Icons.repeat_rounded,
                              AudioLoopMode.loopOne => Icons.repeat_one_rounded,
                            },
                            tooltip: '循环模式：${loopMode.label}',
                            color: p.textPrimary,
                            size: 20,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: notifier.cycleLoopMode,
                          ),
                          KonataCapsuleIconButton(
                            key: const ValueKey(
                              'portrait_toggle_lyrics_button',
                            ),
                            icon: Icons.lyrics_rounded,
                            tooltip: _portraitShowLyricsInPlace
                                ? '切换专辑封面'
                                : '原位展开歌词',
                            color: p.textPrimary,
                            size: 20,
                            highlighted: _portraitShowLyricsInPlace,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: () => setState(
                              () => _portraitShowLyricsInPlace =
                                  !_portraitShowLyricsInPlace,
                            ),
                          ),
                          KonataCapsuleIconButton(
                            key: const ValueKey('portrait_open_queue_button'),
                            icon: Icons.queue_music_rounded,
                            tooltip: '上拉或点击展开播放队列',
                            color: p.textPrimary,
                            size: 21,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: _openPortraitQueueSheet,
                          ),
                          KonataCapsuleIconButton(
                            key: const ValueKey('portrait_audio_mute_button'),
                            icon: isMuted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            tooltip: isMuted ? '取消静音' : '静音',
                            color: p.textPrimary,
                            size: 20,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: notifier.toggleMute,
                          ),
                        ],
                      ),
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

  Widget _buildTopBar({
    required AudioQueueItem item,
    required double topPadding,
  }) {
    final p = context.palette;
    final isWindows = KonataAdaptiveTokens.isWindows;
    final isAndroid = KonataAdaptiveTokens.isAndroid;

    Widget headerRow = Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              KonataCapsuleIconButton(
                key: const ValueKey('immersive_collapse_button'),
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: '收起为迷你底栏 (Esc)',
                color: p.textPrimary,
                size: 26,
                fixedSize: isAndroid ? KonataAdaptiveTokens.touchTarget : 40,
                onTap: _collapseToMiniBar,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EllipsisTextWithTooltip(
                      text: item.work.title,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (item.albumTitle.isNotEmpty &&
                        item.albumTitle != item.work.title)
                      EllipsisTextWithTooltip(
                        text: item.albumTitle,
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                  ],
                ),
              ),
              if (isWindows) ...[
                const SizedBox(width: 8),
                const WindowControls(),
              ],
            ],
          ),
        ),
      ),
    );

    if (isWindows) {
      headerRow = DragToMoveArea(child: headerRow);
    }
    return headerRow;
  }

  Widget _buildLyricsViewport(
    LrcDocument? lrc,
    AudioPlaybackNotifier notifier, {
    bool compact = false,
    VoidCallback? onTapEmptyArea,
  }) {
    final p = context.palette;
    if (lrc == null || lrc.lines.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTapEmptyArea,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lyrics_outlined, size: 40, color: p.textMuted),
              const SizedBox(height: 12),
              Text(
                '当前曲目暂无同步歌词',
                style: TextStyle(color: p.textSecondary, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _onUserLyricScrollActivity();
        } else if (notification is UserScrollNotification) {
          _onUserLyricScrollActivity();
        }
        return false;
      },
      child: KonataDraggableScrollbar(
        controller: _lyricScrollCtrl,
        trackInsets: const EdgeInsets.only(top: 20, bottom: 24, right: 4),
        builder: (_, ctrl) => ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0.0, 0.06, 0.93, 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: ListView.builder(
            controller: ctrl,
            padding: EdgeInsets.fromLTRB(
              4,
              compact ? 14 : 28,
              22,
              compact ? 18 : 32,
            ),
            itemCount: lrc.lines.length,
            itemBuilder: (context, index) {
              final line = lrc.lines[index];
              return KeyedSubtree(
                key: _lyricKeys[index],
                child: ImmersiveLyricLineLeaf(
                  index: index,
                  line: line,
                  compact: compact,
                  userScrolling: _isUserScrollingLyrics,
                  onSeekLine: () {
                    _scrollResetTimer?.cancel();
                    setState(() => _isUserScrollingLyrics = false);
                    notifier.seekRelativeTrackSeconds(line.startSeconds);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildQueueViewport(
    AudioPlaybackState state,
    AudioPlaybackNotifier notifier, {
    VoidCallback? onPicked,
  }) {
    final displayRows = state.buildDisplayRows();
    return KonataDraggableScrollbar(
      controller: _queueScrollCtrl,
      trackInsets: const EdgeInsets.only(top: 16, bottom: 20, right: 4),
      builder: (_, ctrl) => ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.04, 0.95, 1.0],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: ListView.separated(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(4, 16, 22, 24),
          itemCount: displayRows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final row = displayRows[index];
            return ImmersiveBorderlessQueueRow(
              key: row.isActiveTrack
                  ? _activeQueueItemKey
                  : ValueKey('q_row_${row.id}'),
              row: row,
              isPlaying: row.isActiveTrack && state.isPlaying,
              onTap: () {
                notifier.playQueueIndex(row.targetQueueIndex);
                onPicked?.call();
              },
            );
          },
        ),
      ),
    );
  }
}
