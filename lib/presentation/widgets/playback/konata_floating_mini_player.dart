import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/playback/audio_playback_notifier.dart';
import '../../../application/playback/playback_preferences_provider.dart';
import '../../../application/playback/unified_playback_coordinator.dart';
import '../../../application/playback/video_playback_controller.dart';
import '../../../application/providers/artwork_provider.dart';
import '../../audio/smart_cover_framing.dart';
import '../../shell/adaptive_capsule_layout.dart';
import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../../theme/konata_theme.dart';
import '../design_system/konata_glass_capsule.dart';
import '../design_system/konata_glass_menu.dart';
import '../design_system/konata_toast.dart';
import '../managed_image.dart';
import 'konata_playback_capsule.dart';

part 'konata_floating_mini_player_leaves.dart';

/// 全端统一可拖拽音视频悬浮小窗组件（流光光学三态音频 + 动态原比例无黑边视频）。
///
/// 核心职责与不变量：
/// - 视频形态：按真实视频宽高比自适应尺寸（零黑边），复用同一 `GlobalObjectKey` 硬件表面，
///   贴边收折时暂停播放并隐藏硬件挖空，点击侧边耳片自动恢复并续播；
/// - 音频形态：收起为 `56×56dp` 圆形封面发光进度环，点击向内展开为 `320×60dp` 光学毛玻璃迷你播控条，
///   点击外部或收起键恢复圆钮（无自动倒计时）；支持拖出边缘超过 `20dp` 或点按收折键收为 `24×72dp` 贴边耳片；
/// - 手机一级主页面协同：音频小窗自动与底部导航胶囊同行水平居中并排，单击直入全屏、左右滑动切歌、长按弹出玻璃菜单；
/// - 拖拽层采用 `ValueNotifier<Offset>` + `RepaintBoundary` 隔离，拖拽全程零宿主页面重建。
class KonataFloatingMiniPlayer extends ConsumerStatefulWidget {
  /// 创建视口内自由拖拽与吸附的音视频悬浮小窗。
  const KonataFloatingMiniPlayer({
    super.key,
    required this.kind,
    required this.layout,
    this.videoRequest,
    this.sharedVideoSurface,
  }) : standalone = false;

  /// 创建独立内嵌展示实例（供不带视口定位的局部单测使用）。
  const KonataFloatingMiniPlayer.standalone({
    super.key,
    required this.kind,
    this.videoRequest,
    this.sharedVideoSurface,
  }) : layout = null,
       standalone = true;

  /// 当前小窗内容类型（视频或音频）。
  final FloatingMiniPlayerKind kind;

  /// 外壳几何与安全区计算器（独立模式下为 `null`）。
  final AdaptiveCapsuleLayout? layout;

  /// 视频模式关联的启动请求。
  final VideoLaunchRequest? videoRequest;

  /// 视频模式复用的共享硬件纹理/原生表面控件。
  final Widget? sharedVideoSurface;

  /// 是否为无绝对定位的独立内嵌模式。
  final bool standalone;

  @override
  ConsumerState<KonataFloatingMiniPlayer> createState() =>
      _KonataFloatingMiniPlayerState();
}

class _KonataFloatingMiniPlayerState
    extends ConsumerState<KonataFloatingMiniPlayer>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<Offset> _liveOffsetNotifier = ValueNotifier<Offset>(
    Offset.zero,
  );
  final ValueNotifier<bool> _chromeVisibleNotifier = ValueNotifier<bool>(false);
  late final AnimationController _snapController;
  Offset _snapStartOffset = Offset.zero;
  Offset _snapEndOffset = Offset.zero;
  Timer? _chromeAutoHideTimer;

  bool _offsetInitialized = false;
  bool _isDragging = false;
  Offset _dragRawOffset = Offset.zero;
  Rect? _lastPublishedRect;
  KonataToastController? _toastController;
  bool _wasVideoPlayingBeforeTuck = false;

  @override
  void initState() {
    super.initState();
    _toastController = ref.read(konataToastControllerProvider);
    _snapController = AnimationController.unbounded(vsync: this)
      ..addListener(_handleSnapTick)
      ..addStatusListener(_handleSnapStatusChanged);
    _syncTargetFromLayout(animate: false);
  }

  @override
  void didUpdateWidget(covariant KonataFloatingMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _hideChromeImmediate();
      _wasVideoPlayingBeforeTuck = false;
    }
    if (!widget.standalone && !_isDragging) {
      final oldRect = oldWidget.layout?.floatingMiniWindowRect;
      final newRect = widget.layout?.floatingMiniWindowRect;
      if (oldWidget.kind != widget.kind || !_rectNearEqual(oldRect, newRect)) {
        _syncTargetFromLayout(
          animate: _offsetInitialized && oldWidget.kind == widget.kind,
        );
      }
    }
  }

  @override
  void dispose() {
    _chromeAutoHideTimer?.cancel();
    _snapController
      ..removeStatusListener(_handleSnapStatusChanged)
      ..removeListener(_handleSnapTick)
      ..dispose();
    _chromeVisibleNotifier.dispose();
    _liveOffsetNotifier.dispose();
    final toastCtrl = _toastController;
    final lastPublished = _lastPublishedRect;
    if (lastPublished != null &&
        toastCtrl != null &&
        !toastCtrl.isDisposed &&
        toastCtrl.floatingMiniWindowRect.value == lastPublished) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        toastCtrl.clearFloatingMiniWindowRectIfMatches(lastPublished);
      });
    }
    _toastController = null;
    super.dispose();
  }

  bool _rectNearEqual(Rect? a, Rect? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return (a.left - b.left).abs() < 0.5 &&
        (a.top - b.top).abs() < 0.5 &&
        (a.width - b.width).abs() < 0.5 &&
        (a.height - b.height).abs() < 0.5;
  }

  void _publishMiniRect(Rect? rect) {
    if (_rectNearEqual(_lastPublishedRect, rect)) return;
    _lastPublishedRect = rect;
    final toastCtrl = _toastController;
    if (toastCtrl == null || toastCtrl.isDisposed) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          toastCtrl.publishFloatingMiniWindowRect(rect);
        }
      });
    } else {
      toastCtrl.publishFloatingMiniWindowRect(rect);
    }
  }

  void _syncTargetFromLayout({required bool animate}) {
    if (widget.standalone) return;
    final targetRect = widget.layout?.floatingMiniWindowRect;
    if (targetRect == null) return;
    _publishMiniRect(targetRect);
    if (!_offsetInitialized || !animate) {
      _snapController.stop();
      _liveOffsetNotifier.value = targetRect.topLeft;
      _offsetInitialized = true;
      return;
    }
    _animateToOffset(targetRect.topLeft);
  }

  void _handleSnapTick() {
    final t = _snapController.value;
    final next = Offset(
      _snapStartOffset.dx + (_snapEndOffset.dx - _snapStartOffset.dx) * t,
      _snapStartOffset.dy + (_snapEndOffset.dy - _snapStartOffset.dy) * t,
    );
    _liveOffsetNotifier.value = next;
  }

  void _handleSnapStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _snapController.stop();
      _liveOffsetNotifier.value = _snapEndOffset;
    }
  }

  void _animateToOffset(
    Offset target, {
    Offset releaseVelocityPxPerSec = Offset.zero,
  }) {
    final start = _liveOffsetNotifier.value;
    final delta = target - start;
    final distance = delta.distance;
    if (distance < 0.5) {
      _snapController.stop();
      _liveOffsetNotifier.value = target;
      return;
    }
    final disableAnimations =
        mounted && (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (disableAnimations) {
      _snapController.stop();
      _liveOffsetNotifier.value = target;
      return;
    }

    _snapStartOffset = start;
    _snapEndOffset = target;
    final projectedSpeedPx =
        (releaseVelocityPxPerSec.dx * delta.dx +
            releaseVelocityPxPerSec.dy * delta.dy) /
        distance;
    final normalizedVelocity = (projectedSpeedPx / distance).clamp(
      -KonataPlaybackTokens.springNormalizedVelocityMax,
      KonataPlaybackTokens.springNormalizedVelocityMax,
    );
    final simulation = SpringSimulation(
      KonataPlaybackTokens.floatingMiniSnapSpring,
      0.0,
      1.0,
      normalizedVelocity,
      tolerance: const Tolerance(distance: 1e-3, velocity: 1e-3),
    );
    _snapController.animateWith(simulation);
  }

  void _revealChromeWithTimer() {
    _chromeAutoHideTimer?.cancel();
    _chromeVisibleNotifier.value = true;
    _chromeAutoHideTimer = Timer(
      KonataPlaybackTokens.floatingMiniOverlayAutoHideDuration,
      () {
        if (mounted) {
          _chromeVisibleNotifier.value = false;
        }
      },
    );
  }

  void _hideChromeImmediate() {
    _chromeAutoHideTimer?.cancel();
    _chromeAutoHideTimer = null;
    if (_chromeVisibleNotifier.value) {
      _chromeVisibleNotifier.value = false;
    }
  }

  void _handleVideoSurfaceTap() {
    if (!_chromeVisibleNotifier.value) {
      _revealChromeWithTimer();
      return;
    }
    _handleExpandToFullscreen();
  }

  void _handleExpandToFullscreen() {
    _hideChromeImmediate();
    ref.read(floatingMiniVisualStateProvider.notifier).state =
        FloatingMiniVisualState.collapsed;
    if (widget.kind == FloatingMiniPlayerKind.video) {
      ref.read(activeVideoSessionProvider.notifier).expandToFull();
    } else if (widget.kind == FloatingMiniPlayerKind.audio) {
      ref.read(immersiveAudioExpandedProvider.notifier).state = true;
    }
  }

  void _handleStopAndClose() {
    _hideChromeImmediate();
    _wasVideoPlayingBeforeTuck = false;
    ref.read(floatingMiniVisualStateProvider.notifier).state =
        FloatingMiniVisualState.collapsed;
    if (widget.kind == FloatingMiniPlayerKind.video) {
      unawaited(ref.read(activeVideoSessionProvider.notifier).closeVideo());
    } else if (widget.kind == FloatingMiniPlayerKind.audio) {
      ref.read(audioPlaybackProvider.notifier).stopAndClose();
    }
  }

  void _handleTuckToEdge({FloatingMiniEdgeSide? side}) {
    _hideChromeImmediate();
    final targetSide =
        side ??
        _inferCurrentEdgeSide(
          _liveOffsetNotifier.value,
          _resolveCurrentMiniSize(context),
        );
    if (widget.kind == FloatingMiniPlayerKind.video &&
        widget.videoRequest != null) {
      final vState = ref.read(videoPlaybackProvider(widget.videoRequest!));
      _wasVideoPlayingBeforeTuck = vState.isPlaying;
      if (vState.isPlaying) {
        ref
            .read(videoPlaybackProvider(widget.videoRequest!).notifier)
            .togglePlayPause();
      }
    }
    ref.read(floatingMiniEdgeSideProvider.notifier).state = targetSide;
    ref.read(floatingMiniVisualStateProvider.notifier).state =
        FloatingMiniVisualState.tucked;
  }

  void _handleUntuckFromEdge() {
    ref.read(floatingMiniVisualStateProvider.notifier).state =
        FloatingMiniVisualState.collapsed;
    if (widget.kind == FloatingMiniPlayerKind.video &&
        widget.videoRequest != null &&
        _wasVideoPlayingBeforeTuck) {
      _wasVideoPlayingBeforeTuck = false;
      final vState = ref.read(videoPlaybackProvider(widget.videoRequest!));
      if (!vState.isPlaying) {
        ref
            .read(videoPlaybackProvider(widget.videoRequest!).notifier)
            .togglePlayPause();
      }
    }
  }

  FloatingMiniEdgeSide _inferCurrentEdgeSide(Offset offset, Size miniSize) {
    final layout = widget.layout;
    if (layout == null || layout.size.width <= 0) {
      return ref.read(floatingMiniEdgeSideProvider);
    }
    return (offset.dx + miniSize.width / 2.0) < layout.size.width / 2.0
        ? FloatingMiniEdgeSide.left
        : FloatingMiniEdgeSide.right;
  }

  void _handlePanStart(DragStartDetails details, Size miniSize) {
    final layout = widget.layout;
    if (widget.standalone ||
        layout == null ||
        layout.inlinePhoneAudioPaired ||
        layout.visualState == FloatingMiniVisualState.tucked) {
      return;
    }
    _snapController.stop();
    _isDragging = true;
    _dragRawOffset = _liveOffsetNotifier.value;
    if (_chromeVisibleNotifier.value) {
      _revealChromeWithTimer();
    }
  }

  void _handlePanUpdate(DragUpdateDetails details, Size miniSize) {
    final layout = widget.layout;
    if (widget.standalone || layout == null || !_isDragging) return;
    _dragRawOffset += details.delta;
    final clamped = layout.clampMiniWindowOffset(_dragRawOffset, miniSize);
    _liveOffsetNotifier.value = clamped;
    if (_toastController?.activeToast.value != null) {
      _publishMiniRect(clamped & miniSize);
    }
  }

  void _handlePanEndOrCancel(Size miniSize, [DragEndDetails? details]) {
    final layout = widget.layout;
    if (widget.standalone || layout == null || !_isDragging) return;
    _isDragging = false;
    final bounds = layout.safeBoundsFor(miniSize);
    final overshootLeft = bounds.minX - _dragRawOffset.dx;
    final overshootRight = _dragRawOffset.dx - bounds.maxX;
    if (overshootLeft > KonataPlaybackTokens.floatingMiniEdgeTuckDragThreshold) {
      final encoded = layout.encodeNormalizedAnchor(
        Offset(bounds.minX, _liveOffsetNotifier.value.dy),
        miniSize,
      );
      ref.read(floatingMiniWindowAnchorProvider.notifier).state = encoded;
      _handleTuckToEdge(side: FloatingMiniEdgeSide.left);
      return;
    }
    if (overshootRight > KonataPlaybackTokens.floatingMiniEdgeTuckDragThreshold) {
      final encoded = layout.encodeNormalizedAnchor(
        Offset(bounds.maxX, _liveOffsetNotifier.value.dy),
        miniSize,
      );
      ref.read(floatingMiniWindowAnchorProvider.notifier).state = encoded;
      _handleTuckToEdge(side: FloatingMiniEdgeSide.right);
      return;
    }

    final velocity = details?.velocity.pixelsPerSecond ?? Offset.zero;
    final projectedOffset =
        _liveOffsetNotifier.value +
        velocity * KonataPlaybackTokens.floatingMiniFlickProjectionSeconds;
    final clampedProjected = layout.clampMiniWindowOffset(
      projectedOffset,
      miniSize,
    );
    final settled = layout.snapMiniWindowOffset(clampedProjected, miniSize);
    _publishMiniRect(settled & miniSize);
    _animateToOffset(settled, releaseVelocityPxPerSec: velocity);
    final nextSide = _inferCurrentEdgeSide(settled, miniSize);
    if (ref.read(floatingMiniEdgeSideProvider) != nextSide) {
      ref.read(floatingMiniEdgeSideProvider.notifier).state = nextSide;
    }
    final encoded = layout.encodeNormalizedAnchor(settled, miniSize);
    final prevAnchor = ref.read(floatingMiniWindowAnchorProvider);
    if (prevAnchor == null || (prevAnchor - encoded).distance > 0.002) {
      ref.read(floatingMiniWindowAnchorProvider.notifier).state = encoded;
    }
  }

  Future<void> _showInlinePhoneAudioMenu(BuildContext anchorContext) async {
    final audioState = ref.read(audioPlaybackProvider);
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final action = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: [
        KonataGlassMenuItem<String>(
          value: 'toggle',
          icon: audioState.isPlaying
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          label: audioState.isPlaying ? '暂停播放' : '继续播放',
        ),
        const KonataGlassMenuItem<String>(
          value: 'tuck',
          icon: Icons.chevron_right_rounded,
          label: '贴边隐藏',
        ),
        const KonataGlassMenuItem<String>(
          value: 'close',
          icon: Icons.close_rounded,
          label: '停止并关闭',
          isDanger: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'toggle':
        unawaited(notifier.togglePlayPause());
      case 'tuck':
        _handleTuckToEdge(side: FloatingMiniEdgeSide.right);
      case 'close':
        _handleStopAndClose();
    }
  }

  Size _resolveCurrentMiniSize(
    BuildContext context, {
    FloatingMiniVisualState? visualState,
    FloatingMiniEdgeSide? edgeSide,
  }) {
    if (widget.layout != null) {
      return widget.layout!.resolveMiniWindowSize(widget.kind);
    }
    final fallbackLayout = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context),
      android: KonataAdaptiveTokens.isAndroid,
      miniKind: widget.kind,
      visualState: visualState ?? ref.read(floatingMiniVisualStateProvider),
      edgeSide: edgeSide ?? ref.read(floatingMiniEdgeSideProvider),
    );
    return fallbackLayout.resolveMiniWindowSize(widget.kind);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.kind == FloatingMiniPlayerKind.none) {
      return const SizedBox.shrink();
    }
    if (widget.kind == FloatingMiniPlayerKind.video &&
        widget.videoRequest == null) {
      return const SizedBox.shrink();
    }

    final visualState = widget.standalone
        ? ref.watch(floatingMiniVisualStateProvider)
        : (widget.layout?.visualState ?? FloatingMiniVisualState.collapsed);
    final edgeSide = widget.standalone
        ? ref.watch(floatingMiniEdgeSideProvider)
        : (widget.layout?.edgeSide ?? FloatingMiniEdgeSide.right);
    final inlinePaired =
        !widget.standalone && (widget.layout?.inlinePhoneAudioPaired ?? false);
    final miniSize = _resolveCurrentMiniSize(
      context,
      visualState: visualState,
      edgeSide: edgeSide,
    );

    final windowsVideoUnderlay =
        !KonataAdaptiveTokens.isAndroid &&
        widget.kind == FloatingMiniPlayerKind.video &&
        visualState != FloatingMiniVisualState.tucked &&
        widget.videoRequest != null &&
        ref.watch(
          videoPlaybackProvider(
            widget.videoRequest!,
          ).select((s) => s.windowsUnderlayActive && !s.audioOnlyMode),
        );
    final usesCanvasHolePunchUnderlay =
        widget.kind == FloatingMiniPlayerKind.video &&
        visualState != FloatingMiniVisualState.tucked &&
        (KonataAdaptiveTokens.isAndroid || windowsVideoUnderlay);

    Widget content;
    if (visualState == FloatingMiniVisualState.tucked) {
      content = _buildEarTab(context, miniSize, edgeSide);
    } else if (widget.kind == FloatingMiniPlayerKind.video) {
      content = _buildVideoCard(
        context,
        miniSize,
        usesCanvasHolePunchUnderlay: usesCanvasHolePunchUnderlay,
      );
    } else if (visualState == FloatingMiniVisualState.expanded &&
        !inlinePaired) {
      content = _buildAudioExpandedPill(context, miniSize);
    } else {
      content = _buildAudioDisc(
        context,
        miniSize,
        inlinePaired: inlinePaired,
      );
    }

    final allowPan =
        !widget.standalone &&
        !inlinePaired &&
        visualState != FloatingMiniVisualState.tucked;

    final innerCard = Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
        child: allowPan
            ? GestureDetector(
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (d) => _handlePanStart(d, miniSize),
                onPanUpdate: (d) => _handlePanUpdate(d, miniSize),
                onPanEnd: (d) => _handlePanEndOrCancel(miniSize, d),
                onPanCancel: () => _handlePanEndOrCancel(miniSize),
                child: content,
              )
            : content,
      ),
    );

    // 底层视频硬件挖空路径禁止外包 RepaintBoundary 阻断 BlendMode.clear 穿透。
    final card = usesCanvasHolePunchUnderlay
        ? innerCard
        : RepaintBoundary(child: innerCard);

    if (widget.standalone) {
      return card;
    }

    return Positioned(
      left: 0,
      top: 0,
      child: ValueListenableBuilder<Offset>(
        valueListenable: _liveOffsetNotifier,
        child: card,
        builder: (_, offset, child) => Transform.translate(
          offset: offset,
          child: child,
        ),
      ),
    );
  }

  Widget _buildEarTab(
    BuildContext context,
    Size miniSize,
    FloatingMiniEdgeSide side,
  ) {
    final p = context.palette;
    final isLeft = side == FloatingMiniEdgeSide.left;
    final radius = isLeft
        ? const BorderRadius.horizontal(right: Radius.circular(14))
        : const BorderRadius.horizontal(left: Radius.circular(14));

    return Tooltip(
      message: '展开悬浮小窗',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('floating_mini_ear_tab'),
          behavior: HitTestBehavior.opaque,
          onTap: _handleUntuckFromEdge,
          child: Container(
            key: const ValueKey('konata_floating_mini_player'),
            width: miniSize.width,
            height: miniSize.height,
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: KonataPlaybackTokens.shadowColor(p),
                  blurRadius: 16,
                  offset: Offset(isLeft ? 3 : -3, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: KonataTheme.blurFilterControl,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: KonataTheme.opticalSheenGradient(
                      p,
                      baseColor: KonataPlaybackTokens.glassSurface(p),
                    ),
                    borderRadius: radius,
                    border: Border.all(
                      color: KonataPlaybackTokens.glassBorder(p),
                      width: KonataPlaybackTokens.floatingMiniBorderWidth,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.kind == FloatingMiniPlayerKind.audio)
                        const _FloatingMiniEqualizerLeaf(compact: true)
                      else
                        Icon(
                          Icons.movie_outlined,
                          size: 13,
                          color: p.textPrimary,
                        ),
                      const SizedBox(height: 4),
                      Icon(
                        isLeft
                            ? Icons.chevron_right_rounded
                            : Icons.chevron_left_rounded,
                        size: 16,
                        color: p.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAudioDisc(
    BuildContext context,
    Size miniSize, {
    required bool inlinePaired,
  }) {
    final p = context.palette;
    final side = miniSize.width;
    final notifier = ref.read(audioPlaybackProvider.notifier);

    return Builder(
      builder: (discCtx) {
        Widget disc = Container(
          key: const ValueKey('konata_floating_mini_player'),
          width: side,
          height: side,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: KonataPlaybackTokens.shadowColor(p),
                blurRadius: KonataPlaybackTokens.floatingMiniShadowBlur,
                offset: KonataPlaybackTokens.floatingMiniShadowOffset,
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.all(
                  KonataPlaybackTokens.floatingMiniAudioRingWidth + 1.2,
                ),
                child: ClipOval(
                  child: _FloatingAudioCoverLeaf(
                    size:
                        side -
                        (KonataPlaybackTokens.floatingMiniAudioRingWidth +
                                1.2) *
                            2,
                  ),
                ),
              ),
              const IgnorePointer(
                child: RepaintBoundary(child: _FloatingAudioProgressLeaf()),
              ),
              Positioned(
                right: 7,
                bottom: 7,
                child: IgnorePointer(
                  child: _FloatingMiniEqualizerLeaf(
                    compact: side < 64.0,
                    forceWhite: true,
                  ),
                ),
              ),
            ],
          ),
        );

        return Tooltip(
          message: inlinePaired ? '点击全屏 · 左滑下一曲 · 长按更多' : '点击展开播控条 · 拖拽吸附/贴边',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey('floating_mini_surface_tap_target'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (inlinePaired) {
                  _handleExpandToFullscreen();
                } else {
                  ref.read(floatingMiniVisualStateProvider.notifier).state =
                      FloatingMiniVisualState.expanded;
                }
              },
              onHorizontalDragEnd: inlinePaired
                  ? (details) {
                      final vx = details.primaryVelocity ?? 0.0;
                      if (vx < -140.0) {
                        unawaited(notifier.next());
                      } else if (vx > 140.0) {
                        unawaited(notifier.previous());
                      }
                    }
                  : null,
              onLongPress: inlinePaired
                  ? () => unawaited(_showInlinePhoneAudioMenu(discCtx))
                  : null,
              child: KeyedSubtree(
                key: const ValueKey('floating_mini_audio_disc'),
                child: disc,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAudioExpandedPill(BuildContext context, Size miniSize) {
    final p = context.palette;
    final notifier = ref.read(audioPlaybackProvider.notifier);
    final trackMeta = ref.watch(
      audioPlaybackProvider.select(
        (s) => (
          title: s.currentItem?.title ?? '',
          subtitle: s.currentItem?.albumTitle.isNotEmpty == true
              ? s.currentItem!.albumTitle
              : (s.currentItem?.work.title ?? ''),
        ),
      ),
    );
    final isTouch = KonataAdaptiveTokens.isAndroid;
    final compactButtons = miniSize.width < 300;
    final iconBtnSize = compactButtons ? 28.0 : (isTouch ? 36.0 : 30.0);

    return TapRegion(
      onTapOutside: (_) {
        if (mounted &&
            ref.read(floatingMiniVisualStateProvider) ==
                FloatingMiniVisualState.expanded) {
          ref.read(floatingMiniVisualStateProvider.notifier).state =
              FloatingMiniVisualState.collapsed;
        }
      },
      child: SizedBox(
        key: const ValueKey('konata_floating_mini_player'),
        width: miniSize.width,
        height: miniSize.height,
        child: KonataGlassCapsule(
        key: const ValueKey('floating_mini_audio_pill'),
        radius: KonataTheme.radiusPill,
        showShadow: true,
        child: Stack(
          children: [
            const Positioned(
              left: 22,
              right: 22,
              top: 1.0,
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: _FloatingAudioProgressLeaf(linear: true),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        key: const ValueKey('floating_mini_surface_tap_target'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _handleExpandToFullscreen,
                        child: Row(
                          children: [
                            ClipOval(
                              child: SizedBox.square(
                                dimension: (miniSize.height - 20.0).clamp(
                                  KonataPlaybackTokens
                                      .floatingMiniAudioPillCoverSize,
                                  48.0,
                                ),
                                child: _FloatingAudioCoverLeaf(
                                  size: (miniSize.height - 20.0).clamp(
                                    KonataPlaybackTokens
                                        .floatingMiniAudioPillCoverSize,
                                    48.0,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    trackMeta.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.textPrimary,
                                      fontSize: KonataTheme.fontSizeBodyXs,
                                      fontWeight: FontWeight.w600,
                                      height: 1.2,
                                    ),
                                  ),
                                  if (trackMeta.subtitle.isNotEmpty) ...[
                                    const SizedBox(height: 1),
                                    Text(
                                      trackMeta.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.textSecondary,
                                        fontSize: KonataTheme.fontSizeMicro,
                                        height: 1.15,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  KonataCapsuleIconButton(
                    key: const ValueKey('floating_mini_audio_prev'),
                    icon: Icons.skip_previous_rounded,
                    tooltip: '上一首',
                    color: p.textPrimary,
                    size: 18,
                    fixedSize: iconBtnSize,
                    padding: EdgeInsets.zero,
                    onTap: notifier.previous,
                  ),
                  _FloatingAudioPlayPauseLeaf(
                    fixedSize: iconBtnSize,
                    onTap: notifier.togglePlayPause,
                  ),
                  KonataCapsuleIconButton(
                    key: const ValueKey('floating_mini_audio_next'),
                    icon: Icons.skip_next_rounded,
                    tooltip: '下一首',
                    color: p.textPrimary,
                    size: 18,
                    fixedSize: iconBtnSize,
                    padding: EdgeInsets.zero,
                    onTap: notifier.next,
                  ),
                  KonataCapsuleIconButton(
                    key: const ValueKey('floating_mini_tuck_button'),
                    icon: Icons.last_page_rounded,
                    tooltip: '贴边隐藏',
                    color: p.textSecondary,
                    size: 16,
                    fixedSize: iconBtnSize,
                    padding: EdgeInsets.zero,
                    onTap: () => _handleTuckToEdge(),
                  ),
                  KonataCapsuleIconButton(
                    key: const ValueKey('floating_mini_collapse_disc_button'),
                    icon: Icons.remove_rounded,
                    tooltip: '收起为圆形图标',
                    color: p.textSecondary,
                    size: 16,
                    fixedSize: iconBtnSize,
                    padding: EdgeInsets.zero,
                    onTap: () {
                      ref.read(floatingMiniVisualStateProvider.notifier).state =
                          FloatingMiniVisualState.collapsed;
                    },
                  ),
                  KonataCapsuleIconButton(
                    key: const ValueKey('floating_mini_close_button'),
                    icon: Icons.close_rounded,
                    tooltip: '停止并关闭',
                    color: p.textSecondary,
                    size: 16,
                    fixedSize: iconBtnSize,
                    padding: EdgeInsets.zero,
                    onTap: _handleStopAndClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildVideoCard(
    BuildContext context,
    Size miniSize, {
    required bool usesCanvasHolePunchUnderlay,
  }) {
    final p = context.palette;
    final req = widget.videoRequest!;
    final bodyChild = SizedBox(
      width: miniSize.width,
      height: miniSize.height,
      child: MouseRegion(
        onEnter: KonataAdaptiveTokens.isAndroid
            ? null
            : (_) => _revealChromeWithTimer(),
        onExit: KonataAdaptiveTokens.isAndroid
            ? null
            : (_) => _hideChromeImmediate(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('floating_mini_surface_tap_target'),
              behavior: HitTestBehavior.opaque,
              onTap: _handleVideoSurfaceTap,
              child:
                  widget.sharedVideoSurface ??
                  const ColoredBox(color: KonataPlaybackTokens.cinemaPureBlack),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: RepaintBoundary(
                child: _FloatingVideoProgressLeaf(request: req),
              ),
            ),
            _FloatingMiniTransientChromeOverlay(
              visibleListenable: _chromeVisibleNotifier,
              videoRequest: req,
              onExpand: _handleExpandToFullscreen,
              onTuck: () => _handleTuckToEdge(),
              onClose: _handleStopAndClose,
            ),
          ],
        ),
      ),
    );

    return Container(
      key: const ValueKey('konata_floating_mini_player'),
      width: miniSize.width,
      height: miniSize.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(
          KonataPlaybackTokens.floatingMiniRadius,
        ),
        boxShadow: [
          BoxShadow(
            color: KonataPlaybackTokens.shadowColor(p),
            blurRadius: KonataPlaybackTokens.floatingMiniShadowBlur,
            offset: KonataPlaybackTokens.floatingMiniShadowOffset,
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(
          KonataPlaybackTokens.floatingMiniRadius,
        ),
        border: Border.all(
          color: KonataPlaybackTokens.glassBorder(p),
          width: KonataPlaybackTokens.floatingMiniBorderWidth,
        ),
      ),
      child: Builder(
        builder: (_) => usesCanvasHolePunchUnderlay
                ? bodyChild
                : ClipRRect(
                    borderRadius: BorderRadius.circular(
                      KonataPlaybackTokens.floatingMiniRadius,
                    ),
                    child: bodyChild,
                  ),
      ),
    );
  }
}
