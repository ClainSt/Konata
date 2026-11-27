import 'dart:async';
import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
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
import 'mini_audio_bar.dart';

/// Salt 风格全屏流光音频舞台主页面。
///
/// 支持桌面双栏、平板横/竖屏与 Android 手机独占纯竖屏自适应布局；
/// 全舞台恒定锁定深邃暗光域与纯白发光排版，绝不随外部浅色主题漂白；
/// 仅依赖 `konata_contracts` 动态拼装外挂歌词视口与 `PlayerMediaMode.audio` 面板。
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
    this.desktopMiniHostedExternally = false,
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

  /// 从各插件收集的播放器扩展面板贡献项（内部自动按 `PlayerMediaMode.audio` 与平台过滤）。
  final List<PlayerSidePanelContribution> extraSidePanels;

  /// 当前运行平台枚举。
  final KonataPlatform platform;

  /// 桌面端外部发烧播放器接力是否可用。
  final bool desktopRelayAvailable;

  /// 当前宿主是否支持桌面端置顶迷你小窗切换。
  final bool desktopMiniWindowSupported;

  /// 桌面异形小窗由应用根层独占挂载时隐藏路由内副本。
  final bool desktopMiniHostedExternally;

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
  bool _portraitQueueOpen = false;
  bool _menuOpen = false;
  bool _topChromeHovered = false;
  bool _relayBusy = false;
  bool _didLockPortraitOrientation = false;
  PlayerSidePanelContribution? _activeSidePanel;

  @override
  void initState() {
    super.initState();
    _syncOrientationLock();
  }

  @override
  void didUpdateWidget(covariant ImmersiveAudioPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.platform != widget.platform) {
      _syncOrientationLock();
    }
  }

  void _syncOrientationLock() {
    if (kIsWeb) return;
    if (widget.platform == KonataPlatform.androidPhone) {
      _didLockPortraitOrientation = true;
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
        ]),
      );
    } else if (_didLockPortraitOrientation) {
      _didLockPortraitOrientation = false;
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
      );
    }
  }

  List<PlayerSidePanelContribution> get _eligibleSidePanels {
    final matched = widget.extraSidePanels
        .where((p) => p.isSupportedOn(widget.platform, PlayerMediaMode.audio))
        .toList();
    matched.sort((a, b) => a.order.compareTo(b.order));
    return matched;
  }

  void _handleSidePanelTap(PlayerSidePanelContribution panel) {
    setState(() {
      _menuOpen = false;
      if (_activeSidePanel?.id == panel.id) {
        _activeSidePanel = null;
      } else {
        _rightTab = AudioStageRightTab.lyrics;
        _portraitQueueOpen = false;
        _activeSidePanel = panel;
      }
    });
  }

  void _handleToggleQueue(bool isVertical) {
    if (isVertical) {
      setState(() {
        _menuOpen = false;
        _activeSidePanel = null;
        _portraitQueueOpen = !_portraitQueueOpen;
      });
      return;
    }
    setState(() {
      _menuOpen = false;
      _activeSidePanel = null;
      _rightTab = _rightTab == AudioStageRightTab.lyrics
          ? AudioStageRightTab.queue
          : AudioStageRightTab.lyrics;
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
        if (widget.controller.snapshot.isDesktopMiniWindow) {
          unawaited(_toggleDesktopMiniWindow(false));
          return KeyEventResult.handled;
        }
        if (_menuOpen ||
            _activeSidePanel != null ||
            _rightTab == AudioStageRightTab.queue ||
            _portraitQueueOpen) {
          setState(() {
            _menuOpen = false;
            _activeSidePanel = null;
            _rightTab = AudioStageRightTab.lyrics;
            _portraitQueueOpen = false;
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
    AudioQueueItem? currentItem, {
    bool embedded = false,
  }) {
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
          'embedded': embedded,
        },
      ),
    );
    return built is Widget ? built : const SizedBox.shrink();
  }

  @override
  void dispose() {
    if (_didLockPortraitOrientation && !kIsWeb) {
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
      );
    }
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  Future<void> _closePlayback() async {
    try {
      await widget.controller.stopAndClose();
      if (mounted) widget.onClosePage?.call();
    } catch (_) {
      if (mounted) showKonataToast(context, '关闭失败，请重试', isError: true);
    }
  }

  Future<void> _relayToDesktop() async {
    if (_relayBusy) return;
    setState(() => _relayBusy = true);
    try {
      var result = await widget.controller.relayActiveToDesktop();
      if (!mounted) return;
      if (result?.requiresBeefwebPrompt == true) {
        final proceed = await confirmFoobarWithoutBeefweb(context);
        if (!mounted || proceed != true) return;
        result = await widget.controller.relayActiveToDesktop(
          allowWithoutBeefweb: true,
        );
      }
      if (!mounted) return;
      showKonataToast(
        context,
        result?.message ?? '外部播放器不可用',
        isError: result?.launched != true,
      );
      if (result?.launched == true &&
          !widget.controller.activeListenable.value) {
        widget.onClosePage?.call();
      }
    } catch (_) {
      if (mounted) {
        showKonataToast(context, '外部播放移交失败，请检查播放器配置', isError: true);
      }
    } finally {
      if (mounted) setState(() => _relayBusy = false);
    }
  }

  Future<void> _toggleDesktopMiniWindow(bool enabled) async {
    try {
      await widget.controller.setDesktopMiniWindow(enabled);
    } catch (_) {
      if (mounted) {
        showKonataToast(context, '窗口切换失败，请重试', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: KonataTheme.darkTheme(),
      child: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: ValueListenableBuilder<AudioPlaybackSnapshot>(
          valueListenable: widget.controller.snapshotListenable,
          builder: (context, snap, _) {
            if (snap.isDesktopMiniWindow) {
              if (widget.desktopMiniHostedExternally) {
                return const SizedBox.shrink();
              }
              return MiniAudioBar(
                controller: widget.controller,
                desktopMiniWindowSupported: true,
                onClose: widget.onClosePage,
                onReturnToInternal: widget.onMinimizeToMiniBar,
              );
            }
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
                    final isVertical =
                        widget.platform == KonataPlatform.androidPhone ||
                        width < 720 ||
                        (widget.platform == KonataPlatform.androidTablet &&
                            width < height);
                    final isTabletPortrait =
                        isVertical &&
                        widget.platform == KonataPlatform.androidTablet;

                    return Stack(
                      children: [
                        Column(
                          children: [
                            // 顶栏：手机竖屏封面态极简留白（左 ⌄ + 右菜单），歌词态顶部中央淡入迷你封面胶囊；
                            // 宽屏顶栏常态静默隐形（0.36 -> 悬停 0.92）并完整保留宿主窗口控制。
                            isVertical
                                ? _buildPortraitTopBar(
                                    context: context,
                                    snap: snap,
                                    currentItem: currentItem,
                                  )
                                : _buildWidescreenTopBar(
                                    context: context,
                                    snap: snap,
                                    currentItem: currentItem,
                                    sidePanels: sidePanels,
                                  ),
                            // 核心舞台：Android 手机锁纯竖屏，桌面与平板横屏双栏。
                            Expanded(
                              child: isVertical
                                  ? AnimatedSwitcher(
                                      duration: KonataTheme.motionStandard,
                                      child: _portraitQueueOpen
                                          ? Padding(
                                              key: const ValueKey(
                                                'audio_portrait_queue_stage',
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 18,
                                                  ),
                                              child: AudioQueueListView(
                                                controller: widget.controller,
                                                snapshot: snap,
                                              ),
                                            )
                                          : PortraitPhoneAudioStage(
                                              controller: widget.controller,
                                              snapshot: snap,
                                              alignmentCache:
                                                  widget.alignmentCache,
                                              showingLyrics:
                                                  _portraitShowLyrics,
                                              isTabletPortrait:
                                                  isTabletPortrait,
                                              onToggleShowLyrics: () =>
                                                  setState(
                                                    () => _portraitShowLyrics =
                                                        !_portraitShowLyrics,
                                                  ),
                                              lyricsViewportBuilder:
                                                  widget.lyricsViewportBuilder,
                                            ),
                                    )
                                  : DesktopAudioDualStage(
                                      controller: widget.controller,
                                      snapshot: snap,
                                      alignmentCache: widget.alignmentCache,
                                      rightTab: _rightTab,
                                      stageHeight: height,
                                      onRightTabChanged: (t) =>
                                          setState(() => _rightTab = t),

                                      lyricsViewportBuilder:
                                          widget.lyricsViewportBuilder,
                                    ),
                            ),
                            // 底部区：宽屏为超轻烟熏玻璃隐形胶囊，手机竖屏为纯白通透播控区。
                            isVertical
                                ? _buildPortraitBottomControls(
                                    snap: snap,
                                    isTabletPortrait: isTabletPortrait,
                                  )
                                : Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      24,
                                      4,
                                      24,
                                      KonataPlaybackTokens.capsuleBottomOffset,
                                    ),
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: KonataPlaybackTokens
                                              .capsuleAudioMaxWidth,
                                        ),
                                        child: AudioPlaybackCapsule(
                                          controller: widget.controller,
                                          snapshot: snap,
                                          sidePanels: const [],
                                          compact: false,
                                          isQueueOpen:
                                              _rightTab ==
                                              AudioStageRightTab.queue,
                                          activeSidePanelId:
                                              _activeSidePanel?.id,
                                          onToggleQueue: () =>
                                              _handleToggleQueue(false),

                                          onOpenSidePanel: _handleSidePanelTap,
                                        ),
                                      ),
                                    ),
                                  ),
                          ],
                        ),
                        // 独立扩展面板不占用歌词与队列的舞台切换路径。
                        if (_activeSidePanel != null && !isVertical)
                          Positioned.fill(
                            child: KonataGlassSideSheet(
                              title: _activeSidePanel!.label,
                              width: math.min(420.0, width * 0.46),
                              bottomInset: 96.0,
                              onClose: () =>
                                  setState(() => _activeSidePanel = null),
                              child: _buildSidePanelContent(
                                context,
                                _activeSidePanel!,
                                currentItem,
                              ),
                            ),
                          ),
                        // 右上角菜单统一弹层：整合双语译文、歌词延迟、词源切换与无损输出链路信息。
                        if (_menuOpen)
                          _buildUnifiedMenuOverlay(
                            context: context,
                            snap: snap,
                            currentItem: currentItem,
                            sidePanels: sidePanels,
                            isVertical: isVertical,
                            viewportW: width,
                            viewportH: height,
                          ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildWidescreenTopBar({
    required BuildContext context,
    required AudioPlaybackSnapshot snap,
    required AudioQueueItem? currentItem,
    required List<PlayerSidePanelContribution> sidePanels,
  }) {
    final activeChrome =
        _topChromeHovered ||
        _menuOpen ||
        _rightTab == AudioStageRightTab.queue ||
        _activeSidePanel != null;
    final quickPanels = sidePanels
        .where((p) => p.id != 'lyrics_control')
        .toList(growable: false);
    final windowControls = KonataDesktopWindowChromeScope.buildWindowControls(
      context,
      forceLightIcons: true,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _topChromeHovered = true),
      onExit: (_) => setState(() => _topChromeHovered = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        opacity: activeChrome ? 1.0 : 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 16, 4),
          child: Row(
            children: [
              if (widget.onMinimizeToMiniBar != null) ...[
                KonataCapsuleIconButton(
                  key: const ValueKey('audio_minimize_button'),
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: '悬浮小窗',
                  color: Colors.white.withValues(alpha: 0.92),
                  size: 24,
                  fixedSize: 38.0,
                  onTap: widget.onMinimizeToMiniBar,
                ),
                const SizedBox(width: 6),
              ],
              if (widget.desktopMiniWindowSupported) ...[
                KonataCapsuleIconButton(
                  icon: snap.isDesktopMiniWindow
                      ? Icons.open_in_full_rounded
                      : Icons.picture_in_picture_alt_rounded,
                  tooltip: snap.isDesktopMiniWindow ? '恢复窗口' : '桌面小窗',
                  color: Colors.white.withValues(alpha: 0.90),
                  highlighted: snap.isDesktopMiniWindow,
                  size: 19,
                  fixedSize: 36.0,
                  onTap: () => unawaited(
                    _toggleDesktopMiniWindow(!snap.isDesktopMiniWindow),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (widget.onClosePage != null) ...[
                const SizedBox(width: 4),
                KonataCapsuleIconButton(
                  icon: Icons.close_rounded,
                  tooltip: '关闭',
                  color: Colors.white.withValues(alpha: 0.88),
                  size: 20,
                  fixedSize: 36.0,
                  onTap: () => unawaited(_closePlayback()),
                ),
              ],
              Expanded(
                child: KonataDesktopWindowChromeScope.wrapDragToMove(
                  context,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                        forceDarkTheme: true,
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
              for (final panel in quickPanels) ...[
                KonataCapsuleIconButton(
                  icon: KonataIconRegistry.resolve(panel.iconKey),
                  tooltip: panel.label,
                  color: Colors.white.withValues(alpha: 0.90),
                  highlighted: _activeSidePanel?.id == panel.id,
                  size: 19,
                  fixedSize: 36.0,
                  onTap: () => _handleSidePanelTap(panel),
                ),
                const SizedBox(width: 4),
              ],
              KonataCapsuleIconButton(
                key: const ValueKey('audio_top_menu_button'),
                icon: Icons.tune_rounded,
                tooltip: '播放设置',
                color: Colors.white.withValues(alpha: _menuOpen ? 1.0 : 0.92),
                showHoverBackground: false,
                size: 19,
                fixedSize: 36.0,
                onTap: () => setState(() {
                  _rightTab = AudioStageRightTab.lyrics;
                  _activeSidePanel = null;
                  _menuOpen = !_menuOpen;
                }),
              ),
              if (widget.desktopRelayAvailable)
                KonataCapsuleIconButton(
                  key: const ValueKey('audio_top_external_relay'),
                  icon: Icons.open_in_new_rounded,
                  tooltip: '外部播放器',
                  color: Colors.white,
                  fixedSize: 36,
                  size: 19,
                  onTap: () => unawaited(_relayToDesktop()),
                ),
              if (windowControls != null) ...[
                const SizedBox(width: 8),
                windowControls,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitTopBar({
    required BuildContext context,
    required AudioPlaybackSnapshot snap,
    required AudioQueueItem? currentItem,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        children: [
          if (widget.onMinimizeToMiniBar != null)
            KonataCapsuleIconButton(
              key: const ValueKey('audio_minimize_button'),
              icon: Icons.keyboard_arrow_down_rounded,
              tooltip: '悬浮小窗',
              color: Colors.white.withValues(alpha: 0.90),
              size: 26,
              fixedSize: 44.0,
              onTap: widget.onMinimizeToMiniBar,
            )
          else
            const SizedBox(width: 44, height: 44),
          Expanded(
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _portraitShowLyrics
                    ? GestureDetector(
                        key: const ValueKey('portrait_top_mini_cover_pill'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            setState(() => _portraitShowLyrics = false),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(5, 4, 12, 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.16),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ImmersiveMicroCover(
                                cover: snap.cover,
                                coverKey: snap.coverVariantTag,
                                size: 28,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  currentItem?.title ?? '返回封面',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.92),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('portrait_top_empty_center'),
                      ),
              ),
            ),
          ),
          KonataCapsuleIconButton(
            key: const ValueKey('audio_top_menu_button'),
            icon: Icons.tune_rounded,
            tooltip: '播放设置',
            color: Colors.white.withValues(alpha: _menuOpen ? 1.0 : 0.90),
            showHoverBackground: false,
            size: 21,
            fixedSize: 44.0,
            onTap: () => setState(() {
              _portraitQueueOpen = false;
              _menuOpen = !_menuOpen;
            }),
          ),
          if (widget.onClosePage != null) ...[
            const SizedBox(width: 2),
            KonataCapsuleIconButton(
              icon: Icons.close_rounded,
              tooltip: '关闭',
              color: Colors.white.withValues(alpha: 0.84),
              size: 20,
              fixedSize: 40.0,
              onTap: () => unawaited(_closePlayback()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPortraitBottomControls({
    required AudioPlaybackSnapshot snap,
    required bool isTabletPortrait,
  }) {
    final loopIcon = switch (snap.loopMode) {
      AudioLoopMode.sequence => Icons.trending_flat_rounded,
      AudioLoopMode.loopAll => Icons.repeat_rounded,
      AudioLoopMode.loopOne => Icons.repeat_one_rounded,
      AudioLoopMode.shuffle => Icons.shuffle_rounded,
    };
    final loopTooltip = switch (snap.loopMode) {
      AudioLoopMode.sequence => '顺序播放',
      AudioLoopMode.loopAll => '列表循环',
      AudioLoopMode.loopOne => '单曲循环',
      AudioLoopMode.shuffle => '随机播放',
    };
    final loopActive = snap.loopMode != AudioLoopMode.sequence;

    return Padding(
      key: const ValueKey('salt_portrait_bottom_controls'),
      padding: EdgeInsets.fromLTRB(
        isTabletPortrait ? 56 : 24,
        4,
        isTabletPortrait ? 56 : 24,
        18,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AudioLeafDurationScrubber(
              positionListenable: widget.controller.positionListenable,
              durationListenable: widget.controller.durationListenable,
              onSeekTo: widget.controller.seekToTrackPosition,
              compact: true,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                KonataCapsuleIconButton(
                  icon: loopIcon,
                  tooltip: loopTooltip,
                  color: Colors.white.withValues(
                    alpha: loopActive ? 0.96 : 0.66,
                  ),
                  onTap: widget.controller.cycleLoopMode,
                  showHoverBackground: false,
                  size: 21,
                  fixedSize: 44.0,
                ),
                KonataCapsuleIconButton(
                  icon: Icons.skip_previous_rounded,
                  tooltip: '上一曲',
                  color: Colors.white.withValues(alpha: 0.94),
                  onTap: () => unawaited(widget.controller.previous()),
                  size: 30,
                  fixedSize: 48.0,
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: widget.controller.playingListenable,
                  builder: (context, isPlaying, _) {
                    return KonataCapsuleIconButton(
                      key: const ValueKey('audio_portrait_play_pause_button'),
                      icon: isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      tooltip: isPlaying ? '暂停' : '继续播放',
                      color: Colors.white,
                      fixedSize: 60,
                      size: 34,
                      showHoverBackground: false,
                      onTap: () =>
                          unawaited(widget.controller.togglePlayPause()),
                    );
                  },
                ),
                KonataCapsuleIconButton(
                  icon: Icons.skip_next_rounded,
                  tooltip: '下一曲',
                  color: Colors.white.withValues(alpha: 0.94),
                  onTap: () => unawaited(widget.controller.next(manual: true)),
                  size: 30,
                  fixedSize: 48.0,
                ),
                KonataCapsuleIconButton(
                  key: const ValueKey('audio_portrait_queue_button'),
                  icon: _portraitQueueOpen
                      ? Icons.lyrics_outlined
                      : Icons.queue_music_rounded,
                  tooltip: _portraitQueueOpen ? '歌词' : '播放队列',
                  color: Colors.white.withValues(alpha: 0.84),
                  onTap: () => _handleToggleQueue(true),
                  showHoverBackground: false,
                  size: 21,
                  fixedSize: 44.0,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnifiedMenuOverlay({
    required BuildContext context,
    required AudioPlaybackSnapshot snap,
    required AudioQueueItem? currentItem,
    required List<PlayerSidePanelContribution> sidePanels,
    required bool isVertical,
    required double viewportW,
    required double viewportH,
  }) {
    final plan = snap.audiophilePlan;
    final routeLabel = switch (plan.routeMode) {
      AudioOutputRouteMode.sharedResampled => '系统共享重采样',
      AudioOutputRouteMode.exclusiveAudioOutput => '桌面独占直通',
      AudioOutputRouteMode.bitstreamPassthrough => 'HDMI / S/PDIF 透传',
      AudioOutputRouteMode.androidBitPerfectUsb => 'USB DAC 逐位直通',
    };
    final detailSpec = [
      if (snap.formattedAudioSpec.isNotEmpty) snap.formattedAudioSpec,
      if (snap.channelCount > 0) '${snap.channelCount}声道',
      routeLabel,
    ].join(' · ');

    final menuBody = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 无损输出链路信息与发烧安全控制卡片。
          KonataSurfaceCard(
            key: const ValueKey('audio_lossless_chain_card'),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.graphic_eq_rounded,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.90),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '无损输出链路',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    KonataSpecBadge(
                      label: plan.safetyLimiterEngaged
                          ? '-12 dBFS 已保护'
                          : '直通未限幅',
                      highlighted: plan.safetyLimiterEngaged,
                      darkOverlay: true,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  detailSpec.isNotEmpty ? detailSpec : routeLabel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    KonataPillButton.secondary(
                      key: const ValueKey('audio_menu_safety_button'),
                      label: '安全链与设备输出',
                      icon: Icons.verified_user_outlined,
                      compact: true,
                      onPressed: () {
                        setState(() => _menuOpen = false);
                        unawaited(
                          showAudiophileSafetyDialog(
                            context,
                            widget.controller,
                            forceDarkTheme: true,
                          ),
                        );
                      },
                    ),
                    if (widget.desktopRelayAvailable)
                      KonataPillButton.secondary(
                        key: const ValueKey('audio_menu_relay_button'),
                        label: '桌面外发接力',
                        icon: Icons.open_in_new_rounded,
                        compact: true,
                        onPressed: _relayBusy
                            ? null
                            : () => unawaited(_relayToDesktop()),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // 动态渲染所有与音频舞台协作的扩展控制面板（如 feature_lyrics 的歌词控制面板）。
          for (final panel in sidePanels) ...[
            const SizedBox(height: 12),
            _buildSidePanelContent(context, panel, currentItem, embedded: true),
          ],
        ],
      ),
    );

    final panelWidth = isVertical
        ? math.min(540.0, viewportW)
        : math.min(440.0, viewportW - 32.0);
    final panelMaxHeight = isVertical
        ? math.min(620.0, viewportH * 0.82)
        : math.max(240.0, viewportH - 130.0);

    return Positioned.fill(
      key: const ValueKey('audio_unified_menu_overlay'),
      child: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _menuOpen = false),
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.44)),
          ),
          Align(
            alignment: isVertical ? Alignment.bottomCenter : Alignment.topRight,
            child: Padding(
              padding: isVertical
                  ? EdgeInsets.zero
                  : const EdgeInsets.fromLTRB(16, 54, 18, 16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: panelWidth,
                  maxHeight: panelMaxHeight,
                ),
                child: ClipRRect(
                  borderRadius: isVertical
                      ? const BorderRadius.vertical(top: Radius.circular(24))
                      : BorderRadius.circular(22),
                  child: KonataAdaptiveBackdropBlur(
                    filter: KonataTheme.blurFilterOverlay,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xE014111C),
                        borderRadius: isVertical
                            ? const BorderRadius.vertical(
                                top: Radius.circular(24),
                              )
                            : BorderRadius.circular(22),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 14, 12, 8),
                            child: Row(
                              children: [
                                const Text(
                                  '歌词与音频菜单',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const Spacer(),
                                KonataGlassCloseButton(
                                  onPressed: () =>
                                      setState(() => _menuOpen = false),
                                ),
                              ],
                            ),
                          ),
                          Flexible(child: menuBody),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
