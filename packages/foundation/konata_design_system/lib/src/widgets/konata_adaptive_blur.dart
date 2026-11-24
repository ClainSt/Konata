import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// 向设计系统子树广播「Windows 实时拖拽窗口缩放态」的零 Riverpod 作用域。
///
/// 宿主壳层将原生 `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` 状态写入 [resizingListenable]，
/// 使所有 [KonataAdaptiveBackdropBlur] 在缩放期间原地挂起离屏模糊、松手首帧无感恢复。
class KonataWindowResizeScope extends InheritedWidget {
  /// 创建窗口实时缩放状态作用域。
  const KonataWindowResizeScope({
    super.key,
    required this.resizingListenable,
    required super.child,
  });

  /// 当前是否正处于实时拖拽窗口边框缩放状态。
  final ValueListenable<bool> resizingListenable;

  /// 查找祖先提供的缩放态通知器（未挂载作用域时返回 `null`）。
  static ValueListenable<bool>? maybeListenableOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<KonataWindowResizeScope>()
        ?.resizingListenable;
  }

  @override
  bool updateShouldNotify(KonataWindowResizeScope oldWidget) =>
      !identical(resizingListenable, oldWidget.resizingListenable);
}

/// 跨端自适应毛玻璃滤镜容器（严格 0 Riverpod 依赖）。
///
/// 职责与优化策略：
/// - 当祖先存在 [BackdropGroup] 且 [grouped] 为 `true` 时，自动切换为 `BackdropFilter.grouped`
///   使同屏多个悬浮胶囊共享单次 GPU 背景采样；
/// - 当祖先 [KonataWindowResizeScope] 指示正在实时缩放窗口时，
///   通过 `BackdropFilter(enabled: false)` 原地挂起离屏模糊并完整保留子树状态与装饰层，
///   松手后首帧无感恢复完整毛玻璃质感。
class KonataAdaptiveBackdropBlur extends StatelessWidget {
  /// 创建自适应毛玻璃滤镜容器。
  const KonataAdaptiveBackdropBlur({
    super.key,
    required this.filter,
    required this.child,
    this.enabled = true,
    this.grouped = true,
  });

  /// 高斯模糊滤镜令牌（须来自 [KonataTheme] 具名常量）。
  final ui.ImageFilter filter;

  /// 内部前景内容。
  final Widget child;

  /// 是否启用实时毛玻璃模糊。
  final bool enabled;

  /// 祖先存在 [BackdropGroup] 时是否复用同组共享背景采样。
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    final resizingListenable = KonataWindowResizeScope.maybeListenableOf(
      context,
    );
    if (resizingListenable == null) {
      return _buildFilter(context, active: true);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: resizingListenable,
      child: child,
      builder: (context, resizing, stableChild) {
        return _buildFilter(context, active: !resizing, overrideChild: stableChild);
      },
    );
  }

  Widget _buildFilter(
    BuildContext context, {
    required bool active,
    Widget? overrideChild,
  }) {
    final targetChild = overrideChild ?? child;
    if (grouped && BackdropGroup.of(context) != null) {
      return BackdropFilter.grouped(
        filter: filter,
        enabled: active,
        child: targetChild,
      );
    }
    return BackdropFilter(
      filter: filter,
      enabled: active,
      child: targetChild,
    );
  }
}
