import 'dart:async';
import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../state/video_playback_controller.dart';
import '../state/video_playback_state.dart';
import 'video_playback_capsule.dart';
import 'video_side_sheet.dart';

/// 内置全屏视频播放舞台的顶底单层毛玻璃浮层、字幕底栏避让与快捷键、滚轮调音协调组件。
///
/// 在播放暂停或三秒无操作隐藏控制栏时立即取消定时倒计时，并卸除底部高频进度监听组件树，
/// 同时同步恢复 `libmpv` 字幕原始定位，确保全屏稳态观看期间零后台定时器与零进度重绘开销。
class EmbeddedVideoOverlays extends StatefulWidget {
  /// 创建视频舞台交互浮层。
  const EmbeddedVideoOverlays({
    super.key,
    required this.controller,
    required this.onExitRequested,
    this.playerSidePanels = const <PlayerSidePanelContribution>[],
    this.onEnterMiniRequested,
    this.autoHideDelay = KonataPlaybackTokens.cursorIdleFadeDelay,
    this.isTouchPlatform = false,
    this.screenLocked = false,
    this.onHudVisibilityChanged,
  });

  /// 视频播放核心状态控制器。
  final VideoPlaybackController controller;

  /// 用户点击返回按钮或按下退出快捷键时的回调。
  final VoidCallback onExitRequested;

  /// 用户点击切换至迷你小窗模式时的回调。
  final VoidCallback? onEnterMiniRequested;

  /// 外部业务包声明并待挂载的视频扩展侧栏贡献列表。
  final List<PlayerSidePanelContribution> playerSidePanels;

  /// 控制条无操作自动隐藏倒计时（默认 3 秒）。
  final Duration autoHideDelay;

  /// 当前是否按触屏密度与交互习惯渲染控件。
  final bool isTouchPlatform;

  /// 当前是否处于触屏防误触锁定态（锁定时隐藏顶底胶囊并立即复原字幕位置）。
  final bool screenLocked;

  /// 当控制层真实显隐状态变更时通知外层（用于同步左侧防误触锁钮可见性）。
  final ValueChanged<bool>? onHudVisibilityChanged;

  @override
  State<EmbeddedVideoOverlays> createState() => _EmbeddedVideoOverlaysState();
}

class _EmbeddedVideoOverlaysState extends State<EmbeddedVideoOverlays> {
  static const double _kSubtitleBreathingGapDp = 16.0;

  final FocusNode _focusNode = FocusNode(debugLabel: 'embedded_video_hud');
  final GlobalKey _bottomCapsuleKey = GlobalKey();

  Timer? _autoHideTimer;
  Timer? _wheelOsdTimer;
  bool _hudVisible = true;
  bool _volumePopupActive = false;
  bool _screenshotMenuOpen = false;
  bool _wheelOsdVisible = false;
  int _volumeRevealPulse = 0;
  VideoSideSheetTab? _activeSheetTab;
  bool _lastIsPlaying = false;
  double _lastViewportHeight = 0.0;
  double _lastBottomOffset = 0.0;
  bool? _lastReportedHudVisible;

  bool get _effectiveHudVisible => _hudVisible && !widget.screenLocked;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _lastIsPlaying = widget.controller.state.isPlaying;
    widget.controller.setHudVisible(_effectiveHudVisible);
    _syncAutoHideTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mq = MediaQuery.maybeOf(context);
    if (mq != null && mq.size.height > 0) {
      _lastViewportHeight = mq.size.height;
      _lastBottomOffset = _resolveBottomCapsuleMargin(mq.padding.bottom);
      _syncSubtitleHudLift();
    }
  }

  @override
  void didUpdateWidget(covariant EmbeddedVideoOverlays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastIsPlaying = widget.controller.state.isPlaying;
      widget.controller.setHudVisible(_effectiveHudVisible);
      _syncSubtitleHudLift();
      _syncAutoHideTimer();
    }
    if (oldWidget.screenLocked != widget.screenLocked) {
      _lastReportedHudVisible = _effectiveHudVisible;
      widget.controller.setHudVisible(_effectiveHudVisible);
      _syncSubtitleHudLift();
      _syncAutoHideTimer();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.setHudVisible(false);
    widget.controller.updateHudSubtitleLift(
      hudVisible: false,
      bottomCapsuleOccupiedHeight: 0.0,
      viewportHeight: _lastViewportHeight,
    );
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    _wheelOsdTimer?.cancel();
    _wheelOsdTimer = null;
    _focusNode.dispose();
    super.dispose();
  }

  double _resolveBottomCapsuleMargin(double safeBottom) {
    if (widget.isTouchPlatform) {
      return math.max(safeBottom, 14.0);
    }
    return KonataPlaybackTokens.capsuleBottomOffset;
  }

  double _resolveMeasuredBottomCapsuleHeight() {
    final ctx = _bottomCapsuleKey.currentContext;
    if (ctx != null) {
      final box = ctx.findRenderObject();
      if (box is RenderBox && box.hasSize && box.size.height > 0) {
        return box.size.height;
      }
    }
    return VideoPlaybackCapsule.capsuleHeight;
  }

  void _syncSubtitleHudLift({
    double? viewportHeightOverride,
    double? bottomOffsetOverride,
  }) {
    final viewportHeight = viewportHeightOverride ?? _lastViewportHeight;
    final bottomOffset = bottomOffsetOverride ?? _lastBottomOffset;
    if (viewportHeightOverride != null) {
      _lastViewportHeight = viewportHeightOverride;
    }
    if (bottomOffsetOverride != null) {
      _lastBottomOffset = bottomOffsetOverride;
    }

    final shouldLift =
        _effectiveHudVisible && !widget.controller.state.audioOnlyMode;
    final occupiedHeight = shouldLift
        ? (bottomOffset +
              _resolveMeasuredBottomCapsuleHeight() +
              _kSubtitleBreathingGapDp)
        : 0.0;
    widget.controller.updateHudSubtitleLift(
      hudVisible: shouldLift,
      bottomCapsuleOccupiedHeight: occupiedHeight,
      viewportHeight: viewportHeight,
    );
  }

  void _notifyHudVisibilityChanged() {
    final effective = _effectiveHudVisible;
    if (_lastReportedHudVisible == effective) return;
    _lastReportedHudVisible = effective;
    widget.onHudVisibilityChanged?.call(effective);
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final nowPlaying = widget.controller.state.isPlaying;
    if (nowPlaying != _lastIsPlaying) {
      _lastIsPlaying = nowPlaying;
      if (!nowPlaying) {
        _revealHud();
      } else {
        _syncAutoHideTimer();
      }
    }
  }

  void _syncAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;

    if (!_effectiveHudVisible ||
        !widget.controller.state.isPlaying ||
        _activeSheetTab != null ||
        _volumePopupActive ||
        _screenshotMenuOpen) {
      return;
    }

    _autoHideTimer = Timer(widget.autoHideDelay, () {
      if (!mounted) return;
      if (widget.controller.state.isPlaying &&
          _activeSheetTab == null &&
          !_volumePopupActive &&
          !_screenshotMenuOpen) {
        _setHudVisible(false);
      }
    });
  }

  void _setHudVisible(bool visible) {
    if (_hudVisible == visible) return;
    setState(() => _hudVisible = visible);
    widget.controller.setHudVisible(_effectiveHudVisible);
    _syncSubtitleHudLift();
    _notifyHudVisibilityChanged();
    if (!_effectiveHudVisible) {
      _autoHideTimer?.cancel();
      _autoHideTimer = null;
    } else {
      _syncAutoHideTimer();
    }
  }

  void _revealHud() {
    if (widget.screenLocked) return;
    if (!_hudVisible) {
      _setHudVisible(true);
    } else {
      _syncAutoHideTimer();
    }
  }

  /// 供外层触控手势层切换控制层显示或隐藏状态。
  void toggleHudVisibility() {
    if (widget.screenLocked) return;
    _setHudVisible(!_hudVisible);
  }

  /// 供宿主画布在鼠标悬停时唤醒控制层并重置隐藏倒计时。
  void notifyPointerHover() {
    if (widget.isTouchPlatform || widget.screenLocked) return;
    _revealHud();
  }

  /// 供宿主画布转发鼠标滚轮音量调节信号。
  void handlePointerWheel(double scrollDeltaY) {
    _handleMouseWheelScroll(scrollDeltaY);
  }

  void _openSheet(VideoSideSheetTab tab) {
    if (widget.screenLocked) return;
    setState(() {
      _activeSheetTab = tab;
      _hudVisible = true;
    });
    widget.controller.setHudVisible(true);
    widget.controller.setSideSheetOpen(true);
    _syncSubtitleHudLift();
    _notifyHudVisibilityChanged();
    _syncAutoHideTimer();
  }

  void _closeSheet() {
    if (_activeSheetTab == null) return;
    setState(() => _activeSheetTab = null);
    widget.controller.setSideSheetOpen(false);
    _syncAutoHideTimer();
    _focusNode.requestFocus();
  }

  void _handleMouseWheelScroll(double scrollDeltaY) {
    if (scrollDeltaY == 0 || widget.screenLocked || _activeSheetTab != null) {
      return;
    }
    final step = scrollDeltaY < 0
        ? KonataPlaybackTokens.wheelVolumeStep
        : -KonataPlaybackTokens.wheelVolumeStep;
    widget.controller.setVolume(widget.controller.state.volume + step);
    _wheelOsdTimer?.cancel();
    setState(() {
      _wheelOsdVisible = true;
      _volumeRevealPulse++;
    });
    _wheelOsdTimer = Timer(KonataPlaybackTokens.wheelVolumeOsdDuration, () {
      if (mounted) {
        setState(() => _wheelOsdVisible = false);
      }
    });
  }

  /// 截图菜单与快捷键共用控制器的双模式原画截图入口。
  Future<void> _showScreenshotMenu(BuildContext anchor) async {
    if (_screenshotMenuOpen) return;
    _screenshotMenuOpen = true;
    _syncAutoHideTimer();
    final controller = widget.controller;
    try {
      final selected = await showKonataGlassMenu<ScreenshotCaptureMode>(
        anchorContext: anchor,
        items: [
          for (final mode in ScreenshotCaptureMode.values)
            KonataGlassMenuItem(value: mode, label: mode.label),
        ],
      );
      if (mounted &&
          identical(widget.controller, controller) &&
          !widget.screenLocked &&
          selected != null) {
        await controller.captureScreenshot(mode: selected);
      }
    } finally {
      _screenshotMenuOpen = false;
      if (mounted) _syncAutoHideTimer();
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (widget.screenLocked) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      final shift = HardwareKeyboard.instance.isShiftPressed;
      if (key == LogicalKeyboardKey.space) {
        unawaited(widget.controller.togglePlayPause());
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        unawaited(widget.controller.seekRelativeSeconds(shift ? -85 : -5));
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        unawaited(widget.controller.seekRelativeSeconds(shift ? 85 : 5));
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        widget.controller.setVolume(widget.controller.state.volume + 5);
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        widget.controller.setVolume(widget.controller.state.volume - 5);
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyM) {
        widget.controller.toggleMute();
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyS) {
        unawaited(
          widget.controller.captureScreenshot(
            mode: shift
                ? ScreenshotCaptureMode.withSubtitles
                : ScreenshotCaptureMode.pureVideo,
          ),
        );
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyF) {
        unawaited(widget.controller.toggleFullscreen());
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        widget.controller.setProbeOverlayVisible(
          !widget.controller.state.probeOverlayVisible,
        );
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        if (_activeSheetTab != null) {
          _closeSheet();
        } else if (widget.controller.state.isFullscreen) {
          unawaited(widget.controller.toggleFullscreen());
        } else {
          widget.onExitRequested();
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final showHud = _effectiveHudVisible;
    final showDesktopCursor =
        widget.isTouchPlatform || showHud || _activeSheetTab != null;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.translucent,
        cursor: showDesktopCursor
            ? SystemMouseCursors.basic
            : SystemMouseCursors.none,
        onHover: widget.isTouchPlatform ? null : (_) => _revealHud(),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              _handleMouseWheelScroll(signal.scrollDelta.dy);
            }
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final mq = MediaQuery.maybeOf(context);
              final safe = mq?.padding ?? EdgeInsets.zero;
              final stageHeight =
                  constraints.maxHeight.isFinite && constraints.maxHeight > 0
                  ? constraints.maxHeight
                  : (mq?.size.height ?? 0.0);
              final bottomOffset = _resolveBottomCapsuleMargin(safe.bottom);

              if ((stageHeight - _lastViewportHeight).abs() > 0.5 ||
                  (bottomOffset - _lastBottomOffset).abs() > 0.5) {
                _lastViewportHeight = stageHeight;
                _lastBottomOffset = bottomOffset;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    _syncSubtitleHudLift(
                      viewportHeightOverride: stageHeight,
                      bottomOffsetOverride: bottomOffset,
                    );
                  }
                });
              }

              return ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final state = widget.controller.state;
                  final workTitle = state.currentWork?.title.trim() ?? '';
                  final epTitle = EpisodeTitleFormatter.formatCardTitle(
                    episode: state.currentEpisode.toSummaryView(),
                    workTitle: workTitle,
                    workMediaType: state.currentWork?.tmdbMediaType,
                    mainEpisodeCount: state.currentBundle?.mainEpisodes.length,
                  );
                  final headerTitle = epTitle;

                  final topInset = math.max(safe.top, 12.0);
                  final horizontalInset = math.max(
                    math.max(safe.left, safe.right),
                    14.0,
                  );
                  final skipBottom =
                      bottomOffset +
                      VideoPlaybackCapsule.capsuleHeight +
                      _kSubtitleBreathingGapDp;

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (showHud) ...[
                        Positioned(
                          top: topInset,
                          left: horizontalInset,
                          right: horizontalInset,
                          child: _TopBar(
                            key: const ValueKey('embedded_video_top_bar'),
                            title: headerTitle,
                            state: state,
                            isTouchPlatform: widget.isTouchPlatform,
                            onBack: widget.onExitRequested,
                            onCollapseToMini: widget.onEnterMiniRequested,
                            onEnterMini: () {
                              _revealHud();
                              if (widget.controller.env.platform ==
                                  KonataPlatform.windows) {
                                unawaited(
                                  widget.controller.enterMiniPlayer(
                                    desktopAlwaysOnTop: true,
                                  ),
                                );
                              } else {
                                widget.onEnterMiniRequested?.call();
                              }
                            },
                            onToggleAudioOnly: () {
                              _revealHud();
                              widget.controller.toggleAudioOnlyMode();
                              _syncSubtitleHudLift();
                            },
                            onToggleProbe: () {
                              _revealHud();
                              widget.controller.setProbeOverlayVisible(
                                !state.probeOverlayVisible,
                              );
                            },
                            onOpenVideoSettings: () =>
                                _openSheet(VideoSideSheetTab.video),
                            onLaunchExternal: () {
                              _revealHud();
                              unawaited(
                                widget.controller.launchExternalVideoPlayer(),
                              );
                            },
                            hasExternalRelay:
                                widget.controller.env.desktopRelayGateway !=
                                    null &&
                                widget.controller.env.platform ==
                                    KonataPlatform.windows,
                          ),
                        ),
                        Positioned(
                          left: horizontalInset,
                          right: horizontalInset,
                          bottom: bottomOffset,
                          child: Center(
                            child: KeyedSubtree(
                              key: _bottomCapsuleKey,
                              child: VideoPlaybackCapsule(
                                key: const ValueKey(
                                  'embedded_video_bottom_capsule',
                                ),
                                isPlaying: state.isPlaying,
                                hasPreviousEpisode:
                                    widget.controller.hasPreviousEpisode,
                                hasNextEpisode:
                                    widget.controller.hasNextEpisode,
                                speed: state.speed,
                                volume: state.volume,
                                isMuted: state.isMuted,
                                isFullscreen: state.isFullscreen,
                                positionListenable:
                                    widget.controller.positionNotifier,
                                durationListenable:
                                    widget.controller.durationNotifier,
                                bufferedListenable:
                                    widget.controller.bufferedNotifier,
                                chapters: state.chapters,
                                thumbnailService:
                                    widget.controller.thumbnailService,
                                volumeRevealPulse: _volumeRevealPulse,
                                showDesktopControls:
                                    widget.controller.env.platform ==
                                        KonataPlatform.windows &&
                                    !widget.isTouchPlatform,
                                enableBackdropBlur:
                                    !widget.isTouchPlatform ||
                                    state.audioOnlyMode,
                                isTouchPlatform: widget.isTouchPlatform,
                                onUserInteraction: _revealHud,
                                onVolumePopupActiveChanged: (active) {
                                  if (_volumePopupActive != active) {
                                    setState(() => _volumePopupActive = active);
                                    _syncAutoHideTimer();
                                  }
                                },
                                onTogglePlayPause: () => unawaited(
                                  widget.controller.togglePlayPause(),
                                ),
                                onSeek: (sec) => unawaited(
                                  widget.controller.seekToSeconds(sec),
                                ),
                                onPreviousEpisode: () => unawaited(
                                  widget.controller.playPreviousEpisode(),
                                ),
                                onNextEpisode: () => unawaited(
                                  widget.controller.playNextEpisode(),
                                ),
                                onVolumeChanged: widget.controller.setVolume,
                                onToggleMute: widget.controller.toggleMute,
                                onOpenScreenshotMenu: (anchor) =>
                                    unawaited(_showScreenshotMenu(anchor)),
                                onOpenEpisodesSheet: () =>
                                    _openSheet(VideoSideSheetTab.episodes),
                                onOpenSubtitlesSheet: () =>
                                    _openSheet(VideoSideSheetTab.subtitles),
                                onOpenAudioSheet: () =>
                                    _openSheet(VideoSideSheetTab.audio),
                                onOpenVideoSheet: () =>
                                    _openSheet(VideoSideSheetTab.video),
                                onToggleFullscreen: () => unawaited(
                                  widget.controller.toggleFullscreen(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (state.activeSkipWindow != null &&
                          !widget.screenLocked)
                        Positioned(
                          right: math.max(
                            KonataPlaybackTokens.skipPillRightOffset,
                            horizontalInset,
                          ),
                          bottom: showHud
                              ? skipBottom
                              : math.max(safe.bottom + 18.0, 24.0),
                          child: KonataPillButton.primary(
                            key: const ValueKey('video_skip_chapter_pill'),
                            icon: Icons.fast_forward_rounded,
                            label: state.activeSkipWindow!.label,
                            onPressed: () => unawaited(
                              widget.controller.triggerActiveSkipWindow(),
                            ),
                          ),
                        ),
                      if (_wheelOsdVisible)
                        Positioned(
                          top: math.max(
                            KonataPlaybackTokens.wheelVolumeOsdTopOffset,
                            topInset + 56.0,
                          ),
                          left: 0,
                          right: 0,
                          child: Center(
                            child: KonataOsdStrokedText(
                              state.isMuted
                                  ? '静音'
                                  : '音量 ${state.volume.round()}%',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      if (state.transientNotice != null)
                        Center(
                          child: _TransientNoticePill(
                            notice: state.transientNotice!,
                          ),
                        ),
                      if (_activeSheetTab != null && !widget.screenLocked)
                        VideoSideSheet(
                          controller: widget.controller,
                          initialTab: _activeSheetTab!,
                          playerSidePanels: widget.playerSidePanels,
                          onClose: _closeSheet,
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    super.key,
    required this.title,
    required this.state,
    required this.isTouchPlatform,
    required this.onBack,
    required this.onCollapseToMini,
    required this.onEnterMini,
    required this.onToggleAudioOnly,
    required this.onToggleProbe,
    required this.onOpenVideoSettings,
    required this.onLaunchExternal,
    required this.hasExternalRelay,
  });

  final String title;
  final VideoPlaybackState state;
  final bool isTouchPlatform;
  final VoidCallback onBack;
  final VoidCallback? onCollapseToMini;
  final VoidCallback onEnterMini;
  final VoidCallback onToggleAudioOnly;
  final VoidCallback onToggleProbe;
  final VoidCallback onOpenVideoSettings;
  final VoidCallback onLaunchExternal;
  final bool hasExternalRelay;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = p.textPrimary;

    final probeRes = PlaybackFormatters.formatResolutionBadge(
      state.probeStats.videoWidth,
      state.probeStats.videoHeight,
    );
    final resBadge = probeRes.isNotEmpty
        ? probeRes
        : (state.currentVariant.resolution ?? '').trim();

    final rawCodec = state.probeStats.videoCodec.isNotEmpty
        ? state.probeStats.videoCodec
        : (state.currentVariant.videoCodec ?? '');
    final codecBadge = PlaybackFormatters.formatCodecShortLabel(rawCodec);
    final probeBitDepth = PlaybackFormatters.formatVideoBitDepthLabel(
      state.probeStats.videoHwPixelFormat.isNotEmpty
          ? state.probeStats.videoHwPixelFormat
          : state.probeStats.videoPixelFormat,
    );
    final bitDepthBadge = probeBitDepth.isNotEmpty
        ? probeBitDepth
        : (state.currentVariant.bitDepth ?? '').trim();
    final codecSpecLabel = [
      if (codecBadge.isNotEmpty) codecBadge,
      if (bitDepthBadge.isNotEmpty) bitDepthBadge,
    ].join(' · ');

    final hwdecCurrent = state.probeStats.hwdecCurrent.trim();
    final hwActive = hwdecCurrent.isNotEmpty && hwdecCurrent != 'no';
    final hwdecLabel = hwActive
        ? '硬解 ($hwdecCurrent)'
        : (state.renderBackend == 'sw'
              ? 'SW 兼容'
              : (hwdecCurrent == 'no' && state.hasFirstFrame ? '软解' : ''));

    final desktopControls = KonataDesktopWindowChromeScope.buildWindowControls(
      context,
      forceLightIcons: true,
    );
    final btnSize = isTouchPlatform ? 40.0 : 32.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 1000.0;
        final showCodecBadge = barWidth >= 520.0 && codecSpecLabel.isNotEmpty;
        final showHwdecBadge =
            barWidth >= 700.0 &&
            hwdecLabel.isNotEmpty &&
            (!isTouchPlatform || hwActive);

        return KonataGlassCapsule(
          radius: KonataTheme.radiusPill,
          showShadow: true,
          enableBackdropBlur: !isTouchPlatform || state.audioOnlyMode,
          solidBackdropColor: p.isDark
              ? KonataPlaybackTokens.osdSurfaceDark
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            children: [
              if (onCollapseToMini != null)
                KonataCapsuleIconButton(
                  key: const ValueKey('video_collapse_button'),
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: '悬浮小窗',
                  color: fg,
                  size: 22,
                  fixedSize: btnSize,
                  padding: EdgeInsets.zero,
                  onTap: onCollapseToMini,
                ),
              KonataCapsuleIconButton(
                key: const ValueKey('video_back_button'),
                icon: onCollapseToMini != null
                    ? Icons.close_rounded
                    : Icons.arrow_back_rounded,
                tooltip: onCollapseToMini != null ? '关闭视频' : '返回',
                color: fg,
                size: onCollapseToMini != null ? 19 : 21,
                fixedSize: btnSize,
                padding: EdgeInsets.zero,
                onTap: onBack,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: KonataDesktopWindowChromeScope.wrapDragToMove(
                  context,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (resBadge.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        KonataSpecBadge(label: resBadge, darkOverlay: true),
                      ],
                      if (showCodecBadge) ...[
                        const SizedBox(width: 6),
                        KonataSpecBadge(
                          label: codecSpecLabel,
                          darkOverlay: true,
                        ),
                      ],
                      if (showHwdecBadge) ...[
                        const SizedBox(width: 6),
                        KonataSpecBadge(label: hwdecLabel, darkOverlay: true),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              KonataCapsuleIconButton(
                key: const ValueKey('video_mini_mode_button'),
                icon: Icons.picture_in_picture_alt_rounded,
                tooltip: isTouchPlatform ? '悬浮小窗' : '桌面小窗',
                color: fg,
                size: 18,
                fixedSize: btnSize,
                padding: EdgeInsets.zero,
                onTap: onEnterMini,
              ),
              KonataCapsuleIconButton(
                key: const ValueKey('video_audio_only_button'),
                icon: Icons.headphones_rounded,
                tooltip: state.audioOnlyMode ? '恢复画面' : '纯音频模式',
                color: fg,
                highlighted: state.audioOnlyMode,
                highlightColor: p.accent,
                size: 18,
                fixedSize: btnSize,
                padding: EdgeInsets.zero,
                onTap: onToggleAudioOnly,
              ),
              KonataCapsuleIconButton(
                key: const ValueKey('video_probe_toggle_button'),
                icon: Icons.analytics_outlined,
                tooltip: '详细信息',
                color: fg,
                highlighted: state.probeOverlayVisible,
                highlightColor: p.accent,
                size: 18,
                fixedSize: btnSize,
                padding: EdgeInsets.zero,
                onTap: onToggleProbe,
              ),
              if (hasExternalRelay)
                KonataCapsuleIconButton(
                  key: const ValueKey('video_external_relay_button'),
                  icon: Icons.open_in_new_rounded,
                  tooltip: '外部播放器',
                  color: fg,
                  size: 18,
                  fixedSize: btnSize,
                  padding: EdgeInsets.zero,
                  onTap: onLaunchExternal,
                ),
              KonataCapsuleIconButton(
                key: const ValueKey('video_top_video_sheet_button'),
                icon: Icons.tune_rounded,
                tooltip: '画面设置',
                color: fg,
                size: 18,
                fixedSize: btnSize,
                padding: EdgeInsets.zero,
                onTap: onOpenVideoSettings,
              ),
              if (desktopControls != null) ...[
                const SizedBox(width: 6),
                desktopControls,
              ],
            ],
          ),
        );
      },
    );
  }
}

class _TransientNoticePill extends StatelessWidget {
  const _TransientNoticePill({required this.notice});

  final VideoTransientNotice notice;

  @override
  Widget build(BuildContext context) {
    final bgColor = notice.isError
        ? const Color(0xD87A1D24)
        : KonataPlaybackTokens.osdSurfaceDark;
    return IgnorePointer(
      child: Container(
        key: const ValueKey('video_transient_notice_pill'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: KonataPlaybackTokens.osdBorderLight,
            width: 1,
          ),
        ),
        child: Text(
          notice.message,
          style: const TextStyle(
            color: KonataPlaybackTokens.osdTextPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
