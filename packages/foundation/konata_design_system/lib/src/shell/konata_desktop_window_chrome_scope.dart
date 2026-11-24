import 'package:flutter/widgets.dart';

/// 桌面无框窗口控制三键构建函数签名。
typedef KonataWindowControlsBuilder =
    Widget Function({bool forceLightIcons, bool showGlassPill});

/// 桌面无框顶栏窗口拖拽区包裹函数签名。
typedef KonataWindowDragAreaBuilder = Widget Function({required Widget child});

/// 桌面无框窗口壳层能力注入作用域（零 Riverpod、零桌面原生插件依赖）。
///
/// 仅由 Windows 启动壳在应用根部注入真实 `WindowControls` 与拖拽区构建器；
/// Android 端不提供该作用域或保持回调为空，各沉浸子页可安全按需挂载桌面三键而不引入桌面依赖。
class KonataDesktopWindowChromeScope extends InheritedWidget {
  /// 创建桌面无框窗口壳层作用域。
  const KonataDesktopWindowChromeScope({
    super.key,
    required this.windowControlsBuilder,
    required this.dragToMoveBuilder,
    required super.child,
  });

  /// 无框窗口三键（最小化 / 最大化还原 / 关闭）构建回调。
  final KonataWindowControlsBuilder? windowControlsBuilder;

  /// 无框顶栏可拖拽区域包裹回调。
  final KonataWindowDragAreaBuilder? dragToMoveBuilder;

  /// 读取最近的桌面窗口壳层作用域（未注入时返回 `null`）。
  static KonataDesktopWindowChromeScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<KonataDesktopWindowChromeScope>();
  }

  /// 构建当前平台的无框窗口控制三键；非桌面端或未注入时返回 `null`。
  static Widget? buildWindowControls(
    BuildContext context, {
    bool forceLightIcons = false,
    bool showGlassPill = false,
  }) {
    final builder = maybeOf(context)?.windowControlsBuilder;
    if (builder == null) return null;
    return builder(
      forceLightIcons: forceLightIcons,
      showGlassPill: showGlassPill,
    );
  }

  /// 将目标组件包裹为桌面窗口拖拽移动区域；非桌面端或未注入时原样返回子组件。
  static Widget wrapDragToMove(
    BuildContext context, {
    required Widget child,
  }) {
    final builder = maybeOf(context)?.dragToMoveBuilder;
    if (builder == null) return child;
    return builder(child: child);
  }

  @override
  bool updateShouldNotify(covariant KonataDesktopWindowChromeScope oldWidget) {
    return windowControlsBuilder != oldWidget.windowControlsBuilder ||
        dragToMoveBuilder != oldWidget.dragToMoveBuilder;
  }
}
