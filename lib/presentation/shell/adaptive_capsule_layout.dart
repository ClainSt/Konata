import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/konata_value_notifier.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_playback_tokens.dart';

/// 二级设置路由进入时隐藏主导航，退出时恢复。
final capsuleNavigationHiddenProvider =
    NotifierProvider<KonataValueNotifier<bool>, bool>(
      () => KonataValueNotifier<bool>.value(false),
    );

/// 根路由栈是否存在推入的二级全屏页面（如作品详情页），存在时隐藏主导航胶囊。
final subRoutePushedProvider =
    NotifierProvider<KonataValueNotifier<bool>, bool>(
      () => KonataValueNotifier<bool>.value(false),
    );

/// 可拖拽音视频悬浮小窗内容形态枚举。
enum FloatingMiniPlayerKind {
  /// 无活跃迷你小窗。
  none,

  /// 动态原比例无黑边视频实时小窗。
  video,

  /// 极简圆形光环 / 展开播控条 / 贴边耳片三态音频小窗。
  audio,
}

/// 悬浮小窗的视觉展开形态（收起态 / 展开播控条 / 贴边耳片隐藏态）。
enum FloatingMiniVisualState {
  /// 默认收起态（音频为 `56×56dp` 圆形封面光环，视频为动态原比例实时画面）。
  collapsed,

  /// 音频展开态（`320×60dp` 光学毛玻璃迷你播控条，点击外部或 `–` 收回圆钮）。
  expanded,

  /// 贴边耳片隐藏态（`24×72dp` 半透明侧边耳片，点击回弹恢复；视频贴边时暂停并释放硬件挖空）。
  tucked,
}

/// 悬浮小窗贴边吸附或耳片收折所在侧边。
enum FloatingMiniEdgeSide {
  /// 视口左侧边缘。
  left,

  /// 视口右侧边缘。
  right,
}

/// 悬浮小窗松手吸附后的归一化停靠锚点（`null` 表示默认右下角合法锚点；拖拽过程不写此状态以避免整页重建）。
final floatingMiniWindowAnchorProvider =
    NotifierProvider<KonataValueNotifier<Offset?>, Offset?>(
      () => KonataValueNotifier<Offset?>.value(null),
    );

/// 悬浮小窗当前视觉展开形态（收起圆钮 / 展开胶囊 / 贴边耳片）。
final floatingMiniVisualStateProvider =
    NotifierProvider<
      KonataValueNotifier<FloatingMiniVisualState>,
      FloatingMiniVisualState
    >(
      () => KonataValueNotifier<FloatingMiniVisualState>.value(
        FloatingMiniVisualState.collapsed,
      ),
    );

/// 悬浮小窗最近停靠或贴边收折的侧边方向。
final floatingMiniEdgeSideProvider =
    NotifierProvider<
      KonataValueNotifier<FloatingMiniEdgeSide>,
      FloatingMiniEdgeSide
    >(
      () => KonataValueNotifier<FloatingMiniEdgeSide>.value(
        FloatingMiniEdgeSide.right,
      ),
    );

/// 模态路由层级注册表（由 Riverpod 托管生命周期，兼容未显式挂载 `KonataRootRouteObserver` 的组件测试场景）。
class KonataModalLayerRegistry extends ChangeNotifier {
  /// 创建模态路由层级注册表。
  KonataModalLayerRegistry();

  final LinkedHashSet<OverlayRoute<dynamic>> _modalRoutes =
      LinkedHashSet<OverlayRoute<dynamic>>();
  bool _disposed = false;

  /// 当前已登记且仍处于挂载态的模态路由列表。
  List<OverlayRoute<dynamic>> routesFor(NavigatorState navigator) {
    if (_disposed) return const [];
    return _modalRoutes
        .where((r) => r.navigator == navigator && r.overlayEntries.isNotEmpty)
        .toList(growable: false);
  }

  /// 登记一个活跃模态路由，并在其进退场动画状态跃迁与彻底结束时同步层级。
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

/// 全局模态路由层级注册表 Provider。
final konataModalLayerRegistryProvider = Provider<KonataModalLayerRegistry>((
  ref,
) {
  final registry = KonataModalLayerRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});

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
      KonataModalLayerRegistry? registry;
      try {
        registry = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(konataModalLayerRegistryProvider);
      } on StateError {
        // 无 ProviderScope 的独立纯 Widget 单测场景下跳过全局模态层登记。
        registry = null;
      }
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

/// 根导航观察器 Provider。
final rootRouteObserverProvider = Provider<KonataRootRouteObserver>((ref) {
  return KonataRootRouteObserver((hasSubRoute) {
    ref.read(subRoutePushedProvider.notifier).state = hasSubRoute;
  });
});

/// 外壳唯一几何入口：统一计算主导航胶囊、悬浮小窗合法边界/吸附点与页面底部避让高度。
class AdaptiveCapsuleLayout {
  /// 创建自适应外壳与悬浮小窗几何计算器。
  AdaptiveCapsuleLayout({
    required this.size,
    required this.safe,
    required this.android,
    this.navigationVisible = true,
    this.desktopTopBarVisible = false,
    this.miniKind = FloatingMiniPlayerKind.none,
    this.normalizedMiniAnchor,
    this.visualState = FloatingMiniVisualState.collapsed,
    this.edgeSide = FloatingMiniEdgeSide.right,
    this.videoAspectRatio,
  });

  /// 当前视口尺寸。
  final Size size;

  /// 系统安全区边距（逐边取 `padding` 与 `viewPadding` 较大值）。
  final EdgeInsets safe;

  /// 是否处于 Android 触屏模式。
  final bool android;

  /// 主导航胶囊当前是否可见（详情页与设置二级页为 `false`）。
  final bool navigationVisible;

  /// Windows 桌面端主壳层顶栏是否可见（主壳层为 `true`，详情页子路由为 `false`）。
  final bool desktopTopBarVisible;

  /// 当前活跃悬浮小窗类型。
  final FloatingMiniPlayerKind miniKind;

  /// 用户上次拖拽松手后的归一化停靠锚点（`null` 时取右下角默认合法位置）。
  final Offset? normalizedMiniAnchor;

  /// 悬浮小窗当前视觉展开形态。
  final FloatingMiniVisualState visualState;

  /// 悬浮小窗停靠或贴边收折方向。
  final FloatingMiniEdgeSide edgeSide;

  /// 当前视频真实画面宽高比（用于无黑边动态尺寸计算；未知时回退 `16:9`）。
  final double? videoAspectRatio;

  /// 提取不受内层组件消费影响的系统真实安全区（逐边取 `padding` 与 `viewPadding` 较大值）。
  static EdgeInsets effectiveSafeInsetsOf(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final viewPad = MediaQuery.viewPaddingOf(context);
    return EdgeInsets.fromLTRB(
      math.max(pad.left, viewPad.left),
      math.max(pad.top, viewPad.top),
      math.max(pad.right, viewPad.right),
      math.max(pad.bottom, viewPad.bottom),
    );
  }

  /// 是否为平板视口（`shortestSide >= 600dp`）。
  bool get tablet =>
      android && size.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint;

  /// 是否为手机矮横屏视口（`height < 500dp`）。
  bool get shortPhone =>
      android &&
      !tablet &&
      size.height < KonataAdaptiveTokens.shortViewportHeight;

  /// 是否使用左侧垂直居中导航胶囊（仅平板模式启用；手机横竖屏统一采用底部水平居中胶囊）。
  bool get verticalNavigation => tablet;

  /// 导航胶囊短边厚度。
  double get navigationThickness => verticalNavigation
      ? (KonataAdaptiveTokens.tabletNavItemSize +
            KonataAdaptiveTokens.tabletNavPadding * 2)
      : (KonataAdaptiveTokens.touchTarget +
            KonataAdaptiveTokens.navigationPadding * 2);

  /// 导航胶囊长边长度。
  double get navigationLength => verticalNavigation
      ? (KonataAdaptiveTokens.tabletNavItemSize * 4 +
            KonataAdaptiveTokens.tabletNavItemGap * 3 +
            KonataAdaptiveTokens.tabletNavPadding * 2)
      : (KonataAdaptiveTokens.touchTarget * 4 +
            KonataAdaptiveTokens.navigationPadding * 2);

  /// 手机一级主页面是否启用「底部导航胶囊 + 右侧 56dp 圆形音频圆钮」同行水平居中并排协同。
  bool get inlinePhoneAudioPaired =>
      android &&
      !tablet &&
      navigationVisible &&
      miniKind == FloatingMiniPlayerKind.audio &&
      visualState != FloatingMiniVisualState.tucked &&
      (size.width - safe.horizontal) >=
          (navigationLength +
              KonataPlaybackTokens.floatingMiniPhoneNavInlineGap +
              KonataPlaybackTokens.floatingMiniAudioDiscSize +
              16.0);

  /// 左侧工作区避让宽度。
  double get leftClearance => verticalNavigation && navigationVisible
      ? (KonataAdaptiveTokens.tabletNavEdgeGap +
            navigationThickness +
            KonataAdaptiveTokens.safeGap)
      : 0;

  /// 主导航胶囊在屏幕中的定位矩形。
  Rect get navigationRect {
    if (verticalNavigation) {
      return Rect.fromLTWH(
        safe.left + KonataAdaptiveTokens.tabletNavEdgeGap,
        safe.top + (size.height - safe.vertical - navigationLength) / 2,
        navigationThickness,
        navigationLength,
      );
    }
    final top =
        size.height -
        safe.bottom -
        KonataAdaptiveTokens.safeGap -
        navigationThickness;
    if (inlinePhoneAudioPaired) {
      final groupWidth =
          navigationLength +
          KonataPlaybackTokens.floatingMiniPhoneNavInlineGap +
          KonataPlaybackTokens.floatingMiniAudioDiscSize;
      final groupLeft = (size.width - groupWidth) / 2.0;
      return Rect.fromLTWH(
        groupLeft,
        top,
        navigationLength,
        navigationThickness,
      );
    }
    return Rect.fromLTWH(
      (size.width - navigationLength) / 2,
      top,
      navigationLength,
      navigationThickness,
    );
  }

  double get _effectiveTopSafeInset => !android && desktopTopBarVisible
      ? math.max(safe.top, KonataPlaybackTokens.floatingMiniDesktopTopBarClearance)
      : safe.top;

  /// 解析指定类型悬浮小窗的精确尺寸（视频按真实画面比例无黑边自适应，音频按三态自适应）。
  Size resolveMiniWindowSize(FloatingMiniPlayerKind kind) {
    if (kind == FloatingMiniPlayerKind.none) {
      return Size.zero;
    }
    if (visualState == FloatingMiniVisualState.tucked) {
      return const Size(
        KonataPlaybackTokens.floatingMiniEarTabWidth,
        KonataPlaybackTokens.floatingMiniEarTabHeight,
      );
    }
    const margin = KonataPlaybackTokens.floatingMiniEdgeMargin;
    final maxW = math.max(
      KonataAdaptiveTokens.touchTarget * 2,
      size.width - safe.horizontal - margin * 2,
    );
    final maxH = math.max(
      KonataAdaptiveTokens.touchTarget * 2,
      size.height - _effectiveTopSafeInset - safe.bottom - margin * 2,
    );
    switch (kind) {
      case FloatingMiniPlayerKind.none:
        return Size.zero;
      case FloatingMiniPlayerKind.video:
        final ar =
            (videoAspectRatio != null &&
                videoAspectRatio!.isFinite &&
                videoAspectRatio! > 0)
            ? videoAspectRatio!.clamp(
                KonataPlaybackTokens.floatingMiniVideoAspectRatioMin,
                KonataPlaybackTokens.floatingMiniVideoAspectRatioMax,
              )
            : (16.0 / 9.0);
        // 纯按实际视口最短边连续自适应缩放，绝不按平台/包体硬编码区分小窗大小。
        final baseLong =
            (size.shortestSide *
                    KonataPlaybackTokens.floatingMiniVideoViewportRatio)
                .clamp(
                  KonataPlaybackTokens.floatingMiniVideoLongSideMin,
                  KonataPlaybackTokens.floatingMiniVideoLongSideMax,
                );
        double w;
        double h;
        if (ar >= 1.0) {
          w = math.min(baseLong, maxW);
          h = w / ar;
          if (h > maxH) {
            h = maxH;
            w = h * ar;
          }
        } else {
          final portraitCapH = math.min(baseLong, maxH * 0.62);
          h = math.min(portraitCapH, maxH);
          w = h * ar;
          if (w < 96.0 && maxW >= 96.0) {
            w = 96.0;
            h = math.min(w / ar, maxH);
            w = h * ar;
          }
          if (w > maxW) {
            w = maxW;
            h = w / ar;
          }
        }
        return Size(w, h);
      case FloatingMiniPlayerKind.audio:
        if (visualState == FloatingMiniVisualState.expanded &&
            !inlinePhoneAudioPaired) {
          final targetPillW =
              (size.width * KonataPlaybackTokens.floatingMiniAudioPillWidthRatio)
                  .clamp(
                    KonataPlaybackTokens.floatingMiniAudioPillWidth,
                    KonataPlaybackTokens.floatingMiniAudioPillMaxWidth,
                  );
          final pillW = math.min(
            targetPillW,
            math.max(220.0, size.width - safe.horizontal - 32.0),
          );
          final pillH =
              (size.shortestSide *
                      KonataPlaybackTokens.floatingMiniAudioPillHeightRatio)
                  .clamp(
                    KonataPlaybackTokens.floatingMiniAudioPillHeight,
                    KonataPlaybackTokens.floatingMiniAudioPillMaxHeight,
                  );
          return Size(pillW, pillH);
        }
        if (inlinePhoneAudioPaired) {
          return const Size.square(
            KonataPlaybackTokens.floatingMiniAudioDiscSize,
          );
        }
        final discSide =
            (size.shortestSide *
                    KonataPlaybackTokens.floatingMiniAudioDiscViewportRatio)
                .clamp(
                  KonataPlaybackTokens.floatingMiniAudioDiscSize,
                  KonataPlaybackTokens.floatingMiniAudioDiscMaxSize,
                );
        return Size.square(discSide);
    }
  }

  /// 计算悬浮小窗允许活动的左上角坐标闭区间边界 `(minX, minY, maxX, maxY)`。
  ({double minX, double minY, double maxX, double maxY}) safeBoundsFor(
    Size miniSize,
  ) {
    const margin = KonataPlaybackTokens.floatingMiniEdgeMargin;
    final minX = safe.left + margin;
    final minY = _effectiveTopSafeInset + margin;
    final maxX = math.max(minX, size.width - safe.right - margin - miniSize.width);
    final maxY = math.max(
      minY,
      size.height - safe.bottom - margin - miniSize.height,
    );
    return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  /// 拖拽跟手期间实时钳制坐标，严格禁止小窗越出系统安全区。
  Offset clampMiniWindowOffset(Offset rawTopLeft, Size miniSize) {
    final b = safeBoundsFor(miniSize);
    return Offset(
      rawTopLeft.dx.clamp(b.minX, b.maxX),
      rawTopLeft.dy.clamp(b.minY, b.maxY),
    );
  }

  /// 松手后计算最近合法停靠坐标：移动端横向吸附至左右安全边缘并避开主导航胶囊，桌面端支持窗口安全区内任意位置自由停放。
  Offset snapMiniWindowOffset(Offset rawTopLeft, Size miniSize) {
    final b = safeBoundsFor(miniSize);
    final clamped = clampMiniWindowOffset(rawTopLeft, miniSize);
    if (!android) {
      return clamped;
    }
    final centerX = clamped.dx + miniSize.width / 2.0;
    final snappedX = centerX < size.width / 2.0 ? b.minX : b.maxX;
    final primary = Offset(snappedX, clamped.dy);

    if (!navigationVisible) {
      return primary;
    }

    final navAvoid = navigationRect.inflate(
      KonataPlaybackTokens.floatingMiniNavigationGap,
    );
    final primaryRect = primary & miniSize;
    if (!primaryRect.overlaps(navAvoid)) {
      return primary;
    }

    final candidates = <Offset>[];
    final aboveY = navAvoid.top - miniSize.height;
    if (aboveY >= b.minY - 0.5) {
      candidates.add(Offset(snappedX, math.max(b.minY, aboveY)));
    }
    final belowY = navAvoid.bottom;
    if (belowY <= b.maxY + 0.5) {
      candidates.add(Offset(snappedX, math.min(b.maxY, belowY)));
    }
    final rightX = navAvoid.right;
    if (rightX <= b.maxX + 0.5) {
      candidates.add(Offset(math.min(b.maxX, rightX), clamped.dy));
    }
    final leftX = navAvoid.left - miniSize.width;
    if (leftX >= b.minX - 0.5) {
      candidates.add(Offset(math.max(b.minX, leftX), clamped.dy));
    }

    final legalCandidates = candidates.where((offset) {
      final rect = offset & miniSize;
      return !rect.overlaps(navAvoid);
    }).toList(growable: false);

    if (legalCandidates.isEmpty) {
      return Offset(
        snappedX,
        math.max(b.minY, math.min(b.maxY, navAvoid.top - miniSize.height)),
      );
    }

    var best = legalCandidates.first;
    var bestDistSq = (best - clamped).distanceSquared;
    for (var i = 1; i < legalCandidates.length; i++) {
      final d = (legalCandidates[i] - clamped).distanceSquared;
      if (d < bestDistSq) {
        bestDistSq = d;
        best = legalCandidates[i];
      }
    }
    return best;
  }

  /// 将松手后的合法坐标编码为 `[0..1]` 归一化锚点，跨旋转与视口变化自适应还原。
  Offset encodeNormalizedAnchor(Offset settledTopLeft, Size miniSize) {
    final b = safeBoundsFor(miniSize);
    final spanX = b.maxX - b.minX;
    final spanY = b.maxY - b.minY;
    final dx = spanX > 0.5 ? ((settledTopLeft.dx - b.minX) / spanX).clamp(0.0, 1.0) : 1.0;
    final dy = spanY > 0.5 ? ((settledTopLeft.dy - b.minY) / spanY).clamp(0.0, 1.0) : 1.0;
    return Offset(dx, dy);
  }

  /// 解析当前稳态悬浮小窗在视口中的矩形（无活跃小窗时返回 `null`）。
  Rect? get floatingMiniWindowRect {
    if (miniKind == FloatingMiniPlayerKind.none ||
        size.width <= 0 ||
        size.height <= 0) {
      return null;
    }
    final miniSize = resolveMiniWindowSize(miniKind);
    if (inlinePhoneAudioPaired) {
      final nav = navigationRect;
      final discTop = nav.center.dy - miniSize.height / 2.0;
      return Rect.fromLTWH(
        nav.right + KonataPlaybackTokens.floatingMiniPhoneNavInlineGap,
        discTop,
        miniSize.width,
        miniSize.height,
      );
    }

    final b = safeBoundsFor(miniSize);
    if (visualState == FloatingMiniVisualState.tucked) {
      final earX = edgeSide == FloatingMiniEdgeSide.left
          ? safe.left
          : math.max(safe.left, size.width - safe.right - miniSize.width);
      final rawY = normalizedMiniAnchor == null
          ? b.maxY
          : b.minY + normalizedMiniAnchor!.dy.clamp(0.0, 1.0) * (b.maxY - b.minY);
      var earY = rawY.clamp(b.minY, b.maxY);
      if (android && navigationVisible) {
        final navAvoid = navigationRect.inflate(
          KonataPlaybackTokens.floatingMiniNavigationGap,
        );
        final rect = Rect.fromLTWH(earX, earY, miniSize.width, miniSize.height);
        if (rect.overlaps(navAvoid)) {
          final aboveY = navAvoid.top - miniSize.height;
          if (aboveY >= b.minY) {
            earY = aboveY;
          } else {
            earY = math.min(b.maxY, navAvoid.bottom);
          }
        }
      }
      return Rect.fromLTWH(earX, earY, miniSize.width, miniSize.height);
    }

    final rawTarget = normalizedMiniAnchor == null
        ? Offset(b.maxX, b.maxY)
        : Offset(
            b.minX + normalizedMiniAnchor!.dx.clamp(0.0, 1.0) * (b.maxX - b.minX),
            b.minY + normalizedMiniAnchor!.dy.clamp(0.0, 1.0) * (b.maxY - b.minY),
          );
    final settled = snapMiniWindowOffset(rawTarget, miniSize);
    return settled & miniSize;
  }

  /// 页面滚动流与底部面板统一安全避让高度（供列表、详情页与 Toast 同源读取）。
  ///
  /// 桌面端悬浮小窗支持窗口内自由移动叠加，绝不把详情页正片/特典列表整体往上顶起；
  /// 仅移动端需要为底部胶囊及小窗保留滚动避让，且全端均确保小窗严禁遮挡弹窗与下拉菜单。
  double get bottomClearance {
    if (!android) {
      return 0.0;
    }
    final baseNavClearance = !verticalNavigation && navigationVisible
        ? size.height - navigationRect.top + KonataAdaptiveTokens.safeGap
        : safe.bottom + KonataAdaptiveTokens.safeGap;
    if (visualState == FloatingMiniVisualState.tucked ||
        inlinePhoneAudioPaired) {
      return baseNavClearance;
    }
    final miniRect = floatingMiniWindowRect;
    if (miniRect == null) {
      return baseNavClearance;
    }
    final inBottomZone =
        miniRect.bottom >=
        size.height * KonataPlaybackTokens.floatingMiniBottomZoneThresholdRatio;
    if (!inBottomZone) {
      return baseNavClearance;
    }
    final miniClearance =
        size.height -
        miniRect.top +
        KonataPlaybackTokens.floatingMiniBottomClearanceGap;
    return math.max(baseNavClearance, miniClearance);
  }
}
