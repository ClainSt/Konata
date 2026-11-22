import 'dart:async';
import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/konata_value_notifier.dart';
import '../../shell/adaptive_capsule_layout.dart' show FloatingMiniPlayerKind;
import '../../theme/konata_playback_tokens.dart';

export '../../shell/adaptive_capsule_layout.dart' show FloatingMiniPlayerKind;

/// 详情页源卡片起播时的全局矩形坐标（用于驱动「详情页源卡片 ↔ 全屏舞台」物理弹簧形变）。
final stageMorphOriginRectProvider =
    NotifierProvider<KonataValueNotifier<Rect?>, Rect?>(
      () => KonataValueNotifier<Rect?>.value(null),
    );

/// 详情页源卡片起播时记录的目标舞台类型（防止 CD/Scan 等非视频卡片矩形串扰视频展开形变）。
final stageMorphOriginKindProvider =
    NotifierProvider<
      KonataValueNotifier<FloatingMiniPlayerKind?>,
      FloatingMiniPlayerKind?
    >(() => KonataValueNotifier<FloatingMiniPlayerKind?>.value(null));

/// 下拉收起全屏舞台时记录的真实拖拽释放速度（逻辑像素/秒，传递给反向 `SpringSimulation` 继承惯性）。
final stageMorphReleaseVelocityProvider =
    NotifierProvider<KonataValueNotifier<double>, double>(
      () => KonataValueNotifier<double>.value(0.0),
    );

/// 视频全屏舞台正处于反向弹簧收起过渡期标记（过渡结束当帧原子移交 `GlobalObjectKey` 至悬浮小窗）。
final stageMorphReverseVideoActiveProvider =
    NotifierProvider<KonataValueNotifier<bool>, bool>(
      () => KonataValueNotifier<bool>.value(false),
    );

/// 捕获详情页剧集/CD 源卡片当前的全局矩形并登记至舞台弹簧起点。
void captureStageMorphOriginRect(
  BuildContext context, {
  FloatingMiniPlayerKind? kind,
}) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) return;
  final topLeft = renderObject.localToGlobal(Offset.zero);
  final size = renderObject.size;
  if (size.width <= 0 || size.height <= 0) return;
  final scope = context.findAncestorWidgetOfExactType<UncontrolledProviderScope>();
  if (scope == null) return;
  scope.container.read(stageMorphOriginKindProvider.notifier).state = kind;
  scope.container.read(stageMorphOriginRectProvider.notifier).state =
      topLeft & size;
}

/// 清空已消费的舞台形变起点记录，避免残留旧卡片坐标串扰后续无起点起播。
void clearStageMorphOrigin(WidgetRef ref) {
  if (ref.read(stageMorphOriginRectProvider) != null) {
    ref.read(stageMorphOriginRectProvider.notifier).state = null;
  }
  if (ref.read(stageMorphOriginKindProvider) != null) {
    ref.read(stageMorphOriginKindProvider.notifier).state = null;
  }
}

/// 详情页源卡片 / 悬浮小窗与全屏舞台之间的双向临界阻尼 `SpringSimulation` 视口矩形与圆角连续形变容器。
///
/// - 展开态（`0.0 -> 1.0`）：从详情页源卡片或悬浮小窗矩形平滑展开至全屏；
/// - 收起态（`1.0 -> 0.0`）：继承真实下拉手势释放初速度，平滑收拢回目标悬浮小窗矩形后原子移交；
/// - 过渡到达终态后立即停钟并直通返回 `child`（零闲置 Ticker、零稳态包装开销）。
class KonataStageMorphFrame extends StatefulWidget {
  /// 创建双向物理弹簧舞台形变容器。
  const KonataStageMorphFrame({
    super.key,
    required this.originRect,
    required this.allowClipRadius,
    required this.child,
    this.isCollapsing = false,
    this.releaseVelocityPxPerSec = 0.0,
    this.onExpandCompleted,
    this.onCollapseCompleted,
  });

  /// 展开起点或收起终点锚定矩形（来自详情页源卡片或悬浮小窗）。
  final Rect? originRect;

  /// 是否允许在形变帧内施加圆角裁剪（Android 底层 Underlay 表面由原生圆角裁剪，避免叠加双重开销）。
  final bool allowClipRadius;

  /// 被形变承载的全屏舞台子树。
  final Widget child;

  /// 是否处于全屏收起至小窗的反向弹簧阶段。
  final bool isCollapsing;

  /// 手势松手瞬间的真实释放初速度（逻辑像素/秒）。
  final double releaseVelocityPxPerSec;

  /// 展开弹簧到达全屏稳态并停钟后的回调（用于切入根 Overlay 不透明剪枝模式）。
  final VoidCallback? onExpandCompleted;

  /// 反向收起弹簧到达终态并停钟后的原子移交回调。
  final VoidCallback? onCollapseCompleted;

  @override
  State<KonataStageMorphFrame> createState() => KonataStageMorphFrameState();
}

/// 双向舞台形变状态（暴露只读进度与初速度供组件回归测试精准校验）。
class KonataStageMorphFrameState extends State<KonataStageMorphFrame>
    with SingleTickerProviderStateMixin {
  final GlobalKey _stableChildKey = GlobalKey();
  AnimationController? _controller;
  Timer? _collapseFailsafeTimer;
  Rect? _anchorRect;
  bool _morphing = false;
  bool _runningCollapse = false;
  bool _expandSettledNotified = false;
  double _lastAppliedNormalizedVelocity = 0.0;

  /// 最近一次驱动 `SpringSimulation` 传入的归一化初速度。
  double get lastAppliedNormalizedVelocity => _lastAppliedNormalizedVelocity;

  /// 当前形变进度（`0.0` 为源卡片/悬浮小窗，`1.0` 为全屏舞台）。
  double get currentProgress =>
      _controller != null ? _controller!.value.clamp(0.0, 1.0) : 1.0;

  /// 当前动画时钟是否仍处于活跃推进状态。
  bool get isTickerActive => _controller?.isAnimating ?? false;

  @override
  void initState() {
    super.initState();
    _anchorRect = widget.originRect;
  }

  void _cancelCollapseFailsafe() {
    _collapseFailsafeTimer?.cancel();
    _collapseFailsafeTimer = null;
  }

  void _finishCollapseNow() {
    _cancelCollapseFailsafe();
    _controller?.stop();
    if (!mounted) return;
    if (!_runningCollapse && !_morphing) return;
    _runningCollapse = false;
    _morphing = false;
    widget.onCollapseCompleted?.call();
  }

  double _normalizeVelocity(double velocityPxPerSec, double viewportHeight) {
    if (viewportHeight <= 0 || velocityPxPerSec == 0.0) return 0.0;
    return (velocityPxPerSec / viewportHeight).clamp(-12.0, 12.0);
  }

  void _ensureController() {
    _controller ??= AnimationController.unbounded(vsync: this)
      ..addStatusListener(_onStatusChanged);
  }

  void _notifyExpandCompletedOnce() {
    if (_expandSettledNotified || !mounted || widget.isCollapsing) return;
    _expandSettledNotified = true;
    widget.onExpandCompleted?.call();
  }

  void _startForwardMorph(double initialVelocity) {
    _cancelCollapseFailsafe();
    final anchor = _anchorRect;
    if (anchor == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifyExpandCompletedOnce();
      });
      return;
    }
    _ensureController();
    _runningCollapse = false;
    _expandSettledNotified = false;
    _morphing = true;
    _lastAppliedNormalizedVelocity = initialVelocity;
    final sim = SpringSimulation(
      KonataPlaybackTokens.stageMorphSpring,
      0.0,
      1.0,
      initialVelocity,
      tolerance: const Tolerance(distance: 1e-3, velocity: 1e-3),
    );
    _controller!.animateWith(sim);
  }

  void _startCollapseMorph() {
    _cancelCollapseFailsafe();
    _expandSettledNotified = false;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final targetRect = widget.originRect ?? _anchorRect;
    final fullSize = MediaQuery.maybeSizeOf(context) ?? Size.zero;
    final current = (_morphing && _controller != null)
        ? _controller!.value.clamp(0.0, 1.0)
        : 1.0;
    if (disableAnimations ||
        targetRect == null ||
        fullSize.width <= 0 ||
        fullSize.height <= 0 ||
        current <= 0.01) {
      _controller?.stop();
      _morphing = false;
      _runningCollapse = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onCollapseCompleted?.call();
        }
      });
      return;
    }
    _ensureController();
    _anchorRect = targetRect;
    // 下拉手势向下释放（primaryVelocity > 0）对应进度由 1.0 向 0.0 加速收拢（负向初速度）。
    final normalizedRelease = _normalizeVelocity(
      widget.releaseVelocityPxPerSec.abs(),
      fullSize.height,
    );
    _runningCollapse = true;
    _morphing = true;
    _lastAppliedNormalizedVelocity = -normalizedRelease;
    final sim = SpringSimulation(
      KonataPlaybackTokens.stageMorphSpring,
      current,
      0.0,
      -normalizedRelease,
      tolerance: const Tolerance(distance: 1e-3, velocity: 1e-3),
    );
    _controller!.animateWith(sim);
    _collapseFailsafeTimer = Timer(
      KonataPlaybackTokens.stageMorphCollapseFailsafeTimeout,
      () {
        if (mounted && _runningCollapse) {
          _finishCollapseNow();
        }
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disableAnimations) {
      _anchorRect = null;
      if (widget.isCollapsing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onCollapseCompleted?.call();
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _notifyExpandCompletedOnce();
        });
      }
      return;
    }
    if (widget.isCollapsing) {
      _startCollapseMorph();
    } else if (_anchorRect != null) {
      final fullSize = MediaQuery.maybeSizeOf(context) ?? const Size(1280, 720);
      final normalizedVel = _normalizeVelocity(
        widget.releaseVelocityPxPerSec,
        fullSize.height,
      );
      _startForwardMorph(normalizedVel);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifyExpandCompletedOnce();
      });
    }
  }

  @override
  void didUpdateWidget(covariant KonataStageMorphFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isCollapsing && widget.isCollapsing) {
      _startCollapseMorph();
    } else if (oldWidget.isCollapsing && !widget.isCollapsing) {
      _anchorRect = widget.originRect ?? _anchorRect;
      final fullSize = MediaQuery.maybeSizeOf(context) ?? const Size(1280, 720);
      final normalizedVel = _normalizeVelocity(
        widget.releaseVelocityPxPerSec,
        fullSize.height,
      );
      _startForwardMorph(normalizedVel);
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _cancelCollapseFailsafe();
      _controller?.stop();
      if (!mounted) return;
      final wasCollapse = _runningCollapse;
      _runningCollapse = false;
      if (wasCollapse) {
        _morphing = false;
        widget.onCollapseCompleted?.call();
      } else if (_morphing) {
        setState(() {
          _morphing = false;
          _anchorRect = null;
        });
        _notifyExpandCompletedOnce();
      }
    }
  }

  @override
  void dispose() {
    _cancelCollapseFailsafe();
    _controller
      ?..removeStatusListener(_onStatusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stableChild = KeyedSubtree(
      key: _stableChildKey,
      child: widget.child,
    );
    final ctrl = _controller;
    final anchorRect = _anchorRect;
    if (!_morphing || ctrl == null || anchorRect == null) {
      return stableChild;
    }
    final fullSize = MediaQuery.sizeOf(context);
    if (fullSize.width <= 0 || fullSize.height <= 0) {
      return stableChild;
    }
    final endRect = Offset.zero & fullSize;
    return AnimatedBuilder(
      animation: ctrl,
      child: stableChild,
      builder: (_, child) {
        final t = ctrl.value.clamp(0.0, 1.0);
        final rect = Rect.lerp(anchorRect, endRect, t) ?? endRect;
        final sx = (rect.width / endRect.width).clamp(0.05, 1.0);
        final sy = (rect.height / endRect.height).clamp(0.05, 1.0);
        final radius =
            lerpDouble(KonataPlaybackTokens.floatingMiniRadius, 0.0, t) ?? 0.0;
        final matrix = Matrix4.identity()
          ..translateByDouble(rect.left, rect.top, 0.0, 1.0)
          ..scaleByDouble(sx, sy, 1.0, 1.0);
        // 保持子页面按全屏终态尺寸一次布局，仅由 GPU 合成矩阵连续缩放平移，彻底消除形变帧溢出与逐帧重排。
        final clipped = (widget.allowClipRadius && radius > 0.5)
            ? ClipRRect(
                borderRadius: BorderRadius.circular(radius / sx),
                child: child,
              )
            : child!;
        return Transform(
          alignment: Alignment.topLeft,
          transform: matrix,
          child: clipped,
        );
      },
    );
  }
}
