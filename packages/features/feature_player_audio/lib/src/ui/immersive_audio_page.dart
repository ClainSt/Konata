import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';
import 'audio_aurora_backdrop.dart';
import 'audio_lyrics_slot.dart';
import 'audio_playback_capsule.dart';
import 'immersive_audio_queue_and_safety.dart';
import 'immersive_audio_stages.dart';

/// Salt 风格全屏流光音频舞台主页面。
///
/// 支持桌面双栏、平板、矮屏手机横屏与手机竖屏四态自适应布局；
/// 仅依赖 `konata_contracts` 动态拼装外挂歌词视口与 `PlayerMediaMode.audio` 侧栏。
class ImmersiveAudioPage extends StatefulWidget {
  /// 创建全屏沉浸式音频舞台。
  const ImmersiveAudioPage({
    super.key,
    required this.controller,
    required this.paletteCache,
    required this.alignmentCache,
    this.lyricsViewportBuilder,
    this.extraSidePanels = const [],
    this.platform = KonataPlatform.windows,
    this.desktopRelayAvailable = false,
    this.desktopMiniWindowSupported = false,
    this.onMinimizeToMiniBar,
    this.onClosePage,
  });

  /// 核心音频播放控制器。
  final AudioPlaybackController controller;

  /// 封面聚类流光缓存。
  final ArtworkPaletteCache paletteCache;

  /// 封面智能构图对齐缓存。
  final SmartCoverAlignmentCache alignmentCache;

  /// 可选外部歌词滚动视图构建器（为空时舞台优雅降级为纯音频信息展示）。
  final AudioLyricsViewportBuilder? lyricsViewportBuilder;

  /// 从各插件收集的播放器右侧扩展抽屉贡献项（内部自动按 `PlayerMediaMode.audio` 与平台过滤）。
  final List<PlayerSidePanelContribution> extraSidePanels;

  /// 当前运行平台枚举。
  final KonataPlatform platform;

  /// 桌面端外部发烧播放器接力是否可用。
  final bool desktopRelayAvailable;

  /// 当前宿主是否支持桌面端置顶迷你小窗切换。
  final bool desktopMiniWindowSupported;

  /// 点击最小化收拢为悬浮小窗时的回调。
  final VoidCallback? onMinimizeToMiniBar;

  /// 点击彻底退出关闭舞台页面时的回调。
  final VoidCallback? onClosePage;

  @override
  State<ImmersiveAudioPage> createState() => _ImmersiveAudioPageState();
}

class _ImmersiveAudioPageState extends State<ImmersiveAudioPage> {
  final FocusNode _keyboardFocusNode = FocusNode();

  AudioStageRightTab _rightTab = AudioStageRightTab.lyrics;
  bool _portraitShowLyrics = false;
  bool _sideQueueOpen = false;
  PlayerSidePanelContribution? _activeSidePanel;

  List<PlayerSidePanelContribution> get _eligibleSidePanels {
    final matched = widget.extraSidePanels
        .where((p) => p.isSupportedOn(widget.platform, PlayerMediaMode.audio))
        .toList();
    matched.sort((a, b) => a.order.compareTo(b.order));
    return matched;
  }

  void _handleSidePanelTap(PlayerSidePanelContribution panel) {
    setState(() {
      if (_activeSidePanel?.id == panel.id) {
        _activeSidePanel = null;
      } else {
        _sideQueueOpen = false;
        _activeSidePanel = panel;
      }
    });
  }

  void _handleToggleQueue(bool isNarrowPortrait) {
    if (isNarrowPortrait) {
      unawaited(
        showKonataGlassBottomSheet<void>(
          context: context,
          title: '播放队列 (${widget.controller.snapshot.queue.length})',
          builder: (_) => SizedBox(
            height: 360,
            child: ValueListenableBuilder<AudioPlaybackSnapshot>(
              valueListenable: widget.controller.snapshotListenable,
              builder: (_, snap, _) => AudioQueueListView(
                controller: widget.controller,
                snapshot: snap,
              ),
            ),
          ),
        ),
      );
      return;
    }
    setState(() {
      _activeSidePanel = null;
      _sideQueueOpen = !_sideQueueOpen;
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        unawaited(widget.controller.togglePlayPause());
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        final nextPos = (widget.controller.currentTrackPositionSeconds - 5.0)
            .clamp(0.0, 86400.0);
        unawaited(widget.controller.seekRelativeTrackSeconds(nextPos));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        unawaited(
          widget.controller.seekRelativeTrackSeconds(
            widget.controller.currentTrackPositionSeconds + 5.0,
          ),
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        unawaited(
          widget.controller.setVolume(
            (widget.controller.snapshot.volume + 5.0).clamp(0.0, 100.0),
          ),
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        unawaited(
          widget.controller.setVolume(
            (widget.controller.snapshot.volume - 5.0).clamp(0.0, 100.0),
          ),
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (_activeSidePanel != null || _sideQueueOpen) {
          setState(() {
            _activeSidePanel = null;
            _sideQueueOpen = false;
          });
          return KeyEventResult.handled;
        }
        widget.onMinimizeToMiniBar?.call();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Widget _buildSidePanelContent(
    BuildContext context,
    PlayerSidePanelContribution panel,
    AudioQueueItem? currentItem,
  ) {
    final built = panel.viewBuilder(
      ViewSlotContext(
        platformContext: context,
        workId: currentItem?.workId,
        variantId: currentItem?.variantId,
        arguments: <String, Object?>{
          'trackKey': currentItem?.itemId,
          'title': currentItem?.title,
          'artist': currentItem?.artist,
          'album': currentItem?.album,
          'controller': widget.controller,
        },
      ),
    );
    return built is Widget ? built : const SizedBox.shrink();
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: ValueListenableBuilder<AudioPlaybackSnapshot>(
        valueListenable: widget.controller.snapshotListenable,
        builder: (context, snap, _) {
          final currentItem = snap.currentItem;
          final sidePanels = _eligibleSidePanels;

          return AudioAuroraBackdrop(
            cover: snap.cover,
            coverVariantTag: snap.coverVariantTag,
            paletteCache: widget.paletteCache,
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final height = constraints.maxHeight;
                  final isPortraitPhone = width < 720 && height >= 520;
                  final isShortLandscape = height < 520;

                  return Stack(
                    children: [
                      Column(
                        children: [
                          // 顶部栏：最小化收拢、专辑标题与安全护耳状态入口、关闭按钮。
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                            child: Row(
                              children: [
                                if (widget.onMinimizeToMiniBar != null)
                                  KonataCapsuleIconButton(
                                    icon: Icons.keyboard_arrow_down_rounded,
                                    tooltip: '收起为悬浮迷你唱片 (Esc)',
                                    color: Colors.white.withValues(alpha: 0.90),
                                    size: 24,
                                    fixedSize: 38.0,
                                    onTap: widget.onMinimizeToMiniBar,
                                  ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: KonataDesktopWindowChromeScope.wrapDragToMove(
                                    context,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          currentItem?.album ?? '沉浸式 CD 音乐舞台',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (snap.errorMessage != null)
                                          Text(
                                            snap.errorMessage!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Color(0xFFFFB4AB),
                                              fontSize: 11.5,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (snap.audiophilePlan.safetyLimiterEngaged)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: GestureDetector(
                                      onTap: () => unawaited(
                                        showAudiophileSafetyDialog(
                                          context,
                                          widget.controller,
                                        ),
                                      ),
                                      child: const KonataSpecBadge(
                                        label: '-12 dBFS',
                                        icon: Icons.verified_user_outlined,
                                        highlighted: true,
                                        darkOverlay: true,
                                      ),
                                    ),
                                  ),
                                if (widget.onClosePage != null)
                                  KonataCapsuleIconButton(
                                    icon: Icons.close_rounded,
                                    tooltip: '关闭音频播放会话',
                                    color: Colors.white.withValues(alpha: 0.85),
                                    size: 20,
                                    fixedSize: 38.0,
                                    onTap: () {
                                      unawaited(
                                        widget.controller.stopAndClose(),
                                      );
                                      widget.onClosePage?.call();
                                    },
                                  ),
                                if (KonataDesktopWindowChromeScope.buildWindowControls(
                                      context,
                                      forceLightIcons: true,
                                    )
                                    case final desktopControls?) ...[
                                  const SizedBox(width: 8),
                                  desktopControls,
                                ],
                              ],
                            ),
                          ),
                          // 自适应核心舞台区域。
                          Expanded(
                            child: isShortLandscape
                                ? ShortPhoneLandscapeStage(
                                    controller: widget.controller,
                                    snapshot: snap,
                                    lyricsViewportBuilder:
                                        widget.lyricsViewportBuilder,
                                  )
                                : (isPortraitPhone
                                      ? PortraitPhoneAudioStage(
                                          controller: widget.controller,
                                          snapshot: snap,
                                          alignmentCache: widget.alignmentCache,
                                          showingLyrics: _portraitShowLyrics,
                                          onToggleShowLyrics: () => setState(
                                            () => _portraitShowLyrics =
                                                !_portraitShowLyrics,
                                          ),
                                          lyricsViewportBuilder:
                                              widget.lyricsViewportBuilder,
                                        )
                                      : DesktopAudioDualStage(
                                          controller: widget.controller,
                                          snapshot: snap,
                                          alignmentCache: widget.alignmentCache,
                                          rightTab: _rightTab,
                                          onRightTabChanged: (t) =>
                                              setState(() => _rightTab = t),
                                          lyricsViewportBuilder:
                                              widget.lyricsViewportBuilder,
                                        )),
                          ),
                          // 底部玻璃胶囊控制条。
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              isPortraitPhone ? 12 : 24,
                              4,
                              isPortraitPhone ? 12 : 24,
                              isShortLandscape ? 8 : 16,
                            ),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth:
                                      KonataPlaybackTokens.capsuleAudioMaxWidth,
                                ),
                                child: AudioPlaybackCapsule(
                                  controller: widget.controller,
                                  snapshot: snap,
                                  sidePanels: sidePanels,
                                  compact: isPortraitPhone || isShortLandscape,
                                  isQueueOpen: _sideQueueOpen,
                                  activeSidePanelId: _activeSidePanel?.id,
                                  onToggleQueue: () =>
                                      _handleToggleQueue(isPortraitPhone),
                                  onOpenSafetyDialog: () => unawaited(
                                    showAudiophileSafetyDialog(
                                      context,
                                      widget.controller,
                                    ),
                                  ),
                                  onOpenSidePanel: _handleSidePanelTap,
                                  onRelayToDesktop: widget.desktopRelayAvailable
                                      ? () => unawaited(
                                          widget.controller
                                              .relayActiveToDesktop(),
                                        )
                                      : null,
                                  onToggleDesktopMini:
                                      widget.desktopMiniWindowSupported
                                      ? () => unawaited(
                                          widget.controller
                                              .setDesktopMiniWindow(
                                                !snap.isDesktopMiniWindow,
                                              ),
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      // 桌面/平板右侧悬浮玻璃抽屉（队列或动态注入面板，自带全屏遮罩与边缘手势关闭）。
                      if ((_sideQueueOpen || _activeSidePanel != null) &&
                          !isPortraitPhone)
                        Positioned.fill(
                          child: KonataGlassSideSheet(
                            title: _activeSidePanel?.label ??
                                '播放队列 (${snap.queue.length})',
                            width: math.min(390.0, width * 0.45),
                            bottomInset: 104.0,
                            onClose: () => setState(() {
                              _sideQueueOpen = false;
                              _activeSidePanel = null;
                            }),
                            child: _activeSidePanel != null
                                ? _buildSidePanelContent(
                                    context,
                                    _activeSidePanel!,
                                    currentItem,
                                  )
                                : AudioQueueListView(
                                    controller: widget.controller,
                                    snapshot: snap,
                                  ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
