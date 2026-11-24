import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Konata 全局多端滚动行为：支持多指针拖拽并禁用隐式默认滚动条，
/// 确保全站滚动视图统一由显式绑定独立 `ScrollController` 的 `KonataDraggableScrollbar` 托管。
class KonataScrollBehavior extends MaterialScrollBehavior {
  /// 创建 Konata 全局滚动行为。
  const KonataScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
