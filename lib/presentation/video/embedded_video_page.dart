import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/unified_playback_coordinator.dart';
import '../../application/playback/video_playback_controller.dart';
import '../../application/providers/diagnostics_providers.dart';
import '../../composition/platform_composition.dart';
import '../../domain/playback/playback_formatters.dart';
import '../../domain/playback/video_aspect_mode.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/players/embedded_mpv_session.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_glass_capsule.dart';
import '../widgets/design_system/konata_glass_menu.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_stage_morph_frame.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'video_cutout_symmetry.dart';
import 'video_hardware_surface.dart';
import 'video_probe_overlay.dart';
import 'video_side_sheet.dart';
import 'video_touch_gesture_layer.dart';
import '../theme/konata_theme.dart';

part 'embedded_video_overlays.dart';

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
        transitionDuration: KonataTheme.motionSnap,
        reverseTransitionDuration: KonataTheme.motionSnap,
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

class _EmbeddedVideoPageState extends ConsumerState<EmbeddedVideoPage>
    with WidgetsBindingObserver {
  final FocusNode _focusNode = FocusNode(debugLabel: 'embedded_video_focus');
  final GlobalKey _stageRectKey = GlobalKey();

  bool _hudVisible = true;
  bool _instantHudHide = false;
  bool _screenLocked = false;
  bool _lockButtonPeek = false;
  bool? _lastAndroidSystemBarsHidden;
  bool? _lastHudProgressActive;
  Timer? _idleTimer;
  Timer? _lockPeekTimer;
  Timer? _portraitRotationWaitTimer;
  bool _portraitRotationWaitExpired = false;

  final ValueNotifier<({String text, IconData icon, bool centered})?>
      _statusCueNotifier = ValueNotifier(null);
  Timer? _cornerBadgeTimer;

  int _externalVolumePulse = 0;

  Timer? _rightHoldTimer;
  bool _rightHoldBoostActivated = false;
  DateTime? _lastLeftRepeatSeekAt;

  VideoSideSheetTab _sideSheetTab = VideoSideSheetTab.episodes;
  bool _exiting = false;
  bool _volumePopupActive = false;
  VideoPlaybackController? _cachedController;
  DiagnosticsLogStore? _logStore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cachedController = ref.read(videoPlaybackProvider(widget.request).notifier);
    _logStore = ref.read(diagnosticsLogStoreProvider);
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
  void didUpdateWidget(covariant EmbeddedVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) {
      _cachedController = ref.read(
        videoPlaybackProvider(widget.request).notifier,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idleTimer?.cancel();
    _lockPeekTimer?.cancel();
    _portraitRotationWaitTimer?.cancel();
    _cornerBadgeTimer?.cancel();
    _cancelRightHoldSpeedBoost(deferNotify: true);
    _statusCueNotifier.dispose();
    if (_lastHudProgressActive == false) {
      final ctrl = _cachedController;
      if (ctrl != null && ctrl.mounted) {
        Future.microtask(() {
          if (!ctrl.mounted) return;
          try {
            ctrl.setHudProgressActive(true);
          } catch (e) {
            _logStore?.record('VIDEO', '视频页销毁后恢复进度订阅失败：$e');
          }
        });
      }
    }
    if (KonataAdaptiveTokens.isAndroid && widget.onCloseSession == null) {
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

  void _syncHudProgressSubscription(bool active) {
    if (_lastHudProgressActive == active) return;
    _lastHudProgressActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctrl = _cachedController;
      if (ctrl == null || !ctrl.mounted) return;
      try {
        ctrl.setHudProgressActive(active);
      } catch (e) {
        _logStore?.record('VIDEO', '同步视频 HUD 进度订阅状态失败：$e');
      }
    });
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

  void _flashCornerStatus(
    String text,
    IconData icon, {
    bool centered = false,
  }) {
    _cornerBadgeTimer?.cancel();
    _statusCueNotifier.value = (text: text, icon: icon, centered: centered);
    _cornerBadgeTimer = Timer(
      KonataPlaybackTokens.pauseBadgeDisplayDuration,
      () {
        if (mounted) {
          _statusCueNotifier.value = null;
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
    if (widget.onCloseSession == null &&
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

  void _collapseOrExit({double releaseVelocityPxPerSec = 0.0}) {
    if (widget.onCollapseToMini != null) {
      ref.read(stageMorphReleaseVelocityProvider.notifier).state =
          releaseVelocityPxPerSec;
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
    final res = await controller.relayToDesktopPlayer();
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _cancelRightHoldSpeedBoost();
    }
  }

  /// 在松键、窗口失焦或应用切后台时立即撤回右方向键 2.0x 临时倍速并恢复按住前的常驻倍速。
  void _cancelRightHoldSpeedBoost({bool deferNotify = false}) {
    _rightHoldTimer?.cancel();
    _rightHoldTimer = null;
    if (!_rightHoldBoostActivated) return;
    _rightHoldBoostActivated = false;
    final ctrl = _cachedController;
    if (ctrl == null || !ctrl.mounted) return;
    void cancelNow() {
      if (!ctrl.mounted) return;
      try {
        ctrl.endSpeedBoost();
      } catch (e) {
        _logStore?.record('VIDEO', '撤回长按临时倍速失败：$e');
      }
    }
    if (deferNotify) {
      Future.microtask(cancelNow);
    } else {
      cancelNow();
    }
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
        _rightHoldTimer = Timer(KonataPlaybackTokens.arrowRightHoldDelay, () {
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
        _rightHoldTimer = null;
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

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (event is KeyDownEvent) {
        _lastLeftRepeatSeekAt = DateTime.now();
        if (shift) {
          controller.seekRelative(-85.0);
          _flashCornerStatus('快退 85 秒', Icons.fast_rewind_rounded);
        } else {
          controller.seekRelative(-5.0);
          _flashCornerStatus('-5 秒', Icons.replay_5_rounded);
        }
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) {
        final now = DateTime.now();
        final last = _lastLeftRepeatSeekAt;
        if (last == null ||
            now.difference(last) >=
                KonataPlaybackTokens.arrowLeftRepeatThrottle) {
          _lastLeftRepeatSeekAt = now;
          if (shift) {
            controller.seekRelative(-85.0);
            _flashCornerStatus('快退 85 秒', Icons.fast_rewind_rounded);
          } else {
            controller.seekRelative(-5.0);
            _flashCornerStatus('-5 秒', Icons.replay_5_rounded);
          }
        }
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _lastLeftRepeatSeekAt = null;
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
        centered: true,
      );
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyS) {
      final mode = shift
          ? ScreenshotCaptureMode.withSubtitles
          : ScreenshotCaptureMode.pureVideo;
      unawaited(() async {
        final res = await controller.captureScreenshot(mode: mode);
        if (mounted && res == null) {
          showKonataToast(context, '截图未能生成，请稍后再试', isError: true);
        }
      }());
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
    ref.listen<VideoTransientNotice?>(
      videoPlaybackProvider(widget.request).select((s) => s.transientNotice),
      (prev, next) {
        if (next == null || next.seq == prev?.seq || !mounted) return;
        showKonataToast(
          context,
          next.message,
          isError: next.isError,
          duration: next.duration,
        );
      },
    );

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
          aspectMode: s.aspectMode,
          probeOverlayVisible: s.probeOverlayVisible,
          sideSheetOpen: s.sideSheetOpen,
          probeStats: s.probeStats,
          chapters: s.chapters,
          activeSkipWindow: s.activeSkipWindow,
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
      _syncHudProgressSubscription(false);
      return ColoredBox(
        key: const ValueKey('video_pip_pure_stage'),
        color: isAndroid && !snap.audioOnlyMode
            ? Colors.transparent
            : KonataPlaybackTokens.cinemaPureBlack,
        child: SizedBox.expand(child: videoSurface),
      );
    }

    final isTablet =
        isAndroid && size.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final displayFeatures = MediaQuery.displayFeaturesOf(context);
    final hideAndroidBars = isAndroid && !snap.audioOnlyMode;

    // 进入视频播放稳定隐藏系统状态栏与手势栏，杜绝因旋转首帧反复显隐造成顶栏跳变与双影
    _syncAndroidSystemBars(hideAndroidBars);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportStageSourceRect();
    });

    final isPortraitViewport = size.width < size.height;
    final needsRotationWait =
        isAndroid &&
        !snap.audioOnlyMode &&
        !widget.inPipMode &&
        !isPipDimensions &&
        isPortraitViewport;
    if (!needsRotationWait) {
      _portraitRotationWaitTimer?.cancel();
      _portraitRotationWaitTimer = null;
    } else if (!_portraitRotationWaitExpired &&
        _portraitRotationWaitTimer == null) {
      _portraitRotationWaitTimer = Timer(
        KonataPlaybackTokens.portraitRotationFallbackTimeout,
        () {
          _portraitRotationWaitTimer = null;
          if (!mounted || _portraitRotationWaitExpired) return;
          setState(() => _portraitRotationWaitExpired = true);
        },
      );
    }
    final awaitingLandscapeRotation =
        needsRotationWait && !_portraitRotationWaitExpired;
    final showHud =
        !awaitingLandscapeRotation &&
        !_screenLocked &&
        (_hudVisible || snap.sideSheetOpen || _volumePopupActive);
    _syncHudProgressSubscription(showHud || snap.probeOverlayVisible);
    final hudDuration = _instantHudHide
        ? Duration.zero
        : KonataPlaybackTokens.hudFadeDuration;
    final epTitle = controller.currentEpisodeTitle;

    // 裁切铺满 / 拉伸填满模式下突破挖孔对称黑边约束，令画面真正全屏边到边铺满（与 Windows 一致）。
    final fillFullViewport =
        snap.aspectMode == VideoAspectMode.cover ||
        snap.aspectMode == VideoAspectMode.stretch;
    final symmetricCutoutPadding =
        (isAndroid && !snap.audioOnlyMode && !fillFullViewport)
        ? VideoCutoutSymmetry.resolveSymmetricCutoutPadding(
            viewportSize: size,
            viewPadding: viewPadding,
            displayFeatures: displayFeatures,
            systemBarsHidden: hideAndroidBars,
          )
        : EdgeInsets.zero;

    final stageStack = KeyedSubtree(
      key: _stageRectKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 纯黑基座 + 挖孔对称黑边避让 + 硬件视频纹理（鼠标滚轮调音热区）
          Positioned.fill(
            child: ColoredBox(
              color: KonataPlaybackTokens.cinemaPureBlack,
              child: Padding(
                key: const ValueKey('video_symmetric_cutout_frame'),
                padding: symmetricCutoutPadding,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerSignal: (event) => _handleVideoSurfacePointerSignal(
                    event,
                    controller: controller,
                  ),
                  child: videoSurface,
                ),
              ),
            ),
          ),

          // 2. 统一触控手势与屏幕锁定防误触层
          Positioned.fill(
            child: VideoTouchGestureLayer(
              screenLocked: _screenLocked,
              showLockButton: _screenLocked ? _lockButtonPeek : showHud,
              gesturesBlocked: snap.sideSheetOpen,
              currentPositionReader: () => ref
                  .read(videoPlaybackProvider(widget.request).notifier)
                  .currentPositionSeconds,
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
                  centered: true,
                );
              },
              onSeekRelative: controller.seekRelative,
              onSeekAbsolute: controller.seekAbsolute,
              onBrightnessChanged: controller.setWindowBrightness,
              onVolumeChanged: controller.setVolume,
              onStartSpeedBoost: controller.startSpeedBoost,
              onEndSpeedBoost: controller.endSpeedBoost,
              onCollapseDragEnd: widget.onCollapseToMini != null
                  ? (vel) => _collapseOrExit(releaseVelocityPxPerSec: vel)
                  : null,
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
                showExternalButton:
                    KonataAdaptiveTokens.isWindows &&
                    controller.errorAllowsExternalRelay,
                onRetry: () => unawaited(controller.retryCurrentEpisode()),
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

          // 5. 视频视口居中暂停提示与右上角倍速/跳转微缩角标（独立叶子订阅，不触发整页重建）
          if (!_screenLocked)
            Positioned.fill(
              child: Padding(
                padding: symmetricCutoutPadding,
                child: _VideoStatusCueOverlayLeaf(
                  cueListenable: _statusCueNotifier,
                  isSpeedBoostActive: snap.isSpeedBoostActive,
                ),
              ),
            ),

          // 6. 右下角智能跳过 OP/ED 胶囊
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

          // 8. 顶栏与底部控制坞（旋转过渡与锁屏时彻底不挂载，确保全局仅存在唯一顶栏胶囊）
          if (!awaitingLandscapeRotation) ...[
            Positioned(
              top: isTablet
                  ? math.max(
                      math.max(safe.top, symmetricCutoutPadding.top),
                      KonataAdaptiveTokens.tabletTopSafeMin,
                    )
                  : (isAndroid
                        ? math.max(
                            math.max(safe.top, symmetricCutoutPadding.top),
                            12.0,
                          )
                        : 12.0),
              left: isAndroid
                  ? math.max(
                      math.max(safe.left, symmetricCutoutPadding.left),
                      14.0,
                    )
                  : 16.0,
              right: isAndroid
                  ? math.max(
                      math.max(safe.right, symmetricCutoutPadding.right),
                      14.0,
                    )
                  : 16.0,
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
              left: isAndroid
                  ? math.max(
                      math.max(safe.left, symmetricCutoutPadding.left),
                      16.0,
                    )
                  : 20.0,
              right: isAndroid
                  ? math.max(
                      math.max(safe.right, symmetricCutoutPadding.right),
                      16.0,
                    )
                  : 20.0,
              bottom: isAndroid
                  ? math.max(
                      math.max(safe.bottom, symmetricCutoutPadding.bottom),
                      14.0,
                    )
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
                          audioOnlyMode: snap.audioOnlyMode,
                          isPlaying: snap.isPlaying,
                          speed: snap.speed,
                          volume: snap.volume,
                          isMuted: snap.isMuted,
                          isFullscreen: snap.isFullscreen,
                          sideSheetOpen: snap.sideSheetOpen,
                          chapters: snap.chapters,
                          externalVolumePulse: _externalVolumePulse,
                          onTogglePlayPause: () {
                            final willPlay = !snap.isPlaying;
                            controller.togglePlayPause();
                            _flashCornerStatus(
                              willPlay ? '继续播放' : '已暂停',
                              willPlay
                                  ? Icons.play_arrow_rounded
                                  : Icons.pause_rounded,
                              centered: true,
                            );
                          },
                          onOpenSideSheet: _openSideSheet,
                          onShowScreenshotMenu: (btnCtx) =>
                              _showScreenshotModeMenu(btnCtx, controller),
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
        onFocusChange: (hasFocus) {
          if (!hasFocus) {
            _cancelRightHoldSpeedBoost();
          }
        },
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: isAndroid && !snap.audioOnlyMode
              ? Colors.transparent
              : KonataPlaybackTokens.cinemaPureBlack,
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
}
