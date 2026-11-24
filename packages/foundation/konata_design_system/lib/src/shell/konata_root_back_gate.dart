import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/konata_adaptive_tokens.dart';

/// 挂载于 `MaterialApp` 之上的全屏播放系统返回键高优先级拦截门控（零 Riverpod 依赖）。
///
/// 在 `_WidgetsAppState` 之前注册 `WidgetsBindingObserver`，确保全屏音视频叠加于子页面之上时，
/// Android 系统返回键优先收起或退出全屏播放层而非静默弹出底层路由。
class KonataRootBackGate extends StatefulWidget {
  /// 创建根级全屏播放返回门控。
  const KonataRootBackGate({
    super.key,
    required this.fullscreenMediaActive,
    required this.onInterceptBack,
    required this.canPopRootNavigator,
    required this.child,
  });

  /// 当前是否存在活跃的全屏音视频叠加层。
  final ValueListenable<bool> fullscreenMediaActive;

  /// 系统触发返回键时的拦截回调（返回 `true` 表示已消费，不再透传给底层路由）。
  final Future<bool> Function() onInterceptBack;

  /// 判断根路由栈是否仍可回退（用于在关闭全屏媒体后正确同步 Android 预测返回状态）。
  final bool Function() canPopRootNavigator;

  /// 被包裹的根应用子树（通常为 `MaterialApp`）。
  final Widget child;

  @override
  State<KonataRootBackGate> createState() => _KonataRootBackGateState();
}

class _KonataRootBackGateState extends State<KonataRootBackGate>
    with WidgetsBindingObserver {
  bool _lastFullscreenActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.fullscreenMediaActive.addListener(_handleActiveChanged);
    _lastFullscreenActive = widget.fullscreenMediaActive.value;
    if (_lastFullscreenActive) {
      _syncBackRegistration(true);
    }
  }

  @override
  void didUpdateWidget(covariant KonataRootBackGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fullscreenMediaActive != widget.fullscreenMediaActive) {
      oldWidget.fullscreenMediaActive.removeListener(_handleActiveChanged);
      widget.fullscreenMediaActive.addListener(_handleActiveChanged);
      _handleActiveChanged();
    }
  }

  @override
  void dispose() {
    widget.fullscreenMediaActive.removeListener(_handleActiveChanged);
    if (KonataAdaptiveTokens.isAndroid && _lastFullscreenActive) {
      unawaited(SystemNavigator.setFrameworkHandlesBack(false));
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _handleActiveChanged() {
    final active = widget.fullscreenMediaActive.value;
    if (active == _lastFullscreenActive) return;
    _lastFullscreenActive = active;
    _syncBackRegistration(active);
  }

  void _syncBackRegistration(bool active) {
    if (!KonataAdaptiveTokens.isAndroid) return;
    if (active) {
      unawaited(SystemNavigator.setFrameworkHandlesBack(true));
      return;
    }
    if (!widget.canPopRootNavigator()) {
      unawaited(SystemNavigator.setFrameworkHandlesBack(false));
    }
  }

  @override
  Future<bool> didPopRoute() {
    if (!mounted) return Future<bool>.value(false);
    return widget.onInterceptBack();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
