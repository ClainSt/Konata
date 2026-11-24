import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'konata_palette.dart';

/// Konata 全局主题、四语可变字体排版与统一布局规范。
///
/// 收口全站字号、连续可变字重（`FontVariation('wght', ...)`）、等宽数字、
/// 边距与动效时序常量，严禁在页面 Widget 内散落硬编码字重/边距魔法值。
abstract final class KonataTheme {
  /// 全站视觉与品牌角标固定色 Token。
  static const Color cinemaObsidian = Color(0xFF0B0C10);
  static const Color bangumiPink = Color(0xFFF09199);
  static const Color bangumiPinkLightTheme = Color(0xFFDC6576);
  static const Color bangumiBadgeDarkSurface = Color(0x9E1E222B);
  static const Color bangumiBadgeLightSurface = Color(0xCCFFFFFF);
  static const Color toastErrorLightSurface = Color(0xF5FEF2F2);
  static const Color toastErrorLightBorder = Color(0x66DC2626);
  static const Color toastErrorLightFg = Color(0xFF991B1B);
  static const Color toastErrorDarkSurface = Color(0xDE3B0D14);
  static const Color toastErrorDarkBorder = Color(0x66FCA5A5);
  static const Color toastErrorDarkFg = Color(0xFFFECACA);
  static const Color ambientShellDarkGlowA = Color(0xFF7B3B69);
  static const Color ambientShellDarkGlowB = Color(0xFF334982);
  static const Color ambientShellDarkGlowC = Color(0xFF4B376E);
  static const Color ambientShellLightGlowA = Color(0xFFF2D4E1);
  static const Color ambientShellLightGlowB = Color(0xFFD5E1F8);
  static const Color ambientShellLightGlowC = Color(0xFFE7DAF3);
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

  /// 离线内置全语种单一体可变字体栈（由覆盖拉丁/数字与简繁日韩的 Noto Sans CJK SC
  /// 主导排版，避免 Impeller OpenGLESSDF 在双可变字体高频跨字族回退时触发字形图集越界）。
  static const String uiFontFamily = 'KonataNotoCJK';
  static const List<String> uiFontFamilyFallback = [
    'KonataInter',
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

  /// 全局动画时序与交互节流 Token。
  static const Duration standardTransition = Duration(milliseconds: 95);
  static const Duration capsuleSlideDuration = Duration(milliseconds: 100);
  static const Duration panelSwitchDuration = Duration(milliseconds: 85);
  static const Duration navSliderDuration = Duration(milliseconds: 240);
  static const Duration tabSwitchDuration = Duration(milliseconds: 220);
  static const Duration settingsAutoSaveDebounce = Duration(milliseconds: 300);
  static const Duration searchInputDebounce = Duration(milliseconds: 150);
  static const Duration motionSnap = Duration(milliseconds: 70);
  static const Duration motionMicro = Duration(milliseconds: 110);
  static const Duration motionFast = Duration(milliseconds: 140);
  static const Duration motionStandard = Duration(milliseconds: 160);
  static const Duration motionMedium = Duration(milliseconds: 180);
  static const Duration motionNormal = Duration(milliseconds: 200);
  static const Duration motionEmphasis = Duration(milliseconds: 260);
  static const Duration tooltipWaitDuration = Duration(milliseconds: 350);
  static const Duration tooltipSlowWaitDuration = Duration(milliseconds: 450);
  static const Duration gesturePillFastFadeDelay = Duration(milliseconds: 520);
  static const Duration gesturePillSlowFadeDelay = Duration(milliseconds: 900);
  static const Duration scrollCaptureSettleDelay = Duration(milliseconds: 24);
  static const Duration toastRemovalGraceDelay = Duration(milliseconds: 40);
  static const Duration windowMetricsDebounce = Duration(milliseconds: 90);
  static const Duration scrollCaptureMetricsDebounce = Duration(
    milliseconds: 240,
  );

  /// 弹窗视口安全边界留白与通用组件圆角/字号/开关几何令牌。
  static const double dialogViewportMargin = 12.0;
  static const double radiusHairline = 1.0;
  static const double radiusXs = 4.0;
  static const double radiusChipSm = 5.0;
  static const double radiusChip = 6.0;
  static const double radiusBadge = 7.0;
  static const double radiusSm = 8.0;
  static const double radiusThumb = 9.0;
  static const double radiusControl = 10.0;
  static const double radiusTile = 11.0;
  static const double radiusCard = 12.0;
  static const double radiusPanel = 14.0;
  static const double radiusSheet = 16.0;
  static const double radiusDialog = 18.0;
  static const double radiusCapsule = 20.0;
  static const double radiusPill = 999.0;

  static const BorderRadius borderRadiusHairline = BorderRadius.all(
    Radius.circular(radiusHairline),
  );
  static const BorderRadius borderRadiusXs = BorderRadius.all(
    Radius.circular(radiusXs),
  );
  static const BorderRadius borderRadiusChipSm = BorderRadius.all(
    Radius.circular(radiusChipSm),
  );
  static const BorderRadius borderRadiusChip = BorderRadius.all(
    Radius.circular(radiusChip),
  );
  static const BorderRadius borderRadiusBadge = BorderRadius.all(
    Radius.circular(radiusBadge),
  );
  static const BorderRadius borderRadiusSm = BorderRadius.all(
    Radius.circular(radiusSm),
  );
  static const BorderRadius borderRadiusThumb = BorderRadius.all(
    Radius.circular(radiusThumb),
  );
  static const BorderRadius borderRadiusControl = BorderRadius.all(
    Radius.circular(radiusControl),
  );
  static const BorderRadius borderRadiusTile = BorderRadius.all(
    Radius.circular(radiusTile),
  );
  static const BorderRadius borderRadiusCard = BorderRadius.all(
    Radius.circular(radiusCard),
  );
  static const BorderRadius borderRadiusPanel = BorderRadius.all(
    Radius.circular(radiusPanel),
  );
  static const BorderRadius borderRadiusSheet = BorderRadius.all(
    Radius.circular(radiusSheet),
  );
  static const BorderRadius borderRadiusDialog = BorderRadius.all(
    Radius.circular(radiusDialog),
  );
  static const BorderRadius borderRadiusCapsule = BorderRadius.all(
    Radius.circular(radiusCapsule),
  );
  static const BorderRadius borderRadiusPill = BorderRadius.all(
    Radius.circular(radiusPill),
  );

  /// 全站标准排版字号阶梯。
  static const double fontSizeMicro = 10.0;
  static const double fontSizeBadge = 10.5;
  static const double fontSizeCaptionXs = 11.0;
  static const double fontSizeCaptionSm = 11.5;
  static const double fontSizeCaption = 12.0;
  static const double fontSizeBodyXs = 12.5;
  static const double fontSizeBodySm = 13.0;
  static const double fontSizeBody = 13.5;
  static const double fontSizeBodyMd = 14.0;
  static const double fontSizeSubtitle = 14.5;
  static const double fontSizeTitleSm = 15.0;
  static const double fontSizeTitle = 16.0;
  static const double fontSizeTitleLg = 18.0;
  static const double fontSizeH2 = 20.0;
  static const double fontSizeDisplaySm = 22.0;

  /// 通用深浅玻璃浮层、遮罩与暗底纯白光学阶梯令牌。
  static const Color pureWhite = Color(0xFFFFFFFF);
  static const Color pureBlack = Color(0xFF000000);
  static const Color overlayWhiteSubtle = Color(0x14FFFFFF);
  static const Color overlayWhiteMuted = Color(0x21FFFFFF);
  static const Color overlayWhiteDim = Color(0x24FFFFFF);
  static const Color overlayWhiteBorder = Color(0x29FFFFFF);
  static const Color overlayWhiteBorderStrong = Color(0x38FFFFFF);
  static const Color overlayWhiteBorderHover = Color(0x3DFFFFFF);
  static const Color overlayWhiteStroke = Color(0x47FFFFFF);
  static const Color overlayWhiteTextMuted = Color(0xADFFFFFF);
  static const Color overlayWhiteTextDim = Color(0xB8FFFFFF);
  static const Color overlayWhiteTextSub = Color(0xCCFFFFFF);
  static const Color overlayWhiteTextMid = Color(0xD6FFFFFF);
  static const Color overlayWhiteTextHigh = Color(0xE6FFFFFF);
  static const Color overlayWhiteTextStrong = Color(0xF0FFFFFF);
  static const Color overlayWhiteTextPeak = Color(0xF5FFFFFF);
  static const Color scrimBlackHairline = Color(0x14000000);
  static const Color scrimBlackFaint = Color(0x29000000);
  static const Color scrimBlackSoft = Color(0x33000000);
  static const Color scrimBlackLight = Color(0x47000000);
  static const Color scrimBlackSubtle = Color(0x4D000000);
  static const Color scrimBlackMedium = Color(0x5C000000);
  static const Color scrimBlackModerate = Color(0x6B000000);
  static const Color scrimBlackStrong = Color(0x7A000000);
  static const Color scrimBlackHeavy = Color(0x94000000);
  static const Color scrimBlackDense = Color(0xAD000000);
  static const Color scrimBlackDeep = Color(0xB8000000);
  static const Color scrimBlackOpaque = Color(0xE6000000);

  /// 全站统一毛玻璃与模糊滤镜令牌（开启边缘钳制避免离屏采样扩张）。
  static final ui.ImageFilter blurFilterSubtle = ui.ImageFilter.blur(
    sigmaX: 14.0,
    sigmaY: 14.0,
    tileMode: ui.TileMode.clamp,
  );
  static final ui.ImageFilter blurFilterControl = ui.ImageFilter.blur(
    sigmaX: 20.0,
    sigmaY: 20.0,
    tileMode: ui.TileMode.clamp,
  );
  static final ui.ImageFilter blurFilterMedium = ui.ImageFilter.blur(
    sigmaX: 22.0,
    sigmaY: 22.0,
    tileMode: ui.TileMode.clamp,
  );
  static final ui.ImageFilter blurFilterOverlay = ui.ImageFilter.blur(
    sigmaX: 24.0,
    sigmaY: 24.0,
    tileMode: ui.TileMode.clamp,
  );
  static final ui.ImageFilter blurFilterCapsule = ui.ImageFilter.blur(
    sigmaX: 28.0,
    sigmaY: 28.0,
    tileMode: ui.TileMode.clamp,
  );
  static final ui.ImageFilter blurFilterLightbox = ui.ImageFilter.blur(
    sigmaX: 30.0,
    sigmaY: 30.0,
    tileMode: ui.TileMode.clamp,
  );
  static final ui.ImageFilter blurFilterSheet = ui.ImageFilter.blur(
    sigmaX: 44.0,
    sigmaY: 44.0,
    tileMode: ui.TileMode.clamp,
  );

  /// 按动态模糊半径构造统一钳制毛玻璃滤镜（供背景层毛玻璃复用）。
  static ui.ImageFilter blurFilterOf(double sigma) => ui.ImageFilter.blur(
    sigmaX: sigma,
    sigmaY: sigma,
    tileMode: ui.TileMode.clamp,
  );

  /// 按动态模糊半径构造边缘透明衰减滤镜（供前景倒影等独立图层模糊，避免边缘像素外延发亮）。
  static ui.ImageFilter blurFilterDecalOf(double sigma) => ui.ImageFilter.blur(
    sigmaX: sigma,
    sigmaY: sigma,
    tileMode: ui.TileMode.decal,
  );

  /// 暗底单色深黑 ClearLogo 的保色相亮度反相滤镜（180° 色相旋转复合反转，黑字柔化为光学象牙白且少量彩色点缀保持原色相）。
  static const ColorFilter clearLogoSmartInvertFilter = ColorFilter.matrix(
    <double>[
      0.540, -1.344, -0.135, 0, 244,
      -0.400, -0.404, -0.135, 0, 244,
      -0.400, -1.344, 0.805, 0, 244,
      0, 0, 0, 1, 0,
    ],
  );

  /// 深彩色无白边 ClearLogo 的字形轮廓霜白背晕滤镜与颜色令牌（`TileMode.decal` 保证画布边缘平滑归零不拖影）。
  static final ui.ImageFilter clearLogoHaloBlurWide = ui.ImageFilter.blur(
    sigmaX: 9.0,
    sigmaY: 9.0,
    tileMode: ui.TileMode.decal,
  );
  static final ui.ImageFilter clearLogoHaloBlurTight = ui.ImageFilter.blur(
    sigmaX: 2.5,
    sigmaY: 2.5,
    tileMode: ui.TileMode.decal,
  );
  static const Color clearLogoHaloGlowWide = Color(0x8CFFFFFF);
  static const Color clearLogoHaloGlowTight = Color(0x7AFFFFFF);

  /// 详情页主卡片与剧集卡片投影。
  static const Shadow heroCardTextShadow = Shadow(
    color: Color(0x8C000000),
    blurRadius: 12,
    offset: Offset(0, 2),
  );
  static const Shadow episodeCardTextShadow = Shadow(
    color: Color(0xA6000000),
    blurRadius: 8,
    offset: Offset(0, 1.5),
  );

  /// 详情页无徽标风格化主标题专属视觉令牌（三层光学投影、局部椭圆暗晕、渐隐细线与冷白微光）。
  static const Color detailHeroKickerBarColor = Color(0x99FFFFFF);
  static const Color detailHeroKickerTextColor = Color(0xC2E8EEF8);
  static const Color detailHeroSubtitleColor = Color(0xD4E8EEF8);
  static const List<Color> detailHeroTitleSheenColors = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFFE4EAF4),
  ];
  static const List<Color> detailHeroHairlineColors = <Color>[
    Color(0xA6FFFFFF),
    Color(0x38FFFFFF),
    Colors.transparent,
  ];
  static const List<double> detailHeroHairlineStops = <double>[0.0, 0.48, 1.0];
  static const List<Color> detailHeroBackdropHaloColors = <Color>[
    Color(0x5C0B0C10),
    Color(0x290B0C10),
    Colors.transparent,
  ];
  static const List<double> detailHeroBackdropHaloStops = <double>[
    0.0,
    0.54,
    1.0,
  ];
  static const List<Shadow> detailHeroTitleShadows = <Shadow>[
    Shadow(
      color: Color(0xC2000000),
      offset: Offset(0, 1),
      blurRadius: 2.5,
    ),
    Shadow(
      color: Color(0x8A000000),
      offset: Offset(0, 3),
      blurRadius: 10,
    ),
    Shadow(
      color: Color(0x4D000000),
      offset: Offset(0, 6),
      blurRadius: 24,
    ),
  ];
  static const double detailHeroMaxTextScale = 1.25;
  static const double detailHeroTitleStepDownDelta = 2.0;
  static const int detailHeroTitleMaxStepDowns = 2;
  static const double detailHeroBackdropHaloHorizontalOverflow = 34.0;
  static const double detailHeroBackdropHaloVerticalOverflow = 24.0;

  /// 透明徽标选择器暗底棋盘格单元格色阶（中性炭灰明度兼顾纯白与纯黑透明徽标辨识度）。
  static const Color logoCheckerDarkCellA = Color(0xFF282E3B);
  static const Color logoCheckerDarkCellB = Color(0xFF333B4C);

  /// 解析毛玻璃弹窗与侧边抽屉的高对比度表面色。
  static Color glassDialogSurface(KonataPalette p) => p.isDark
      ? const Color(0xE0141722)
      : const Color(0xF2FDFDFE);

  /// 解析毛玻璃弹窗与侧边抽屉的微光外框色。
  static Color glassDialogBorder(KonataPalette p) =>
      p.isDark ? const Color(0x33FFFFFF) : const Color(0xF5FFFFFF);

  /// 解析毛玻璃弹窗外围柔和阴影色。
  static Color glassDialogShadow(KonataPalette p) =>
      p.isDark ? const Color(0x70000000) : const Color(0x24000000);

  /// 解析光学玻璃表面顶部柔和斜向反光渐变（传入 [baseColor] 时通过 `Color.alphaBlend`
  /// 预混底层磨砂色，避免 `BoxDecoration` 同时指定 `color` 与 `gradient` 时丢弃底色）。
  static LinearGradient opticalSheenGradient(
    KonataPalette p, {
    bool hovered = false,
    Color? baseColor,
  }) {
    Color compose(Color sheen) =>
        baseColor != null ? Color.alphaBlend(sheen, baseColor) : sheen;
    if (p.isDark) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          compose(Colors.white.withValues(alpha: hovered ? 0.08 : 0.045)),
          compose(Colors.transparent),
          compose(Colors.black.withValues(alpha: 0.04)),
        ],
        stops: const [0.0, 0.42, 1.0],
      );
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        compose(Colors.white.withValues(alpha: hovered ? 0.46 : 0.30)),
        compose(Colors.white.withValues(alpha: 0.0)),
      ],
      stops: const [0.0, 0.55],
    );
  }

  /// 海报卡片 Bangumi 评分角标双主题毛玻璃填充色（对齐「N 部」计数胶囊视觉体系）。
  static Color bangumiBadgeFill(KonataPalette p) =>
      p.isDark ? bangumiBadgeDarkSurface : bangumiBadgeLightSurface;

  /// 海报卡片 Bangumi 评分角标双主题细亮描边色。
  static Color bangumiBadgeBorderFor(KonataPalette p) =>
      p.isDark ? overlayWhiteBorderStrong : p.hairline;

  /// 海报卡片 Bangumi 评分角标高对比品牌粉前景色（浅底微加深以防白底发飘）。
  static Color bangumiBadgeForeground(KonataPalette p) =>
      p.isDark ? bangumiPink : bangumiPinkLightTheme;

  /// 错误悬浮提示胶囊高对比底色、描边与文字色（杜绝浅色模式红底深字不可读）。
  static Color toastErrorSurface(KonataPalette p) =>
      p.isDark ? toastErrorDarkSurface : toastErrorLightSurface;

  static Color toastErrorBorder(KonataPalette p) =>
      p.isDark ? toastErrorDarkBorder : toastErrorLightBorder;

  static Color toastErrorForeground(KonataPalette p) =>
      p.isDark ? toastErrorDarkFg : toastErrorLightFg;

  /// 解析毛玻璃弹窗标准背景暗罩色。
  static Color glassDialogBarrier(bool isDark) =>
      isDark ? const Color(0x73000000) : const Color(0x59000000);

  /// 解析强模态毛玻璃浮层（如居中确认框、音频选单）背景暗罩色。
  static Color glassModalBarrier(bool isDark) =>
      isDark ? const Color(0x7A000000) : const Color(0x57000000);

  /// 解析右侧毛玻璃滑入抽屉背景暗罩色。
  static Color glassSideSheetBarrier(bool isDark) =>
      isDark ? const Color(0x70000000) : const Color(0x59000000);

  /// 解析单行溢出悬浮 Tooltip 背景色。
  static Color tooltipSurface(KonataPalette p) =>
      p.isDark ? const Color(0xEC1B2029) : const Color(0xF6FFFFFF);

  /// 解析单行溢出悬浮 Tooltip 前景文字色。
  static Color tooltipTextColor(KonataPalette p) =>
      p.isDark ? overlayWhiteTextStrong : p.textPrimary;

  /// 解析单行溢出悬浮 Tooltip 细边描边色。
  static Color tooltipBorder(KonataPalette p) =>
      p.isDark ? overlayWhiteBorder : const Color(0x1A000000);

  /// 解析单行溢出悬浮 Tooltip 柔和投影色。
  static Color tooltipShadow(KonataPalette p) =>
      p.isDark ? scrimBlackMedium : const Color(0x1F000000);

  /// 解析分段胶囊选中滑块填充色。
  static Color segmentedThumbSurface(KonataPalette p) =>
      p.isDark ? const Color(0x2EFFFFFF) : overlayWhiteTextPeak;

  /// 解析分段胶囊选中滑块细边描边色。
  static Color segmentedThumbBorder(KonataPalette p) =>
      p.isDark ? overlayWhiteBorder : scrimBlackHairline;

  /// 解析分段胶囊选中滑块柔和投影色。
  static Color segmentedThumbShadow(bool isDark) =>
      isDark ? const Color(0x3D000000) : scrimBlackHairline;

  /// 解析通用表面卡片极轻柔外框色。
  static Color surfaceCardSubtleBorder(KonataPalette p) =>
      p.isDark ? const Color(0x12FFFFFF) : const Color(0x0C000000);

  /// 解析深色半透烟熏毛玻璃胶囊底色（浅色回退至 `p.surface`）。
  static Color capsuleDarkSurface(KonataPalette p) =>
      p.isDark ? const Color(0xCC161618) : p.surface;

  /// 解析规格角标中性底色与描边色。
  static Color specNeutralBadgeBg(KonataPalette p) =>
      p.isDark ? const Color(0x991C2029) : const Color(0x160F172A);
  static Color specNeutralBadgeBorder(KonataPalette p) =>
      p.isDark ? const Color(0x42FFFFFF) : const Color(0x3D0F172A);

  /// 解析通用次级控件柔边、悬停填充与轻描边色。
  static Color subtleOutlineBorder(KonataPalette p) =>
      p.isDark ? const Color(0x18FFFFFF) : const Color(0x0D0F172A);
  static Color subtleControlBorder(KonataPalette p) =>
      p.isDark ? const Color(0x22FFFFFF) : const Color(0x1A0F172A);
  static Color subtleControlFill(KonataPalette p) =>
      p.isDark ? const Color(0x1FFFFFFF) : const Color(0x140F172A);
  static Color activeControlBorder(KonataPalette p) =>
      p.isDark ? const Color(0x42FFFFFF) : p.primaryButtonBg;
  static Color darkInkBorder(KonataPalette p) =>
      p.isDark ? overlayWhiteBorder : const Color(0x260F172A);
  static Color episodeCardOutline(
    KonataPalette p, {
    required bool hovered,
  }) => p.isDark
      ? (hovered ? const Color(0x5CFFFFFF) : overlayWhiteBorder)
      : detailLightSlatePrimary.withValues(alpha: hovered ? 0.28 : 0.12);

  static const double switchTrackWidth = 44.0;
  static const double switchTrackHeight = 24.0;
  static const double switchThumbSize = 18.0;
  static const double switchThumbPadding = 3.0;
  static const double switchOutlineWidth = 1.4;

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
  static const List<Shadow> detailTextShadows = <Shadow>[
    Shadow(
      color: Color(0xA6000000),
      offset: Offset(0, 1.5),
      blurRadius: 4,
    ),
    Shadow(
      color: Color(0x73000000),
      offset: Offset(0, 3),
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

  /// 构建详情页无徽标风格化展示大标题样式（直接透传可变展示字重与三层光学投影，不受全局浅色主题去影影响）。
  static TextStyle detailHeroTitleStyle({
    required double fontSize,
    required double weight,
    Color color = pureWhite,
    double? letterSpacing,
    double? height,
    List<Shadow>? shadows,
  }) {
    return textStyle(
      fontSize: fontSize,
      weight: weight.clamp(400.0, 800.0),
      color: color,
      letterSpacing: letterSpacing,
      height: height,
      tabularFigures: false,
      shadows: shadows ?? detailHeroTitleShadows,
    );
  }

  /// 构建深色模式主题（应用壳层可按需缓存复用）。
  static ThemeData darkTheme() => _buildTheme(KonataPalette.dark);

  /// 构建亮色模式主题（应用壳层可按需缓存复用）。
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
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.accent,
        selectionColor: palette.accent.withValues(
          alpha: palette.isDark ? 0.34 : 0.24,
        ),
        selectionHandleColor: palette.accent,
      ),
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
                ? Colors.white.withValues(alpha: 0.68)
                : Colors.black.withValues(alpha: 0.52);
          }
          if (states.contains(WidgetState.hovered)) {
            return palette.isDark
                ? Colors.white.withValues(alpha: 0.48)
                : Colors.black.withValues(alpha: 0.38);
          }
          return palette.isDark
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.black.withValues(alpha: 0.18);
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
      switchTheme: SwitchThemeData(
        splashRadius: 0,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return palette.textMuted.withValues(alpha: 0.45);
          }
          if (states.contains(WidgetState.selected)) {
            return palette.primaryButtonFg;
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed)) {
            return palette.textPrimary;
          }
          return palette.isDark
              ? Colors.white.withValues(alpha: 0.75)
              : palette.textPrimary.withValues(alpha: 0.82);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return palette.softFill.withValues(alpha: 0.35);
          }
          final hovered = states.contains(WidgetState.hovered);
          final pressed = states.contains(WidgetState.pressed);
          if (states.contains(WidgetState.selected)) {
            if (pressed) {
              return palette.primaryButtonBg.withValues(alpha: 0.76);
            }
            if (hovered) {
              return palette.primaryButtonBg.withValues(alpha: 0.86);
            }
            return palette.primaryButtonBg;
          }
          if (pressed) {
            return palette.isDark
                ? Colors.white.withValues(alpha: 0.20)
                : Colors.black.withValues(alpha: 0.13);
          }
          if (hovered) {
            return palette.isDark
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.black.withValues(alpha: 0.08);
          }
          return palette.isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.025);
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          if (states.contains(WidgetState.disabled)) {
            return palette.hairline;
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed)) {
            return palette.isDark
                ? Colors.white.withValues(alpha: 0.64)
                : palette.textPrimary;
          }
          return palette.isDark
              ? Colors.white.withValues(alpha: 0.38)
              : palette.textPrimary.withValues(alpha: 0.72);
        }),
        trackOutlineWidth: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? 0.0 : 1.5;
        }),
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
