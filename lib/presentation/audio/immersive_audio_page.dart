import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/playback_formatters.dart';
import '../shell/window_controls.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_capsule.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_cached_artwork_backdrop.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'smart_cover_framing.dart';

enum _ImmersiveRightPane { lyrics, queue }

/// 全屏流光音频播放器页面（覆盖桌面双栏、Android 平板双栏舞台、手机竖屏三段单列与手机矮横屏 44:56 双栏）。
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
          duration: const Duration(milliseconds: 300),
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

  void _collapseToMiniBar() {
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
        duration: animated ? const Duration(milliseconds: 360) : Duration.zero,
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
          duration: const Duration(milliseconds: 360),
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
      _collapseToMiniBar();
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
    final p = context.palette;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final size = MediaQuery.sizeOf(sheetContext);
        final safe = MediaQuery.paddingOf(sheetContext);
        return Padding(
          padding: EdgeInsets.only(top: math.max(safe.top + 32, 64)),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: KonataPlaybackTokens.capsuleBlurSigma,
                sigmaY: KonataPlaybackTokens.capsuleBlurSigma,
              ),
              child: Container(
                height: (size.height * 0.68).clamp(260.0, 620.0),
                decoration: BoxDecoration(
                  color: KonataPlaybackTokens.popoverSurface(p),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  border: Border.all(color: KonataPlaybackTokens.glassBorder(p)),
                ),
                child: Consumer(
                  builder: (ctx, sheetRef, _) {
                    sheetRef.watch(
                      audioPlaybackProvider.select(
                        (s) => (
                          s.currentIndex,
                          s.queue,
                          s.isPlaying,
                        ),
                      ),
                    );
                    final s = sheetRef.read(audioPlaybackProvider);
                    final n = sheetRef.read(audioPlaybackProvider.notifier);
                    return Column(
                      children: [
                        const SizedBox(height: 8),
                        Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: p.textMuted.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 6, 10, 6),
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
                                  '播放队列 (${s.queue.length})',
                                  style: TextStyle(
                                    color: p.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              KonataCapsuleIconButton(
                                icon: Icons.close_rounded,
                                tooltip: '关闭队列抽屉',
                                color: p.textSecondary,
                                size: 18,
                                fixedSize: KonataAdaptiveTokens.touchTarget,
                                onTap: () => Navigator.of(sheetContext).pop(),
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
                            padding: EdgeInsets.only(bottom: safe.bottom + 8),
                            child: _buildQueueViewport(
                              s,
                              n,
                              onPicked: () => Navigator.of(sheetContext).pop(),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
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
    final safe = MediaQuery.paddingOf(context);
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final isTablet =
        isAndroid && size.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint;
    final isShortPhone =
        isAndroid &&
        !isTablet &&
        size.height < KonataAdaptiveTokens.shortViewportHeight;
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
        cover: snap.cover,
        isPlaying: snap.isPlaying,
        loopMode: snap.loopMode,
        isMuted: snap.isMuted,
        specLabel: specLabel,
        notifier: notifier,
      );
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
                            child: _CoverAndReflectionColumn(
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
            child: _AudioCapsuleDockLeaf(
              leading: _ImmersiveMicroCover(cover: cover),
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
    final p = context.palette;
    final snapshotState = ref.read(audioPlaybackProvider);
    final topSafe = math.max(safe.top, KonataAdaptiveTokens.tabletTopSafeMin);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        math.max(safe.left, 24),
        topSafe,
        math.max(safe.right, 24),
        math.max(safe.bottom, 16),
      ),
      child: Column(
        children: [
          _buildTopBar(item: item, topPadding: 0),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 左栏：垂直居中封面上限 360~420dp 与完整控制坞
                Expanded(
                  flex: 5,
                  child: LayoutBuilder(
                    builder: (context, leftConstraints) {
                      final maxCover = math.min(
                        KonataPlaybackTokens.tabletAlbumCoverMaxSize,
                        math.min(
                          leftConstraints.maxWidth - 16.0,
                          leftConstraints.maxHeight - 168.0,
                        ),
                      ).clamp(140.0, KonataPlaybackTokens.tabletAlbumCoverMaxSize);

                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Hero(
                            tag: 'konata_audio_cover_hero',
                            child: _SquareCoverCard(
                              cover: cover,
                              size: maxCover,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.textPrimary,
                                      fontSize: 18,
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
                          ),
                          const SizedBox(height: 14),
                          _AudioCapsuleDockLeaf(
                            maxWidth: KonataAdaptiveTokens.tabletPlayerMaxWidth,
                            title: null,
                            isPlaying: isPlaying,
                            loopMode: loopMode,
                            notifier: notifier,
                            rightSlot: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                KonataCapsuleIconButton(
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
                      );
                    },
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            // 左 44%：封面、信息、进度与主控（严禁纵向溢出）
            Expanded(
              flex: 44,
              child: LayoutBuilder(
                builder: (context, leftBox) {
                  final availableCover = math.min(
                    leftBox.maxWidth * 0.62,
                    leftBox.maxHeight - 168.0,
                  );
                  final showCover = availableCover >= 48.0;
                  final coverSide = availableCover.clamp(48.0, 148.0);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
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
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (showCover)
                        Center(
                          child: Hero(
                            tag: 'konata_audio_cover_hero',
                            child: _SquareCoverCard(
                              cover: cover,
                              size: coverSide,
                              radius: 14,
                            ),
                          ),
                        ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (item.albumTitle.isNotEmpty)
                            Text(
                              item.albumTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          const SizedBox(height: 4),
                          _TouchAudioScrubberLeaf(notifier: notifier, compact: true),
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
                    ],
                  );
                },
              ),
            ),
            const SizedBox(width: 14),
            // 右 56%：胶囊切换全高歌词与队列（带上下渐隐）
            Expanded(
              flex: 56,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
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
                  const SizedBox(height: 4),
                  Expanded(
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
          // 第一段：封面 ↔ 滚动歌词原位淡入淡出切换（封面态支持下拉收起）
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
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
                          child: LayoutBuilder(
                            builder: (context, stageBox) {
                              final side = math.min(
                                stageBox.maxWidth,
                                stageBox.maxHeight,
                              ).clamp(140.0, 340.0);
                              return Center(
                                child: Hero(
                                  tag: 'konata_audio_cover_hero',
                                  child: _SquareCoverCard(
                                    cover: cover,
                                    size: side,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
              ),
            ),
          ),
          // 第二段：中段左对齐曲目信息及两行实时歌词预览
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
                const SizedBox(height: 3),
                Text(
                  item.albumTitle.isNotEmpty ? item.albumTitle : item.work.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.textSecondary, fontSize: 13.5),
                ),
                if (!_portraitShowLyricsInPlace) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _portraitShowLyricsInPlace = true),
                    child: const _TwoLineLyricPreviewLeaf(),
                  ),
                ],
              ],
            ),
          ),
          // 第三段：底部进度、主控及至少 48dp 工具行（支持上拉打开队列抽屉）
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
                    _TouchAudioScrubberLeaf(notifier: notifier),
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
                            key: const ValueKey('portrait_toggle_lyrics_button'),
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
                            icon: isMuted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            tooltip: isMuted ? '取消静音' : '静音',
                            color: p.textPrimary,
                            size: 20,
                            fixedSize: KonataAdaptiveTokens.touchTarget,
                            onTap: notifier.toggleMute,
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
                        style: TextStyle(color: p.textSecondary, fontSize: 11.5),
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
                child: _LyricLineLeaf(
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
            return _BorderlessQueueRow(
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

/// 独立歌词行叶子组件：仅当自身高亮态或邻近模糊阶梯变化时重建。
class _LyricLineLeaf extends ConsumerWidget {
  const _LyricLineLeaf({
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

    final activeSize = compact ? 18.0 : KonataPlaybackTokens.lyricActiveFontSize;
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
                duration: const Duration(milliseconds: 220),
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

/// 手机竖屏中段两行实时歌词预览叶子（重绘隔离，不带动全屏树重建）。
class _TwoLineLyricPreviewLeaf extends ConsumerWidget {
  const _TwoLineLyricPreviewLeaf();

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
      return RepaintBoundary(
        child: SizedBox(
          height: 40,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '轻触封面查看歌词详情',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.textMuted, fontSize: 13),
            ),
          ),
        ),
      );
    }

    final activeIdx = snap.idx >= 0 && snap.idx < lines.length ? snap.idx : 0;
    final primary = lines[activeIdx].primaryText;
    final secondary = lines[activeIdx].secondaryLines.isNotEmpty
        ? lines[activeIdx].secondaryLines.first
        : (activeIdx + 1 < lines.length ? lines[activeIdx + 1].primaryText : '');

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
class _AudioCapsuleDockLeaf extends ConsumerWidget {
  const _AudioCapsuleDockLeaf({
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
class _TouchAudioScrubberLeaf extends ConsumerStatefulWidget {
  const _TouchAudioScrubberLeaf({
    required this.notifier,
    this.compact = false,
  });

  final AudioPlaybackNotifier notifier;
  final bool compact;

  @override
  ConsumerState<_TouchAudioScrubberLeaf> createState() =>
      _TouchAudioScrubberLeafState();
}

class _TouchAudioScrubberLeafState
    extends ConsumerState<_TouchAudioScrubberLeaf> {
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
              height: widget.compact ? 28 : 34,
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

class _BorderlessQueueRow extends StatefulWidget {
  const _BorderlessQueueRow({
    super.key,
    required this.row,
    required this.isPlaying,
    required this.onTap,
  });

  final AudioQueueDisplayRow row;
  final bool isPlaying;
  final VoidCallback onTap;

  @override
  State<_BorderlessQueueRow> createState() => _BorderlessQueueRowState();
}

class _BorderlessQueueRowState extends State<_BorderlessQueueRow> {
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
                        duration: const Duration(milliseconds: 200),
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

class _SquareCoverCard extends ConsumerWidget {
  const _SquareCoverCard({
    required this.cover,
    required this.size,
    this.radius = KonataPlaybackTokens.albumCoverRadius,
  });

  final AudioCoverSource cover;
  final double size;
  final double radius;

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
              key: ValueKey('imm_sq_${workId}_${url}_$revision'),
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
            art = _emptyArt(p, size);
        }

        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
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
            borderRadius: BorderRadius.circular(radius),
            child: art,
          ),
        );
      },
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

class _CoverAndReflectionColumn extends ConsumerWidget {
  const _CoverAndReflectionColumn({
    required this.cover,
    required this.maxCoverSize,
  });

  final AudioCoverSource cover;
  final double maxCoverSize;

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
          final coverSize = constraints.maxWidth.clamp(200.0, maxCoverSize);

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
                    borderRadius: BorderRadius.circular(
                      KonataPlaybackTokens.albumCoverRadius,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: KonataPlaybackTokens.shadowColor(p),
                        blurRadius: 38,
                        offset: const Offset(0, 20),
                      ),
                    ],
                    border: Border.all(
                      color: KonataPlaybackTokens.glassBorder(p),
                      width: 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      KonataPlaybackTokens.albumCoverRadius,
                    ),
                    child: buildArtwork(coverSize, coverAlignment),
                  ),
                ),
              ),
              SizedBox(
                width: coverSize,
                height: KonataPlaybackTokens.albumReflectionHeight,
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
                            Rect.fromLTWH(
                              0,
                              0,
                              coverSize,
                              KonataPlaybackTokens.albumReflectionHeight,
                            ),
                          ),
                      blendMode: BlendMode.dstIn,
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.diagonal3Values(1.0, -1.0, 1.0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            KonataPlaybackTokens.albumCoverRadius,
                          ),
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

class _ImmersiveMicroCover extends ConsumerWidget {
  const _ImmersiveMicroCover({required this.cover});

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
