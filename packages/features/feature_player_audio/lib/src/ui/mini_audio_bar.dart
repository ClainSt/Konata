import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';
import 'audio_aurora_backdrop.dart';

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

  @override
  State<MiniAudioBar> createState() => _MiniAudioBarState();
}

class _MiniAudioBarState extends State<MiniAudioBar>
    with TickerProviderStateMixin {
  late ValueNotifier<Offset> _dragOffset;
  bool _ownsOffsetNotifier = false;

  late final AnimationController _snapController;
  late final AnimationController _eqController;

  FloatingMiniVisualState _visualState = FloatingMiniVisualState.collapsed;
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

    _snapController = AnimationController.unbounded(vsync: this);
    _eqController = AnimationController(
      vsync: this,
      duration: KonataPlaybackTokens.equalizerCycleDuration,
    );

    widget.controller.playingListenable.addListener(_syncEqualizerTicker);
    widget.controller.activeListenable.addListener(_syncEqualizerTicker);
    _syncEqualizerTicker();
  }

  @override
  void didUpdateWidget(covariant MiniAudioBar oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.playingListenable.removeListener(
        _syncEqualizerTicker,
      );
      oldWidget.controller.activeListenable.removeListener(_syncEqualizerTicker);
      widget.controller.playingListenable.addListener(_syncEqualizerTicker);
      widget.controller.activeListenable.addListener(_syncEqualizerTicker);
    }
    _syncEqualizerTicker();
  }

  /// 严格受控：仅在会话激活、组件可见、折叠唱片态且真实播放中驱动律动 Ticker。
  void _syncEqualizerTicker() {
    final shouldAnimate =
        widget.visible &&
        widget.controller.activeListenable.value &&
        widget.controller.playingListenable.value &&
        _visualState == FloatingMiniVisualState.collapsed;
    if (shouldAnimate) {
      if (!_eqController.isAnimating) {
        unawaited(_eqController.repeat());
      }
    } else {
      if (_eqController.isAnimating) {
        _eqController.stop();
      }
    }
  }

  Size _currentBoxSize() {
    return switch (_visualState) {
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
    final right = math.max(left, viewport.width - safe.right - boxSize.width - margin);
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
          if (mounted) {
            _dragOffset.value = clamped;
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
    if (_visualState == nextState) return;
    _snapController.stop();
    setState(() {
      _visualState = nextState;
    });
    _syncEqualizerTicker();

    final boxSize = _currentBoxSize();
    final bounds = _boundsForViewport(viewport, safe, boxSize);
    final targetX = nextState == FloatingMiniVisualState.tucked
        ? (_edgeSide == FloatingMiniEdgeSide.left
              ? safe.left
              : math.max(safe.left, viewport.width - safe.right - boxSize.width))
        : _dragOffset.value.dx.clamp(bounds.left, bounds.right);
    final targetY = _dragOffset.value.dy.clamp(bounds.top, bounds.bottom);
    _dragOffset.value = Offset(targetX, targetY);
  }

  void _onPanUpdate(DragUpdateDetails details, Size viewport, EdgeInsets safe) {
    _snapController.stop();
    final current = _dragOffset.value;
    final boxSize = _currentBoxSize();
    const overshoot = KonataPlaybackTokens.floatingMiniEdgeTuckDragThreshold;
    final minX = safe.left - overshoot;
    final maxX = math.max(minX, viewport.width - safe.right - boxSize.width + overshoot);
    final minY = safe.top + KonataPlaybackTokens.floatingMiniEdgeMargin;
    final maxY = math.max(
      minY,
      viewport.height -
          safe.bottom -
          boxSize.height -
          KonataPlaybackTokens.floatingMiniEdgeMargin,
    );
    _dragOffset.value = Offset(
      (current.dx + details.delta.dx).clamp(minX, maxX),
      (current.dy + details.delta.dy).clamp(minY, maxY),
    );
  }

  void _onPanEnd(DragEndDetails details, Size viewport, EdgeInsets safe) {
    final boxSize = _currentBoxSize();
    final bounds = _boundsForViewport(viewport, safe, boxSize);
    final cur = _dragOffset.value;
    final vel = details.velocity.pixelsPerSecond;
    final projectedX =
        cur.dx + vel.dx * KonataPlaybackTokens.floatingMiniFlickProjectionSeconds;
    const tuckThreshold = 10.0;

    if (cur.dx <= bounds.left - tuckThreshold ||
        projectedX <= bounds.left - tuckThreshold * 2) {
      _edgeSide = FloatingMiniEdgeSide.left;
      _setVisualState(FloatingMiniVisualState.tucked, viewport, safe);
      return;
    }
    if (cur.dx >= bounds.right + tuckThreshold ||
        projectedX >= bounds.right + tuckThreshold * 2) {
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
    final targetY = (cur.dy +
            vel.dy * KonataPlaybackTokens.floatingMiniFlickProjectionSeconds)
        .clamp(bounds.top, bounds.bottom);

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
      (vel.distance / math.max(1.0, distance)).clamp(0.0, 6.0),
    );
    void tickListener() {
      if (!mounted) return;
      final t = _snapController.value;
      _dragOffset.value = Offset.lerp(startOffset, endOffset, t) ?? endOffset;
    }

    _snapController.removeListener(tickListener);
    _snapController.addListener(tickListener);
    unawaited(
      _snapController.animateWith(sim).whenComplete(() {
        _snapController.removeListener(tickListener);
        if (mounted) {
          _dragOffset.value = endOffset;
        }
      }),
    );
  }

  @override
  void dispose() {
    widget.controller.playingListenable.removeListener(_syncEqualizerTicker);
    widget.controller.activeListenable.removeListener(_syncEqualizerTicker);
    _snapController.dispose();
    _eqController.dispose();
    if (_ownsOffsetNotifier) {
      _dragOffset.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: widget.controller.activeListenable,
      builder: (context, isActive, _) {
        if (!isActive) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.biggest;
            final safe = MediaQuery.paddingOf(context);
            _ensureInitialPosition(viewport, safe);

            return Stack(
              fit: StackFit.expand,
              children: [
                ValueListenableBuilder<Offset>(
                  valueListenable: _dragOffset,
                  builder: (context, offset, child) {
                    return Positioned(
                      left: offset.dx,
                      top: offset.dy,
                      child: child!,
                    );
                  },
                  child: RepaintBoundary(
                    child: GestureDetector(
                      onPanUpdate: (d) => _onPanUpdate(d, viewport, safe),
                      onPanEnd: (d) => _onPanEnd(d, viewport, safe),
                      child: ValueListenableBuilder<AudioPlaybackSnapshot>(
                        valueListenable: widget.controller.snapshotListenable,
                        builder: (context, snap, _) {
                          return switch (_visualState) {
                            FloatingMiniVisualState.collapsed =>
                              _buildCollapsedDisc(snap, viewport, safe),
                            FloatingMiniVisualState.expanded =>
                              _buildExpandedCapsule(snap, viewport, safe),
                            FloatingMiniVisualState.tucked => _buildTuckedTab(
                              viewport,
                              safe,
                            ),
                          };
                        },
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildCollapsedDisc(
    AudioPlaybackSnapshot snap,
    Size viewport,
    EdgeInsets safe,
  ) {
    const discSize = KonataPlaybackTokens.floatingMiniAudioDiscSize;
    return GestureDetector(
      key: const ValueKey('mini_audio_disc_surface'),
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
              Positioned(
                right: 2,
                bottom: 2,
                child: ValueListenableBuilder<bool>(
                  valueListenable: widget.controller.playingListenable,
                  builder: (_, isPlaying, _) {
                    return _MiniEqualizerPill(
                      animation: _eqController,
                      isPlaying: isPlaying,
                    );
                  },
                ),
              ),
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
    return SizedBox(
      key: const ValueKey('mini_audio_expanded_capsule'),
      width: KonataPlaybackTokens.floatingMiniAudioPillWidth,
      height: KonataPlaybackTokens.floatingMiniAudioPillHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          KonataGlassCapsule(
            radius: KonataPlaybackTokens.floatingMiniRadius,
            showShadow: true,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                GestureDetector(
                  onTap: widget.onExpandFullStage,
                  child: SizedBox.square(
                    dimension:
                        KonataPlaybackTokens.floatingMiniAudioPillCoverSize,
                    child: AudioCoverArtworkView(
                      cover: snap.cover,
                      coverKey: snap.coverVariantTag,
                      borderRadius: 10,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onExpandFullStage,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          current?.title ?? '未在播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.palette.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          (current?.artist.isNotEmpty ?? false)
                              ? current!.artist
                              : (current?.album ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.palette.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                KonataCapsuleIconButton(
                  icon: Icons.skip_previous_rounded,
                  tooltip: '上一曲',
                  color: context.palette.textPrimary,
                  size: 18,
                  fixedSize: 28.0,
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
                      highlighted: true,
                      size: 20,
                      fixedSize: 32.0,
                      onTap: () =>
                          unawaited(widget.controller.togglePlayPause()),
                    );
                  },
                ),
                KonataCapsuleIconButton(
                  icon: Icons.skip_next_rounded,
                  tooltip: '下一曲',
                  color: context.palette.textPrimary,
                  size: 18,
                  fixedSize: 28.0,
                  onTap: () =>
                      unawaited(widget.controller.next(manual: true)),
                ),
                if (widget.desktopMiniWindowSupported)
                  KonataCapsuleIconButton(
                    icon: Icons.picture_in_picture_alt_rounded,
                    tooltip: snap.isDesktopMiniWindow ? '退出置顶小窗' : '置顶迷你小窗',
                    color: context.palette.textSecondary,
                    highlighted: snap.isDesktopMiniWindow,
                    size: 15,
                    fixedSize: 26.0,
                    onTap: () => unawaited(
                      widget.controller.setDesktopMiniWindow(
                        !snap.isDesktopMiniWindow,
                      ),
                    ),
                  ),
                KonataCapsuleIconButton(
                  icon: Icons.remove_rounded,
                  tooltip: '收起为迷你唱片',
                  color: context.palette.textSecondary,
                  size: 16,
                  fixedSize: 26.0,
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
                  fixedSize: 24.0,
                  onTap: () => unawaited(widget.controller.stopAndClose()),
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
        child: Center(
          child: Icon(
            isLeft
                ? Icons.chevron_right_rounded
                : Icons.chevron_left_rounded,
            size: 18,
            color: Colors.white.withValues(alpha: 0.88),
          ),
        ),
      ),
    );
  }
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
    if (progress <= 0) return;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final y = size.height - 2.0;
    const inset = 14.0;
    final maxW = math.max(0.0, size.width - inset * 2);
    canvas.drawLine(
      Offset(inset, y),
      Offset(inset + maxW * progress, y),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CapsuleBottomProgressPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _MiniEqualizerPill extends StatelessWidget {
  const _MiniEqualizerPill({
    required this.animation,
    required this.isPlaying,
  });

  final Animation<double> animation;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: KonataPlaybackTokens.floatingMiniDiscEqualizerLightHalo,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, _) {
          final phase = animation.value * math.pi * 2;
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(3, (i) {
              final h = isPlaying
                  ? 4.0 + 4.5 * (0.5 + 0.5 * math.sin(phase + i * 1.4))
                  : 4.0 + i * 1.5;
              return Container(
                width: 2.0,
                height: h,
                margin: EdgeInsets.only(right: i < 2 ? 1.5 : 0),
                decoration: BoxDecoration(
                  color: KonataPlaybackTokens.floatingMiniDiscEqualizerDarkBar,
                  borderRadius: BorderRadius.circular(1),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
