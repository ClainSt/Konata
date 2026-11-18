import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../application/playback/unified_playback_coordinator.dart';
import '../../application/playback/video_playback_controller.dart';
import '../../domain/playback/playback_formatters.dart';
import '../shell/window_controls.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_glass_capsule.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_osd_stroked_text.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'video_hardware_surface.dart';
import 'video_probe_overlay.dart';
import 'video_side_sheet.dart';
import 'video_touch_gesture_layer.dart';

/// 内置高保真 `libmpv` 视频播放器沉浸页面。
///
/// 架构特性：
/// - 顶层绝不订阅 `positionSeconds`；播放无操作满 3 秒后平滑隐藏 OSD，并彻底停止进度时间 UI 订阅（零重建重绘）；
/// - 支持全局保活宿主挂载（收起为底部播放胶囊圆角预览不断流、不重建解码会话）与路由独立挂载双模式；
/// - 完整覆盖桌面端、Android 平板（`>=44dp` 顶部避让、`<=640dp` 底坞、右滑抽屉）与手机横屏（强制横屏 + 隐藏系统栏 + 不贴边悬浮胶囊）；
/// - Android 画中画（PiP）纯净态隐藏全部胶囊、抽屉与 `SafeArea` 留白，仅保留全幅硬件纹理与原生字幕。
class EmbeddedVideoPage extends ConsumerStatefulWidget {
  /// 创建内置视频播放页。
  const EmbeddedVideoPage({
    super.key,
    required this.request,
    this.sharedVideoSurface,
    this.onCollapseToMini,
    this.onCloseSession,
    this.inPipMode = false,
  });

  /// 视频启动请求描述。
  final VideoLaunchRequest request;

  /// 全局宿主注入的共享硬件视频表面（用于展开/收起无缝复用）。
  final Widget? sharedVideoSurface;

  /// 收起为常驻迷你播放胶囊圆角预览回调（非空时左上角返回与系统返回优先收起不断流）。
  final VoidCallback? onCollapseToMini;

  /// 彻底关闭全局视频会话回调。
  final Future<void> Function()? onCloseSession;

  /// 当前是否处于 Android 系统画中画纯净小窗态。
  final bool inPipMode;

  /// 通过全局保活视频会话启动或以柔和渐变路由推入内置高保真视频页。
  static Future<void> push(
    NavigatorState navigator,
    VideoLaunchRequest request, {
    WidgetRef? ref,
  }) async {
    if (ref != null) {
      await ref.read(activeVideoSessionProvider.notifier).openVideo(request);
      return;
    }
    await navigator.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 160),
        reverseTransitionDuration: const Duration(milliseconds: 140),
        pageBuilder: (context, animation, secondaryAnimation) =>
            EmbeddedVideoPage(request: request),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  ConsumerState<EmbeddedVideoPage> createState() => _EmbeddedVideoPageState();
}

class _EmbeddedVideoPageState extends ConsumerState<EmbeddedVideoPage> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'embedded_video_focus');
  final GlobalKey _stageRectKey = GlobalKey();

  bool _hudVisible = true;
  bool _instantHudHide = false;
  bool _screenLocked = false;
  bool _lockButtonPeek = false;
  bool? _lastAndroidSystemBarsHidden;
  Timer? _idleTimer;
  Timer? _lockPeekTimer;

  bool _cornerBadgeVisible = false;
  String _cornerBadgeText = '';
  IconData _cornerBadgeIcon = Icons.pause_rounded;
  Timer? _cornerBadgeTimer;

  int _externalVolumePulse = 0;

  Timer? _rightHoldTimer;
  bool _rightHoldBoostActivated = false;

  VideoSideSheetTab _sideSheetTab = VideoSideSheetTab.episodes;
  bool _exiting = false;
  bool _volumePopupActive = false;

  @override
  void initState() {
    super.initState();
    _scheduleIdleHide();
    if (KonataAdaptiveTokens.isAndroid && !widget.inPipMode) {
      final audioOnly =
          ref.read(videoPlaybackProvider(widget.request)).audioOnlyMode;
      if (!audioOnly) {
        unawaited(
          AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
            landscape: true,
            hideSystemBars: true,
          ),
        );
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        _reportStageSourceRect();
      }
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _lockPeekTimer?.cancel();
    _cornerBadgeTimer?.cancel();
    _rightHoldTimer?.cancel();
    if (KonataAdaptiveTokens.isAndroid && widget.onCollapseToMini == null) {
      unawaited(
        AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: false,
          hideSystemBars: false,
        ),
      );
    } else if (_lastAndroidSystemBarsHidden == true) {
      unawaited(AndroidPlaybackWindowBridge.setSystemBarsHidden(false));
    }
    _focusNode.dispose();
    super.dispose();
  }

  void _reportStageSourceRect() {
    if (!KonataAdaptiveTokens.isAndroid || !mounted || widget.inPipMode) return;
    final ctx = _stageRectKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final topLeft = box.localToGlobal(Offset.zero);
    final size = box.size;
    if (size.width <= 0 || size.height <= 0) return;
    final rect = (
      left: (topLeft.dx * dpr).round(),
      top: (topLeft.dy * dpr).round(),
      right: ((topLeft.dx + size.width) * dpr).round(),
      bottom: ((topLeft.dy + size.height) * dpr).round(),
    );
    ref.read(activeVideoSessionProvider.notifier).updateSourceRect(rect);
  }

  void _syncAndroidSystemBars(bool hideBars) {
    if (!KonataAdaptiveTokens.isAndroid) return;
    if (_lastAndroidSystemBarsHidden == hideBars) return;
    _lastAndroidSystemBarsHidden = hideBars;
    unawaited(AndroidPlaybackWindowBridge.setSystemBarsHidden(hideBars));
  }

  void _scheduleIdleHide() {
    _idleTimer?.cancel();
    if (_volumePopupActive) return;
    _idleTimer = Timer(KonataPlaybackTokens.cursorIdleFadeDelay, () {
      if (!mounted) return;
      final state = ref.read(videoPlaybackProvider(widget.request));
      if (state.sideSheetOpen || _volumePopupActive) return;
      setState(() {
        _instantHudHide = false;
        _hudVisible = false;
      });
    });
  }

  void _onUserActivity() {
    if (_screenLocked) return;
    if (!_hudVisible || _instantHudHide) {
      setState(() {
        _instantHudHide = false;
        _hudVisible = true;
      });
    }
    _scheduleIdleHide();
  }

  void _onStageSingleTap() {
    _focusNode.requestFocus();
    final state = ref.read(videoPlaybackProvider(widget.request));
    if (state.sideSheetOpen) {
      _closeSideSheet();
      return;
    }
    if (_screenLocked) {
      _lockPeekTimer?.cancel();
      setState(() => _lockButtonPeek = !_lockButtonPeek);
      if (_lockButtonPeek) {
        _lockPeekTimer = Timer(KonataPlaybackTokens.cursorIdleFadeDelay, () {
          if (mounted) setState(() => _lockButtonPeek = false);
        });
      }
      return;
    }
    if (KonataAdaptiveTokens.isAndroid) {
      setState(() {
        _instantHudHide = false;
        _hudVisible = !_hudVisible;
      });
      if (_hudVisible) {
        _scheduleIdleHide();
      } else {
        _idleTimer?.cancel();
      }
      return;
    }
    _onUserActivity();
  }

  void _toggleScreenLock() {
    _lockPeekTimer?.cancel();
    final nextLocked = !_screenLocked;
    unawaited(AndroidPlaybackWindowBridge.setOrientationLocked(nextLocked));
    setState(() {
      _screenLocked = nextLocked;
      _lockButtonPeek = nextLocked;
      _hudVisible = !nextLocked;
      _instantHudHide = false;
    });
    if (nextLocked) {
      _idleTimer?.cancel();
      _lockPeekTimer = Timer(KonataPlaybackTokens.cursorIdleFadeDelay, () {
        if (mounted) setState(() => _lockButtonPeek = false);
      });
    } else {
      _scheduleIdleHide();
    }
  }

  void _hideHudImmediatelyOnExit() {
    if (KonataAdaptiveTokens.isAndroid) return;
    _idleTimer?.cancel();
    final state = ref.read(videoPlaybackProvider(widget.request));
    if (state.sideSheetOpen || _volumePopupActive) return;
    if (_hudVisible) {
      setState(() {
        _instantHudHide = true;
        _hudVisible = false;
      });
    }
  }

  void _handleVolumePopupActiveChanged(bool active) {
    if (_volumePopupActive == active) return;
    setState(() {
      _volumePopupActive = active;
      if (active) {
        _instantHudHide = false;
        _hudVisible = true;
      }
    });
    if (active) {
      _idleTimer?.cancel();
    } else {
      _scheduleIdleHide();
    }
  }

  void _flashCornerStatus(String text, IconData icon) {
    _cornerBadgeTimer?.cancel();
    setState(() {
      _cornerBadgeText = text;
      _cornerBadgeIcon = icon;
      _cornerBadgeVisible = true;
    });
    _cornerBadgeTimer = Timer(
      KonataPlaybackTokens.pauseBadgeDisplayDuration,
      () {
        if (mounted) {
          setState(() => _cornerBadgeVisible = false);
        }
      },
    );
  }

  void _triggerVolumeCapsuleFeedback() {
    setState(() {
      _instantHudHide = false;
      _hudVisible = true;
      _externalVolumePulse++;
    });
    _scheduleIdleHide();
  }

  void _handleVideoSurfacePointerSignal(
    PointerSignalEvent event, {
    required VideoPlaybackController controller,
  }) {
    if (event is! PointerScrollEvent || _screenLocked) return;
    final state = ref.read(videoPlaybackProvider(widget.request));
    if (state.sideSheetOpen) return;
    if (widget.onCollapseToMini == null &&
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    final step = dy < 0
        ? KonataPlaybackTokens.wheelVolumeStep
        : -KonataPlaybackTokens.wheelVolumeStep;
    final base = state.isMuted && step > 0 ? 0.0 : state.volume;
    final nextVol = (base + step).clamp(0.0, 100.0);
    controller.setVolume(nextVol);
    _triggerVolumeCapsuleFeedback();
  }

  void _collapseOrExit() {
    if (widget.onCollapseToMini != null) {
      widget.onCollapseToMini!();
      return;
    }
    unawaited(_closeSessionAndExit());
  }

  Future<void> _closeSessionAndExit() async {
    if (_exiting) return;
    _exiting = true;
    if (widget.onCloseSession != null) {
      await widget.onCloseSession!();
      return;
    }
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    await controller.closeAndRelease();
    if (mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  Future<void> _relayToExternal() async {
    if (_exiting || !KonataAdaptiveTokens.isWindows) return;
    _exiting = true;
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    final res = await controller.relayToExternalPlayer();
    if (widget.onCloseSession != null) {
      await widget.onCloseSession!();
    } else if (mounted) {
      final nav = Navigator.of(context);
      nav.pop();
      showKonataToast(nav.context, res.message, isError: !res.launched);
      return;
    }
    if (mounted) {
      showKonataToast(context, res.message, isError: !res.launched);
    }
  }

  void _openSideSheet(VideoSideSheetTab tab) {
    if (_screenLocked) return;
    setState(() {
      _sideSheetTab = tab;
      _hudVisible = true;
    });
    _idleTimer?.cancel();
    ref
        .read(videoPlaybackProvider(widget.request).notifier)
        .setSideSheetOpen(true);
  }

  void _closeSideSheet() {
    ref
        .read(videoPlaybackProvider(widget.request).notifier)
        .setSideSheetOpen(false);
    _scheduleIdleHide();
    _focusNode.requestFocus();
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (_screenLocked) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    final state = ref.read(videoPlaybackProvider(widget.request));
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (key == LogicalKeyboardKey.arrowRight) {
      if (shift && event is KeyDownEvent) {
        controller.seekRelative(85.0);
        _flashCornerStatus('快进 85 秒', Icons.fast_forward_rounded);
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent) {
        _rightHoldBoostActivated = false;
        _rightHoldTimer?.cancel();
        _rightHoldTimer = Timer(const Duration(milliseconds: 260), () {
          if (!mounted) return;
          _rightHoldBoostActivated = true;
          controller.startSpeedBoost();
        });
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) {
        if (!_rightHoldBoostActivated) {
          _rightHoldTimer?.cancel();
          _rightHoldBoostActivated = true;
          controller.startSpeedBoost();
        }
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _rightHoldTimer?.cancel();
        if (_rightHoldBoostActivated) {
          _rightHoldBoostActivated = false;
          controller.endSpeedBoost();
        } else {
          controller.seekRelative(5.0);
          _flashCornerStatus('+5 秒', Icons.forward_5_rounded);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.space) {
      final willPlay = !state.isPlaying;
      controller.togglePlayPause();
      _flashCornerStatus(
        willPlay ? '继续播放' : '已暂停',
        willPlay ? Icons.play_arrow_rounded : Icons.pause_rounded,
      );
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyS) {
      unawaited(() async {
        final f = await controller.captureCleanScreenshot();
        if (mounted && f == null) {
          showKonataToast(context, '截图未能生成，请稍后再试', isError: true);
        }
      }());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (shift) {
        controller.seekRelative(-85.0);
        _flashCornerStatus('快退 85 秒', Icons.fast_rewind_rounded);
      } else {
        controller.seekRelative(-5.0);
        _flashCornerStatus('-5 秒', Icons.replay_5_rounded);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      controller.adjustVolume(KonataPlaybackTokens.wheelVolumeStep);
      _triggerVolumeCapsuleFeedback();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      controller.adjustVolume(-KonataPlaybackTokens.wheelVolumeStep);
      _triggerVolumeCapsuleFeedback();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyM) {
      controller.toggleMute();
      _flashCornerStatus(
        state.isMuted ? '恢复声音' : '已静音',
        state.isMuted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
      );
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.comma) {
      controller.stepFrameBackward();
      _flashCornerStatus('逐帧后退', Icons.skip_previous_rounded);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.period) {
      controller.stepFrameForward();
      _flashCornerStatus('逐帧前进', Icons.skip_next_rounded);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.pageUp) {
      controller.previousChapterOrEpisode();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.pageDown) {
      controller.nextChapterOrEpisode();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyF ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      unawaited(controller.toggleFullscreen());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.tab) {
      controller.toggleProbeOverlay();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (state.sideSheetOpen) {
        _closeSideSheet();
      } else if (state.isFullscreen) {
        unawaited(controller.toggleFullscreen());
      } else {
        _collapseOrExit();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // 严格隔离高频进度：顶层绝不订阅 positionSeconds 或 durationSeconds！
    final snap = ref.watch(
      videoPlaybackProvider(widget.request).select(
        (s) => (
          isInitializing: s.isInitializing,
          isBuffering: s.isBuffering,
          hasFirstFrame: s.hasFirstFrame,
          isPlaying: s.isPlaying,
          renderBackend: s.renderBackend,
          adapterName: s.adapterName,
          speed: s.speed,
          isSpeedBoostActive: s.isSpeedBoostActive,
          volume: s.volume,
          isMuted: s.isMuted,
          isFullscreen: s.isFullscreen,
          audioOnlyMode: s.audioOnlyMode,
          probeOverlayVisible: s.probeOverlayVisible,
          sideSheetOpen: s.sideSheetOpen,
          probeStats: s.probeStats,
          chapters: s.chapters,
          activeSkipWindow: s.activeSkipWindow,
          transientBanner: s.transientBanner,
          errorMessage: s.errorMessage,
          episodeId: s.currentEpisode.id,
          workId: s.currentWork?.id,
        ),
      ),
    );
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);

    final videoSurface =
        widget.sharedVideoSurface ??
        KonataHardwareVideoSurface(request: widget.request);

    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final isPipDimensions = isAndroid && size.height < 260 && size.width < 520;

    // 画中画纯净态：隐藏所有 Flutter 胶囊、抽屉与 SafeArea 留白，挂起进度监听，仅全幅纹理与字幕
    if (widget.inPipMode || isPipDimensions) {
      return ColoredBox(
        key: const ValueKey('video_pip_pure_stage'),
        color: KonataPlaybackTokens.cinemaPureBlack,
        child: SizedBox.expand(child: videoSurface),
      );
    }

    final isTablet =
        isAndroid && size.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint;
    final isPhoneLandscape = isAndroid && !isTablet && size.width > size.height;

    // 进入视频全幅播放隐藏系统状态栏与手势栏，确保视口完整铺满
    _syncAndroidSystemBars(isAndroid && (isPhoneLandscape || snap.isFullscreen));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportStageSourceRect();
    });

    final isWidgetTest = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('TestWidgetsFlutterBinding');
    final awaitingLandscapeRotation =
        isAndroid &&
        !isWidgetTest &&
        !snap.audioOnlyMode &&
        !widget.inPipMode &&
        !isPipDimensions &&
        size.width < size.height;
    final showHud =
        !awaitingLandscapeRotation &&
        !_screenLocked &&
        (_hudVisible || snap.sideSheetOpen || _volumePopupActive);
    final hudDuration = _instantHudHide
        ? Duration.zero
        : KonataPlaybackTokens.hudFadeDuration;
    final epTitle = controller.currentEpisodeTitle;

    final stageStack = KeyedSubtree(
      key: _stageRectKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 纯黑基座 + 硬件视频纹理（鼠标滚轮调音热区）
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: (event) =>
                  _handleVideoSurfacePointerSignal(event, controller: controller),
              child: videoSurface,
            ),
          ),

          // 2. 统一触控手势与屏幕锁定防误触层
          Positioned.fill(
            child: VideoTouchGestureLayer(
              screenLocked: _screenLocked,
              showLockButton: _screenLocked ? _lockButtonPeek : showHud,
              gesturesBlocked: snap.sideSheetOpen,
              currentPositionReader: () =>
                  ref.read(videoPlaybackProvider(widget.request)).positionSeconds,
              durationReader: () =>
                  ref.read(videoPlaybackProvider(widget.request)).durationSeconds,
              brightnessReader: () => ref
                  .read(videoPlaybackProvider(widget.request))
                  .windowBrightness,
              volumeReader: () =>
                  ref.read(videoPlaybackProvider(widget.request)).volume,
              onToggleScreenLock: _toggleScreenLock,
              onSingleTap: _onStageSingleTap,
              onDesktopDoubleTapFullscreen: () =>
                  unawaited(controller.toggleFullscreen()),
              onTogglePlayPause: () {
                final willPlay = !snap.isPlaying;
                controller.togglePlayPause();
                _flashCornerStatus(
                  willPlay ? '继续播放' : '已暂停',
                  willPlay ? Icons.play_arrow_rounded : Icons.pause_rounded,
                );
              },
              onSeekRelative: controller.seekRelative,
              onSeekAbsolute: controller.seekAbsolute,
              onBrightnessChanged: controller.setWindowBrightness,
              onVolumeChanged: controller.setVolume,
              onStartSpeedBoost: controller.startSpeedBoost,
              onEndSpeedBoost: controller.endSpeedBoost,
            ),
          ),

          // 3. 加载或出错兜底提示
          if ((snap.isInitializing || snap.isBuffering) &&
              snap.errorMessage == null &&
              !snap.audioOnlyMode)
            const Center(
              child: IgnorePointer(
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: KonataPlaybackTokens.osdAccent,
                  ),
                ),
              ),
            ),

          if (snap.errorMessage != null)
            Center(
              child: _ErrorFallbackCard(
                message: snap.errorMessage!,
                showExternalButton: KonataAdaptiveTokens.isWindows,
                onRelayExternal: _relayToExternal,
                onBack: _closeSessionAndExit,
              ),
            ),

          // 4. 左上角技术探针
          if (snap.probeOverlayVisible && !_screenLocked)
            Positioned(
              left: 20,
              top: 72,
              child: VideoProbeOverlay(
                stats: snap.probeStats,
                adapterName: snap.adapterName,
                renderBackend: snap.renderBackend,
              ),
            ),

          // 5. 倍速快进 / 暂停微缩角标
          if ((_cornerBadgeVisible || snap.isSpeedBoostActive) &&
              !_screenLocked)
            Positioned(
              top: 72,
              right: 20,
              child: IgnorePointer(
                child: _MiniCornerStatusPill(
                  icon: snap.isSpeedBoostActive
                      ? Icons.fast_forward_rounded
                      : _cornerBadgeIcon,
                  label: snap.isSpeedBoostActive
                      ? '2.0x 倍速快进中'
                      : _cornerBadgeText,
                ),
              ),
            ),

          // 6. 自动连播 / 硬解回退 / 截图保存顶部描边纯文字提示
          if (snap.transientBanner != null && !_screenLocked)
            Positioned(
              top: 76,
              left: 24,
              right: 24,
              child: IgnorePointer(
                child: Center(
                  child: KonataOsdStrokedText(
                    snap.transientBanner!,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),

          // 7. 右下角智能跳过 OP/ED 胶囊
          if (snap.activeSkipWindow != null && !_screenLocked)
            Positioned(
              bottom: KonataPlaybackTokens.skipPillBottomOffset,
              right: KonataPlaybackTokens.skipPillRightOffset,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                child: _SkipChapterCapsule(
                  label: snap.activeSkipWindow!.label,
                  onTap: () => unawaited(
                    controller.executeSkipWindow(snap.activeSkipWindow!),
                  ),
                ),
              ),
            ),

          // 8. 顶栏与底部控制坞（锁屏时彻底屏蔽）
          Positioned(
            top: isTablet
                ? math.max(safe.top, KonataAdaptiveTokens.tabletTopSafeMin)
                : (isAndroid ? math.max(safe.top, 12.0) : 0.0),
            left: isAndroid ? math.max(safe.left, 14.0) : 0.0,
            right: isAndroid ? math.max(safe.right, 14.0) : 0.0,
            child: AnimatedOpacity(
              duration: hudDuration,
              opacity: showHud ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !showHud,
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.15,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    child: isAndroid
                        ? _buildAndroidFloatingTopCapsule(
                            snap: snap,
                            controller: controller,
                            epTitle: epTitle,
                          )
                        : _buildDesktopTopOverlayBar(
                            snap: snap,
                            controller: controller,
                            epTitle: epTitle,
                          ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: isAndroid ? math.max(safe.left, 16.0) : 20.0,
            right: isAndroid ? math.max(safe.right, 16.0) : 20.0,
            bottom: isAndroid
                ? math.max(safe.bottom, 14.0)
                : KonataPlaybackTokens.capsuleBottomOffset,
            child: AnimatedOpacity(
              duration: hudDuration,
              opacity: showHud ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !showHud,
                child: Center(
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.15,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      child: _VideoBottomHudLeaf(
                        request: widget.request,
                        subscribeProgress: showHud && !widget.inPipMode,
                        isTablet: isTablet,
                        isPlaying: snap.isPlaying,
                        speed: snap.speed,
                        volume: snap.volume,
                        isMuted: snap.isMuted,
                        isFullscreen: snap.isFullscreen,
                        sideSheetOpen: snap.sideSheetOpen,
                        chapters: snap.chapters,
                        externalVolumePulse: _externalVolumePulse,
                        onOpenSideSheet: _openSideSheet,
                        onVolumePopupActiveChanged:
                            _handleVolumePopupActiveChanged,
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_screenLocked) {
          _toggleScreenLock();
          return;
        }
        if (snap.sideSheetOpen) {
          _closeSideSheet();
          return;
        }
        if (isAndroid && snap.isFullscreen) {
          unawaited(controller.toggleFullscreen());
          return;
        }
        _collapseOrExit();
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: KonataPlaybackTokens.cinemaPureBlack,
          body: MouseRegion(
            cursor: showHud
                ? SystemMouseCursors.basic
                : SystemMouseCursors.none,
            onHover: isAndroid ? null : (_) => _onUserActivity(),
            onExit: isAndroid ? null : (_) => _hideHudImmediatelyOnExit(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                stageStack,

                // 右滑毛玻璃五标签侧栏（选集/章节/字幕/音轨/画面，开启期间不中断播放）
                if (snap.sideSheetOpen && !_screenLocked)
                  Positioned.fill(
                    child: VideoSideSheet(
                      request: widget.request,
                      initialTab: _sideSheetTab,
                      onClose: _closeSideSheet,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAndroidFloatingTopCapsule({
    required dynamic snap,
    required VideoPlaybackController controller,
    required String epTitle,
  }) {
    final p = context.palette;
    final stats = snap.probeStats;
    final resBadge = PlaybackFormatters.formatResolutionBadge(
      stats.videoWidth,
      stats.videoHeight,
    );
    final hwActive =
        stats.hwdecCurrent.isNotEmpty && stats.hwdecCurrent != 'no';

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrowTop = constraints.maxWidth < 540;
        return KonataGlassCapsule(
          key: const ValueKey('android_video_top_capsule'),
          radius: KonataAdaptiveTokens.capsuleRadius,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              KonataCapsuleIconButton(
                key: const ValueKey('video_collapse_button'),
                icon: widget.onCollapseToMini != null
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.arrow_back_rounded,
                tooltip: widget.onCollapseToMini != null ? '收起至小窗胶囊' : '返回',
                color: p.textPrimary,
                size: 24,
                fixedSize: KonataAdaptiveTokens.touchTarget,
                onTap: _collapseOrExit,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: EllipsisTextWithTooltip(
                        text: '${controller.activeWork.title} · $epTitle',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (resBadge.isNotEmpty && !narrowTop) ...[
                      const SizedBox(width: 8),
                      KonataSpecBadge(label: resBadge, darkOverlay: true),
                    ],
                    if (hwActive && !narrowTop) ...[
                      const SizedBox(width: 6),
                      KonataSpecBadge(
                        label: '硬解 (${stats.hwdecCurrent})',
                        darkOverlay: true,
                      ),
                    ],
                  ],
                ),
              ),
              if (!narrowTop) ...[
                KonataCapsuleIconButton(
                  key: const ValueKey('video_toggle_audio_only_button'),
                  icon: Icons.headphones_rounded,
                  tooltip: snap.audioOnlyMode ? '恢复视频画面' : '切换后台纯音频',
                  color: p.textPrimary,
                  highlighted: snap.audioOnlyMode,
                  size: 19,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: controller.toggleAudioOnlyMode,
                ),
                KonataCapsuleIconButton(
                  key: const ValueKey('video_enter_pip_button'),
                  icon: Icons.picture_in_picture_alt_rounded,
                  tooltip: '进入画中画',
                  color: p.textPrimary,
                  size: 19,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: () => unawaited(
                    ref
                        .read(activeVideoSessionProvider.notifier)
                        .enterPipManually(),
                  ),
                ),
              ],
              KonataCapsuleIconButton(
                key: const ValueKey('video_top_more_tune_button'),
                icon: Icons.tune_rounded,
                tooltip: '播控与画质设置',
                color: p.textPrimary,
                size: 20,
                fixedSize: KonataAdaptiveTokens.touchTarget,
                onTap: () => _openSideSheet(VideoSideSheetTab.video),
              ),
              if (widget.onCollapseToMini != null)
                KonataCapsuleIconButton(
                  key: const ValueKey('video_close_session_button'),
                  icon: Icons.close_rounded,
                  tooltip: '停止并关闭视频',
                  color: p.textPrimary,
                  size: 20,
                  fixedSize: KonataAdaptiveTokens.touchTarget,
                  onTap: () => unawaited(_closeSessionAndExit()),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopTopOverlayBar({
    required dynamic snap,
    required VideoPlaybackController controller,
    required String epTitle,
  }) {
    final p = context.palette;
    final isWindows = KonataAdaptiveTokens.isWindows;
    final stats = snap.probeStats;
    final resBadge = PlaybackFormatters.formatResolutionBadge(
      stats.videoWidth,
      stats.videoHeight,
    );
    final codecBadge = PlaybackFormatters.formatCodecShortLabel(
      stats.videoCodec,
    );
    final bitDepthBadge = PlaybackFormatters.formatVideoBitDepthLabel(
      stats.videoPixelFormat,
    );
    final hwActive =
        stats.hwdecCurrent.isNotEmpty && stats.hwdecCurrent != 'no';

    Widget bar = Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: p.isDark
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  KonataPlaybackTokens.cinemaPureBlack.withValues(alpha: 0.72),
                  KonataPlaybackTokens.cinemaPureBlack.withValues(alpha: 0.0),
                ],
              ),
            )
          : BoxDecoration(
              color: KonataPlaybackTokens.glassSurface(p),
              border: Border(
                bottom: BorderSide(color: KonataPlaybackTokens.glassBorder(p)),
              ),
            ),
      child: Row(
        children: [
          IconButton(
            tooltip: widget.onCollapseToMini != null
                ? '收起为小窗播放胶囊 (Esc)'
                : '返回作品详情 (Esc)',
            onPressed: _collapseOrExit,
            icon: Icon(
              widget.onCollapseToMini != null
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.arrow_back_rounded,
              color: p.textPrimary,
            ),
          ),
          if (widget.onCollapseToMini != null)
            IconButton(
              tooltip: '停止并关闭视频',
              onPressed: () => unawaited(_closeSessionAndExit()),
              icon: Icon(Icons.close_rounded, size: 20, color: p.textPrimary),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: EllipsisTextWithTooltip(
                    text: '${controller.activeWork.title} · $epTitle',
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                if (resBadge.isNotEmpty) ...[
                  KonataSpecBadge(label: resBadge, darkOverlay: true),
                  const SizedBox(width: 6),
                ],
                if (codecBadge.isNotEmpty) ...[
                  KonataSpecBadge(
                    label: bitDepthBadge.isNotEmpty
                        ? '$codecBadge · $bitDepthBadge'
                        : codecBadge,
                    darkOverlay: true,
                  ),
                  const SizedBox(width: 6),
                ],
                if (hwActive ||
                    snap.renderBackend == 'sw' ||
                    snap.hasFirstFrame)
                  KonataSpecBadge(
                    label: hwActive
                        ? '硬解 (${stats.hwdecCurrent})'
                        : (snap.renderBackend == 'sw' ? 'SW 兼容' : '软解'),
                    darkOverlay: true,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: snap.audioOnlyMode ? '恢复视频画面' : '切换后台纯音频',
            onPressed: controller.toggleAudioOnlyMode,
            icon: Icon(
              Icons.headphones_rounded,
              size: 19,
              color: snap.audioOnlyMode ? p.progressFill : p.textPrimary,
            ),
          ),
          IconButton(
            tooltip: '技术探针指标 (Tab)',
            onPressed: controller.toggleProbeOverlay,
            icon: Icon(
              Icons.analytics_outlined,
              size: 20,
              color: snap.probeOverlayVisible ? p.progressFill : p.textPrimary,
            ),
          ),
          if (isWindows)
            IconButton(
              tooltip: '切换外部播放器无缝接力续播',
              onPressed: _relayToExternal,
              icon: Icon(
                Icons.open_in_new_rounded,
                size: 19,
                color: p.textPrimary,
              ),
            ),
          IconButton(
            tooltip: '播控与画质设置',
            onPressed: () => _openSideSheet(VideoSideSheetTab.video),
            icon: Icon(Icons.tune_rounded, size: 20, color: p.textPrimary),
          ),
          if (isWindows && !snap.isFullscreen) ...[
            const SizedBox(width: 4),
            const WindowControls(),
          ],
        ],
      ),
    );
    if (!p.isDark) {
      bar = ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: bar,
        ),
      );
    }

    if (isWindows && !snap.isFullscreen) {
      bar = DragToMoveArea(child: bar);
    }
    return bar;
  }
}

/// 底部播控胶囊进度叶子：当 `subscribeProgress == false`（OSD 3 秒隐藏或画中画态）时，彻底退订 `positionSeconds` 监听！
class _VideoBottomHudLeaf extends ConsumerWidget {
  const _VideoBottomHudLeaf({
    required this.request,
    required this.subscribeProgress,
    required this.isTablet,
    required this.isPlaying,
    required this.speed,
    required this.volume,
    required this.isMuted,
    required this.isFullscreen,
    required this.sideSheetOpen,
    required this.chapters,
    required this.externalVolumePulse,
    required this.onOpenSideSheet,
    required this.onVolumePopupActiveChanged,
  });

  final VideoLaunchRequest request;
  final bool subscribeProgress;
  final bool isTablet;
  final bool isPlaying;
  final double speed;
  final double volume;
  final bool isMuted;
  final bool isFullscreen;
  final bool sideSheetOpen;
  final List<dynamic> chapters;
  final int externalVolumePulse;
  final ValueChanged<VideoSideSheetTab> onOpenSideSheet;
  final ValueChanged<bool> onVolumePopupActiveChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final controller = ref.read(videoPlaybackProvider(request).notifier);
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final btnSize = isAndroid ? KonataAdaptiveTokens.touchTarget : null;

    // 关键门禁：OSD 隐藏期间停止订阅进度与时长，杜绝后台无谓 UI 重建与重绘！
    final timing = subscribeProgress
        ? ref.watch(
            videoPlaybackProvider(request).select(
              (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
            ),
          )
        : (
            pos: ref.read(videoPlaybackProvider(request)).positionSeconds,
            dur: ref.read(videoPlaybackProvider(request)).durationSeconds,
          );

    final canPrev = controller.hasPreviousEpisodeAny;
    final canNext = controller.hasNextEpisodeAny;
    final speedChanged = (speed - 1.0).abs() > 0.02;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final narrowAndroidHud = isAndroid && screenWidth < 680;
    final ultraNarrowAndroidHud = isAndroid && screenWidth < 400;

    return RepaintBoundary(
      child: KonataPlaybackCapsule(
        maxWidth: isTablet ? KonataAdaptiveTokens.tabletPlayerMaxWidth : null,
        title: null,
        positionSeconds: timing.pos,
        durationSeconds: timing.dur,
        isPlaying: isPlaying,
        chapters: chapters.cast(),
        onTogglePlayPause: controller.togglePlayPause,
        onSeek: controller.seekAbsolute,
        onPrevious: canPrev
            ? () => unawaited(controller.goToPreviousEpisode())
            : null,
        onNext: canNext ? () => unawaited(controller.goToNextEpisode()) : null,
        onToggleList: () => onOpenSideSheet(VideoSideSheetTab.episodes),
        isListActive: sideSheetOpen,
        listTooltip: '选集与章节列表',
        supportsThumbnailPreview: !isAndroid,
        previewRevisionListenable: controller.thumbnailRevisionListenable,
        previewThumbnailResolver: controller.resolveThumbnailPreview,
        onPreviewHoverSecondsChanged: controller.requestThumbnailPreview,
        rightSlot: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!narrowAndroidHud) ...[
              KonataCapsuleIconButton(
                icon: Icons.subtitles_outlined,
                tooltip: '字幕轨道',
                color: p.textPrimary,
                size: 18,
                fixedSize: btnSize,
                onTap: () => onOpenSideSheet(VideoSideSheetTab.subtitles),
              ),
              KonataCapsuleIconButton(
                icon: Icons.audiotrack_outlined,
                tooltip: '音轨切换',
                color: p.textPrimary,
                size: 18,
                fixedSize: btnSize,
                onTap: () => onOpenSideSheet(VideoSideSheetTab.audio),
              ),
            ] else
              KonataCapsuleIconButton(
                key: const ValueKey('video_bottom_secondary_sheet_button'),
                icon: Icons.tune_rounded,
                tooltip: '音轨与字幕设置',
                color: p.textPrimary,
                size: 18,
                fixedSize: btnSize,
                onTap: () => onOpenSideSheet(VideoSideSheetTab.audio),
              ),
            if (!isAndroid)
              KonataCapsuleIconButton(
                icon: Icons.camera_alt_outlined,
                tooltip: '纯净原画截图 (S)',
                color: p.textPrimary,
                size: 18,
                onTap: () => unawaited(controller.captureCleanScreenshot()),
              ),
            if (speedChanged && !isAndroid)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onOpenSideSheet(VideoSideSheetTab.video),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 4,
                    ),
                    child: Text(
                      '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}x',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: KonataPlaybackTokens.tabularNumbers,
                      ),
                    ),
                  ),
                ),
              ),
            if (!isAndroid)
              KonataVolumeControl(
                volume: (volume / 100.0).clamp(0.0, 1.0),
                isMuted: isMuted,
                onVolumeChanged: (v) => controller.setVolume(v * 100.0),
                onToggleMute: controller.toggleMute,
                allowPopover: subscribeProgress,
                externalRevealPulse: externalVolumePulse,
                onPopupActiveChanged: onVolumePopupActiveChanged,
              ),
            if (!ultraNarrowAndroidHud)
              KonataCapsuleIconButton(
                icon: isFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                tooltip: isFullscreen ? '退出全屏 (F / Esc)' : '全屏播放 (F / 双击)',
                color: p.textPrimary,
                size: 20,
                fixedSize: btnSize,
                onTap: () => unawaited(controller.toggleFullscreen()),
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniCornerStatusPill extends StatelessWidget {
  const _MiniCornerStatusPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(p),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: KonataPlaybackTokens.glassBorder(p)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: p.textPrimary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkipChapterCapsule extends StatelessWidget {
  const _SkipChapterCapsule({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Material(
          color: KonataPlaybackTokens.glassSurface(p),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: KonataPlaybackTokens.glassBorder(p)),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: KonataAdaptiveTokens.isAndroid
                    ? KonataAdaptiveTokens.touchTarget
                    : 0,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 9,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.fast_forward_rounded,
                      size: 16,
                      color: p.progressFill,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorFallbackCard extends StatelessWidget {
  const _ErrorFallbackCard({
    required this.message,
    required this.showExternalButton,
    required this.onRelayExternal,
    required this.onBack,
  });

  final String message;
  final bool showExternalButton;
  final VoidCallback onRelayExternal;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(p),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: KonataPlaybackTokens.glassBorder(p)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: p.danger),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textPrimary, fontSize: 13.5),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  KonataPillButton.secondary(label: '返回', onPressed: onBack),
                  if (showExternalButton)
                    KonataPillButton.primary(
                      label: '外部播放器打开',
                      icon: Icons.open_in_new_rounded,
                      onPressed: onRelayExternal,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
