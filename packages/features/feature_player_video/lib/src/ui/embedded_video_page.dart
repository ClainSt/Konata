import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/video_session_models.dart';
import '../providers.dart';
import '../state/video_playback_controller.dart';
import '../state/video_playback_state.dart';
import 'embedded_video_overlays.dart';
import 'video_cutout_symmetry.dart';
import 'video_floating_mini_player.dart';
import 'video_hardware_surface.dart';
import 'video_probe_overlay.dart';
import 'video_touch_gesture_layer.dart';

/// 全屏内置视频播放舞台页面（Windows / 平板 / 手机三端一律采用纯横屏舞台）。
///
/// Android 手机与平板进入本页时自动锁定横屏（`landscapeLeft` / `landscapeRight`），
/// 退出或销毁时自动恢复原有屏幕方向；未注入渲染回调时自动优雅渲染无头测试占位舞台。
class EmbeddedVideoPage extends ConsumerStatefulWidget {
  /// 创建全屏视频播放舞台页面。
  const EmbeddedVideoPage({
    super.key,
    required this.request,
    this.controller,
    this.videoSurfaceBuilder,
    this.playerSidePanels,
    this.onClose,
    this.onEnterMiniPlayer,
    this.autoHideDelay = KonataPlaybackTokens.cursorIdleFadeDelay,
  });

  /// 起播作品与分集定位请求。
  final VideoLaunchRequest request;

  /// 可选显式注入的视频播放控制器（未传时从状态容器按需创建绑定）。
  final VideoPlaybackController? controller;

  /// 可选宿主平台视频画面构建器（接收当前上下文与原生共享纹理编号）。
  final Widget Function(BuildContext context, int? textureId)?
  videoSurfaceBuilder;

  /// 可选外部扩展播放器侧栏贡献列表（未传时自动读取依赖容器中注册的贡献列表）。
  final List<PlayerSidePanelContribution>? playerSidePanels;

  /// 退出全屏视频舞台回调（未传时默认弹出当前路由或关闭会话）。
  final VoidCallback? onClose;

  /// 切换入悬浮小窗模式回调（未传时默认调用控制器内部小窗切换状态）。
  final VoidCallback? onEnterMiniPlayer;

  /// 交互浮层无操作自动隐藏延时（默认 3 秒）。
  final Duration autoHideDelay;

  @override
  ConsumerState<EmbeddedVideoPage> createState() => _EmbeddedVideoPageState();
}

class _EmbeddedVideoPageState extends ConsumerState<EmbeddedVideoPage> {
  final GlobalKey _overlaysKey = GlobalKey();

  bool _screenLocked = false;
  bool _lockButtonPeek = false;
  bool _hudVisible = true;
  Timer? _lockPeekTimer;

  bool _lockedAndroidLandscape = false;
  VideoPlaybackController? _landscapeLockedController;

  VideoPlaybackController _resolveController() {
    final explicit = widget.controller;
    if (explicit != null) return explicit;
    return ref.watch(videoPlaybackControllerProvider(widget.request));
  }

  List<PlayerSidePanelContribution> _resolveSidePanels() {
    if (widget.playerSidePanels != null) {
      return widget.playerSidePanels!;
    }
    if (widget.controller != null) {
      return const <PlayerSidePanelContribution>[];
    }
    return ref.watch(featurePlayerVideoDependenciesProvider).playerSidePanels;
  }

  bool _isAndroidDevice(VideoPlaybackController controller) {
    return controller.env.platform == KonataPlatform.androidPhone ||
        controller.env.platform == KonataPlatform.androidTablet ||
        KonataAdaptiveTokens.isAndroid;
  }

  void _ensureAndroidLandscapeLock(VideoPlaybackController controller) {
    if (!_isAndroidDevice(controller)) return;
    if (_lockedAndroidLandscape &&
        identical(_landscapeLockedController, controller)) {
      return;
    }
    _lockedAndroidLandscape = true;
    _landscapeLockedController = controller;
    unawaited(controller.env.hostWindow.setPreferredLandscape(true));
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
  }

  void _restoreAndroidOrientation() {
    if (!_lockedAndroidLandscape) return;
    _lockedAndroidLandscape = false;
    final ctrl = _landscapeLockedController;
    _landscapeLockedController = null;
    if (ctrl != null) {
      unawaited(ctrl.env.hostWindow.setPreferredLandscape(false));
    }
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
    );
  }

  @override
  void initState() {
    super.initState();
    final explicit = widget.controller;
    if (explicit != null) {
      _ensureAndroidLandscapeLock(explicit);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.controller == null) {
      _ensureAndroidLandscapeLock(_resolveController());
    }
  }

  @override
  void didUpdateWidget(covariant EmbeddedVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller &&
        widget.controller != null) {
      _ensureAndroidLandscapeLock(widget.controller!);
    }
  }

  @override
  void dispose() {
    _lockPeekTimer?.cancel();
    _lockPeekTimer = null;
    _restoreAndroidOrientation();
    super.dispose();
  }

  void _toggleScreenLock() {
    _lockPeekTimer?.cancel();
    final nextLocked = !_screenLocked;
    setState(() {
      _screenLocked = nextLocked;
      _lockButtonPeek = nextLocked;
    });
    if (nextLocked) {
      _lockPeekTimer = Timer(widget.autoHideDelay, () {
        if (mounted) {
          setState(() => _lockButtonPeek = false);
        }
      });
    }
  }

  void _handleCanvasSingleTap() {
    if (_screenLocked) {
      _lockPeekTimer?.cancel();
      final nextPeek = !_lockButtonPeek;
      setState(() => _lockButtonPeek = nextPeek);
      if (nextPeek) {
        _lockPeekTimer = Timer(widget.autoHideDelay, () {
          if (mounted) {
            setState(() => _lockButtonPeek = false);
          }
        });
      }
      return;
    }
    final overlayState = _overlaysKey.currentState;
    if (overlayState != null) {
      (overlayState as dynamic).toggleHudVisibility();
    }
  }

  void _handleExit(VideoPlaybackController controller) {
    _restoreAndroidOrientation();
    if (widget.onClose != null) {
      widget.onClose!();
      return;
    }
    unawaited(() async {
      try {
        await controller.closeSession();
      } catch (_) {
        if (!controller.state.isClosing) return;
      }
      if (!mounted) return;
      await controller.env.navigator?.pop();
    }());
  }

  @override
  Widget build(BuildContext context) {
    final controller = _resolveController();
    if (!controller.state.isMiniPlayer) {
      _ensureAndroidLandscapeLock(controller);
    }
    final sidePanels = _resolveSidePanels();

    return ColoredBox(
      key: const ValueKey('embedded_video_page'),
      color: KonataPlaybackTokens.cinemaPureBlack,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final state = controller.state;
          if (state.isMiniPlayer) {
            if (state.miniMode == VideoMiniMode.desktop) {
              return VideoFloatingMiniPlayer(
                key: const ValueKey('video_desktop_mini_stage'),
                controller: controller,
                desktopWindow: true,
                videoSurfaceBuilder: widget.videoSurfaceBuilder,
                onExpand: () => unawaited(controller.exitMiniPlayerToStage()),
                onClose: () => _handleExit(controller),
              );
            }
            if (widget.onEnterMiniPlayer != null) {
              return const SizedBox.expand();
            }
            return Stack(
              children: [
                VideoFloatingMiniPlayer(
                  controller: controller,
                  videoSurfaceBuilder: widget.videoSurfaceBuilder,
                  viewportSize: MediaQuery.sizeOf(context),
                  onExpand: () => unawaited(controller.exitMiniPlayerToStage()),
                  onClose: () => _handleExit(controller),
                ),
              ],
            );
          }
          final mq = MediaQuery.maybeOf(context);
          final viewportSize = mq?.size ?? Size.zero;
          final viewPadding = mq?.viewPadding ?? EdgeInsets.zero;
          final displayFeatures = mq?.displayFeatures ?? const [];
          final cutoutPadding =
              VideoCutoutSymmetry.resolveSymmetricCutoutPadding(
                viewportSize: viewportSize,
                viewPadding: viewPadding,
                displayFeatures: displayFeatures,
                systemBarsHidden: state.isFullscreen,
              );
          final isTouchPlatform = _isAndroidDevice(controller);
          // 原生回调与窗口尺寸变化可能乱序；极小视口先安全隐藏控制层。
          final compactSystemSurface =
              isTouchPlatform &&
              (controller.systemPipActive ||
                  (viewportSize.width > 0 &&
                      (viewportSize.width < 320 || viewportSize.height < 180)));

          return MouseRegion(
            hitTestBehavior: HitTestBehavior.translucent,
            onHover: isTouchPlatform
                ? null
                : (_) {
                    final overlayState = _overlaysKey.currentState;
                    if (overlayState != null) {
                      (overlayState as dynamic).notifyPointerHover();
                    }
                  },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent) {
                  final overlayState = _overlaysKey.currentState;
                  if (overlayState != null) {
                    (overlayState as dynamic).handlePointerWheel(
                      signal.scrollDelta.dy,
                    );
                  }
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: cutoutPadding,
                    child: _buildVideoStage(
                      context,
                      state,
                      controller,
                      compactSystemSurface: compactSystemSurface,
                    ),
                  ),
                  if (state.windowBrightness < 0.99 && !state.audioOnlyMode)
                    IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha:
                              (1.0 - state.windowBrightness.clamp(0.15, 1.0)) *
                              0.65,
                        ),
                      ),
                    ),
                  if (!compactSystemSurface)
                    Positioned.fill(
                      child: VideoTouchGestureLayer(
                        isPlaying: state.isPlaying,
                        durationSeconds: state.durationSeconds,
                        positionListenable: controller.positionNotifier,
                        currentVolume: state.volume,
                        currentBrightness: state.windowBrightness,
                        enableTouchGestures: isTouchPlatform,
                        screenLocked: _screenLocked,
                        showLockButton: _screenLocked
                            ? _lockButtonPeek
                            : _hudVisible,
                        onToggleScreenLock: _toggleScreenLock,
                        onSingleTap: _handleCanvasSingleTap,
                        onDoubleTapCenter: () =>
                            unawaited(controller.togglePlayPause()),
                        onDoubleTapLeftSeek: () =>
                            unawaited(controller.seekRelativeSeconds(-10)),
                        onDoubleTapRightSeek: () =>
                            unawaited(controller.seekRelativeSeconds(10)),
                        onLongPressBoostStart: () =>
                            controller.setTemporarySpeedBoost(true),
                        onLongPressBoostEnd: () =>
                            controller.setTemporarySpeedBoost(false),
                        onSeekCommitted: (sec) =>
                            unawaited(controller.seekToSeconds(sec)),
                        onVolumeChanged: controller.setVolume,
                        onBrightnessChanged: controller.setWindowBrightness,
                      ),
                    ),
                  if (!compactSystemSurface)
                    Positioned.fill(
                      child: EmbeddedVideoOverlays(
                        key: _overlaysKey,
                        controller: controller,
                        playerSidePanels: sidePanels,
                        autoHideDelay: widget.autoHideDelay,
                        isTouchPlatform: isTouchPlatform,
                        screenLocked: _screenLocked,
                        onHudVisibilityChanged: (visible) {
                          if (_hudVisible != visible && mounted) {
                            setState(() => _hudVisible = visible);
                          }
                        },
                        onExitRequested: () => _handleExit(controller),
                        onEnterMiniRequested:
                            widget.onEnterMiniPlayer ??
                            () => unawaited(
                              controller.enterMiniPlayer(
                                desktopAlwaysOnTop: false,
                              ),
                            ),
                      ),
                    ),
                  if (!compactSystemSurface &&
                      state.probeOverlayVisible &&
                      !_screenLocked)
                    Positioned(
                      left: 16 + cutoutPadding.left,
                      right: 16 + cutoutPadding.right,
                      top: 68,
                      bottom: 16 + cutoutPadding.bottom,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: VideoProbeOverlay(
                          stats: state.probeStats,
                          renderBackend: state.renderBackend,
                          adapterName: state.adapterName,
                          positionSeconds:
                              controller.positionNotifier.value.inMilliseconds /
                              1000.0,
                          durationSeconds: state.durationSeconds,
                          hwdecForcedReason: state.hwdecForcedSoftwareReason,
                        ),
                      ),
                    ),
                  if (!compactSystemSurface &&
                      state.errorMessage != null &&
                      state.errorMessage!.isNotEmpty)
                    Center(
                      child: _FatalStageCard(
                        message: state.errorMessage!,
                        onRetry: () =>
                            unawaited(controller.initialize(widget.request)),
                        onClose: () => _handleExit(controller),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildVideoStage(
    BuildContext context,
    VideoPlaybackState state,
    VideoPlaybackController controller, {
    required bool compactSystemSurface,
  }) {
    if (state.audioOnlyMode) {
      if (compactSystemSurface) {
        return const ColoredBox(color: KonataPlaybackTokens.cinemaPureBlack);
      }
      return const Center(
        key: ValueKey('embedded_video_audio_only_stage'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.headphones_rounded,
              size: 48,
              color: KonataPlaybackTokens.osdTextSecondary,
            ),
            SizedBox(height: 10),
            Text(
              '纯音频模式 · 画面输出已关闭',
              style: TextStyle(
                color: KonataPlaybackTokens.osdTextSecondary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    if (widget.videoSurfaceBuilder != null ||
        VideoHardwareSurface.hasUnderlay(controller, state) ||
        (state.textureId != null && state.textureId! >= 0)) {
      return VideoHardwareSurface(
        controller: controller,
        state: state,
        textureBuilder: widget.videoSurfaceBuilder,
        fallback: const ColoredBox(color: KonataPlaybackTokens.cinemaPureBlack),
      );
    }
    if (compactSystemSurface) {
      return const ColoredBox(color: KonataPlaybackTokens.cinemaPureBlack);
    }
    return Center(
      key: const ValueKey('embedded_video_placeholder_stage'),
      child: AspectRatio(
        aspectRatio: switch (state.aspectMode) {
          VideoAspectMode.ratio4x3 => 4.0 / 3.0,
          _ => 16.0 / 9.0,
        },
        child: Container(
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.cinemaPureBlack,
            border: Border.all(color: const Color(0x18FFFFFF), width: 1),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.smart_display_outlined,
                size: 42,
                color: KonataPlaybackTokens.osdTextSecondary,
              ),
              const SizedBox(height: 8),
              Text(
                state.isInitializing
                    ? '正在初始化视频解码舞台…'
                    : (state.currentWork?.title.isNotEmpty == true
                          ? state.currentWork!.title
                          : '视频播放舞台就绪'),
                style: const TextStyle(
                  color: KonataPlaybackTokens.osdTextSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FatalStageCard extends StatelessWidget {
  const _FatalStageCard({
    required this.message,
    required this.onRetry,
    required this.onClose,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('embedded_video_error_card'),
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: KonataPlaybackTokens.popoverSurface(p),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 32, color: p.danger),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.textPrimary, fontSize: 13.5),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              KonataPillButton.ghost(
                compact: true,
                label: '返回',
                onPressed: onClose,
              ),
              const SizedBox(width: 8),
              KonataPillButton.primary(
                compact: true,
                label: '重试装载',
                onPressed: onRetry,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
