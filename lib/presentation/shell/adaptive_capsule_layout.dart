import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/konata_adaptive_tokens.dart';

/// 二级设置路由进入时隐藏主导航，退出时恢复。
final capsuleNavigationHiddenProvider = StateProvider<bool>((ref) => false);

/// 外壳唯一几何入口，业务页面不参与设备形态判断。
class AdaptiveCapsuleLayout {
  AdaptiveCapsuleLayout({
    required this.size,
    required this.safe,
    required this.android,
    this.playerVisible = false,
    this.navigationVisible = true,
  });
  final Size size;
  final EdgeInsets safe;
  final bool android;
  final bool playerVisible;
  final bool navigationVisible;
  bool get tablet =>
      android && size.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint;
  bool get shortPhone =>
      android &&
      !tablet &&
      size.height < KonataAdaptiveTokens.shortViewportHeight;
  double get navigationThickness =>
      KonataAdaptiveTokens.touchTarget +
      KonataAdaptiveTokens.navigationPadding * 2;
  double get navigationLength =>
      KonataAdaptiveTokens.touchTarget * 4 +
      KonataAdaptiveTokens.navigationPadding * 2;
  double get leftClearance => tablet && navigationVisible
      ? navigationThickness + KonataAdaptiveTokens.safeGap
      : 0;
  Rect get navigationRect {
    if (tablet) {
      return Rect.fromLTWH(
        safe.left,
        safe.top + (size.height - safe.vertical - navigationLength) / 2,
        navigationThickness,
        navigationLength,
      );
    }
    final left = shortPhone && playerVisible
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

  Rect get playerRect {
    final bottom =
        size.height -
        safe.bottom -
        (tablet
            ? KonataAdaptiveTokens.tabletBottomInset
            : KonataAdaptiveTokens.safeGap);
    final workspaceLeft = safe.left + leftClearance;
    final width = math.min(
      KonataAdaptiveTokens.playerMaxWidth,
      size.width -
          workspaceLeft -
          safe.right -
          KonataAdaptiveTokens.horizontalInset * 2,
    );
    if (shortPhone && navigationVisible) {
      final left = navigationRect.right + KonataAdaptiveTokens.horizontalInset;
      return Rect.fromLTRB(
        left,
        bottom - KonataAdaptiveTokens.playerHeight,
        size.width - safe.right - KonataAdaptiveTokens.horizontalInset,
        bottom,
      );
    }
    final lift = !tablet && navigationVisible
        ? navigationThickness + KonataAdaptiveTokens.safeGap
        : 0.0;
    return Rect.fromLTWH(
      workspaceLeft + (size.width - safe.right - workspaceLeft - width) / 2,
      bottom - lift - KonataAdaptiveTokens.playerHeight,
      width,
      KonataAdaptiveTokens.playerHeight,
    );
  }

  /// 提示浮层始终位于当前导航或播放胶囊上方。
  double get errorBottomInset {
    final top = playerVisible
        ? playerRect.top
        : (!tablet && navigationVisible
              ? navigationRect.top
              : size.height - safe.bottom);
    return size.height - top + KonataAdaptiveTokens.safeGap;
  }

  double get bottomClearance {
    if (!android) return 0;
    final top = playerVisible
        ? playerRect.top
        : (!tablet && navigationVisible
              ? navigationRect.top
              : size.height - safe.bottom);
    return size.height - top + KonataAdaptiveTokens.safeGap;
  }
}
