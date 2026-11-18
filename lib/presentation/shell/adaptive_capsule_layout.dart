import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/konata_adaptive_tokens.dart';

/// 二级设置路由进入时隐藏主导航，退出时恢复。
final capsuleNavigationHiddenProvider = StateProvider<bool>((ref) => false);

/// 根路由栈是否存在推入的二级全屏页面（如作品详情页），存在时隐藏主导航胶囊并使迷你播放胶囊整屏水平居中。
final subRoutePushedProvider = StateProvider<bool>((ref) => false);

/// 根 `Navigator` 路由栈深度观察器：精准感知详情页等全屏子路由推入/弹出（忽略弹窗遮罩路由）。
class KonataRootRouteObserver extends NavigatorObserver {
  /// 创建根路由观察器。
  KonataRootRouteObserver(this._onSubRouteChanged);

  final ValueChanged<bool> _onSubRouteChanged;
  int _nonRootPageCount = 0;

  bool _isFullPageSubRoute(Route<dynamic>? route) {
    if (route == null || route.isFirst) return false;
    return route is PageRoute;
  }

  void _notifyChanged() {
    final active = _nonRootPageCount > 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onSubRouteChanged(active);
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (_isFullPageSubRoute(route)) {
      _nonRootPageCount++;
      _notifyChanged();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (_isFullPageSubRoute(route) && _nonRootPageCount > 0) {
      _nonRootPageCount--;
      _notifyChanged();
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (_isFullPageSubRoute(route) && _nonRootPageCount > 0) {
      _nonRootPageCount--;
      _notifyChanged();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    final oldSub = _isFullPageSubRoute(oldRoute);
    final newSub = _isFullPageSubRoute(newRoute);
    if (oldSub && !newSub && _nonRootPageCount > 0) {
      _nonRootPageCount--;
      _notifyChanged();
    } else if (!oldSub && newSub) {
      _nonRootPageCount++;
      _notifyChanged();
    }
  }
}

/// 根导航观察器 Provider。
final rootRouteObserverProvider = Provider<KonataRootRouteObserver>((ref) {
  return KonataRootRouteObserver((hasSubRoute) {
    ref.read(subRoutePushedProvider.notifier).state = hasSubRoute;
  });
});

/// 外壳唯一几何入口，业务页面不参与设备形态判断。
class AdaptiveCapsuleLayout {
  /// 创建自适应胶囊几何布局计算器。
  AdaptiveCapsuleLayout({
    required this.size,
    required this.safe,
    required this.android,
    this.playerVisible = false,
    this.navigationVisible = true,
    this.isVideoMini = false,
  });

  /// 当前视口尺寸。
  final Size size;

  /// 系统安全区边距（推荐使用 `viewPadding` 以保证手势白条底距不被内层消费）。
  final EdgeInsets safe;

  /// 是否处于 Android 触屏模式。
  final bool android;

  /// 当前是否有活跃迷你播放胶囊。
  final bool playerVisible;

  /// 主导航胶囊当前是否可见（详情页与设置二级页为 `false`）。
  final bool navigationVisible;

  /// 当前迷你播放胶囊是否为视频小窗胶囊（手机横屏下视频小窗居中置于主导航正上方，音频胶囊并排置于主导航右侧）。
  final bool isVideoMini;

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

  static const double _minSideBySidePlayerWidth = 360.0;

  /// 是否为平板视口（`shortestSide >= 600dp`）。
  bool get tablet =>
      android && size.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint;

  /// 是否为手机矮横屏视口（`height < 500dp`）。
  bool get shortPhone =>
      android &&
      !tablet &&
      size.height < KonataAdaptiveTokens.shortViewportHeight;

  double get _usableBottomWidth => math.max(
    0.0,
    size.width - safe.horizontal - KonataAdaptiveTokens.horizontalInset * 2,
  );

  double get _remainingSideBySidePlayerWidth =>
      _usableBottomWidth -
      navigationLength -
      KonataAdaptiveTokens.horizontalInset;

  /// 手机横屏音频迷你胶囊是否采用底部同行左右并排布局。
  bool get _sideBySideAudioOnShortPhone =>
      shortPhone && playerVisible && navigationVisible && !isVideoMini;

  /// 当可用底宽不足以从容并排容纳导航与音频胶囊时，矮横屏自动将导航迁至左侧垂直居中释放水平宽度。
  bool get verticalNavigation =>
      tablet ||
      (_sideBySideAudioOnShortPhone &&
          _remainingSideBySidePlayerWidth < _minSideBySidePlayerWidth);

  /// 导航胶囊短边厚度。
  double get navigationThickness =>
      KonataAdaptiveTokens.touchTarget +
      KonataAdaptiveTokens.navigationPadding * 2;

  /// 导航胶囊长边长度。
  double get navigationLength =>
      KonataAdaptiveTokens.touchTarget * 4 +
      KonataAdaptiveTokens.navigationPadding * 2;

  /// 左侧工作区避让宽度。
  double get leftClearance => verticalNavigation && navigationVisible
      ? navigationThickness + KonataAdaptiveTokens.safeGap
      : 0;

  /// 主导航胶囊在屏幕中的定位矩形。
  Rect get navigationRect {
    if (verticalNavigation) {
      return Rect.fromLTWH(
        safe.left,
        safe.top + (size.height - safe.vertical - navigationLength) / 2,
        navigationThickness,
        navigationLength,
      );
    }
    final left = _sideBySideAudioOnShortPhone
        ? safe.left + KonataAdaptiveTokens.horizontalInset
        : (size.width - navigationLength) / 2;
    return Rect.fromLTWH(
      left,
      size.height -
          safe.bottom -
          KonataAdaptiveTokens.safeGap -
          navigationThickness,
      navigationLength,
      navigationThickness,
    );
  }

  /// 迷你播放胶囊在屏幕中的定位矩形。
  Rect get playerRect {
    final bottom =
        size.height -
        safe.bottom -
        (tablet
            ? KonataAdaptiveTokens.tabletBottomInset
            : KonataAdaptiveTokens.safeGap);

    // 手机横屏含底部导航栏时，音频迷你胶囊置于主导航胶囊右侧并保持 12dp 间距。
    if (_sideBySideAudioOnShortPhone && !verticalNavigation) {
      final left = navigationRect.right + KonataAdaptiveTokens.horizontalInset;
      return Rect.fromLTRB(
        left,
        bottom - KonataAdaptiveTokens.playerHeight,
        size.width - safe.right - KonataAdaptiveTokens.horizontalInset,
        bottom,
      );
    }

    // 平板端、详情页（无导航栏）及手机端主导航上方模式：统一相对于整块屏幕宽度水平居中。
    final lift = !verticalNavigation && navigationVisible
        ? navigationThickness + KonataAdaptiveTokens.capsuleStackGap
        : 0.0;
    final playerTop = bottom - lift - KonataAdaptiveTokens.playerHeight;
    final verticalNavOverlapsBottom =
        verticalNavigation &&
        navigationVisible &&
        (navigationRect.bottom + KonataAdaptiveTokens.safeGap > playerTop);

    if (!verticalNavOverlapsBottom) {
      final symmetricSideInset =
          math.max(safe.left, safe.right) + KonataAdaptiveTokens.horizontalInset;
      final width = math.min(
        KonataAdaptiveTokens.playerMaxWidth,
        math.max(0.0, size.width - symmetricSideInset * 2),
      );
      return Rect.fromLTWH(
        (size.width - width) / 2,
        playerTop,
        width,
        KonataAdaptiveTokens.playerHeight,
      );
    }

    final minLeft =
        safe.left + leftClearance + KonataAdaptiveTokens.horizontalInset;
    final maxRight = size.width - safe.right - KonataAdaptiveTokens.horizontalInset;
    final maxAllowedWidth = math.max(0.0, maxRight - minLeft);
    final width = math.min(KonataAdaptiveTokens.playerMaxWidth, maxAllowedWidth);
    final idealCenterLeft = (size.width - width) / 2;
    final clampedLeft = maxRight >= minLeft + width
        ? idealCenterLeft.clamp(minLeft, maxRight - width)
        : minLeft;

    return Rect.fromLTWH(
      clampedLeft,
      playerTop,
      width,
      KonataAdaptiveTokens.playerHeight,
    );
  }

  /// 提示浮层始终位于当前导航或播放胶囊上方。
  double get errorBottomInset {
    final top = playerVisible
        ? playerRect.top
        : (!verticalNavigation && navigationVisible
              ? navigationRect.top
              : size.height - safe.bottom);
    return size.height - top + KonataAdaptiveTokens.safeGap;
  }

  /// 页面滚动流底部安全避让高度。
  double get bottomClearance {
    if (!android) return 0;
    final top = playerVisible
        ? playerRect.top
        : (!verticalNavigation && navigationVisible
              ? navigationRect.top
              : size.height - safe.bottom);
    return size.height - top + KonataAdaptiveTokens.safeGap;
  }
}
