import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart'
    show DesktopMiniDockSide;
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';
import 'audio_aurora_backdrop.dart';
import 'audio_playing_bars.dart';

/// 可自由拖拽的全端迷你音频悬浮唱片与胶囊控制条（3 态折叠/展开/贴边耳片）。
///
/// 拖拽坐标直接写入叶子 `ValueNotifier<Offset>` 并被 `RepaintBoundary` 隔离，
/// 拖动过程零宿主界面重建；并在暂停或隐藏时彻底停止律动动画 Ticker。
class MiniAudioBar extends StatefulWidget {
  /// 创建悬浮迷你音频 bar。
  const MiniAudioBar({
    super.key,
    required this.controller,
    this.visible = true,
    this.desktopMiniWindowSupported = false,
    this.dragOffsetNotifier,
    this.initialVisualState = FloatingMiniVisualState.collapsed,
    this.onExpandFullStage,
    this.onClose,
    this.onReturnToInternal,
  });

  /// 核心音频播放控制器。
  final AudioPlaybackController controller;

  /// 外部显隐开关（全屏舞台正遮罩展示或偏好关闭时传 `false`）。
  final bool visible;

  /// 是否显示桌面端置顶迷你窗快捷按钮。
  final bool desktopMiniWindowSupported;

  /// 可选外部共享的拖拽坐标叶子通知器（为空时组件内部自管并自动释放）。
  final ValueNotifier<Offset>? dragOffsetNotifier;

  /// 初始视觉展开形态（默认折叠态 1:1 迷你唱片）。
  final FloatingMiniVisualState initialVisualState;

  /// 点击展开进入全屏沉浸音频舞台的回调。
  final VoidCallback? onExpandFullStage;

  /// 结束播放后关闭独立舞台。
  final VoidCallback? onClose;

  /// 桌面小窗恢复至应用内浮窗时，由完整舞台关闭自身。
  final VoidCallback? onReturnToInternal;

  @override
  State<MiniAudioBar> createState() => _MiniAudioBarState();
}

class _MiniAudioBarState extends State<MiniAudioBar>
    with SingleTickerProviderStateMixin {
  late ValueNotifier<Offset> _dragOffset;
  bool _ownsOffsetNotifier = false;

  late final AnimationController _snapController;
  Offset _snapStart = Offset.zero;
  Offset _snapEnd = Offset.zero;
  Offset? _panOrigin;
  Offset? _panOffset;

  FloatingMiniVisualState _visualState = FloatingMiniVisualState.collapsed;
  FloatingMiniVisualState _desktopVisualState =
      FloatingMiniVisualState.collapsed;
  bool _desktopResizing = false;
  StreamSubscription<void>? _desktopMoveSubscription;
  StreamSubscription<void>? _desktopBlurSubscription;
  bool _desktopDockPending = false;
  FloatingMiniEdgeSide _edgeSide = FloatingMiniEdgeSide.right;
  bool _positionedOnce = false;
  Size _lastViewportSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _visualState = widget.initialVisualState;
    if (widget.dragOffsetNotifier != null) {
      _dragOffset = widget.dragOffsetNotifier!;
    } else {
      _dragOffset = ValueNotifier<Offset>(Offset.zero);
      _ownsOffsetNotifier = true;
    }

    _snapController = AnimationController.unbounded(vsync: this)
      ..addListener(_onSnapTick);
    _bindDesktopMoveEvents();
  }

  void _bindDesktopMoveEvents() {
    if (!widget.visible || !widget.desktopMiniWindowSupported) return;
    _desktopBlurSubscription = widget.controller.desktopAudioMiniBlur.listen((
      _,
    ) {
      if (!mounted ||
          !widget.visible ||
          !widget.controller.snapshot.isDesktopMiniWindow ||
          _desktopVisualState != FloatingMiniVisualState.expanded ||
          _desktopDockPending ||
          _desktopResizing) {
        return;
      }
      unawaited(_setDesktopVisualState(FloatingMiniVisualState.collapsed));
    });
    _desktopMoveSubscription = widget.controller.desktopMiniMoveEnded.listen((
      _,
    ) async {
      if (!mounted ||
          !widget.visible ||
          !widget.controller.snapshot.isDesktopMiniWindow ||
          _desktopResizing ||
          _desktopDockPending) {
        return;
      }
      _desktopDockPending = true;
      final controller = widget.controller;
      try {
        final side = await controller.snapDesktopMiniWindow();
        if (!mounted ||
            !widget.visible ||
            controller != widget.controller ||
            !controller.snapshot.isDesktopMiniWindow ||
            side == null) {
          return;
        }
        setState(
          () => _edgeSide = side == DesktopMiniDockSide.left
              ? FloatingMiniEdgeSide.left
              : FloatingMiniEdgeSide.right,
        );
        await _setDesktopVisualState(FloatingMiniVisualState.tucked);
      } catch (_) {
        if (mounted) showKonataToast(context, '小窗吸附失败，请重试', isError: true);
      } finally {
        _desktopDockPending = false;
      }
    });
  }

  @override
  void didUpdateWidget(covariant MiniAudioBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible ||
        oldWidget.desktopMiniWindowSupported !=
            widget.desktopMiniWindowSupported ||
        oldWidget.controller != widget.controller) {
      unawaited(_desktopMoveSubscription?.cancel());
      _desktopMoveSubscription = null;
      unawaited(_desktopBlurSubscription?.cancel());
      _desktopBlurSubscription = null;
      _bindDesktopMoveEvents();
    }
    if (!widget.visible ||
        oldWidget.dragOffsetNotifier != widget.dragOffsetNotifier) {
      _snapController.stop();
    }
    if (oldWidget.dragOffsetNotifier != widget.dragOffsetNotifier) {
      if (_ownsOffsetNotifier) {
        _dragOffset.dispose();
        _ownsOffsetNotifier = false;
      }
      if (widget.dragOffsetNotifier != null) {
        _dragOffset = widget.dragOffsetNotifier!;
      } else {
        _dragOffset = ValueNotifier<Offset>(Offset.zero);
        _ownsOffsetNotifier = true;
      }
      _positionedOnce = false;
    }
  }

  Size _currentBoxSize([FloatingMiniVisualState? state]) {
    return switch (state ?? _visualState) {
      FloatingMiniVisualState.collapsed => const Size.square(
        KonataPlaybackTokens.floatingMiniAudioDiscSize,
      ),
      FloatingMiniVisualState.expanded => const Size(
        KonataPlaybackTokens.floatingMiniAudioPillWidth,
        KonataPlaybackTokens.floatingMiniAudioPillHeight,
      ),
      FloatingMiniVisualState.tucked => const Size(
        KonataPlaybackTokens.floatingMiniEarTabWidth,
        KonataPlaybackTokens.floatingMiniEarTabHeight,
      ),
    };
  }

  Rect _boundsForViewport(Size viewport, EdgeInsets safe, Size boxSize) {
    const margin = KonataPlaybackTokens.floatingMiniEdgeMargin;
    final left = safe.left + margin;
    final top = safe.top + margin;
    final right = math.max(
      left,
      viewport.width - safe.right - boxSize.width - margin,
    );
    final bottom = math.max(
      top,
      viewport.height - safe.bottom - boxSize.height - margin,
    );
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _ensureInitialPosition(Size viewport, EdgeInsets safe) {
    if (viewport.isEmpty) return;
    final boxSize = _currentBoxSize();
    final bounds = _boundsForViewport(viewport, safe, boxSize);
    if (!_positionedOnce && _dragOffset.value == Offset.zero) {
      _positionedOnce = true;
      final initialOffset = Offset(
        bounds.right.clamp(bounds.left, bounds.right),
        (bounds.bottom - 72.0).clamp(bounds.top, bounds.bottom),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_dragOffset.value == Offset.zero) {
          _dragOffset.value = initialOffset;
        }
      });
    } else if (viewport != _lastViewportSize) {
      final clamped = Offset(
        _dragOffset.value.dx.clamp(bounds.left, bounds.right),
        _dragOffset.value.dy.clamp(bounds.top, bounds.bottom),
      );
      if (clamped != _dragOffset.value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _panOrigin == null && _lastViewportSize == viewport) {
            final current = _dragOffset.value;
            _dragOffset.value = Offset(
              current.dx.clamp(bounds.left, bounds.right),
              current.dy.clamp(bounds.top, bounds.bottom),
            );
          }
        });
      }
    }
    _lastViewportSize = viewport;
  }

  void _setVisualState(
    FloatingMiniVisualState nextState,
    Size viewport,
    EdgeInsets safe,
  ) {
    if (widget.controller.snapshot.isDesktopMiniWindow) {
      unawaited(_setDesktopVisualState(nextState));
      return;
    }
    if (_visualState == nextState) return;
    _snapController.stop();
    setState(() {
      _visualState = nextState;
    });

    final boxSize = _currentBoxSize();
    final bounds = _boundsForViewport(viewport, safe, boxSize);
    final targetX = nextState == FloatingMiniVisualState.tucked
        ? (_edgeSide == FloatingMiniEdgeSide.left
              ? safe.left
              : math.max(
                  safe.left,
                  viewport.width - safe.right - boxSize.width,
                ))
        : _dragOffset.value.dx.clamp(bounds.left, bounds.right);
    final targetY = _dragOffset.value.dy.clamp(bounds.top, bounds.bottom);
    _dragOffset.value = Offset(targetX, targetY);
  }

  void _onPanStart(DragStartDetails details) {
    _snapController.stop();
    _panOrigin = details.globalPosition;
    _panOffset = _dragOffset.value;
  }

  void _onPanUpdate(DragUpdateDetails details, Size viewport, EdgeInsets safe) {
    final origin = _panOrigin;
    final start = _panOffset;
    if (origin == null || start == null) return;
    final candidate = start + details.globalPosition - origin;
    final boxSize = _currentBoxSize();
    const overshoot = KonataPlaybackTokens.floatingMiniEdgeTuckDragThreshold;
    final minX = safe.left - overshoot;
    final maxX = math.max(
      minX,
      viewport.width - safe.right - boxSize.width + overshoot,
    );
    final minY = safe.top + KonataPlaybackTokens.floatingMiniEdgeMargin;
    final maxY = math.max(
      minY,
      viewport.height -
          safe.bottom -
          boxSize.height -
          KonataPlaybackTokens.floatingMiniEdgeMargin,
    );
    _dragOffset.value = Offset(
      candidate.dx.clamp(minX, maxX),
      candidate.dy.clamp(minY, maxY),
    );
  }

  void _onPanEnd(DragEndDetails details, Size viewport, EdgeInsets safe) {
    final boxSize = _currentBoxSize();
    final bounds = _boundsForViewport(viewport, safe, boxSize);
    _panOrigin = null;
    _panOffset = null;
    final cur = _dragOffset.value;
    final vel = details.velocity.pixelsPerSecond;
    final projectedX =
        cur.dx +
        vel.dx * KonataPlaybackTokens.floatingMiniFlickProjectionSeconds;
    const tuckThreshold = 10.0;

    if (cur.dx <= bounds.left - tuckThreshold) {
      _edgeSide = FloatingMiniEdgeSide.left;
      _setVisualState(FloatingMiniVisualState.tucked, viewport, safe);
      return;
    }
    if (cur.dx >= bounds.right + tuckThreshold) {
      _edgeSide = FloatingMiniEdgeSide.right;
      _setVisualState(FloatingMiniVisualState.tucked, viewport, safe);
      return;
    }

    final midX = (bounds.left + bounds.right) * 0.5;
    final snapLeft = projectedX < midX;
    _edgeSide = snapLeft
        ? FloatingMiniEdgeSide.left
        : FloatingMiniEdgeSide.right;
    final targetX = snapLeft ? bounds.left : bounds.right;
    final targetY = cur.dy.clamp(bounds.top, bounds.bottom);

    final startOffset = cur;
    final endOffset = Offset(targetX, targetY);
    final distance = (endOffset - startOffset).distance;
    if (distance < 0.5) {
      _dragOffset.value = endOffset;
      return;
    }

    final sim = SpringSimulation(
      KonataPlaybackTokens.floatingMiniSnapSpring,
      0.0,
      1.0,
      (vel.dx.abs() / math.max(1.0, distance)).clamp(0.0, 6.0),
    );
    _snapStart = startOffset;
    _snapEnd = endOffset;
    unawaited(
      _snapController.animateWith(sim).then((_) {
        if (mounted) _dragOffset.value = endOffset;
      }),
    );
  }

  // 单一监听器复用，连续拖拽中断时不会残留旧动画监听。
  void _onSnapTick() {
    _dragOffset.value = Offset.lerp(
      _snapStart,
      _snapEnd,
      _snapController.value.clamp(0.0, 1.0),
    )!;
  }

  @override
  void dispose() {
    unawaited(_desktopMoveSubscription?.cancel());
    unawaited(_desktopBlurSubscription?.cancel());
    _snapController.dispose();
    if (_ownsOffsetNotifier) {
      _dragOffset.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    return Theme(
      data: KonataTheme.darkTheme(),
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.controller.activeListenable,
        builder: (context, isActive, _) {
          if (!isActive) return const SizedBox.shrink();
          return ValueListenableBuilder<AudioPlaybackSnapshot>(
            valueListenable: widget.controller.snapshotListenable,
            builder: (context, snap, _) => LayoutBuilder(
              builder: (context, constraints) {
                final viewport = constraints.biggest;
                final safe = MediaQuery.paddingOf(context);
                if (snap.isDesktopMiniWindow) {
                  return Center(
                    key: const ValueKey('audio_desktop_mini_stage'),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox.fromSize(
                        size: _currentBoxSize(_desktopVisualState),
                        child: KonataDesktopWindowChromeScope.wrapDragToMove(
                          context,
                          child: RepaintBoundary(
                            child: switch (_desktopVisualState) {
                              FloatingMiniVisualState.collapsed =>
                                _buildCollapsedDisc(snap, viewport, safe),
                              FloatingMiniVisualState.expanded =>
                                _buildExpandedCapsule(snap, viewport, safe),
                              FloatingMiniVisualState.tucked => _buildTuckedTab(
                                viewport,
                                safe,
                              ),
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                }
                _ensureInitialPosition(viewport, safe);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ValueListenableBuilder<Offset>(
                      valueListenable: _dragOffset,
                      builder: (context, offset, child) => Positioned(
                        left: offset.dx,
                        top: offset.dy,
                        child: child!,
                      ),
                      child: RepaintBoundary(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          dragStartBehavior: DragStartBehavior.down,
                          onPanStart: _onPanStart,
                          onPanUpdate: (d) => _onPanUpdate(d, viewport, safe),
                          onPanEnd: (d) => _onPanEnd(d, viewport, safe),
                          onPanCancel: () {
                            _panOrigin = null;
                            _panOffset = null;
                          },
                          child: switch (_visualState) {
                            FloatingMiniVisualState.collapsed =>
                              _buildCollapsedDisc(snap, viewport, safe),
                            FloatingMiniVisualState.expanded =>
                              _buildExpandedCapsule(snap, viewport, safe),
                            FloatingMiniVisualState.tucked => _buildTuckedTab(
                              viewport,
                              safe,
                            ),
                          },
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _setDesktopVisualState(FloatingMiniVisualState next) async {
    if (_desktopResizing || _desktopVisualState == next) return;
    _desktopResizing = true;
    final size = _currentBoxSize(next);
    try {
      await widget.controller.resizeDesktopMiniWindow(
        width: size.width + 16,
        height: size.height + 16,
      );
      if (mounted) setState(() => _desktopVisualState = next);
    } catch (_) {
      if (mounted) showKonataToast(context, '小窗调整失败，请重试', isError: true);
    } finally {
      _desktopResizing = false;
    }
  }

  Future<void> _returnToInternal() async {
    if (await _toggleDesktopMiniWindow(false) && mounted) {
      widget.onReturnToInternal?.call();
    }
  }

  Future<bool> _toggleDesktopMiniWindow(bool enabled) async {
    try {
      if (enabled) _desktopVisualState = FloatingMiniVisualState.collapsed;
      await widget.controller.setDesktopMiniWindow(enabled);
      return widget.controller.snapshot.isDesktopMiniWindow == enabled;
    } catch (_) {
      if (mounted) {
        showKonataToast(context, '窗口切换失败，请重试', isError: true);
      }
      return false;
    }
  }

  Future<void> _expandToStage() async {
    if (widget.controller.snapshot.isDesktopMiniWindow) {
      if (!await _toggleDesktopMiniWindow(false)) return;
    }
    if (mounted) widget.onExpandFullStage?.call();
  }

  Future<void> _close() async {
    final onClose = widget.onClose;
    try {
      await widget.controller.stopAndClose();
      onClose?.call();
    } catch (_) {
      if (mounted) showKonataToast(context, '关闭失败，请重试', isError: true);
    }
  }

  Widget _buildCollapsedDisc(
    AudioPlaybackSnapshot snap,
    Size viewport,
    EdgeInsets safe,
  ) {
    const discSize = KonataPlaybackTokens.floatingMiniAudioDiscSize;
    return GestureDetector(
      key: const ValueKey('mini_audio_disc_surface'),
      onSecondaryTap: snap.isDesktopMiniWindow
          ? () =>
                _setVisualState(FloatingMiniVisualState.tucked, viewport, safe)
          : null,
      onTap: () =>
          _setVisualState(FloatingMiniVisualState.expanded, viewport, safe),
      child: SizedBox.square(
        dimension: discSize,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF141820),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.36),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.all(4.0),
                child: ClipOval(
                  child: AudioCoverArtworkView(
                    cover: snap.cover,
                    coverKey: snap.coverVariantTag,
                    borderRadius: discSize,
                  ),
                ),
              ),
              _MiniCircularProgressRing(
                positionListenable: widget.controller.positionListenable,
                durationListenable: widget.controller.durationListenable,
              ),
              Positioned(right: 8, bottom: 8, child: _playingBars()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedCapsule(
    AudioPlaybackSnapshot snap,
    Size viewport,
    EdgeInsets safe,
  ) {
    final current = snap.currentItem;
    return TapRegion(
      onTapOutside: snap.isDesktopMiniWindow
          ? null
          : (_) {
              if (_visualState == FloatingMiniVisualState.expanded &&
                  _panOrigin == null) {
                _setVisualState(
                  FloatingMiniVisualState.collapsed,
                  viewport,
                  safe,
                );
              }
            },
      child: SizedBox(
        key: const ValueKey('mini_audio_expanded_capsule'),
        width: KonataPlaybackTokens.floatingMiniAudioPillWidth,
        height: KonataPlaybackTokens.floatingMiniAudioPillHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            KonataGlassCapsule(
              radius: KonataPlaybackTokens.floatingMiniAudioPillHeight / 2,
              showShadow: false,
              showBorder: false,
              enableBackdropBlur: false,
              solidBackdropColor: const Color(0xFF22252B),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => unawaited(_expandToStage()),
                    child: SizedBox.square(
                      dimension:
                          KonataPlaybackTokens.floatingMiniAudioPillCoverSize,
                      child: AudioCoverArtworkView(
                        cover: snap.cover,
                        coverKey: snap.coverVariantTag,
                        borderRadius:
                            KonataPlaybackTokens
                                .floatingMiniAudioPillCoverSize /
                            2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => unawaited(_expandToStage()),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          current?.title ?? '未在播放',
                          key: const ValueKey('mini_audio_track_title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.start,
                          style: TextStyle(
                            color: context.palette.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  KonataCapsuleIconButton(
                    icon: Icons.skip_previous_rounded,
                    tooltip: '上一曲',
                    color: context.palette.textPrimary,
                    size: 17,
                    fixedSize: 24.0,
                    padding: EdgeInsets.zero,
                    onTap: () => unawaited(widget.controller.previous()),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: widget.controller.playingListenable,
                    builder: (_, isPlaying, _) {
                      return KonataCapsuleIconButton(
                        icon: isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: isPlaying ? '暂停' : '播放',
                        color: context.palette.textPrimary,
                        size: 20,
                        fixedSize: 28.0,
                        padding: EdgeInsets.zero,
                        onTap: () =>
                            unawaited(widget.controller.togglePlayPause()),
                      );
                    },
                  ),
                  KonataCapsuleIconButton(
                    icon: Icons.skip_next_rounded,
                    tooltip: '下一曲',
                    color: context.palette.textPrimary,
                    size: 17,
                    fixedSize: 24.0,
                    padding: EdgeInsets.zero,
                    onTap: () =>
                        unawaited(widget.controller.next(manual: true)),
                  ),
                  if (widget.desktopMiniWindowSupported)
                    KonataCapsuleIconButton(
                      icon: Icons.picture_in_picture_alt_rounded,
                      key: snap.isDesktopMiniWindow
                          ? const ValueKey('audio_desktop_mini_internal')
                          : null,
                      tooltip: snap.isDesktopMiniWindow ? '应用内小窗' : '桌面小窗',
                      color: context.palette.textSecondary,
                      size: 15,
                      fixedSize: 24.0,
                      padding: EdgeInsets.zero,
                      onTap: () => unawaited(
                        snap.isDesktopMiniWindow
                            ? _returnToInternal()
                            : _toggleDesktopMiniWindow(true),
                      ),
                    ),
                  KonataCapsuleIconButton(
                    icon: Icons.remove_rounded,
                    tooltip: '收起',
                    color: context.palette.textSecondary,
                    size: 16,
                    fixedSize: 24.0,
                    padding: EdgeInsets.zero,
                    onTap: () => _setVisualState(
                      FloatingMiniVisualState.collapsed,
                      viewport,
                      safe,
                    ),
                  ),
                  KonataCapsuleIconButton(
                    icon: Icons.close_rounded,
                    tooltip: '结束播放',
                    color: context.palette.textSecondary,
                    size: 15,
                    fixedSize: 24,
                    padding: EdgeInsets.zero,
                    onTap: () => unawaited(_close()),
                  ),
                ],
              ),
            ),

            IgnorePointer(
              child: _MiniCapsuleContourProgress(
                positionListenable: widget.controller.positionListenable,
                durationListenable: widget.controller.durationListenable,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTuckedTab(Size viewport, EdgeInsets safe) {
    final isLeft = _edgeSide == FloatingMiniEdgeSide.left;
    return GestureDetector(
      key: const ValueKey('mini_audio_tucked_tab'),
      onTap: () =>
          _setVisualState(FloatingMiniVisualState.collapsed, viewport, safe),
      child: Container(
        width: KonataPlaybackTokens.floatingMiniEarTabWidth,
        height: KonataPlaybackTokens.floatingMiniEarTabHeight,
        decoration: BoxDecoration(
          color: const Color(0xCC181C26),
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(isLeft ? 0 : 12),
            right: Radius.circular(isLeft ? 12 : 0),
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.24),
            width: 0.8,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isLeft ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
              size: 18,
              color: Colors.white.withValues(alpha: 0.88),
            ),
            const SizedBox(height: 5),
            AudioPlayingBars(
              playing: widget.controller.playingListenable,
              color: Colors.white,
            ),
          ],
        ),
      ),
    );
  }

  Widget _playingBars() => IgnorePointer(
    child: AudioPlayingBars(
      playing: widget.controller.playingListenable,
      color: Colors.white,
    ),
  );
}

class _MiniCircularProgressRing extends StatelessWidget {
  const _MiniCircularProgressRing({
    required this.positionListenable,
    required this.durationListenable,
  });

  final ValueListenable<Duration> positionListenable;
  final ValueListenable<Duration> durationListenable;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: durationListenable,
      builder: (_, duration, _) {
        final totalMs = duration.inMilliseconds;
        return ValueListenableBuilder<Duration>(
          valueListenable: positionListenable,
          builder: (_, position, _) {
            final ratio = totalMs > 0
                ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0)
                : 0.0;
            return CustomPaint(
              painter: _CircularProgressPainter(progress: ratio),
            );
          },
        );
      },
    );
  }
}

class _CircularProgressPainter extends CustomPainter {
  const _CircularProgressPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = KonataPlaybackTokens.floatingMiniAudioRingWidth;
    final rect = (Offset.zero & size).deflate(stroke * 0.5);
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withValues(alpha: 0.22);
    canvas.drawArc(rect, 0, math.pi * 2, false, trackPaint);

    if (progress > 0.0) {
      final fillPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = Colors.white;
      canvas.drawArc(
        rect,
        -math.pi * 0.5,
        math.pi * 2 * progress,
        false,
        fillPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CircularProgressPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _MiniCapsuleContourProgress extends StatelessWidget {
  const _MiniCapsuleContourProgress({
    required this.positionListenable,
    required this.durationListenable,
  });

  final ValueListenable<Duration> positionListenable;
  final ValueListenable<Duration> durationListenable;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: durationListenable,
      builder: (_, duration, _) {
        final totalMs = duration.inMilliseconds;
        return ValueListenableBuilder<Duration>(
          valueListenable: positionListenable,
          builder: (_, position, _) {
            final ratio = totalMs > 0
                ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0)
                : 0.0;
            return CustomPaint(
              painter: _CapsuleBottomProgressPainter(progress: ratio),
            );
          },
        );
      },
    );
  }
}

class _CapsuleBottomProgressPainter extends CustomPainter {
  const _CapsuleBottomProgressPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final radius = Radius.circular(rect.height / 2);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.18);
    canvas.drawPath(path, paint);
    if (progress <= 0) return;
    paint.color = Colors.white.withValues(alpha: 0.85);
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * progress), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CapsuleBottomProgressPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
