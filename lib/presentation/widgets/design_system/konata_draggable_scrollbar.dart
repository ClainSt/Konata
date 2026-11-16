import 'package:flutter/material.dart';

/// 显式绑定独立生命周期 `ScrollController` 的桌面端可拖拽滚动条容器。
///
/// 将 [Scrollbar] 置于最外层并与内部的 `ListView` / `GridView` / `CustomScrollView`
/// 共享同一个非 `Primary` 的 `ScrollController`，确保弹窗、分栏与标签切换场景下
/// 均可稳定响应鼠标左键长按拖拽、悬停加粗与点击轨道跳转。
class KonataDraggableScrollbar extends StatefulWidget {
  /// 创建可拖拽滚动条包裹组件。
  const KonataDraggableScrollbar({
    super.key,
    required this.builder,
    this.controller,
    this.thumbVisibility = true,
    this.trackVisibility = false,
    this.padding,
  });

  /// 接收已绑定的 [ScrollController] 并构建内部可滚动视图。
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  /// 可选外部传入的控制器；未传入时由组件内部创建并自动销毁。
  final ScrollController? controller;

  /// 是否常驻展示滚动滑块。
  final bool thumbVisibility;

  /// 是否始终显示轨道底槽。
  final bool trackVisibility;

  /// 滚动条轨道相对外缘的内边距。
  final EdgeInsetsGeometry? padding;

  @override
  State<KonataDraggableScrollbar> createState() =>
      _KonataDraggableScrollbarState();
}

class _KonataDraggableScrollbarState extends State<KonataDraggableScrollbar> {
  ScrollController? _ownedController;

  ScrollController get _effectiveController =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = ScrollController();
    }
  }

  @override
  void didUpdateWidget(covariant KonataDraggableScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == null && widget.controller != null) {
      _ownedController?.dispose();
      _ownedController = null;
    } else if (oldWidget.controller != null && widget.controller == null) {
      _ownedController ??= ScrollController();
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    _ownedController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _effectiveController;
    return Scrollbar(
      controller: controller,
      thumbVisibility: widget.thumbVisibility,
      trackVisibility: widget.trackVisibility,
      interactive: true,
      scrollbarOrientation: ScrollbarOrientation.right,
      child: widget.padding != null
          ? Padding(
              padding: widget.padding!,
              child: widget.builder(context, controller),
            )
          : widget.builder(context, controller),
    );
  }
}
