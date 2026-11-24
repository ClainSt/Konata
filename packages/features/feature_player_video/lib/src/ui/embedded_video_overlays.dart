import 'dart:async';

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

/// 内置全屏视频播放舞台的顶底交互浮层与快捷键、滚轮调音协调组件。
///
/// 在播放暂停或三秒无操作隐藏控制栏时立即取消定时倒计时，并卸除底部高频进度监听组件树，
/// 确保视频全屏稳态观看期间界面层零后台定时器与零进度重绘开销。
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

  @override
  State<EmbeddedVideoOverlays> createState() => _EmbeddedVideoOverlaysState();
}

class _EmbeddedVideoOverlaysState extends State<EmbeddedVideoOverlays> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'embedded_video_hud');

  Timer? _autoHideTimer;
  Timer? _wheelOsdTimer;
  bool _hudVisible = true;
  bool _volumePopupActive = false;
  bool _wheelOsdVisible = false;
  int _volumeRevealPulse = 0;
  VideoSideSheetTab? _activeSheetTab;
  bool _lastIsPlaying = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _lastIsPlaying = widget.controller.state.isPlaying;
    widget.controller.setHudVisible(_hudVisible);
    _syncAutoHideTimer();
  }

  @override
  void didUpdateWidget(covariant EmbeddedVideoOverlays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastIsPlaying = widget.controller.state.isPlaying;
      widget.controller.setHudVisible(_hudVisible);
      _syncAutoHideTimer();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    _wheelOsdTimer?.cancel();
    _wheelOsdTimer = null;
    _focusNode.dispose();
    super.dispose();
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

    if (!_hudVisible ||
        !widget.controller.state.isPlaying ||
        _activeSheetTab != null ||
        _volumePopupActive) {
      return;
    }

    _autoHideTimer = Timer(widget.autoHideDelay, () {
      if (!mounted) return;
      if (widget.controller.state.isPlaying &&
          _activeSheetTab == null &&
          !_volumePopupActive) {
        _setHudVisible(false);
      }
    });
  }

  void _setHudVisible(bool visible) {
    if (_hudVisible == visible) return;
    setState(() => _hudVisible = visible);
    widget.controller.setHudVisible(visible);
    if (!visible) {
      _autoHideTimer?.cancel();
      _autoHideTimer = null;
    } else {
      _syncAutoHideTimer();
    }
  }

  void _revealHud() {
    if (!_hudVisible) {
      _setHudVisible(true);
    } else {
      _syncAutoHideTimer();
    }
  }

  /// 供外层触控手势层切换控制层显示或隐藏状态。
  void toggleHudVisibility() {
    _setHudVisible(!_hudVisible);
  }

  void _openSheet(VideoSideSheetTab tab) {
    setState(() {
      _activeSheetTab = tab;
      _hudVisible = true;
    });
    widget.controller.setHudVisible(true);
    widget.controller.setSideSheetOpen(true);
    _syncAutoHideTimer();
  }

  void _closeSheet() {
    if (_activeSheetTab == null) return;
    setState(() => _activeSheetTab = null);
    widget.controller.setSideSheetOpen(false);
    _syncAutoHideTimer();
  }

  void _handleMouseWheelScroll(double scrollDeltaY) {
    if (scrollDeltaY == 0) return;
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

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.space) {
        unawaited(widget.controller.togglePlayPause());
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        unawaited(widget.controller.seekRelativeSeconds(-5));
        _revealHud();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        unawaited(widget.controller.seekRelativeSeconds(5));
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
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: widget.isTouchPlatform
            ? null
            : (_) => _revealHud(),
        onPointerDown: (_) => _revealHud(),
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent) {
            _handleMouseWheelScroll(signal.scrollDelta.dy);
          }
        },
        child: ListenableBuilder(
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
            final headerTitle = workTitle.isEmpty
                ? epTitle
                : '$workTitle · $epTitle';

            return Stack(
              fit: StackFit.expand,
              children: [
                if (_hudVisible) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _TopBar(
                      key: const ValueKey('embedded_video_top_bar'),
                      title: headerTitle,
                      state: state,
                      onBack: widget.onExitRequested,
                      onEnterMini: () {
                        _revealHud();
                        if (widget.onEnterMiniRequested != null) {
                          widget.onEnterMiniRequested!();
                        } else {
                          unawaited(widget.controller.enterMiniPlayer());
                        }
                      },
                      onToggleProbe: () {
                        _revealHud();
                        widget.controller.setProbeOverlayVisible(
                          !state.probeOverlayVisible,
                        );
                      },
                      onScreenshot: () {
                        _revealHud();
                        unawaited(widget.controller.captureScreenshot());
                      },
                      onLaunchExternal: () {
                        _revealHud();
                        unawaited(
                          widget.controller.launchExternalVideoPlayer(),
                        );
                      },
                      hasExternalRelay:
                          widget.controller.env.desktopRelayGateway != null &&
                          widget.controller.env.platform ==
                              KonataPlatform.windows,
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: KonataPlaybackTokens.capsuleBottomOffset,
                    child: Center(
                      child: VideoPlaybackCapsule(
                        key: const ValueKey('embedded_video_bottom_capsule'),
                        isPlaying: state.isPlaying,
                        hasPreviousEpisode:
                            widget.controller.hasPreviousEpisode,
                        hasNextEpisode: widget.controller.hasNextEpisode,
                        speed: state.speed,
                        volume: state.volume,
                        isMuted: state.isMuted,
                        isFullscreen: state.isFullscreen,
                        positionListenable: widget.controller.positionNotifier,
                        durationListenable: widget.controller.durationNotifier,
                        bufferedListenable: widget.controller.bufferedNotifier,
                        chapters: state.chapters,
                        thumbnailService: widget.controller.thumbnailService,
                        volumeRevealPulse: _volumeRevealPulse,
                        onUserInteraction: _revealHud,
                        onVolumePopupActiveChanged: (active) {
                          if (_volumePopupActive != active) {
                            setState(() => _volumePopupActive = active);
                            _syncAutoHideTimer();
                          }
                        },
                        onTogglePlayPause: () =>
                            unawaited(widget.controller.togglePlayPause()),
                        onSeek: (sec) =>
                            unawaited(widget.controller.seekToSeconds(sec)),
                        onPreviousEpisode: () => unawaited(
                          widget.controller.playPreviousEpisode(),
                        ),
                        onNextEpisode: () =>
                            unawaited(widget.controller.playNextEpisode()),
                        onSelectSpeed: widget.controller.setPlaybackSpeed,
                        onVolumeChanged: widget.controller.setVolume,
                        onToggleMute: widget.controller.toggleMute,
                        onOpenEpisodesSheet: () =>
                            _openSheet(VideoSideSheetTab.episodes),
                        onOpenSubtitlesSheet: () =>
                            _openSheet(VideoSideSheetTab.subtitles),
                        onOpenAudioSheet: () =>
                            _openSheet(VideoSideSheetTab.audio),
                        onOpenVideoSheet: () =>
                            _openSheet(VideoSideSheetTab.video),
                        onToggleFullscreen: () =>
                            unawaited(widget.controller.toggleFullscreen()),
                      ),
                    ),
                  ),
                ],
                if (state.activeSkipWindow != null)
                  Positioned(
                    right: KonataPlaybackTokens.skipPillRightOffset,
                    bottom: KonataPlaybackTokens.skipPillBottomOffset,
                    child: KonataPillButton.primary(
                      key: const ValueKey('video_skip_chapter_pill'),
                      icon: Icons.fast_forward_rounded,
                      label: state.activeSkipWindow!.label,
                      onPressed: () =>
                          unawaited(widget.controller.triggerActiveSkipWindow()),
                    ),
                  ),
                if (_wheelOsdVisible)
                  Positioned(
                    top: KonataPlaybackTokens.wheelVolumeOsdTopOffset,
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
                if (_activeSheetTab != null)
                  VideoSideSheet(
                    controller: widget.controller,
                    initialTab: _activeSheetTab!,
                    playerSidePanels: widget.playerSidePanels,
                    onClose: _closeSheet,
                  ),
              ],
            );
          },
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
    required this.onBack,
    required this.onEnterMini,
    required this.onToggleProbe,
    required this.onScreenshot,
    required this.onLaunchExternal,
    required this.hasExternalRelay,
  });

  final String title;
  final VideoPlaybackState state;
  final VoidCallback onBack;
  final VoidCallback onEnterMini;
  final VoidCallback onToggleProbe;
  final VoidCallback onScreenshot;
  final VoidCallback onLaunchExternal;
  final bool hasExternalRelay;

  @override
  Widget build(BuildContext context) {
    const fg = KonataPlaybackTokens.osdTextPrimary;
    final res = (state.probeStats.videoWidth != null &&
            state.probeStats.videoHeight != null)
        ? '${state.probeStats.videoHeight}p'
        : (state.currentVariant.resolution ?? '');
    final codec = state.probeStats.videoCodec.isNotEmpty
        ? state.probeStats.videoCodec.toUpperCase()
        : (state.currentVariant.videoCodec?.toUpperCase() ?? '');
    final specLabel = [
      if (codec.isNotEmpty) codec,
      if ((state.currentVariant.bitDepth ?? '').isNotEmpty)
        state.currentVariant.bitDepth!,
      if (res.isNotEmpty) res,
    ].join(' · ');

    final desktopControls = KonataDesktopWindowChromeScope.buildWindowControls(
      context,
      forceLightIcons: true,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0xA8000000),
            Color(0x36000000),
            Color(0x00000000),
          ],
        ),
      ),
      child: Row(
        children: [
          KonataCapsuleIconButton(
            key: const ValueKey('video_back_button'),
            icon: Icons.arrow_back_rounded,
            tooltip: '返回',
            color: fg,
            onTap: onBack,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: KonataDesktopWindowChromeScope.wrapDragToMove(
              context,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fg,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          if (specLabel.isNotEmpty) ...[
            const SizedBox(width: 8),
            KonataSpecBadge(label: specLabel, darkOverlay: true),
          ],
          const SizedBox(width: 8),
          if (hasExternalRelay)
            KonataCapsuleIconButton(
              key: const ValueKey('video_external_relay_button'),
              icon: Icons.open_in_new_rounded,
              tooltip: '外部播放器打开',
              color: fg,
              onTap: onLaunchExternal,
            ),
          KonataCapsuleIconButton(
            key: const ValueKey('video_screenshot_button'),
            icon: Icons.camera_alt_outlined,
            tooltip: '原画截图',
            color: fg,
            onTap: onScreenshot,
          ),
          KonataCapsuleIconButton(
            key: const ValueKey('video_probe_toggle_button'),
            icon: Icons.analytics_outlined,
            tooltip: '音画技术探针',
            color: fg,
            highlighted: state.probeOverlayVisible,
            onTap: onToggleProbe,
          ),
          KonataCapsuleIconButton(
            key: const ValueKey('video_mini_mode_button'),
            icon: Icons.picture_in_picture_alt_rounded,
            tooltip: '悬浮小窗播放',
            color: fg,
            onTap: onEnterMini,
          ),
          if (desktopControls != null) ...[
            const SizedBox(width: 8),
            desktopControls,
          ],
        ],
      ),
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
