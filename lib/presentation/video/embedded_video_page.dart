import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../application/playback/video_playback_controller.dart';
import '../../domain/playback/playback_formatters.dart';
import '../../infrastructure/players/android/android_video_surface_controller.dart';
import '../shell/window_controls.dart';
import '../theme/konata_playback_tokens.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import '../widgets/playback/konata_spec_badge.dart';
import '../widgets/playback/konata_volume_control.dart';
import 'video_probe_overlay.dart';
import 'video_side_sheet.dart';

/// 内置高保真 `libmpv` 视频播放器沉浸页面。
///
/// 严格视觉与交互约定：
/// - 底层铺设 [KonataPlaybackTokens.cinemaPureBlack] 纯黑防透底画布，全屏切换永不调用 `flutter_acrylic`；
/// - 鼠标静置 `2.0s` 自动隐藏指针与胶囊 HUD，移出窗口 `0ms` 立即收起；
/// - 按 `Space` 切换播放/暂停时仅在右上角微缩闪现 `0.8s` 状态徽标，不强制弹起遮挡画面底栏；
/// - 全套桌面快捷键：短按 `←/→` ±5s、长按 `→` 2.0x、松手恢复、`Shift+→` +85s、`S` 无损截屏、
///   `↑/↓` 音量、`M` 静音、`,/.` 逐帧、`PgUp/PgDn` 章节切换、`F/Enter/双击` 全屏、`Tab` 探针、`Esc` 退出。
class EmbeddedVideoPage extends ConsumerStatefulWidget {
  /// 创建内置视频播放页。
  const EmbeddedVideoPage({super.key, required this.request});

  /// 视频启动请求描述。
  final VideoLaunchRequest request;

  /// 以无黑闪柔和渐变路由推入内置高保真视频页。
  static Future<void> push(
    NavigatorState navigator,
    VideoLaunchRequest request,
  ) {
    return navigator.push<void>(
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

  bool _hudVisible = true;
  bool _instantHudHide = false;
  Timer? _idleTimer;

  bool _cornerBadgeVisible = false;
  String _cornerBadgeText = '';
  IconData _cornerBadgeIcon = Icons.pause_rounded;
  Timer? _cornerBadgeTimer;

  Timer? _rightHoldTimer;
  bool _rightHoldBoostActivated = false;

  VideoSideSheetTab _sideSheetTab = VideoSideSheetTab.episodes;
  Size? _lastReportedSurfaceSize;
  double? _lastReportedDpr;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _scheduleIdleHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _cornerBadgeTimer?.cancel();
    _rightHoldTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _scheduleIdleHide() {
    _idleTimer?.cancel();
    _idleTimer = Timer(KonataPlaybackTokens.cursorIdleFadeDelay, () {
      if (!mounted) return;
      final state = ref.read(videoPlaybackProvider(widget.request));
      if (state.sideSheetOpen) return;
      setState(() {
        _instantHudHide = false;
        _hudVisible = false;
      });
    });
  }

  void _onMouseActivity() {
    if (!_hudVisible || _instantHudHide) {
      setState(() {
        _instantHudHide = false;
        _hudVisible = true;
      });
    }
    _scheduleIdleHide();
  }

  void _hideHudImmediatelyOnExit() {
    _idleTimer?.cancel();
    final state = ref.read(videoPlaybackProvider(widget.request));
    if (state.sideSheetOpen) return;
    if (_hudVisible) {
      setState(() {
        _instantHudHide = true;
        _hudVisible = false;
      });
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

  Future<void> _exitPage() async {
    if (_exiting) return;
    _exiting = true;
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    await controller.closeAndRelease();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _relayToExternal() async {
    if (_exiting) return;
    _exiting = true;
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    final res = await controller.relayToExternalPlayer();
    if (mounted) {
      final nav = Navigator.of(context);
      nav.pop();
      showKonataToast(nav.context, res.message, isError: !res.launched);
    }
  }

  void _openSideSheet(VideoSideSheetTab tab) {
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
    final key = event.logicalKey;
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    final state = ref.read(videoPlaybackProvider(widget.request));
    final shift = HardwareKeyboard.instance.isShiftPressed;

    // 右键长按 2.0x 松开恢复
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
      controller.adjustVolume(5.0);
      final nextVol = (state.volume + 5.0).clamp(0.0, 100.0).round();
      _flashCornerStatus('音量 $nextVol%', Icons.volume_up_rounded);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      controller.adjustVolume(-5.0);
      final nextVol = (state.volume - 5.0).clamp(0.0, 100.0).round();
      _flashCornerStatus('音量 $nextVol%', Icons.volume_down_rounded);
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
        unawaited(_exitPage());
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(videoPlaybackProvider(widget.request));
    final controller = ref.read(videoPlaybackProvider(widget.request).notifier);
    final showHud = _hudVisible || state.sideSheetOpen;
    final hudDuration = _instantHudHide
        ? Duration.zero
        : KonataPlaybackTokens.hudFadeDuration;
    final epTitle = controller.currentEpisodeTitle;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_exitPage());
        }
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
            onHover: (_) => _onMouseActivity(),
            onExit: (_) => _hideHudImmediatelyOnExit(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                _focusNode.requestFocus();
                if (state.sideSheetOpen) {
                  _closeSideSheet();
                  return;
                }
                _onMouseActivity();
                controller.togglePlayPause();
              },
              onDoubleTap: () => unawaited(controller.toggleFullscreen()),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. 纯黑防透底基座
                  const ColoredBox(color: KonataPlaybackTokens.cinemaPureBlack),

                  // 2. 硬件纹理 / PlatformView 视频画面层
                  _buildVideoSurfaceLayer(context, state, controller),

                  // 3. 加载或出错兜底提示
                  if ((state.isInitializing || state.isBuffering) &&
                      state.errorMessage == null)
                    const Center(
                      child: SizedBox(
                        width: 34,
                        height: 34,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: KonataPlaybackTokens.osdAccent,
                        ),
                      ),
                    ),

                  if (state.errorMessage != null)
                    Center(
                      child: _ErrorFallbackCard(
                        message: state.errorMessage!,
                        onRelayExternal: _relayToExternal,
                        onBack: _exitPage,
                      ),
                    ),

                  // 4. 左上角技术探针（Tab 开关）
                  if (state.probeOverlayVisible)
                    Positioned(
                      left: 20,
                      top: 72,
                      child: VideoProbeOverlay(
                        stats: state.probeStats,
                        adapterName: state.adapterName,
                        renderBackend: state.renderBackend,
                      ),
                    ),

                  // 5. Space 洁净暂停 / 快进 / 音量 微缩角标
                  if (_cornerBadgeVisible || state.isSpeedBoostActive)
                    Positioned(
                      top: 72,
                      right: 24,
                      child: IgnorePointer(
                        child: _MiniCornerStatusPill(
                          icon: state.isSpeedBoostActive
                              ? Icons.fast_forward_rounded
                              : _cornerBadgeIcon,
                          label: state.isSpeedBoostActive
                              ? '2.0x 倍速快进中'
                              : _cornerBadgeText,
                        ),
                      ),
                    ),

                  // 6. 自动连播 / 硬解回退 / 截图保存 顶部轻提示
                  if (state.transientBanner != null)
                    Positioned(
                      top: 72,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: _MiniCornerStatusPill(
                            icon: Icons.info_outline_rounded,
                            label: state.transientBanner!,
                          ),
                        ),
                      ),
                    ),

                  // 7. 右下角智能跳过 OP/ED 胶囊（独立位置 bottom: 84, right: 24）
                  if (state.activeSkipWindow != null)
                    Positioned(
                      bottom: KonataPlaybackTokens.skipPillBottomOffset,
                      right: KonataPlaybackTokens.skipPillRightOffset,
                      child: _SkipChapterCapsule(
                        label: state.activeSkipWindow!.label,
                        onTap: () => unawaited(
                          controller.executeSkipWindow(state.activeSkipWindow!),
                        ),
                      ),
                    ),

                  // 8. 极简隐身顶栏与底部居中播控胶囊
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: AnimatedOpacity(
                      duration: hudDuration,
                      opacity: showHud ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !showHud,
                        child: _buildTopOverlayBar(
                          state: state,
                          controller: controller,
                          epTitle: epTitle,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: KonataPlaybackTokens.capsuleBottomOffset,
                    child: AnimatedOpacity(
                      duration: hudDuration,
                      opacity: showHud ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !showHud,
                        child: Center(
                          child: _buildBottomCapsule(state, controller),
                        ),
                      ),
                    ),
                  ),

                  // 9. 右滑毛玻璃四标签侧栏
                  if (state.sideSheetOpen)
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
      ),
    );
  }

  Widget _buildVideoSurfaceLayer(
    BuildContext context,
    VideoPlaybackState state,
    VideoPlaybackController controller,
  ) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        viewType: AndroidVideoSurfaceController.viewType,
        onPlatformViewCreated: (viewId) =>
            controller.attachAndroidSurface(AndroidVideoSurfaceController(viewId)),
      );
    }

    final texId = state.textureId;
    if (texId == null || texId < 0) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final sz = Size(constraints.maxWidth, constraints.maxHeight);
        if (_lastReportedSurfaceSize != sz || _lastReportedDpr != dpr) {
          _lastReportedSurfaceSize = sz;
          _lastReportedDpr = dpr;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && sz.width > 0 && sz.height > 0) {
              controller.notifySurfaceViewportSize(sz.width, sz.height, dpr);
            }
          });
        }
        return SizedBox.expand(
          child: Texture(
            textureId: texId,
            filterQuality: FilterQuality.medium,
          ),
        );
      },
    );
  }

  Widget _buildTopOverlayBar({
    required VideoPlaybackState state,
    required VideoPlaybackController controller,
    required String epTitle,
  }) {
    final isWindows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final stats = state.probeStats;
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
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            KonataPlaybackTokens.cinemaPureBlack.withValues(alpha: 0.72),
            KonataPlaybackTokens.cinemaPureBlack.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回作品详情 (Esc)',
            onPressed: _exitPage,
            icon: const Icon(
              Icons.arrow_back_rounded,
              color: KonataPlaybackTokens.osdTextPrimary,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: EllipsisTextWithTooltip(
                    text: '${widget.request.work.title} · $epTitle',
                    style: const TextStyle(
                      color: KonataPlaybackTokens.osdTextPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                if (resBadge.isNotEmpty) ...[
                  KonataSpecBadge(
                    label: resBadge,
                    forceOnDarkOverlay: true,
                  ),
                  const SizedBox(width: 6),
                ],
                if (codecBadge.isNotEmpty) ...[
                  KonataSpecBadge(
                    label: bitDepthBadge.isNotEmpty
                        ? '$codecBadge · $bitDepthBadge'
                        : codecBadge,
                    forceOnDarkOverlay: true,
                  ),
                  const SizedBox(width: 6),
                ],
                if (hwActive ||
                    state.renderBackend == 'sw' ||
                    state.hasFirstFrame)
                  KonataSpecBadge(
                    label: hwActive
                        ? '硬解 (${stats.hwdecCurrent})'
                        : (state.renderBackend == 'sw' ? 'SW 兼容' : '软解'),
                    highlighted: hwActive,
                    forceOnDarkOverlay: true,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '技术探针指标 (Tab)',
            onPressed: controller.toggleProbeOverlay,
            icon: Icon(
              Icons.analytics_outlined,
              size: 20,
              color: state.probeOverlayVisible
                  ? KonataPlaybackTokens.osdAccent
                  : KonataPlaybackTokens.osdTextSecondary,
            ),
          ),
          IconButton(
            tooltip: '切换外部播放器无缝接力续播',
            onPressed: _relayToExternal,
            icon: const Icon(
              Icons.open_in_new_rounded,
              size: 19,
              color: KonataPlaybackTokens.osdTextPrimary,
            ),
          ),
          IconButton(
            tooltip: '播控与画质设置',
            onPressed: () => _openSideSheet(VideoSideSheetTab.video),
            icon: const Icon(
              Icons.tune_rounded,
              size: 20,
              color: KonataPlaybackTokens.osdTextPrimary,
            ),
          ),
          if (isWindows && !state.isFullscreen) ...[
            const SizedBox(width: 4),
            const WindowControls(forceLightIcons: true),
          ],
        ],
      ),
    );

    if (isWindows && !state.isFullscreen) {
      bar = DragToMoveArea(child: bar);
    }
    return bar;
  }

  Widget _buildBottomCapsule(
    VideoPlaybackState state,
    VideoPlaybackController controller,
  ) {
    final nextEp = controller.findNextEpisode();
    final prevEp = controller.findPreviousEpisode();
    final stats = state.probeStats;
    final resBadge = PlaybackFormatters.formatResolutionBadge(
      stats.videoWidth,
      stats.videoHeight,
    );
    final bitDepthBadge = PlaybackFormatters.formatVideoBitDepthLabel(
      stats.videoPixelFormat,
    );
    final specLabel = [
      if (bitDepthBadge.isNotEmpty) bitDepthBadge,
      if (resBadge.isNotEmpty) resBadge,
    ].join(' · ');
    final speedChanged = (state.speed - 1.0).abs() > 0.02;

    return KonataPlaybackCapsule(
      title: controller.currentEpisodeTitle,
      positionSeconds: state.positionSeconds,
      durationSeconds: state.durationSeconds,
      isPlaying: state.isPlaying,
      chapters: state.chapters,
      onTogglePlayPause: controller.togglePlayPause,
      onSeek: controller.seekAbsolute,
      onPrevious: prevEp != null
          ? () => controller.switchToEpisode(prevEp, startSeconds: 0)
          : null,
      onNext: nextEp != null
          ? () => controller.switchToEpisode(nextEp, startSeconds: 0)
          : null,
      onToggleList: () => _openSideSheet(VideoSideSheetTab.episodes),
      isListActive: state.sideSheetOpen,
      listTooltip: '选集与播放列表',
      forceOnDarkOverlay: true,
      rightSlot: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KonataCapsuleIconButton(
            icon: Icons.subtitles_outlined,
            tooltip: '字幕轨道',
            color: KonataPlaybackTokens.osdTextSecondary,
            size: 18,
            onTap: () => _openSideSheet(VideoSideSheetTab.subtitles),
          ),
          KonataCapsuleIconButton(
            icon: Icons.audiotrack_outlined,
            tooltip: '音轨切换',
            color: KonataPlaybackTokens.osdTextSecondary,
            size: 18,
            onTap: () => _openSideSheet(VideoSideSheetTab.audio),
          ),
          KonataCapsuleIconButton(
            icon: Icons.camera_alt_outlined,
            tooltip: '纯净原画截图 (S)',
            color: KonataPlaybackTokens.osdTextPrimary,
            size: 18,
            onTap: () => unawaited(controller.captureCleanScreenshot()),
          ),
          if (speedChanged)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openSideSheet(VideoSideSheetTab.video),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 4,
                  ),
                  child: Text(
                    '${state.speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}x',
                    style: const TextStyle(
                      color: KonataPlaybackTokens.osdAccent,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      fontFeatures: KonataPlaybackTokens.tabularNumbers,
                    ),
                  ),
                ),
              ),
            ),
          if (specLabel.isNotEmpty) ...[
            const SizedBox(width: 4),
            KonataSpecBadge(label: specLabel, forceOnDarkOverlay: true),
            const SizedBox(width: 4),
          ],
          KonataVolumeControl(
            volume: (state.volume / 100.0).clamp(0.0, 1.0),
            isMuted: state.isMuted,
            onVolumeChanged: (v) => controller.setVolume(v * 100.0),
            onToggleMute: controller.toggleMute,
            forceOnDarkOverlay: true,
          ),
          KonataCapsuleIconButton(
            icon: state.isFullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            tooltip: state.isFullscreen ? '退出全屏 (F / Esc)' : '全屏播放 (F / 双击)',
            color: KonataPlaybackTokens.osdTextPrimary,
            size: 20,
            onTap: () => unawaited(controller.toggleFullscreen()),
          ),
        ],
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.osdSurfaceDark.withValues(alpha: 0.84),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: KonataPlaybackTokens.osdBorderLight),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: KonataPlaybackTokens.osdTextPrimary),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: KonataPlaybackTokens.osdTextPrimary,
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Material(
          color: KonataPlaybackTokens.osdSurfaceDark.withValues(alpha: 0.86),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: const BorderSide(color: KonataPlaybackTokens.osdBorderLight),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.fast_forward_rounded,
                    size: 16,
                    color: KonataPlaybackTokens.osdAccent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: KonataPlaybackTokens.osdTextPrimary,
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
    );
  }
}

class _ErrorFallbackCard extends StatelessWidget {
  const _ErrorFallbackCard({
    required this.message,
    required this.onRelayExternal,
    required this.onBack,
  });

  final String message;
  final VoidCallback onRelayExternal;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: KonataPlaybackTokens.osdSurfaceDark,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KonataPlaybackTokens.osdBorderLight),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 36,
            color: KonataPlaybackTokens.osdTextPrimary,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: KonataPlaybackTokens.osdTextPrimary,
              fontSize: 13.5,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: KonataPlaybackTokens.osdTextPrimary,
                  side: const BorderSide(
                    color: KonataPlaybackTokens.osdBorderLight,
                  ),
                ),
                onPressed: onBack,
                child: const Text('返回'),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: onRelayExternal,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('外部播放器打开'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
