import 'konata_ui_platform.dart';

/// 跨端胶囊、触控与安全避让的统一几何令牌。
abstract final class KonataAdaptiveTokens {
  /// 当前是否启用 Android 触屏与胶囊布局。
  static bool get isAndroid => KonataUiPlatform.isAndroid;

  /// 当前是否启用 Windows 桌面与外部程序能力。
  static bool get isWindows => KonataUiPlatform.isWindows;

  /// 设置页宽屏左栏导航宽度。
  static const double settingsRailWidth = 220.0;

  /// 设置面板内部模块间距。
  static const double settingsGap = 16.0;

  /// 设置分类条圆角半径。
  static const double settingsRadius = 12.0;

  /// 设置分类标题字号。
  static const double settingsFontSize = 14.5;

  /// 平板与手机形态分界断点（`shortestSide >= 600dp`）。
  static const double tabletBreakpoint = 600.0;

  /// 手机矮横屏视口高度判定阈值。
  static const double shortViewportHeight = 500.0;

  /// 移动端最小触控热区尺寸。
  static const double touchTarget = 48.0;

  /// 手机横排胶囊内边距。
  static const double navigationPadding = 4.0;

  /// 平板纵排胶囊单按钮尺寸。
  static const double tabletNavItemSize = 56.0;

  /// 平板纵排胶囊内边距。
  static const double tabletNavPadding = 6.0;

  /// 平板纵排胶囊按钮间距。
  static const double tabletNavItemGap = 6.0;

  /// 平板纵排胶囊距左侧安全区边缘间距。
  static const double tabletNavEdgeGap = 14.0;

  /// 平板纵排胶囊图标尺寸。
  static const double tabletNavIconSize = 24.0;

  /// 通用安全避让留白间距。
  static const double safeGap = 8.0;

  /// 移动端页面内容标准水平边距。
  static const double horizontalInset = 12.0;

  /// 平板底部避让附加留白。
  static const double tabletBottomInset = 18.0;

  /// 标准紧凑播放条高度参考值。
  static const double playerHeight = 64.0;

  /// 平板底部播放条最大宽度参考值。
  static const double tabletPlayerMaxWidth = 640.0;

  /// 平板顶部安全留白下限。
  static const double tabletTopSafeMin = 44.0;

  /// 悬浮毛玻璃胶囊圆角半径。
  static const double capsuleRadius = 28.0;

  /// 胶囊与浮层微光边框宽度。
  static const double borderWidth = 1.0;

  /// 极细进度条默认高度。
  static const double progressHeight = 2.0;

  /// 手机胶囊导航图标尺寸。
  static const double iconSize = 20.0;

  /// 悬浮轻提示默认自动淡出时长。
  static const Duration toastAutoDismissDuration = Duration(seconds: 4);

  /// 悬浮轻提示长文案自动淡出时长。
  static const Duration toastExtendedDismissDuration = Duration(seconds: 6);

  /// 悬浮轻提示入场动效时长。
  static const Duration toastEnterDuration = Duration(milliseconds: 200);

  /// 悬浮轻提示退场动效时长。
  static const Duration toastExitDuration = Duration(milliseconds: 160);

  /// 悬浮轻提示最大宽度。
  static const double toastMaxWidth = 540.0;

  /// 悬浮轻提示距视口边缘最小水平边距。
  static const double toastHorizontalMargin = 16.0;

  /// 悬浮轻提示毛玻璃模糊半径。
  static const double toastBlurSigma = 24.0;

  /// 桌面端悬浮轻提示关闭按钮点击热区尺寸。
  static const double desktopToastCloseHitSize = 28.0;
}
