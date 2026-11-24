import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../composition/platform_composition.dart';

/// 跨端自适应毛玻璃滤镜容器。
///
/// 职责与优化策略：
/// - 当祖先存在 [BackdropGroup] 且 [grouped] 为 `true` 时，自动切换为 `BackdropFilter.grouped`
///   使同屏多个悬浮胶囊共享单次 GPU 背景采样，显著降低离屏 FBO 拷贝开销；
/// - 在 Windows 实时拖动窗口边框（`windowLiveResizingProvider == true`）期间，
///   通过 `BackdropFilter(enabled: false)` 原地挂起离屏模糊并完整保留子树状态与装饰层，
///   松手后首帧无感恢复完整毛玻璃质感；
/// - 兼容未包裹 `ProviderScope` 的孤立组件单元测试环境，零异常回退至常规模糊渲染。
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
    final hasScope =
        context.findAncestorWidgetOfExactType<UncontrolledProviderScope>() !=
        null;
    if (!hasScope) {
      return _buildFilter(context, active: true);
    }
    return _ScopedAdaptiveBackdropBlur(
      filter: filter,
      grouped: grouped,
      child: child,
    );
  }

  Widget _buildFilter(BuildContext context, {required bool active}) {
    if (grouped && BackdropGroup.of(context) != null) {
      return BackdropFilter.grouped(
        filter: filter,
        enabled: active,
        child: child,
      );
    }
    return BackdropFilter(
      filter: filter,
      enabled: active,
      child: child,
    );
  }
}

class _ScopedAdaptiveBackdropBlur extends ConsumerWidget {
  const _ScopedAdaptiveBackdropBlur({
    required this.filter,
    required this.grouped,
    required this.child,
  });

  final ui.ImageFilter filter;
  final bool grouped;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resizing = ref.watch(windowLiveResizingProvider);
    final active = !resizing;
    if (grouped && BackdropGroup.of(context) != null) {
      return BackdropFilter.grouped(
        filter: filter,
        enabled: active,
        child: child,
      );
    }
    return BackdropFilter(
      filter: filter,
      enabled: active,
      child: child,
    );
  }
}
