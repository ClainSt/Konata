import 'package:flutter/widgets.dart';

/// 由外壳层向页面子树透传主导航胶囊与悬浮小窗统一底部避让高度的纯 Flutter 作用域。
class KonataBottomClearanceScope extends InheritedWidget {
  /// 创建底部安全避让高度作用域。
  const KonataBottomClearanceScope({
    super.key,
    required this.bottomClearance,
    required super.child,
  });

  /// 当前生效的底部防遮挡避让高度（逻辑像素）。
  final double bottomClearance;

  /// 读取祖先节点透传的底部避让高度（未包覆时返回 `null`）。
  static double? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<KonataBottomClearanceScope>()
        ?.bottomClearance;
  }

  /// 读取祖先节点透传的底部避让高度（未包覆时安全回退为 `0.0`）。
  static double of(BuildContext context) => maybeOf(context) ?? 0.0;

  @override
  bool updateShouldNotify(KonataBottomClearanceScope oldWidget) {
    return (bottomClearance - oldWidget.bottomClearance).abs() > 0.25;
  }
}
