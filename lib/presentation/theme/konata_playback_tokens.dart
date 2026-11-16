import 'package:flutter/material.dart';

/// Konata 音视频播放器、流光音频页与极简 OSD 全局统一视觉与时序常量。
///
/// 严禁在播放页面或播控控件内部散落硬编码像素、模糊 sigma、时长或裸色值。
abstract final class KonataPlaybackTokens {
  /// 内置视频页最底层防 DWM 透底纯黑画布（全屏/非全屏切换绝不触碰窗体材质）。
  static const Color cinemaPureBlack = Color(0xFF000000);

  /// 全屏流光音乐页背景底色与默认流光极光主色采样回退色。
  static const Color auroraCanvasDark = Color(0xFF0C0E14);
  static const Color auroraDefaultGlowA = Color(0xFF3E4C8A);
  static const Color auroraDefaultGlowB = Color(0xFF6E3C6B);
  static const Color auroraDefaultGlowC = Color(0xFF285B6E);

  /// 深色浮层底色（确保视频亮画面之上胶囊控件依然可读）。
  static const Color osdSurfaceDark = Color(0x9C10131A);

  /// 浮层描边高光。
  static const Color osdBorderLight = Color(0x30FFFFFF);

  /// 浮层主前景色。
  static const Color osdTextPrimary = Color(0xFFF5F7FA);

  /// 浮层次前景色。
  static const Color osdTextSecondary = Color(0xBAE5EAF2);

  /// 浮层微弱填充色（滑块底槽 / 次级按钮底色）。
  static const Color osdSoftFill = Color(0x24FFFFFF);

  /// 浮层主色调（亮白激活态）。
  static const Color osdAccent = Color(0xFFFFFFFF);

  /// 音视频共享单层底部居中悬浮毛玻璃播控胶囊约束与几何规范。
  static const double capsuleHeight = 58.0;
  static const double capsuleMaxWidth = 760.0;
  static const double capsuleMinWidth = 340.0;
  static const double capsuleRadius = 22.0;
  static const double capsuleBlurSigma = 36.0;
  static const double capsuleBottomOffset = 20.0;
  static const EdgeInsets capsulePadding = EdgeInsets.fromLTRB(16, 4, 14, 0);

  /// 贴顶内沿超薄进度线几何参数（悬停平滑加粗至 6px 并显示预览气泡）。
  static const double capsuleProgressRestHeight = 2.5;
  static const double capsuleProgressHoverHeight = 6.0;
  static const double capsuleProgressHitHeight = 14.0;
  static const double capsuleProgressHorizontalInset = 16.0;
  static const double capsuleHoverBubbleBottomOffset = 64.0;

  /// 紧凑滚轮数字音量与悬停纵向浮层几何规范。
  static const double volumePopoverWidth = 36.0;
  static const double volumePopoverHeight = 118.0;
  static const Duration volumePopoverDismissDelay = Duration(
    milliseconds: 140,
  );

  /// 实时音画规格胶囊徽标规范。
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

  /// 内置视频右滑毛玻璃侧栏避让尺寸。
  static const double videoSideSheetWidth = 420.0;

  /// 右下角智能跳过 OP/ED 胶囊固定位置（与 `AGENTS.md` / 阶段 3 规范对齐）。
  static const double skipPillBottomOffset = 88.0;
  static const double skipPillRightOffset = 24.0;
  static const Duration skipPillAutoFadeDuration = Duration(
    milliseconds: 4000,
  );

  /// 极简隐身 HUD 定时阈值。
  static const Duration cursorIdleFadeDelay = Duration(milliseconds: 2000);
  static const Duration hudFadeDuration = Duration(milliseconds: 200);
  static const Duration pauseBadgeDisplayDuration = Duration(milliseconds: 800);
  static const Duration autoNextEpisodeToastDuration = Duration(
    milliseconds: 3000,
  );

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
