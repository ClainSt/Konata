import 'package:flutter/material.dart';

import '../../theme/konata_theme.dart';

/// 顶栏四主页面共用的「首次访问懒加载 + 常驻保活 + 方向感轻量切换」容器。
///
/// 特性：
/// - 闲置页面保持挂载以 100% 保留滚动位置与状态，同时自动施加
///   `Offstage` + `TickerMode(enabled: false)` + `IgnorePointer` + `ExcludeFocus` 零绘制休眠；
/// - 切换页签时按方向执行 `220ms` `Curves.easeOutCubic` 滑入淡入与微移淡出，
///   支持中途连点无缝接力，静息态不挂载动画监听与额外离屏合成层。
class KonataKeepAliveTabSwitcher extends StatefulWidget {
  /// 创建保状态方向感页面切换容器。
  const KonataKeepAliveTabSwitcher({
    super.key,
    required this.activeIndex,
    required this.children,
    this.duration = KonataTheme.tabSwitchDuration,
    this.incomingSlidePixels = 16.0,
    this.outgoingSlidePixels = 10.0,
  });

  /// 当前激活页面索引。
  final int activeIndex;

  /// 常驻子页面列表（每个子页面内部由固定 [RepaintBoundary] 隔离重绘）。
  final List<Widget> children;

  /// 转场动画时长。
  final Duration duration;

  /// 新页面滑入起始水平像素偏移量。
  final double incomingSlidePixels;

  /// 旧页面淡出终止水平像素偏移量。
  final double outgoingSlidePixels;

  @override
  State<KonataKeepAliveTabSwitcher> createState() =>
      _KonataKeepAliveTabSwitcherState();
}

class _KonataKeepAliveTabSwitcherState
    extends State<KonataKeepAliveTabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final Animation<double> _curved;
  late List<bool> _mountedFlags;
  late List<Widget> _wrappedChildren;
  int? _leavingIndex;
  double _direction = 1.0;

  @override
  void initState() {
    super.initState();
    _initChildrenCache();
    _animCtrl = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1.0,
    );
    _curved = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOutCubic,
    );
    _animCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && _leavingIndex != null) {
        if (mounted) {
          setState(() => _leavingIndex = null);
        } else {
          _leavingIndex = null;
        }
      }
    });
  }

  void _initChildrenCache() {
    _mountedFlags = List<bool>.generate(
      widget.children.length,
      (i) => i == widget.activeIndex,
    );
    _wrappedChildren = [
      for (var i = 0; i < widget.children.length; i++)
        RepaintBoundary(child: widget.children[i]),
    ];
  }

  @override
  void didUpdateWidget(covariant KonataKeepAliveTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.children.length != widget.children.length) {
      final prevMounted = _mountedFlags;
      _initChildrenCache();
      for (var i = 0; i < prevMounted.length && i < _mountedFlags.length; i++) {
        _mountedFlags[i] = _mountedFlags[i] || prevMounted[i];
      }
    } else if (!identical(oldWidget.children, widget.children)) {
      _wrappedChildren = [
        for (var i = 0; i < widget.children.length; i++)
          RepaintBoundary(child: widget.children[i]),
      ];
    }

    if (oldWidget.activeIndex != widget.activeIndex) {
      _mountedFlags[widget.activeIndex] = true;
      _direction = widget.activeIndex >= oldWidget.activeIndex ? 1.0 : -1.0;
      final disableAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (disableAnim || widget.duration == Duration.zero) {
        _leavingIndex = null;
        _animCtrl.value = 1.0;
      } else {
        _leavingIndex = oldWidget.activeIndex;
        _animCtrl.duration = widget.duration;
        _animCtrl.forward(from: 0.0);
      }
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < _wrappedChildren.length; i++)
          if (_mountedFlags[i]) _buildSlot(i),
      ],
    );
  }

  Widget _buildSlot(int index) {
    final isActive = index == widget.activeIndex;
    final isLeaving = index == _leavingIndex;
    final visible = isActive || isLeaving;
    final animating = visible && _leavingIndex != null;

    // 保持 Widget 树层级结构在进场、退场与静息态完全一致，防止 Opacity/Transform
    // 增删拆装子树导致子页面 State 与列表 ScrollPosition 被意外销毁重建。
    return Offstage(
      offstage: !visible,
      child: IgnorePointer(
        ignoring: !isActive,
        child: ExcludeFocus(
          excluding: !isActive,
          child: TickerMode(
            enabled: isActive,
            child: AnimatedBuilder(
              animation: animating ? _curved : kAlwaysCompleteAnimation,
              child: _wrappedChildren[index],
              builder: (_, child) {
                var opacity = 1.0;
                var dx = 0.0;
                if (isActive && _leavingIndex != null) {
                  final t = _curved.value.clamp(0.0, 1.0);
                  opacity = t;
                  dx = _direction * widget.incomingSlidePixels * (1.0 - t);
                } else if (isLeaving) {
                  final t = _curved.value.clamp(0.0, 1.0);
                  opacity = 1.0 - t;
                  dx = -_direction * widget.outgoingSlidePixels * t;
                }
                return Opacity(
                  opacity: opacity,
                  child: Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
