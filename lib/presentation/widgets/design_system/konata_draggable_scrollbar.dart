import 'package:material_ui/material_ui.dart';

/// 显式绑定独立生命周期 `ScrollController` 的桌面端可拖拽滚动条容器。
class KonataDraggableScrollbar extends StatefulWidget {
  /// 创建可拖拽滚动条包裹组件。
  const KonataDraggableScrollbar({
    super.key,
    required this.builder,
    this.controller,
    this.thumbVisibility = true,
    this.trackVisibility = false,
    this.padding,
    this.trackInsets,
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

  /// 内容容器相对外缘的内边距。
  final EdgeInsetsGeometry? padding;

  /// 滚动条轨道自身的上下左右缩进（用于与带渐隐内边距的列表正文首尾严格对齐）。
  final EdgeInsets? trackInsets;

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
    final inner = widget.padding != null
        ? Padding(
            padding: widget.padding!,
            child: widget.builder(context, controller),
          )
        : widget.builder(context, controller);

    Widget bar = Scrollbar(
      controller: controller,
      thumbVisibility: widget.thumbVisibility,
      trackVisibility: widget.trackVisibility,
      interactive: true,
      scrollbarOrientation: ScrollbarOrientation.right,
      child: inner,
    );

    if (widget.trackInsets != null) {
      final mq = MediaQuery.of(context);
      bar = MediaQuery(
        data: mq.copyWith(padding: widget.trackInsets!),
        child: bar,
      );
    }
    return bar;
  }
}
