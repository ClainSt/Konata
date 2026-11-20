import 'package:flutter/material.dart';

import 'konata_palette.dart';
import 'konata_theme.dart';

/// Konata 音视频播放器、流光音频页与极简 OSD 全局统一视觉与时序常量。
///
/// 严禁在播放页面或播控控件内部散落硬编码像素、模糊 sigma、时长或裸色值。
abstract final class KonataPlaybackTokens {
  /// 根据当前主题调色盘解析明暗双套光学玻璃表面色（浅色陶瓷柔白 / 深色轻透流光暗玻璃）。
  static Color glassSurface(KonataPalette p) =>
      p.isDark ? const Color(0x7810131C) : p.surface;

  /// 根据当前主题解析弹出式菜单、选曲队列及浮层底色。
  static Color popoverSurface(KonataPalette p) =>
      p.isDark ? const Color(0xE8131620) : p.elevatedSurface;

  /// 根据当前主题解析毛玻璃细微描边。
  static Color glassBorder(KonataPalette p) =>
      p.isDark ? const Color(0x2BFFFFFF) : p.hairline;

  /// 根据当前主题解析悬停或激活态毛玻璃描边。
  static Color activeGlassBorder(KonataPalette p) =>
      p.isDark ? const Color(0x4DFFFFFF) : p.hoverBorder;

  /// 根据当前主题解析播控进度条发光填充色（暗色为光学纯白，亮色为深石板墨色）。
  static Color capsuleProgressFillFor(KonataPalette p) => p.progressFill;

  /// 根据当前主题解析播控进度条微透明底轨色。
  static Color capsuleProgressTrackFor(KonataPalette p) =>
      p.isDark ? capsuleProgressTrack : p.progressTrack;

  /// 根据当前主题解析柔和半透明次级底衬色。
  static Color softFill(KonataPalette p) =>
      p.isDark ? const Color(0x24FFFFFF) : const Color(0x120F172A);

  /// 分段切换胶囊外轨描边色（深浅主题均保持清晰 1px 轮廓与质感层次）。
  static Color segmentedTrackBorder(KonataPalette p) =>
      p.isDark ? const Color(0x24FFFFFF) : const Color(0x1A0F172A);

  /// 根据当前主题解析胶囊内部微交互高亮/激活背景色。
  static Color activePillBg(KonataPalette p) =>
      p.isDark ? const Color(0x38FFFFFF) : const Color(0x140F172A);

  /// 根据当前主题解析悬停柔和底色。
  static Color hoverFill(KonataPalette p) =>
      p.isDark ? const Color(0x14FFFFFF) : const Color(0x0D0F172A);

  /// 根据当前主题解析柔和环境投影色。
  static Color shadowColor(KonataPalette p) =>
      Colors.black.withValues(alpha: p.isDark ? 0.34 : 0.12);

  /// 全屏流光音频页背景底色（随明暗切换：暗夜黑曜 / 画册暖白）。
  static Color auroraCanvas(KonataPalette p) =>
      p.isDark ? auroraCanvasDark : const Color(0xFFF6F5F1);

  /// 详情页与音频页定向渐隐遮罩基色。
  static Color detailScrimBase(KonataPalette p) =>
      p.isDark ? cinemaPureBlack : const Color(0xFFF6F8FC);

  /// 详情页「继续播放」主胶囊双主题毛玻璃填充色（浅色对齐「待复核」柔和 p.surface 磨砂）。
  static Color heroPlayButtonFill(
    KonataPalette p, {
    required bool enabled,
    required bool hovered,
    required bool pressed,
  }) {
    if (p.isDark) {
      if (!enabled) return const Color(0x8014171E);
      if (pressed) return const Color(0xBA14171E);
      if (hovered) return const Color(0xEB1F2430);
      return const Color(0xD414171E);
    }
    if (!enabled) return p.surface.withValues(alpha: 0.48);
    if (pressed) return p.secondaryButtonBg;
    if (hovered) return p.surfaceHover;
    return p.surface;
  }

  /// 详情页二级筛选胶囊背景色（浅色对齐「待复核」p.surface 柔和磨砂，深色烟熏暗透）。
  static Color secondaryFilterPillBg(
    KonataPalette p, {
    required bool selected,
    required bool hovered,
  }) {
    if (p.isDark) {
      if (selected) {
        return Color.alphaBlend(
          p.accent.withValues(alpha: 0.28),
          const Color(0xE014171E),
        );
      }
      return hovered ? const Color(0xE01E222B) : const Color(0xCC14171E);
    }
    if (selected) {
      return Color.alphaBlend(p.accent.withValues(alpha: 0.20), p.surfaceHover);
    }
    return hovered ? p.surfaceHover : p.surface;
  }

  /// 详情页二级筛选胶囊描边色。
  static Color secondaryFilterPillBorder(
    KonataPalette p, {
    required bool selected,
  }) {
    if (selected) {
      return p.isDark
          ? p.accent.withValues(alpha: 0.55)
          : p.accent.withValues(alpha: 0.48);
    }
    return glassBorder(p);
  }

  /// 详情页二级筛选胶囊文本色。
  static Color secondaryFilterPillText(
    KonataPalette p, {
    required bool selected,
    required bool hovered,
  }) {
    if (p.isDark) {
      if (selected) return p.accentBadge.fg;
      return hovered ? p.textPrimary : p.textSecondary;
    }
    if (selected) return p.accent;
    return KonataTheme.detailLightSlatePrimary;
  }

  /// 内置视频页最底层防 DWM 透底纯黑画布（全屏/非全屏切换绝不触碰窗体材质）。
  static const Color cinemaPureBlack = Color(0xFF000000);

  /// 全屏流光音乐页背景底色与默认流光极光主色采样回退色（丝绒玫瑰莓紫 + 靛蓝 + 暖梅调）。
  static const Color auroraCanvasDark = Color(0xFF0A0C12);
  static const Color auroraDefaultGlowA = Color(0xFFA23E6F);
  static const Color auroraDefaultGlowB = Color(0xFF3E4E96);
  static const Color auroraDefaultGlowC = Color(0xFF7B436E);

  /// 中性烟熏暗玻璃胶囊浮层统一底色（四侧连续闭合 1px 微光描边）。
  static const Color osdSurfaceDark = Color(0x8810131C);

  /// 浮层连续 1px 微光玻璃描边。
  static const Color osdBorderLight = Color(0x2BFFFFFF);

  /// 浮层主前景色。
  static const Color osdTextPrimary = Color(0xFFF6F7FB);

  /// 浮层次前景色。
  static const Color osdTextSecondary = Color(0xC2E6EBF4);

  /// 浮层微弱填充色（滑块底槽 / 次级按钮底色）。
  static const Color osdSoftFill = Color(0x26FFFFFF);

  /// 浮层主色调（亮白激活态）。
  static const Color osdAccent = Color(0xFFFFFFFF);

  /// 播控胶囊与音频进度的光学纯白发光填充与轻柔微透明白底轨。
  static const Color capsuleProgressFill = Color(0xFFFFFFFF);
  static const Color capsuleProgressTrack = Color(0x36FFFFFF);

  /// 音视频共享单层底部居中悬浮光学毛玻璃播控胶囊约束与几何规范。
  static const double capsuleHeight = 60.0;
  static const double capsuleMaxWidth = 860.0;
  static const double capsuleAudioMaxWidth = 720.0;
  static const double capsuleMinWidth = 340.0;
  static const double capsuleCenterSymmetricBreakpoint = 440.0;
  static const double capsuleRadius = 999.0;
  static const double capsuleBlurSigma = 28.0;
  static const double capsuleBottomOffset = 20.0;
  static const EdgeInsets capsulePadding = EdgeInsets.fromLTRB(20, 10, 20, 6);

  /// 胶囊内部顶沿发光全圆角细滑轨几何参数（常态 2.5px，悬停/拖拽 5.0px，命中高度 18px 防抖）。
  static const double capsuleProgressRestHeight = 2.5;
  static const double capsuleProgressHoverHeight = 5.0;
  static const double capsuleProgressHitHeight = 18.0;
  static const double capsuleProgressHorizontalInset = 28.0;
  static const double capsuleProgressTopInset = 1.5;
  static const double capsuleHoverBubbleBottomOffset = 72.0;

  /// 全屏音乐页独立「曲目列表 / 同步歌词」紧凑圆角方块按钮规范。
  static const double immersiveSwitchButtonSize = 32.0;
  static const double immersiveSwitchButtonRadius = 8.0;
  static const Color immersiveSwitchActiveBg = Color(0x24FFFFFF);
  static const Color immersiveSwitchInactiveFg = Color(0x99FFFFFF);

  /// 紧凑滚轮静音与悬停纵向浮层几何规范（无数字标签，悬停纵向滑杆支持 1% 连续微调）。
  static const double volumePopoverWidth = 36.0;
  static const double volumePopoverHeight = 118.0;
  static const double volumePopoverVerticalPadding = 12.0;
  static const double volumePopoverBridgeHeight = 8.0;
  static const double volumeKnobRestSize = 10.0;
  static const double volumeKnobDraggingSize = 13.0;
  static const Duration volumePopoverDismissDelay = Duration(milliseconds: 140);

  /// 实时音画规格胶囊徽标规范。
  static const Color videoOverlayBadgeBg = Color(0xBD0C1017);
  static const Color videoOverlayBadgeBorder = Color(0x40FFFFFF);
  static const Color videoOverlayBadgeFg = Color(0xFFF8FAFC);
  static const double specBadgeRadius = 999.0;
  static const EdgeInsets specBadgePadding = EdgeInsets.symmetric(
    horizontal: 9,
    vertical: 3.5,
  );
  static const double specBadgeFontSize = 11.0;

  /// 全端统一可拖拽音视频悬浮小窗几何、动态比例、贴边收折与手机底栏协同常量。
  static const double floatingMiniVideoWidth = 256.0;
  static const double floatingMiniVideoHeight = 144.0;
  static const double floatingMiniVideoLongSideDesktop = 256.0;
  static const double floatingMiniVideoLongSidePhone = 208.0;
  static const double floatingMiniVideoAspectRatioMin = 0.42;
  static const double floatingMiniVideoAspectRatioMax = 2.39;
  static const double floatingMiniAudioDiscSize = 56.0;
  static const double floatingMiniAudioRingWidth = 2.4;
  static const double floatingMiniAudioPillWidth = 320.0;
  static const double floatingMiniAudioPillHeight = 60.0;
  static const double floatingMiniAudioPillCoverSize = 40.0;
  static const double floatingMiniEarTabWidth = 24.0;
  static const double floatingMiniEarTabHeight = 72.0;
  static const double floatingMiniEdgeTuckDragThreshold = 20.0;
  static const double floatingMiniPhoneNavInlineGap = 10.0;
  static const double floatingMiniRadius = 16.0;
  static const double floatingMiniBorderWidth = 1.0;
  static const double floatingMiniEdgeMargin = 12.0;
  static const double floatingMiniNavigationGap = 10.0;
  static const double floatingMiniBottomClearanceGap = 12.0;
  static const double floatingMiniDesktopTopBarClearance = 52.0;
  static const double floatingMiniBottomZoneThresholdRatio = 0.55;
  static const double floatingMiniOverlayPillSize = 28.0;
  static const double floatingMiniOverlayIconSize = 16.0;
  static const double floatingMiniTransportIconSize = 20.0;
  static const double floatingMiniFallbackIconSize = 26.0;
  static const int floatingMiniCoverDecodeWidth = 240;
  static const double floatingMiniShadowBlur = 24.0;
  static const Offset floatingMiniShadowOffset = Offset(0, 8);
  static const double floatingMiniFlickProjectionSeconds = 0.07;
  static const Color floatingMiniChromeScrimTop = Color(0x75000000);
  static const Color floatingMiniChromeScrimMid = Color(0x1F000000);

  /// 悬浮小窗松手吸附临界阻尼物理弹簧参数（120Hz 跟手速度继承，落位立即停钟）。
  static final SpringDescription floatingMiniSnapSpring =
      SpringDescription.withDampingRatio(
        mass: 1.0,
        stiffness: 420.0,
        ratio: 1.0,
      );

  /// 悬浮小窗与全屏播放舞台之间的视口/圆角形变临界阻尼物理弹簧参数。
  static final SpringDescription stageMorphSpring =
      SpringDescription.withDampingRatio(
        mass: 1.0,
        stiffness: 380.0,
        ratio: 1.0,
      );

  /// 物理弹簧初始归一化速度钳位上限，防止极高速甩动产生过冲。
  static const double springNormalizedVelocityMax = 14.0;

  /// Windows 左方向键按住连发快退节流周期（250ms）。
  static const Duration arrowLeftRepeatThrottle = Duration(milliseconds: 250);

  /// Windows 右方向键长按进入 2.0x 临时倍速判定阈值（260ms）。
  static const Duration arrowRightHoldDelay = Duration(milliseconds: 260);
  static const Duration floatingMiniOverlayFadeDuration = Duration(
    milliseconds: 140,
  );
  static const Duration floatingMiniOverlayAutoHideDuration = Duration(
    seconds: 3,
  );
  static const double miniBarHideBadgeBreakpoint = 720.0;
  static const Duration audioCueSeekDebounceWindow = Duration(
    milliseconds: 900,
  );

  /// 内置视频右滑毛玻璃侧栏避让尺寸（底部保证停留在播控胶囊上方 14px 呼吸间距处）。
  static const double videoSideSheetWidth = 420.0;
  static const double videoSideSheetBottomInset =
      capsuleBottomOffset + capsuleHeight + 14.0;

  /// 右下角智能跳过 OP/ED 胶囊固定位置（与 `AGENTS.md` / 阶段 3 规范对齐）。
  static const double skipPillBottomOffset = 88.0;
  static const double skipPillRightOffset = 24.0;
  static const Duration skipPillAutoFadeDuration = Duration(milliseconds: 4000);

  /// 极简隐身 HUD 定时阈值（播放无操作满 3 秒平滑隐藏并退订进度界面监听）。
  static const Duration cursorIdleFadeDelay = Duration(milliseconds: 3000);
  static const Duration hudFadeDuration = Duration(milliseconds: 95);
  static const Duration pauseBadgeDisplayDuration = Duration(milliseconds: 800);
  static const Duration wheelVolumeOsdDuration = Duration(milliseconds: 1200);
  static const Duration autoNextEpisodeToastDuration = Duration(
    milliseconds: 3000,
  );

  /// 全屏音频与后台纯音频 GPU 径向流光着色场遮罩透明度（严格位于 0.4 ~ 0.6 红线区间）。
  static const double auroraScrimDarkAlpha = 0.40;
  static const double auroraScrimLightAlpha = 0.52;

  /// 全屏音频流光背景切歌有界色彩过渡时长（800 ms，到位立即停钟）。
  static const Duration auroraColorTransitionDuration = Duration(
    milliseconds: 800,
  );

  /// 平板端双栏全屏音频左栏封面最大边长（位于 360 ~ 420dp 区间）。
  static const double tabletAlbumCoverMaxSize = 396.0;

  /// 详情页「继续播放」主按钮与「系列切换下拉」同行等高胶囊几何常量。
  static const double detailActionCapsuleDesktopHeight = 42.0;
  static const double detailActionCapsuleTouchHeight = 48.0;
  static const double detailActionCapsuleRadius = 999.0;
  static const double detailActionCapsuleBorderWidth = 1.0;

  /// 解析详情页同行主操作胶囊的标准高度。
  static double detailActionCapsuleHeight({required bool isTouch}) =>
      isTouch ? detailActionCapsuleTouchHeight : detailActionCapsuleDesktopHeight;

  /// 全局鼠标滚轮与键盘音量调节步进（0 ~ 100，精确 1% 整数步进）。
  static const double wheelVolumeStep = 1.0;

  /// 原生 `mpv` 纯文字描边 OSD（技术探针 & 瞬时音量提示）样式常量。
  static const Color osdStrokeColor = Color(0xFF000000);
  static const double osdStrokeWidth = 2.4;
  static const Color osdProbeLabelColor = Color(0xFFD6DCE6);
  static const Color osdProbeValueColor = Color(0xFFFFFFFF);
  static const double wheelVolumeOsdTopOffset = 76.0;

  /// 进度条高对比度 45° 菱形章节点尺寸与描边常量。
  static const double chapterDiamondRestSize = 7.0;
  static const double chapterDiamondHoverSize = 10.5;
  static const double chapterDiamondStrokeWidth = 1.25;

  /// `thumbfast` 级后台缩略图会话解码尺寸、预热延迟与时间桶配置（严格 4 像素对齐 192x108）。
  static const int thumbnailDecodeWidth = 192;
  static const int thumbnailDecodeHeight = 108;
  static const double thumbnailPreviewDisplayWidth = 176.0;
  static const double thumbnailPreviewDisplayHeight = 99.0;
  static const double thumbnailPreviewRadius = 10.0;
  static const Duration thumbnailWarmupDelay = Duration(milliseconds: 800);
  static const double thumbnailLocalBucketSeconds = 1.0;
  static const double thumbnailRemoteBucketSeconds = 5.0;
  static const int thumbnailCacheCapacity = 48;

  /// 全屏沉浸音频页几何、流光采样与阶梯景深模糊歌词参数。
  static const double albumCoverSize = 340.0;
  static const double albumCoverRadius = 14.0;
  static const double albumReflectionHeight = 104.0;
  static const double albumReflectionBlurSigma = 2.8;
  static const double auroraBlurSigma = 88.0;
  static const List<Color> albumReflectionMaskColors = [
    Color(0x52FFFFFF),
    Color(0x18FFFFFF),
    Colors.transparent,
  ];
  static const double lyricActiveFontSize = 24.0;
  static const double lyricCompactActiveFontSize = 18.0;
  static const double lyricInactiveFontSize = 18.5;
  static const double lyricCompactInactiveFontSize = 14.5;
  static const double lyricSecondaryFontSize = 13.5;
  static const double lyricBlurStep1 = 1.5;
  static const double lyricBlurStep2 = 3.0;
  static const double lyricBlurStepFar = 4.4;
  static const double lyricGlowBlurRadius = 18.0;
  static const double lyricSweepGlowBlurRadius = 14.0;
  static const double queueRowTitleActiveFontSize = 16.0;
  static const double queueRowTitleInactiveFontSize = 14.5;
  static const double queueSubTrackTitleActiveFontSize = 15.0;
  static const double queueSubTrackTitleInactiveFontSize = 13.8;
  static const double queueRowMetaFontSize = 12.0;
  static const double queueRowSubtitleFontSize = 11.5;
  static const double queueRowPrefixFontSize = 12.5;
  static const double touchScrubberTrackHeight = 2.5;
  static const double touchScrubberThumbRadius = 5.5;
  static const double touchScrubberOverlayRadius = 14.0;
  static const double touchScrubberHeight = 30.0;
  static const double touchScrubberCompactHeight = 24.0;
  static const double touchScrubberTimeFontSize = 11.5;
  static const double albumCoverShadowBlur = 42.0;
  static const Offset albumCoverShadowOffset = Offset(0, 20);
  static const int albumCoverDecodeWidth = 800;
  static const double microCoverSize = 38.0;
  static const double microCoverRadius = 9.0;
  static const int microCoverDecodeWidth = 160;
  static const double microCoverFallbackIconSize = 18.0;
  static const Duration lyricStyleTransitionDuration = Duration(
    milliseconds: 160,
  );
  static const Duration queueRowTransitionDuration = Duration(
    milliseconds: 140,
  );
  static const Duration equalizerCycleDuration = Duration(milliseconds: 1150);
  static const Duration lyricUserScrollResetDelay = Duration(
    milliseconds: 2500,
  );

  /// Android 进入视频页等待自动旋转至横屏的最大有界宽限时长（超时或锁定竖屏/分屏时自动恢复全部 HUD）。
  static const Duration portraitRotationFallbackTimeout = Duration(
    milliseconds: 350,
  );

  /// 音量滚轮或拖拽停止后浮层自动收起的空闲延时。
  static const Duration volumeAdjustIdleAutoHideDelay = Duration(
    milliseconds: 1500,
  );

  /// 音量滑块圆点交互缩放过渡时长。
  static const Duration volumeKnobMotionDuration = Duration(milliseconds: 100);

  /// 歌词与当前队列高亮行统一柔光阴影（随明暗主题自动切换对比度）。
  static List<Shadow> lyricGlowShadow(
    KonataPalette p, {
    double intensity = 1.0,
    double blurRadius = lyricGlowBlurRadius,
  }) {
    final alpha = (p.isDark ? 0.34 : 0.11) * intensity.clamp(0.0, 1.0);
    return <Shadow>[
      Shadow(
        color: (p.isDark ? Colors.white : Colors.black).withValues(
          alpha: alpha,
        ),
        blurRadius: blurRadius,
      ),
    ];
  }

  /// 探针浮层与 HUD 等宽数字样式。
  static const List<FontFeature> tabularNumbers = [
    FontFeature.tabularFigures(),
  ];
}
