import 'package:flutter/material.dart';

import 'konata_palette.dart';

/// Konata 全局主题、四语可变字体排版与统一布局规范。
///
/// 收口全站字号、连续可变字重（`FontVariation('wght', ...)`）、等宽数字、
/// 边距与动效时序常量，严禁在页面 Widget 内散落硬编码字重/边距魔法值。
abstract final class KonataTheme {
  /// 全站视觉与品牌角标固定色 Token。
  static const Color cinemaObsidian = Color(0xFF0B0C10);
  static const Color bangumiPink = Color(0xFFF09199);
  static const Color tmdbNavy = Color(0xFF0D253F);
  static const Color tmdbMint = Color(0xFF90CEA1);
  static const Color tmdbCyan = Color(0xFF01B4E4);
  static const LinearGradient tmdbBrandGradient = LinearGradient(
    colors: [tmdbMint, tmdbCyan],
  );
  static const Color resolutionBadgeTextDark = Color(0xFF111827);
  static const Color specReleaseBlue = Color(0xFF58A6FF);
  static const Color specSubtitleGreen = Color(0xFF3FB950);
  static const Color specVideoPurple = Color(0xFFB388FF);
  static const Color specAudioAmber = Color(0xFFE5A93B);
  static const Color windowCloseHoverRed = Color(0xFFE81123);
  static const Color reviewBannerDarkBg = Color(0xFF141822);
  static const Color reviewBannerSubtleFg = Color(0xFFD0D7E2);
  static const Color darkPopoverSurface = Color(0xFF1E2026);
  static const Color lightPopoverSurface = Color(0xFFFFFFFF);
  static const Color lightboxDarkSurface = Color(0xFF141820);
  static const Color themePreviewDarkCard = Color(0xFF14161D);
  static const Color themePreviewLightCanvas = Color(0xFFF6F5F1);
  static const Color themePreviewNeutralPill = Color(0xFF8E93A4);
  static const Color detailLightSlatePrimary = Color(0xFF0F172A);
  static const Color detailLightSlateSecondary = Color(0xEB0F172A);

  /// 离线内置双可变字体栈（Inter 接管拉丁/数字/符号，Noto Sans CJK SC 接管简繁日韩同源文字）。
  static const String uiFontFamily = 'KonataInter';
  static const List<String> uiFontFamilyFallback = [
    'KonataNotoCJK',
    'Yu Gothic UI',
    'Microsoft YaHei UI',
  ];

  /// 全局顶栏与主页面边缘对齐几何 Token。
  static const double topNavHeight = 52.0;
  static const double topNavOuterHorizontalPadding = 24.0;
  static const double topNavTabHorizontalPadding = 6.0;
  static const double pageHorizontalPadding =
      topNavOuterHorizontalPadding + topNavTabHorizontalPadding; // 30.0px
  static const double pageHeaderTopSpacing = 16.0;
  static const double pageHeaderHeight = 44.0;
  static const double pageHeaderBottomSpacing = 16.0;

  /// 全局动画时序与曲线 Token。
  static const Duration standardTransition = Duration(milliseconds: 200);
  static const Duration capsuleSlideDuration = Duration(milliseconds: 220);
  static const Duration panelSwitchDuration = Duration(milliseconds: 180);
  static const Duration navSliderDuration = Duration(milliseconds: 260);
  static const Duration tabSwitchDuration = Duration(milliseconds: 220);

  /// 弹窗视口安全边界留白。
  static const double dialogViewportMargin = 12.0;

  /// 全局收敛可变字重 Token（去重粗体压迫感）。
  static const double weightH1 = 600.0;
  static const double weightH2 = 600.0;
  static const double weightActive = 600.0;
  static const double weightRegularLabel = 450.0;
  static const double weightCaption = 400.0;

  /// 将连续可变字重值映射为最接近的标准 [FontWeight]。
  static FontWeight mapVariableWeight(double weight) {
    if (weight <= 350) return FontWeight.w300;
    if (weight <= 425) return FontWeight.w400;
    if (weight <= 525) return FontWeight.w500;
    if (weight <= 650) return FontWeight.w600;
    return FontWeight.w700;
  }

  /// 统一构建全站排版样式（同步写入 [FontWeight]、`FontVariation('wght', ...)` 与等宽数字）。
  static TextStyle textStyle({
    double? fontSize,
    double weight = weightRegularLabel,
    Color? color,
    double? letterSpacing,
    double? height,
    bool tabularFigures = true,
    List<Shadow>? shadows,
  }) {
    return TextStyle(
      fontFamily: uiFontFamily,
      fontFamilyFallback: uiFontFamilyFallback,
      fontSize: fontSize,
      fontWeight: mapVariableWeight(weight),
      fontVariations: [FontVariation('wght', weight)],
      fontFeatures: tabularFigures
          ? const [FontFeature.tabularFigures()]
          : const [FontFeature.proportionalFigures()],
      color: color,
      letterSpacing: letterSpacing,
      height: height,
      shadows: shadows,
    );
  }

  /// 一级主页面大标题样式（26px / w600）。
  static TextStyle h1Style(KonataPalette p) => textStyle(
    color: p.textPrimary,
    fontSize: 26,
    weight: weightH1,
    letterSpacing: -0.3,
    height: 1.2,
  );

  /// 二级面板与弹窗标题样式（20px / w600）。
  static TextStyle h2Style(KonataPalette p) => textStyle(
    color: p.textPrimary,
    fontSize: 20,
    weight: weightH2,
    letterSpacing: -0.2,
    height: 1.25,
  );

  /// 卡片标题 / 导航激活态样式（默认 15px / w600）。
  static TextStyle cardTitleStyle(
    KonataPalette p, {
    double fontSize = 15,
    Color? color,
  }) => textStyle(
    color: color ?? p.textPrimary,
    fontSize: fontSize,
    weight: weightActive,
  );

  /// 正文与标签样式（默认 13.5px / w450）。
  static TextStyle bodyLabelStyle(
    KonataPalette p, {
    double fontSize = 13.5,
    Color? color,
    double? height,
  }) => textStyle(
    color: color ?? p.textPrimary,
    fontSize: fontSize,
    weight: weightRegularLabel,
    height: height,
  );

  /// 辅助说明与微弱说明文字样式（默认 12px / w400）。
  static TextStyle captionStyle(
    KonataPalette p, {
    double fontSize = 12,
    Color? color,
    double? height,
  }) => textStyle(
    color: color ?? p.textSecondary,
    fontSize: fontSize,
    weight: weightCaption,
    height: height,
  );

  /// 详情页叠放于背景原画之上的统一双层柔和文字投影（内层贴边轮廓 + 外层环境晕影）。
  static final List<Shadow> detailTextShadows = [
    Shadow(
      color: Colors.black.withValues(alpha: 0.65),
      offset: const Offset(0, 1.5),
      blurRadius: 4,
    ),
    Shadow(
      color: Colors.black.withValues(alpha: 0.45),
      offset: const Offset(0, 3),
      blurRadius: 14,
    ),
  ];

  /// 亮色详情页彻底清空白色发光阴影，保持高对比深石板色实字锐利清晰。
  static const List<Shadow> lightDetailTextShadows = <Shadow>[];

  /// 详情页主信息与选集卡片高对比度主文字色（亮色深石板 / 深色亮白）。
  static Color detailPrimaryTextColor(KonataPalette p) =>
      p.isDark ? p.textPrimary : detailLightSlatePrimary;

  /// 详情页元信息与原文件名高对比度次级文字色（亮色深石板次级 / 深色半透亮白）。
  static Color detailSecondaryTextColor(KonataPalette p) =>
      p.isDark ? p.textSecondary : detailLightSlateSecondary;

  /// 构建详情页背景文字统一舒适排版样式。
  static TextStyle detailTextStyle({
    required double fontSize,
    required FontWeight fontWeight,
    Color? color,
    KonataPalette? palette,
    double? letterSpacing,
    double? height,
  }) {
    final isDark = palette?.isDark ?? true;
    final resolvedColor =
        color ??
        (palette != null ? detailPrimaryTextColor(palette) : Colors.white);
    final targetWeight = fontWeight.value.toDouble().clamp(400.0, 700.0);
    return textStyle(
      fontSize: fontSize,
      weight: targetWeight > 600 ? weightH1 : targetWeight,
      color: resolvedColor,
      letterSpacing: letterSpacing,
      height: height,
      tabularFigures: false,
      shadows: isDark ? detailTextShadows : lightDetailTextShadows,
    );
  }

  /// 构建深色模式主题。
  static ThemeData darkTheme() => _buildTheme(KonataPalette.dark);

  /// 构建亮色模式主题。
  static ThemeData lightTheme() => _buildTheme(KonataPalette.light);

  static ThemeData _buildTheme(KonataPalette palette) {
    final brightness = palette.isDark ? Brightness.dark : Brightness.light;
    final menuBorder = palette.isDark
        ? Colors.white.withValues(alpha: 0.16)
        : const Color(0x1A0F172A);
    final menuSurface = palette.isDark
        ? darkPopoverSurface.withValues(alpha: 0.94)
        : lightPopoverSurface.withValues(alpha: 0.96);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: uiFontFamily,
      fontFamilyFallback: uiFontFamilyFallback,
      scaffoldBackgroundColor: Colors.transparent,
      extensions: [palette],
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: palette.primaryButtonBg,
        onPrimary: palette.primaryButtonFg,
        secondary: palette.secondaryButtonBg,
        onSecondary: palette.textPrimary,
        error: palette.danger,
        onError: Colors.white,
        surface: palette.elevatedSurface,
        onSurface: palette.textPrimary,
      ),
      dividerColor: palette.hairline,
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.progressFill,
        linearTrackColor: palette.progressTrack,
        borderRadius: BorderRadius.circular(999),
        stopIndicatorColor: Colors.transparent,
        stopIndicatorRadius: 0,
      ),
      scrollbarTheme: ScrollbarThemeData(
        interactive: true,
        radius: const Radius.circular(999),
        minThumbLength: 36,
        thickness: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return 8.0;
          }
          return 5.5;
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.dragged)) {
            return palette.isDark
                ? Colors.white.withValues(alpha: 0.62)
                : Colors.black.withValues(alpha: 0.52);
          }
          if (states.contains(WidgetState.hovered)) {
            return palette.isDark
                ? Colors.white.withValues(alpha: 0.48)
                : Colors.black.withValues(alpha: 0.38);
          }
          return palette.isDark
              ? Colors.white.withValues(alpha: 0.28)
              : Colors.black.withValues(alpha: 0.22);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return palette.isDark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.05);
          }
          return Colors.transparent;
        }),
        trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        color: palette.surface,
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        elevation: 8,
        surfaceTintColor: Colors.transparent,
        color: menuSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: menuBorder, width: 1),
        ),
        textStyle: textStyle(
          color: palette.textPrimary,
          fontSize: 13.5,
          weight: weightRegularLabel,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return palette.primaryButtonBg;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStatePropertyAll(palette.primaryButtonFg),
        side: BorderSide(color: palette.textSecondary, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 4,
        backgroundColor: palette.elevatedSurface,
        insetPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        contentTextStyle: textStyle(
          color: palette.textPrimary,
          fontSize: 13,
          weight: weightRegularLabel,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: menuBorder, width: 1),
        ),
      ),
      textTheme: TextTheme(
        headlineMedium: h1Style(palette),
        headlineSmall: h2Style(palette),
        titleMedium: cardTitleStyle(palette),
        bodyMedium: bodyLabelStyle(palette, fontSize: 14),
        bodySmall: captionStyle(palette),
      ),
    );
  }
}
