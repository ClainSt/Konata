import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
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
import 'video_probe_overlay.dart';
import 'video_touch_gesture_layer.dart';

/// 全屏内置视频播放舞台页面。
///
/// 接收宿主平台按需注入的底层画面渲染回调（如桌面共享纹理或移动平台硬件表面）；
/// 当未注入渲染回调时自动优雅渲染无头测试占位舞台，支持零原生插件环境测试与预览。
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

  void _handleExit(VideoPlaybackController controller) {
    if (widget.onClose != null) {
      widget.onClose!();
      return;
    }
    unawaited(() async {
      await controller.closeSession();
      if (!mounted) return;
      await controller.env.navigator?.pop();
    }());
  }

  @override
  Widget build(BuildContext context) {
    final controller = _resolveController();
    final sidePanels = _resolveSidePanels();

    return ColoredBox(
      key: const ValueKey('embedded_video_page'),
      color: KonataPlaybackTokens.cinemaPureBlack,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final state = controller.state;
          final mq = MediaQuery.maybeOf(context);
          final viewportSize = mq?.size ?? Size.zero;
          final viewPadding = mq?.viewPadding ?? EdgeInsets.zero;
          final displayFeatures = mq?.displayFeatures ?? const [];
          final cutoutPadding = VideoCutoutSymmetry.resolveSymmetricCutoutPadding(
            viewportSize: viewportSize,
            viewPadding: viewPadding,
            displayFeatures: displayFeatures,
            systemBarsHidden: state.isFullscreen,
          );
          final isTouchPlatform =
              controller.env.platform != KonataPlatform.windows;

          return Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: cutoutPadding,
                child: _buildVideoStage(context, state),
              ),
              if (state.windowBrightness < 0.99 && !state.audioOnlyMode)
                IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: (1.0 - state.windowBrightness.clamp(0.15, 1.0)) *
                          0.65,
                    ),
                  ),
                ),
              Positioned.fill(
                child: VideoTouchGestureLayer(
                  isPlaying: state.isPlaying,
                  durationSeconds: state.durationSeconds,
                  positionListenable: controller.positionNotifier,
                  currentVolume: state.volume,
                  currentBrightness: state.windowBrightness,
                  enableTouchGestures: isTouchPlatform,
                  onSingleTap: () {
                    final overlayState = _overlaysKey.currentState;
                    if (overlayState != null) {
                      (overlayState as dynamic).toggleHudVisibility();
                    }
                  },
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
              Positioned.fill(
                child: EmbeddedVideoOverlays(
                  key: _overlaysKey,
                  controller: controller,
                  playerSidePanels: sidePanels,
                  autoHideDelay: widget.autoHideDelay,
                  isTouchPlatform: isTouchPlatform,
                  onExitRequested: () => _handleExit(controller),
                  onEnterMiniRequested: widget.onEnterMiniPlayer ??
                      () => unawaited(controller.enterMiniPlayer()),
                ),
              ),
              if (state.probeOverlayVisible)
                Positioned(
                  left: 16 + cutoutPadding.left,
                  top: 68,
                  child: VideoProbeOverlay(
                    stats: state.probeStats,
                    renderBackend: state.renderBackend,
                    adapterName: state.adapterName,
                    positionSeconds:
                        controller.positionNotifier.value.inMilliseconds / 1000.0,
                    durationSeconds: state.durationSeconds,
                    hwdecForcedReason: state.hwdecForcedSoftwareReason,
                  ),
                ),
              if (state.errorMessage != null && state.errorMessage!.isNotEmpty)
                Center(
                  child: _FatalStageCard(
                    message: state.errorMessage!,
                    onRetry: () => unawaited(controller.initialize(widget.request)),
                    onClose: () => _handleExit(controller),
                  ),
                ),
              if (state.isMiniPlayer && widget.onEnterMiniPlayer == null)
                VideoFloatingMiniPlayer(
                  controller: controller,
                  videoSurfaceBuilder: widget.videoSurfaceBuilder,
                  viewportSize: viewportSize,
                  onExpand: () =>
                      unawaited(controller.exitMiniPlayerToStage()),
                  onClose: () => _handleExit(controller),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVideoStage(BuildContext context, VideoPlaybackState state) {
    if (state.audioOnlyMode) {
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
              '纯音频省电模式 · 画面输出已关闭',
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

    final customSurface = widget.videoSurfaceBuilder;
    if (customSurface != null) {
      return customSurface(context, state.textureId);
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
            border: Border.all(
              color: const Color(0x18FFFFFF),
              width: 1,
            ),
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
