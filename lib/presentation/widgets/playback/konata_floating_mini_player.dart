import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
import '../design_system/konata_toast.dart';
import '../managed_image.dart';

/// 全端统一可拖拽音视频悬浮小窗组件（替代旧版底部宽条播放胶囊）。
///
/// 核心职责与不变量：
/// - 视频形态：`16:9` 实时画面（复用同一 `GlobalObjectKey` 硬件表面，跨页与展开收起零重建会话）；
/// - 音频形态：`1:1` 正方形纯封面（与视频小窗等高），正下方紧凑等距排列「上一首 / 播放暂停 / 下一首」三键（无曲名、无循环键）；
/// - 纯净态与两段式轻触分流：默认不常驻角标，轻触画面/封面显现右上 `×` 与左上展开图标并 3 秒无操作自动隐去；`×` 显示期间轻触 `×` 立即停止并关闭，轻触中心或左上展开图标回到全屏；
/// - 自由拖拽与合法边缘吸附：通过 `ValueNotifier<Offset>` + `RepaintBoundary` 隔离变换层，拖拽全程零宿主页面重建，松手自动吸附至安全区内不遮挡导航胶囊的最近合法位置。
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
  Animation<Offset>? _snapAnimation;
  Timer? _chromeAutoHideTimer;

  bool _offsetInitialized = false;
  bool _isDragging = false;
  Offset _dragRawOffset = Offset.zero;
  Rect? _lastPublishedRect;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: KonataPlaybackTokens.floatingMiniSnapDuration,
    )..addListener(_handleSnapTick);
    _syncTargetFromLayout(animate: false);
  }

  @override
  void didUpdateWidget(covariant KonataFloatingMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _hideChromeImmediate();
    }
    if (!widget.standalone && !_isDragging) {
      final oldRect = oldWidget.layout?.floatingMiniWindowRect;
      final newRect = widget.layout?.floatingMiniWindowRect;
      if (oldWidget.kind != widget.kind || !_rectNearEqual(oldRect, newRect)) {
        _syncTargetFromLayout(animate: _offsetInitialized && oldWidget.kind == widget.kind);
      }
    }
  }

  @override
  void dispose() {
    _chromeAutoHideTimer?.cancel();
    _snapController
      ..removeListener(_handleSnapTick)
      ..dispose();
    _chromeVisibleNotifier.dispose();
    _liveOffsetNotifier.dispose();
    if (_lastPublishedRect != null &&
        konataFloatingMiniWindowRectNotifier.value == _lastPublishedRect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (konataFloatingMiniWindowRectNotifier.value == _lastPublishedRect) {
          konataFloatingMiniWindowRectNotifier.value = null;
        }
      });
    }
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
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          konataFloatingMiniWindowRectNotifier.value = rect;
        }
      });
    } else {
      konataFloatingMiniWindowRectNotifier.value = rect;
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
    final anim = _snapAnimation;
    if (anim != null) {
      _liveOffsetNotifier.value = anim.value;
    }
  }

  void _animateToOffset(Offset target) {
    final start = _liveOffsetNotifier.value;
    if ((start - target).distance < 0.5) {
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
    _snapAnimation = Tween<Offset>(begin: start, end: target).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOutCubic),
    );
    _snapController.forward(from: 0.0);
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

  void _handleSurfaceTap() {
    if (!_chromeVisibleNotifier.value) {
      _revealChromeWithTimer();
      return;
    }
    _handleExpandToFullscreen();
  }

  void _handleExpandToFullscreen() {
    _hideChromeImmediate();
    if (widget.kind == FloatingMiniPlayerKind.video) {
      ref.read(activeVideoSessionProvider.notifier).expandToFull();
    } else if (widget.kind == FloatingMiniPlayerKind.audio) {
      ref.read(immersiveAudioExpandedProvider.notifier).state = true;
    }
  }

  void _handleStopAndClose() {
    _hideChromeImmediate();
    if (widget.kind == FloatingMiniPlayerKind.video) {
      unawaited(ref.read(activeVideoSessionProvider.notifier).closeVideo());
    } else if (widget.kind == FloatingMiniPlayerKind.audio) {
      ref.read(audioPlaybackProvider.notifier).stopAndClose();
    }
  }

  void _handlePanStart(DragStartDetails details, Size miniSize) {
    if (widget.standalone || widget.layout == null) return;
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
    if (KonataToastController.activeToast.value != null) {
      _publishMiniRect(clamped & miniSize);
    }
  }

  void _handlePanEndOrCancel(Size miniSize) {
    final layout = widget.layout;
    if (widget.standalone || layout == null || !_isDragging) return;
    _isDragging = false;
    final settled = layout.snapMiniWindowOffset(
      _liveOffsetNotifier.value,
      miniSize,
    );
    _publishMiniRect(settled & miniSize);
    _animateToOffset(settled);
    final encoded = layout.encodeNormalizedAnchor(settled, miniSize);
    final prevAnchor = ref.read(floatingMiniWindowAnchorProvider);
    if (prevAnchor == null || (prevAnchor - encoded).distance > 0.002) {
      ref.read(floatingMiniWindowAnchorProvider.notifier).state = encoded;
    }
  }

  Size _resolveCurrentMiniSize(BuildContext context) {
    if (widget.layout != null) {
      return widget.layout!.resolveMiniWindowSize(widget.kind);
    }
    final fallbackLayout = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: AdaptiveCapsuleLayout.effectiveSafeInsetsOf(context),
      android: KonataAdaptiveTokens.isAndroid,
      miniKind: widget.kind,
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

    final p = context.palette;
    final miniSize = _resolveCurrentMiniSize(context);
    final card = RepaintBoundary(
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle.merge(
          style: const TextStyle(decoration: TextDecoration.none),
          child: GestureDetector(
            dragStartBehavior: DragStartBehavior.down,
            onPanStart: widget.standalone
                ? null
                : (d) => _handlePanStart(d, miniSize),
            onPanUpdate: widget.standalone
                ? null
                : (d) => _handlePanUpdate(d, miniSize),
            onPanEnd: widget.standalone
                ? null
                : (_) => _handlePanEndOrCancel(miniSize),
            onPanCancel: widget.standalone
                ? null
                : () => _handlePanEndOrCancel(miniSize),
            child: Container(
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
                    blurRadius: 22,
                    offset: const Offset(0, 8),
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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  KonataPlaybackTokens.floatingMiniRadius,
                ),
                child: widget.kind == FloatingMiniPlayerKind.video
                    ? _buildVideoBody(miniSize)
                    : _buildAudioBody(context, miniSize),
              ),
            ),
          ),
        ),
      ),
    );

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

  Widget _buildVideoBody(Size miniSize) {
    final req = widget.videoRequest!;
    return SizedBox(
      width: miniSize.width,
      height: miniSize.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const ValueKey('floating_mini_surface_tap_target'),
            behavior: HitTestBehavior.opaque,
            onTap: _handleSurfaceTap,
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
            onExpand: _handleExpandToFullscreen,
            onClose: _handleStopAndClose,
          ),
        ],
      ),
    );
  }

  Widget _buildAudioBody(BuildContext context, Size miniSize) {
    final p = context.palette;
    final coverSide = miniSize.width;
    final controlsHeight = miniSize.height - coverSide;
    final notifier = ref.read(audioPlaybackProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: coverSide,
          height: coverSide,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                key: const ValueKey('floating_mini_surface_tap_target'),
                behavior: HitTestBehavior.opaque,
                onTap: _handleSurfaceTap,
                child: RepaintBoundary(
                  child: _FloatingAudioCoverLeaf(size: coverSide),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: RepaintBoundary(child: _FloatingAudioProgressLeaf()),
              ),
              _FloatingMiniTransientChromeOverlay(
                visibleListenable: _chromeVisibleNotifier,
                onExpand: _handleExpandToFullscreen,
                onClose: _handleStopAndClose,
              ),
            ],
          ),
        ),
        SizedBox(
          width: coverSide,
          height: controlsHeight,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: KonataPlaybackTokens.floatingMiniAudioStripBlurSigma,
                sigmaY: KonataPlaybackTokens.floatingMiniAudioStripBlurSigma,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: KonataPlaybackTokens.glassSurface(p),
                  border: Border(
                    top: BorderSide(
                      color: KonataPlaybackTokens.glassBorder(p),
                      width: KonataPlaybackTokens.floatingMiniBorderWidth,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _FloatingAudioTransportButton(
                        buttonKey: const ValueKey('floating_mini_audio_prev'),
                        icon: Icons.skip_previous_rounded,
                        tooltip: '上一首',
                        onTap: notifier.previous,
                      ),
                    ),
                    Expanded(
                      child: _FloatingAudioPlayPauseLeaf(
                        onTap: notifier.togglePlayPause,
                      ),
                    ),
                    Expanded(
                      child: _FloatingAudioTransportButton(
                        buttonKey: const ValueKey('floating_mini_audio_next'),
                        icon: Icons.skip_next_rounded,
                        tooltip: '下一首',
                        onTap: notifier.next,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 轻触画面/封面后临时显现 3 秒的左上展开与右上 `×` 关闭浮层（所有触控热区严格 `>= 48dp`）。
class _FloatingMiniTransientChromeOverlay extends StatelessWidget {
  const _FloatingMiniTransientChromeOverlay({
    required this.visibleListenable,
    required this.onExpand,
    required this.onClose,
  });

  final ValueNotifier<bool> visibleListenable;
  final VoidCallback onExpand;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: visibleListenable,
      builder: (context, visible, _) {
        if (!visible) {
          return const SizedBox.shrink();
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.45, 1.0],
                    colors: [
                      Colors.black.withValues(alpha: 0.46),
                      Colors.black.withValues(alpha: 0.12),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: _FloatingOverlayCornerButton(
                buttonKey: const ValueKey('floating_mini_expand_button'),
                icon: Icons.open_in_full_rounded,
                tooltip: '展开全屏',
                onTap: onExpand,
              ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: _FloatingOverlayCornerButton(
                buttonKey: const ValueKey('floating_mini_close_button'),
                icon: Icons.close_rounded,
                tooltip: '停止并关闭',
                onTap: onClose,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FloatingOverlayCornerButton extends StatelessWidget {
  const _FloatingOverlayCornerButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: buttonKey,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: KonataAdaptiveTokens.touchTarget,
            child: Center(
              child: Container(
                width: KonataPlaybackTokens.floatingMiniOverlayPillSize,
                height: KonataPlaybackTokens.floatingMiniOverlayPillSize,
                decoration: BoxDecoration(
                  color: KonataPlaybackTokens.videoOverlayBadgeBg,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: KonataPlaybackTokens.videoOverlayBadgeBorder,
                    width: KonataPlaybackTokens.floatingMiniBorderWidth,
                  ),
                ),
                child: Icon(
                  icon,
                  size: KonataPlaybackTokens.floatingMiniOverlayIconSize,
                  color: KonataPlaybackTokens.videoOverlayBadgeFg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingAudioTransportButton extends StatefulWidget {
  const _FloatingAudioTransportButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_FloatingAudioTransportButton> createState() =>
      _FloatingAudioTransportButtonState();
}

class _FloatingAudioTransportButtonState
    extends State<_FloatingAudioTransportButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          key: widget.buttonKey,
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: KonataAdaptiveTokens.touchTarget,
              minHeight: KonataAdaptiveTokens.touchTarget,
            ),
            child: ColoredBox(
              color: _hovered
                  ? KonataPlaybackTokens.hoverFill(p)
                  : Colors.transparent,
              child: Center(
                child: Icon(
                  widget.icon,
                  size: KonataPlaybackTokens.floatingMiniTransportIconSize,
                  color: p.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 仅订阅音频播放/暂停布尔状态的独立叶子按钮，防止曲目时间推进触发底栏重绘。
class _FloatingAudioPlayPauseLeaf extends ConsumerWidget {
  const _FloatingAudioPlayPauseLeaf({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      audioPlaybackProvider.select((s) => s.isPlaying),
    );
    return _FloatingAudioTransportButton(
      buttonKey: const ValueKey('floating_mini_audio_play_pause'),
      icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      tooltip: isPlaying ? '暂停' : '播放',
      onTap: onTap,
    );
  }
}

/// 仅订阅封面数据源变更的 `1:1` 纯正方形封面叶子组件。
class _FloatingAudioCoverLeaf extends ConsumerWidget {
  const _FloatingAudioCoverLeaf({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final cover = ref.watch(audioPlaybackProvider.select((s) => s.cover));
    final expanded = ref.watch(immersiveAudioExpandedProvider);
    final loader = ref.watch(tmdbImageLoaderProvider);

    return HeroMode(
      enabled: !expanded,
      child: Hero(
        tag: 'konata_audio_cover_hero',
        child: SmartCoverAlignmentBuilder(
          cover: cover,
          loader: loader,
          builder: (context, coverAlignment) {
            switch (cover) {
              case MemoryAudioCover(:final bytes):
                return Image.memory(
                  bytes,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  alignment: coverAlignment,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                );
              case ManagedPosterAudioCover(
                :final url,
                :final workId,
                :final revision,
              ):
                return ManagedImage(
                  url,
                  key: ValueKey('floating_mini_cov_${workId}_${url}_$revision'),
                  loader: loader,
                  owner: workId,
                  width: size,
                  height: size,
                  decodeWidth: 320,
                  fit: BoxFit.cover,
                  alignment: coverAlignment,
                  errorBuilder: (_, _, _) => _fallbackCover(p),
                );
              case EmptyAudioCover():
                return _fallbackCover(p);
            }
          },
        ),
      ),
    );
  }

  Widget _fallbackCover(KonataPalette p) {
    return ColoredBox(
      color: KonataPlaybackTokens.auroraCanvas(p),
      child: Center(
        child: Icon(
          Icons.album_rounded,
          size: 42,
          color: p.textSecondary,
        ),
      ),
    );
  }
}

/// 视频悬浮小窗底部 `2dp` 进度指示叶子（高频进度仅重绘此叶子，零外层重建）。
class _FloatingVideoProgressLeaf extends ConsumerWidget {
  const _FloatingVideoProgressLeaf({required this.request});

  final VideoLaunchRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timing = ref.watch(
      videoPlaybackProvider(request).select(
        (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
      ),
    );
    final ratio = timing.dur > 0
        ? (timing.pos / timing.dur).clamp(0.0, 1.0)
        : 0.0;
    return IgnorePointer(
      child: LinearProgressIndicator(
        key: const ValueKey('floating_mini_video_progress'),
        value: ratio,
        minHeight: KonataAdaptiveTokens.progressHeight,
        color: context.palette.progressFill,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}

/// 音频悬浮小窗封面底沿 `2dp` 进度指示叶子（高频进度仅重绘此叶子，零外层重建）。
class _FloatingAudioProgressLeaf extends ConsumerWidget {
  const _FloatingAudioProgressLeaf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timing = ref.watch(
      audioPlaybackProvider.select(
        (s) => (pos: s.positionSeconds, dur: s.durationSeconds),
      ),
    );
    final ratio = timing.dur > 0
        ? (timing.pos / timing.dur).clamp(0.0, 1.0)
        : 0.0;
    return IgnorePointer(
      child: LinearProgressIndicator(
        key: const ValueKey('floating_mini_audio_progress'),
        value: ratio,
        minHeight: KonataAdaptiveTokens.progressHeight,
        color: context.palette.progressFill,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}
