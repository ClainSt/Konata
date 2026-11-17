import 'package:flutter/material.dart';

import 'konata_palette.dart';
import 'konata_theme.dart';

/// Konata 音视频播放器、流光音频页与极简 OSD 全局统一视觉与时序常量。
///
/// 严禁在播放页面或播控控件内部散落硬编码像素、模糊 sigma、时长或裸色值。
abstract final class KonataPlaybackTokens {
  /// 根据当前主题调色盘解析明暗双套毛玻璃表面色（浅色画册米白 / 深色中性炭黑）。
  static Color glassSurface(KonataPalette p) =>
      p.isDark ? const Color(0xB8161618) : p.surface;

  /// 根据当前主题解析弹出式菜单、选曲队列及浮层底色。
  static Color popoverSurface(KonataPalette p) =>
      p.isDark ? const Color(0xF01E2026) : p.elevatedSurface;

  /// 根据当前主题解析毛玻璃细微描边。
  static Color glassBorder(KonataPalette p) =>
      p.isDark ? const Color(0x24FFFFFF) : p.hairline;

  /// 根据当前主题解析悬停或激活态毛玻璃描边。
  static Color activeGlassBorder(KonataPalette p) =>
      p.isDark ? const Color(0x42FFFFFF) : p.hoverBorder;

  /// 根据当前主题解析柔和半透明次级底衬色。
  static Color softFill(KonataPalette p) =>
      p.isDark ? const Color(0x24FFFFFF) : const Color(0x120F172A);

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

  /// 全屏流光音乐页背景底色与默认流光极光主色采样回退色。
  static const Color auroraCanvasDark = Color(0xFF0C0E14);
  static const Color auroraDefaultGlowA = Color(0xFF3E4C8A);
  static const Color auroraDefaultGlowB = Color(0xFF6E3C6B);
  static const Color auroraDefaultGlowC = Color(0xFF285B6E);

  /// 中性烟熏炭黑毛玻璃胶囊浮层统一底色（零蓝色偏色，四侧连续闭合 1px 微光描边）。
  static const Color osdSurfaceDark = Color(0xB3161618);

  /// 浮层连续 1px 微光玻璃描边。
  static const Color osdBorderLight = Color(0x24FFFFFF);

  /// 浮层主前景色。
  static const Color osdTextPrimary = Color(0xFFF5F7FA);

  /// 浮层次前景色。
  static const Color osdTextSecondary = Color(0xBAE5EAF2);

  /// 浮层微弱填充色（滑块底槽 / 次级按钮底色）。
  static const Color osdSoftFill = Color(0x24FFFFFF);

  /// 浮层主色调（亮白激活态）。
  static const Color osdAccent = Color(0xFFFFFFFF);

  /// 播控胶囊与音频进度的全站统一蓝色填充与轻柔微透明白底轨。
  static const Color capsuleProgressFill = Color(0xFF6BA6FF);
  static const Color capsuleProgressTrack = Color(0x22FFFFFF);

  /// 音视频共享单层底部居中悬浮毛玻璃播控胶囊约束与几何规范。
  static const double capsuleHeight = 62.0;
  static const double capsuleMaxWidth = 900.0;
  static const double capsuleMinWidth = 340.0;
  static const double capsuleCenterSymmetricBreakpoint = 560.0;
  static const double capsuleRadius = 20.0;
  static const double capsuleBlurSigma = 28.0;
  static const double capsuleBottomOffset = 20.0;
  static const EdgeInsets capsulePadding = EdgeInsets.fromLTRB(16, 4, 16, 12);

  /// 胶囊内部底置内缩全圆角细滑轨几何参数（无背景盒，常态 4.5px，悬停/拖拽 9.0px，命中高度 18px 防抖）。
  static const double capsuleProgressRestHeight = 4.5;
  static const double capsuleProgressHoverHeight = 9.0;
  static const double capsuleProgressHitHeight = 18.0;
  static const double capsuleProgressHorizontalInset = 18.0;
  static const double capsuleProgressBottomInset = 6.0;
  static const double capsuleHoverBubbleBottomOffset = 68.0;

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

  /// 全局持久迷你音频底栏规范（与 `KonataPlaybackCapsule` 共享同源几何尺寸）。
  static const double miniBarHeight = capsuleHeight;
  static const double miniBarMaxWidth = capsuleMaxWidth;
  static const double miniBarRadius = capsuleRadius;
  static const double miniBarBlurSigma = capsuleBlurSigma;
  static const double miniBarBottomInset = 18.0;
  static const double miniBarHorizontalInset = 20.0;
  static const double miniBarClearanceHeight = 88.0;
  static const double miniQueuePopoverMaxWidth = 440.0;
  static const double miniQueuePopoverMaxHeight = 320.0;
  static const double miniQueuePopoverMinHeight = 160.0;
  static const double miniQueuePopoverOffsetY = -10.0;
  static const double miniQueuePopoverRadius = 18.0;
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
  static const Duration hudFadeDuration = Duration(milliseconds: 200);
  static const Duration pauseBadgeDisplayDuration = Duration(milliseconds: 800);
  static const Duration wheelVolumeOsdDuration = Duration(milliseconds: 1200);
  static const Duration autoNextEpisodeToastDuration = Duration(
    milliseconds: 3000,
  );

  /// 全屏音频与后台纯音频静态三层模糊背景遮罩透明度（严格位于 0.4 ~ 0.6 红线区间）。
  static const double auroraScrimDarkAlpha = 0.48;
  static const double auroraScrimLightAlpha = 0.56;

  /// 平板端双栏全屏音频左栏封面最大边长（位于 360 ~ 420dp 区间）。
  static const double tabletAlbumCoverMaxSize = 396.0;

  /// 视频迷你胶囊实时画面圆角预览框尺寸。
  static const double miniVideoPreviewWidth = 60.0;
  static const double miniVideoPreviewHeight = 38.0;
  static const double miniVideoPreviewRadius = 10.0;

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
  static const double albumCoverSize = 336.0;
  static const double albumCoverRadius = 18.0;
  static const double albumReflectionHeight = 86.0;
  static const double auroraBlurSigma = 88.0;
  static const List<Color> albumReflectionMaskColors = [
    Color(0x58FFFFFF),
    Color(0x16FFFFFF),
    Colors.transparent,
  ];
  static const double lyricActiveFontSize = 24.0;
  static const double lyricInactiveFontSize = 18.5;
  static const double lyricSecondaryFontSize = 13.5;
  static const double lyricBlurStep1 = 1.6;
  static const double lyricBlurStep2 = 3.2;
  static const double lyricBlurStepFar = 5.0;
  static const Duration lyricUserScrollResetDelay = Duration(
    milliseconds: 2500,
  );

  /// 探针浮层与 HUD 等宽数字样式。
  static const List<FontFeature> tabularNumbers = [
    FontFeature.tabularFigures(),
  ];
}
