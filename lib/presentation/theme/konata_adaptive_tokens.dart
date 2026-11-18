import '../../application/providers/platform_capability.dart';

/// 跨端胶囊、触控与安全避让的统一几何令牌。
abstract final class KonataAdaptiveTokens {
  /// 当前是否启用 Android 触屏与胶囊布局。
  static bool get isAndroid => KonataPlatform.isAndroid;

  /// 当前是否启用 Windows 桌面与外部程序能力。
  static bool get isWindows => KonataPlatform.isWindows;

  static const settingsRailWidth = 220.0;
  static const settingsGap = 16.0;
  static const settingsRadius = 12.0;
  static const settingsFontSize = 14.5;
  static const tabletBreakpoint = 600.0;
  static const shortViewportHeight = 500.0;
  static const touchTarget = 48.0;
  static const navigationPadding = 4.0;
  static const safeGap = 8.0;
  static const capsuleStackGap = 10.0;
  static const horizontalInset = 12.0;
  static const tabletBottomInset = 18.0;
  static const playerHeight = 64.0;
  static const playerMaxWidth = 600.0;
  static const tabletPlayerMaxWidth = 640.0;
  static const tabletTopSafeMin = 44.0;
  static const capsuleRadius = 28.0;
  static const borderWidth = 1.0;
  static const progressHeight = 2.0;
  static const coverSize = 38.0;
  static const iconSize = 20.0;
  static const toastAutoDismissDuration = Duration(seconds: 4);
  static const toastEnterDuration = Duration(milliseconds: 200);
  static const toastExitDuration = Duration(milliseconds: 160);
  static const toastMaxWidth = 540.0;
  static const toastHorizontalMargin = 16.0;
  static const toastSafeBottomGapAndroid = 16.0;
  static const toastSafeBottomGapDesktop = 20.0;
  static const toastMiniWindowGap = 12.0;
  static const toastBlurSigma = 24.0;
  static const desktopToastCloseHitSize = 28.0;
}
