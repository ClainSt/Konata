import 'dart:async';
import 'dart:collection';

import 'package:material_ui/material_ui.dart';

/// 模态路由层级注册表（纯 Flutter 实现，驱动悬浮小窗始终处于弹窗遮罩之下）。
class KonataModalLayerRegistry extends ChangeNotifier {
  /// 创建模态路由层级注册表。
  KonataModalLayerRegistry();

  final LinkedHashSet<OverlayRoute<dynamic>> _modalRoutes =
      LinkedHashSet<OverlayRoute<dynamic>>();
  bool _disposed = false;

  /// 当前已登记且仍处于挂载态的模态路由列表。
  List<OverlayRoute<dynamic>> routesFor(NavigatorState navigator) {
    if (_disposed) return const <OverlayRoute<dynamic>>[];
    return _modalRoutes
        .where((r) => r.navigator == navigator && r.overlayEntries.isNotEmpty)
        .toList(growable: false);
  }

  /// 登记一个活跃模态路由，并在其进退场动画状态跃迁与结束时同步层级。
  void registerRoute(OverlayRoute<dynamic> route) {
    if (_disposed) return;
    if (_modalRoutes.add(route)) {
      notifyListeners();
      if (route is TransitionRoute<dynamic>) {
        void onAnimStatus(AnimationStatus status) {
          if (_disposed) return;
          if (status == AnimationStatus.dismissed) {
            route.animation?.removeStatusListener(onAnimStatus);
            unregisterRoute(route);
            return;
          }
          if (status == AnimationStatus.completed ||
              status == AnimationStatus.reverse) {
            notifyListeners();
          }
        }

        route.animation?.addStatusListener(onAnimStatus);
        unawaited(
          route.completed.whenComplete(() {
            route.animation?.removeStatusListener(onAnimStatus);
            unregisterRoute(route);
          }),
        );
      }
    }
  }

  /// 注销一个已结束的模态路由。
  void unregisterRoute(OverlayRoute<dynamic> route) {
    if (_disposed) return;
    if (_modalRoutes.remove(route)) {
      notifyListeners();
    }
  }

  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_disposed) return;
    super.removeListener(listener);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _modalRoutes.clear();
    super.dispose();
  }
}

/// 向子树提供 [KonataModalLayerRegistry] 的纯 Flutter 作用域（0 Riverpod 依赖）。
class KonataModalLayerScope extends InheritedWidget {
  /// 创建模态层级注册表作用域。
  const KonataModalLayerScope({
    super.key,
    required this.registry,
    required super.child,
  });

  /// 模态层级资源供路由访问，层级监听由悬浮窗直接管理。
  final KonataModalLayerRegistry registry;

  /// 读取最近的 [KonataModalLayerRegistry]（无订阅副作用，未挂载时返回 `null`）。
  static KonataModalLayerRegistry? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<KonataModalLayerScope>()
        ?.registry;
  }

  @override
  bool updateShouldNotify(KonataModalLayerScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}

/// 在弹窗、底部抽屉与弹出菜单根节点自动向 [KonataModalLayerRegistry] 登记所属 `ModalRoute` 的轻量作用域。
class KonataModalRouteScope extends StatefulWidget {
  /// 创建模态路由层级登记作用域。
  const KonataModalRouteScope({super.key, required this.child});

  /// 被包裹的模态内容子树。
  final Widget child;

  @override
  State<KonataModalRouteScope> createState() => _KonataModalRouteScopeState();
}

class _KonataModalRouteScopeState extends State<KonataModalRouteScope> {
  ModalRoute<dynamic>? _registeredRoute;
  KonataModalLayerRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final modalRoute = ModalRoute.of(context);
    if (modalRoute != null &&
        modalRoute is! PageRoute &&
        !identical(modalRoute, _registeredRoute)) {
      final registry = KonataModalLayerScope.maybeOf(context);
      _registeredRoute = modalRoute;
      _registry = registry;
      registry?.registerRoute(modalRoute);
    }
  }

  @override
  void dispose() {
    final route = _registeredRoute;
    final registry = _registry;
    _registeredRoute = null;
    _registry = null;
    if (route != null && !route.isActive) {
      registry?.unregisterRoute(route);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 根 `Navigator` 路由栈观察器：追踪页面路由与模态弹窗路由栈序，驱动悬浮小窗始终处于模态遮罩之下。
class KonataRootRouteObserver extends NavigatorObserver {
  /// 创建根路由观察器。
  KonataRootRouteObserver(this._onSubRouteChanged);

  final ValueChanged<bool> _onSubRouteChanged;
  final List<Route<dynamic>> _activeRoutes = <Route<dynamic>>[];
  final LinkedHashSet<Route<dynamic>> _exitingModalRoutes =
      LinkedHashSet<Route<dynamic>>();
  final List<VoidCallback> _stackListeners = <VoidCallback>[];
  int _nonRootPageCount = 0;

  /// 当前根路由栈上有序的 `PageRoute` 列表。
  List<Route<dynamic>> get pageRoutes =>
      _activeRoutes.whereType<PageRoute<dynamic>>().toList(growable: false);

  /// 当前根路由栈上有序的非页面模态路由列表（含退场动画期间尚未卸载遮罩的弹窗路由）。
  List<Route<dynamic>> get modalRoutes {
    final result = <Route<dynamic>>[];
    for (final r in _activeRoutes) {
      if (r is! PageRoute) {
        result.add(r);
      }
    }
    for (final r in _exitingModalRoutes) {
      final stillAnimatingOut =
          r is TransitionRoute<dynamic> && r.animation?.isDismissed == false;
      if (stillAnimatingOut && !result.contains(r)) {
        result.add(r);
      }
    }
    return result;
  }

  /// 订阅路由栈顺序变更（用于在微任务中重排 `OverlayEntry` 层级）。
  void addStackListener(VoidCallback listener) {
    if (!_stackListeners.contains(listener)) {
      _stackListeners.add(listener);
    }
  }

  /// 取消订阅路由栈顺序变更。
  void removeStackListener(VoidCallback listener) {
    _stackListeners.remove(listener);
  }

  bool _isFullPageSubRoute(Route<dynamic>? route) {
    if (route == null || route.isFirst) return false;
    return route is PageRoute;
  }

  void _notifyStackListeners() {
    if (_stackListeners.isEmpty) return;
    for (final listener in List<VoidCallback>.of(_stackListeners)) {
      listener();
    }
  }

  void _attachTransitionSync(Route<dynamic> route) {
    if (route is! TransitionRoute<dynamic>) return;
    void onAnimStatus(AnimationStatus status) {
      if (status == AnimationStatus.dismissed) {
        route.animation?.removeStatusListener(onAnimStatus);
        _exitingModalRoutes.remove(route);
        _notifyStackListeners();
        return;
      }
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.reverse) {
        _notifyStackListeners();
      }
    }

    route.animation?.addStatusListener(onAnimStatus);
    unawaited(
      route.completed.whenComplete(() {
        route.animation?.removeStatusListener(onAnimStatus);
        _exitingModalRoutes.remove(route);
      }),
    );
  }

  void _notifySubRouteChanged() {
    final active = _nonRootPageCount > 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onSubRouteChanged(active);
    });
  }

  void _trackExitingModal(Route<dynamic> route) {
    if (route is PageRoute) return;
    if (route is TransitionRoute<dynamic>) {
      _exitingModalRoutes.add(route);
      unawaited(
        route.completed.whenComplete(() {
          if (_exitingModalRoutes.remove(route)) {
            _notifyStackListeners();
          }
        }),
      );
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _exitingModalRoutes.remove(route);
    if (!_activeRoutes.contains(route)) {
      _activeRoutes.add(route);
      _attachTransitionSync(route);
    }
    if (_isFullPageSubRoute(route)) {
      _nonRootPageCount++;
      _notifySubRouteChanged();
    }
    _notifyStackListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _activeRoutes.remove(route);
    _trackExitingModal(route);
    if (_isFullPageSubRoute(route) && _nonRootPageCount > 0) {
      _nonRootPageCount--;
      _notifySubRouteChanged();
    }
    _notifyStackListeners();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _activeRoutes.remove(route);
    _exitingModalRoutes.remove(route);
    if (_isFullPageSubRoute(route) && _nonRootPageCount > 0) {
      _nonRootPageCount--;
      _notifySubRouteChanged();
    }
    _notifyStackListeners();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute != null) {
      final idx = _activeRoutes.indexOf(oldRoute);
      if (idx >= 0 && newRoute != null) {
        _activeRoutes[idx] = newRoute;
        _attachTransitionSync(newRoute);
      } else {
        _activeRoutes.remove(oldRoute);
        if (newRoute != null && !_activeRoutes.contains(newRoute)) {
          _activeRoutes.add(newRoute);
          _attachTransitionSync(newRoute);
        }
      }
      _exitingModalRoutes.remove(oldRoute);
    } else if (newRoute != null && !_activeRoutes.contains(newRoute)) {
      _activeRoutes.add(newRoute);
      _attachTransitionSync(newRoute);
    }
    final oldSub = _isFullPageSubRoute(oldRoute);
    final newSub = _isFullPageSubRoute(newRoute);
    if (oldSub && !newSub && _nonRootPageCount > 0) {
      _nonRootPageCount--;
      _notifySubRouteChanged();
    } else if (!oldSub && newSub) {
      _nonRootPageCount++;
      _notifySubRouteChanged();
    }
    _notifyStackListeners();
  }
}
