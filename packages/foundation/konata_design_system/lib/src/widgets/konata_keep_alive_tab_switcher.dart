import 'package:material_ui/material_ui.dart';

import '../tokens/konata_theme.dart';

/// 顶栏四主页面共用的「首次访问懒加载 + 常驻保活 + 引擎原生合成层轻量切换」容器。
///
/// 特性：
/// - 闲置页面保持挂载以 100% 保留滚动位置与状态，同时自动施加
///   `Offstage` + `TickerMode(enabled: false)` + `IgnorePointer` + `ExcludeFocus` 零绘制休眠；
/// - 固定各页槽位顺序与稳定子树结构，绝不触发 `GlobalKey` 跨节点重挂；
/// - 实底画布模式（传入 `scrimFadeColor`）以零离屏 `saveLayer` 的单次同色遮罩叠加
///   `SlideTransition` 实现数学等价淡入滑入，彻底消除高分屏全屏离屏纹理拷贝引发的光栅 P99 毛刺；
/// - 透明桌面材质模式仅在进场瞬态施加轻量位移淡入，动画结束后立即解绑动画监听，静息态零额外合成层。
class KonataKeepAliveTabSwitcher extends StatefulWidget {
  /// 创建保状态方向感页面切换容器。
  const KonataKeepAliveTabSwitcher({
    super.key,
    required this.activeIndex,
    required this.children,
    this.duration = KonataTheme.tabSwitchDuration,
    this.incomingSlidePixels = 10.0,
    this.outgoingSlidePixels = 8.0,
    this.scrimFadeColor,
    this.idleEvictAfter,
    this.pinnedIndices = const <int>{0},
    this.clock,
  });

  /// 当前激活页面索引。
  final int activeIndex;

  /// 常驻子页面列表（每个子页面内部由固定 [RepaintBoundary] 隔离重绘）。
  final List<Widget> children;

  /// 转场动画时长。
  final Duration duration;

  /// 新页面滑入起始水平像素偏移量。
  final double incomingSlidePixels;

  /// 旧页面淡出终止水平像素偏移量（保留参数以兼容外部契约）。
  final double outgoingSlidePixels;

  /// 可选实底画布淡入遮罩色；非空时用零 `saveLayer` 顶层同色遮罩等价替代 `FadeTransition`。
  final Color? scrimFadeColor;

  /// 非锁定后台页超时懒回收阈值；非空时在切页、退场动画结束或应用生命周期变化时卸载超期失活子树（零后台定时器）。
  final Duration? idleEvictAfter;

  /// 永不因闲置被自动卸载的常驻页索引集合（默认锁定 0 号媒体库首页）。
  final Set<int> pinnedIndices;

  /// 可选时钟注入（仅用于确定性单元测试，不传时默认使用系统时间）。
  final DateTime Function()? clock;

  @override
  State<KonataKeepAliveTabSwitcher> createState() =>
      _KonataKeepAliveTabSwitcherState();
}

class _KonataKeepAliveTabSwitcherState
    extends State<KonataKeepAliveTabSwitcher>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const AlwaysStoppedAnimation<Offset> _kZeroOffsetAnimation =
      AlwaysStoppedAnimation<Offset>(Offset.zero);

  late final AnimationController _animCtrl;
  late final CurvedAnimation _curved;
  late final CurvedAnimation _incomingOpacity;
  late final CurvedAnimation _outgoingOpacityCurve;
  late final Animation<double> _outgoingOpacity;
  late Animation<Offset> _incomingSlide;
  late Animation<Offset> _outgoingSlide;
  late List<bool> _mountedFlags;
  late List<DateTime?> _lastDeactivatedAt;
  late List<Widget> _wrappedChildren;
  bool _animating = false;
  int? _outgoingIndex;
  double _direction = 1.0;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initChildrenCache();
    _animCtrl = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1.0,
    );
    _curved = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOutQuart,
    );
    _incomingOpacity = CurvedAnimation(
      parent: _animCtrl,
      curve: const Interval(0.12, 1.0, curve: Curves.easeOutQuart),
    );
    _outgoingOpacityCurve = CurvedAnimation(
      parent: _animCtrl,
      curve: const Interval(0.0, 0.52, curve: Curves.easeOutCubic),
    );
    _outgoingOpacity = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(_outgoingOpacityCurve);
    _incomingSlide = _buildIncomingSlide(_direction);
    _outgoingSlide = _buildOutgoingSlide(_direction);
    _animCtrl.addStatusListener(_handleAnimationStatus);
  }

  Animation<Offset> _buildIncomingSlide(double direction) {
    // 轻柔短距分数位移配合 easeOutQuart 丝滑刹车到位，跳过逐帧 Widget 重建。
    final fractionalDx = (widget.incomingSlidePixels / 960.0).clamp(
      0.006,
      0.022,
    );
    return Tween<Offset>(
      begin: Offset(direction * fractionalDx, 0.0),
      end: Offset.zero,
    ).animate(_curved);
  }

  Animation<Offset> _buildOutgoingSlide(double direction) {
    final fractionalDx = (widget.outgoingSlidePixels / 960.0).clamp(
      0.004,
      0.018,
    );
    return Tween<Offset>(
      begin: Offset.zero,
      end: Offset(-direction * fractionalDx, 0.0),
    ).animate(_curved);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _animating) {
      if (mounted) {
        setState(() {
          _animating = false;
          _outgoingIndex = null;
          _evictIdleOffstageTabs(_now());
        });
      } else {
        _animating = false;
        _outgoingIndex = null;
      }
    }
  }

  void _initChildrenCache() {
    _mountedFlags = List<bool>.generate(
      widget.children.length,
      (i) => i == widget.activeIndex,
    );
    _lastDeactivatedAt = List<DateTime?>.filled(widget.children.length, null);
    _wrappedChildren = [
      for (var i = 0; i < widget.children.length; i++)
        RepaintBoundary(child: widget.children[i]),
    ];
  }

  bool _evictIdleOffstageTabs(DateTime now, {int? excludeIndex}) {
    final ttl = widget.idleEvictAfter;
    if (ttl == null) return false;
    var evictedAny = false;
    for (var i = 0; i < _mountedFlags.length; i++) {
      if (!_mountedFlags[i] ||
          i == widget.activeIndex ||
          i == excludeIndex ||
          widget.pinnedIndices.contains(i)) {
        continue;
      }
      final deactivatedAt = _lastDeactivatedAt[i];
      if (deactivatedAt != null && now.difference(deactivatedAt) >= ttl) {
        _mountedFlags[i] = false;
        _lastDeactivatedAt[i] = null;
        evictedAny = true;
      }
    }
    return evictedAny;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.resumed) {
      final changed = _evictIdleOffstageTabs(
        _now(),
        excludeIndex: _outgoingIndex,
      );
      if (changed) {
        setState(() {});
      }
    }
  }

  @override
  void didUpdateWidget(covariant KonataKeepAliveTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.children.length != widget.children.length) {
      final prevMounted = _mountedFlags;
      final prevDeactivated = _lastDeactivatedAt;
      _initChildrenCache();
      for (var i = 0; i < prevMounted.length && i < _mountedFlags.length; i++) {
        _mountedFlags[i] = _mountedFlags[i] || prevMounted[i];
        _lastDeactivatedAt[i] = prevDeactivated[i];
      }
    } else if (!identical(oldWidget.children, widget.children)) {
      _wrappedChildren = [
        for (var i = 0; i < widget.children.length; i++)
          RepaintBoundary(child: widget.children[i]),
      ];
    }

    if (oldWidget.activeIndex != widget.activeIndex) {
      final now = _now();
      if (oldWidget.activeIndex >= 0 &&
          oldWidget.activeIndex < _lastDeactivatedAt.length) {
        _lastDeactivatedAt[oldWidget.activeIndex] = now;
      }
      _mountedFlags[widget.activeIndex] = true;
      _lastDeactivatedAt[widget.activeIndex] = null;
      _direction = widget.activeIndex >= oldWidget.activeIndex ? 1.0 : -1.0;
      _incomingSlide = _buildIncomingSlide(_direction);
      _outgoingSlide = _buildOutgoingSlide(_direction);
      final disableAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (disableAnim || widget.duration == Duration.zero) {
        _animating = false;
        _outgoingIndex = null;
        _animCtrl.value = 1.0;
        _evictIdleOffstageTabs(now);
      } else {
        _animating = true;
        _outgoingIndex = oldWidget.activeIndex;
        _animCtrl.duration = widget.duration;
        _animCtrl.forward(from: 0.0);
        _evictIdleOffstageTabs(now, excludeIndex: _outgoingIndex);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animCtrl.removeStatusListener(_handleAnimationStatus);
    _incomingOpacity.dispose();
    _outgoingOpacityCurve.dispose();
    _curved.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scrimColor = widget.scrimFadeColor;
    final useScrimFade = scrimColor != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < _wrappedChildren.length; i++)
          if (_mountedFlags[i]) _buildSlot(i, useScrimFade: useScrimFade),
        if (useScrimFade && _animating)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _ScrimFadePainter(
                  animation: _curved,
                  color: scrimColor,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSlot(int index, {required bool useScrimFade}) {
    final isActive = index == widget.activeIndex;
    final isOutgoing = !useScrimFade && _animating && index == _outgoingIndex;
    final isVisible = isActive || isOutgoing;
    final animatingIn = isActive && _animating;

    // 保持固定槽位顺序与一致子树结构，防止子页面状态与滚动位置重建；
    // 实底画布模式免除全屏离屏合成层，透明桌面模式仅在 220ms 转场瞬态做前后页柔滑交叉淡入淡出，终态立即退回静息零开销。
    final Widget content;
    if (useScrimFade) {
      content = SlideTransition(
        position: animatingIn ? _incomingSlide : _kZeroOffsetAnimation,
        child: _wrappedChildren[index],
      );
    } else {
      final Animation<double> opacityAnim;
      final Animation<Offset> slideAnim;
      if (animatingIn) {
        opacityAnim = _incomingOpacity;
        slideAnim = _incomingSlide;
      } else if (isOutgoing) {
        opacityAnim = _outgoingOpacity;
        slideAnim = _outgoingSlide;
      } else {
        opacityAnim = kAlwaysCompleteAnimation;
        slideAnim = _kZeroOffsetAnimation;
      }
      content = FadeTransition(
        opacity: opacityAnim,
        child: SlideTransition(
          position: slideAnim,
          child: _wrappedChildren[index],
        ),
      );
    }
    return Offstage(
      key: ValueKey<int>(index),
      offstage: !isVisible,
      child: IgnorePointer(
        ignoring: !isActive,
        child: ExcludeFocus(
          excluding: !isActive,
          child: TickerMode(enabled: isActive, child: content),
        ),
      ),
    );
  }
}

/// 实底画布等价淡入绘制器：以单次矩形混色替代全屏 `OpacityLayer`，0 次 Widget 重建且 0 离屏纹理。
class _ScrimFadePainter extends CustomPainter {
  _ScrimFadePainter({required this.animation, required this.color})
    : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = ((1.0 - animation.value) * 0.72).clamp(0.0, 1.0);
    if (alpha <= 0.001) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_ScrimFadePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.animation != animation;
  }
}
