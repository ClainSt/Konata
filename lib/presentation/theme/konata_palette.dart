import 'package:flutter/material.dart';

/// 语义化彩色徽章成套光学 Token（高遮蔽暗腔底 + 高明度冰色浅字 + 1px 同色微光描边）。
///
/// 确保深色模式与毛玻璃浮层在叠放于任意中灰背景之上时，文字对比度恒定 `>= 4.5:1`。
@immutable
class KonataBadgeColors {
  /// 创建一组语义徽章颜色。
  const KonataBadgeColors({
    required this.bg,
    required this.fg,
    required this.border,
  });

  /// 徽章胶囊填充底色。
  final Color bg;

  /// 徽章前景文本与图标色（建议配合 `FontWeight.w600`）。
  final Color fg;

  /// `1px` 边框微光描边色。
  final Color border;

  /// 线性插值两组徽章配色。
  static KonataBadgeColors lerp(
    KonataBadgeColors a,
    KonataBadgeColors b,
    double t,
  ) {
    return KonataBadgeColors(
      bg: Color.lerp(a.bg, b.bg, t)!,
      fg: Color.lerp(a.fg, b.fg, t)!,
      border: Color.lerp(a.border, b.border, t)!,
    );
  }
}

/// Konata 2.0 语义化亮/暗双主题调色盘（基于 Windows 11 原生 DWM 材质透光与微光描边体系）。
///
/// 全站页面必须通过 `context.palette` 读取语义颜色，严禁硬编码实心背景遮挡 DWM 毛玻璃。
@immutable
class KonataPalette extends ThemeExtension<KonataPalette> {
  /// 创建语义调色盘实例。
  const KonataPalette({
    required this.isDark,
    required this.canvas,
    required this.surface,
    required this.surfaceHover,
    required this.elevatedSurface,
    required this.softFill,
    required this.hairline,
    required this.hoverBorder,
    required this.posterBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.primaryButtonBg,
    required this.primaryButtonFg,
    required this.primaryButtonHoverBg,
    required this.secondaryButtonBg,
    required this.secondaryButtonHoverBg,
    required this.glassOverlay,
    required this.accent,
    required this.progressFill,
    required this.progressTrack,
    required this.warning,
    required this.success,
    required this.danger,
    required this.successBadge,
    required this.accentBadge,
    required this.warningBadge,
    required this.dangerBadge,
  });

  /// 当前是否为深色模式。
  final bool isDark;

  /// 主画布背景色（Windows 原生材质穿透模式下为全透明）。
  final Color canvas;

  /// 一级半透明卡片表面色（透出底层 DWM 光影）。
  final Color surface;

  /// 卡片悬停态表面色。
  final Color surfaceHover;

  /// 二级浮层/弹窗背景色（保持可读性高不透明度）。
  final Color elevatedSurface;

  /// 二级悬浮、滑槽与无框输入框填充色。
  final Color softFill;

  /// 1px 极细微光描边或微弱分割线。
  final Color hairline;

  /// 悬停态微光边框。
  final Color hoverBorder;

  /// 海报外缘内嵌 1px 微光细边。
  final Color posterBorder;

  /// 主文本颜色。
  final Color textPrimary;

  /// 次级说明文本颜色。
  final Color textSecondary;

  /// 弱化提示文本颜色。
  final Color textMuted;

  /// 主操作胶囊按钮底色。
  final Color primaryButtonBg;

  /// 主操作胶囊按钮文字色。
  final Color primaryButtonFg;

  /// 主操作胶囊按钮悬停底色。
  final Color primaryButtonHoverBg;

  /// 次级无框柔和胶囊按钮底色。
  final Color secondaryButtonBg;

  /// 次级胶囊按钮悬停底色。
  final Color secondaryButtonHoverBg;

  /// 半透明毛玻璃遮罩底色。
  final Color glassOverlay;

  /// 低饱和度状态强调色（仅用于徽章或图标点缀）。
  final Color accent;

  /// 全站统一进度条填充色（暗色为纯白光学微光，亮色为深石板墨色）。
  final Color progressFill;

  /// 全站高辨识度进度条底轨填充色。
  final Color progressTrack;

  /// 待复核/警示琥珀金。
  final Color warning;

  /// 成功态青绿。
  final Color success;

  /// 错误/危险态红色。
  final Color danger;

  /// 成套语义徽章光学令牌（Bg / Fg / Border）。
  final KonataBadgeColors successBadge;
  final KonataBadgeColors accentBadge;
  final KonataBadgeColors warningBadge;
  final KonataBadgeColors dangerBadge;

  /// 暗色模式光学调色盘（透明穿透底 + 轻薄光学玻璃层 + 1px 微光边缘）。
  static const KonataPalette dark = KonataPalette(
    isDark: true,
    canvas: Colors.transparent,
    surface: Color(0x12FFFFFF),
    surfaceHover: Color(0x1CFFFFFF),
    elevatedSurface: Color(0xDC11141E),
    softFill: Color(0x17FFFFFF),
    hairline: Color(0x1DFFFFFF),
    hoverBorder: Color(0x3BFFFFFF),
    posterBorder: Color(0x29FFFFFF),
    textPrimary: Color(0xFFF6F7FB),
    textSecondary: Color(0xA6F5F7FB),
    textMuted: Color(0x70F5F7FB),
    primaryButtonBg: Color(0xFFF6F7FB),
    primaryButtonFg: Color(0xFF0B0C10),
    primaryButtonHoverBg: Color(0xFFFFFFFF),
    secondaryButtonBg: Color(0x17FFFFFF),
    secondaryButtonHoverBg: Color(0x28FFFFFF),
    glassOverlay: Color(0x9E11141E),
    accent: Color(0xFF6BA6FF),
    progressFill: Color(0xFFFFFFFF),
    progressTrack: Color(0x2EFFFFFF),
    warning: Color(0xFFE5A93B),
    success: Color(0xFF3FB950),
    danger: Color(0xFFE5534B),
    successBadge: KonataBadgeColors(
      bg: Color(0xC7082E1E),
      fg: Color(0xFF86EFAC),
      border: Color(0x4D86EFAC),
    ),
    accentBadge: KonataBadgeColors(
      bg: Color(0xC70C2545),
      fg: Color(0xFF93C5FD),
      border: Color(0x4D93C5FD),
    ),
    warningBadge: KonataBadgeColors(
      bg: Color(0xC7382307),
      fg: Color(0xFFFDE68A),
      border: Color(0x4DFDE68A),
    ),
    dangerBadge: KonataBadgeColors(
      bg: Color(0xC73B0D14),
      fg: Color(0xFFFCA5A5),
      border: Color(0x4DFCA5A5),
    ),
  );

  /// 亮色模式光学调色盘（透明穿透底 + 陶瓷磨砂白玻璃 + 高对比深石板墨色）。
  static const KonataPalette light = KonataPalette(
    isDark: false,
    canvas: Colors.transparent,
    surface: Color(0xADFFFFFF),
    surfaceHover: Color(0xD1FFFFFF),
    elevatedSurface: Color(0xEBFFFFFF),
    softFill: Color(0x85FFFFFF),
    hairline: Color(0xE0FFFFFF),
    hoverBorder: Color(0xFFFFFFFF),
    posterBorder: Color(0x2EFFFFFF),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xEB0F172A),
    textMuted: Color(0xCC0F172A),
    primaryButtonBg: Color(0xFF0F172A),
    primaryButtonFg: Color(0xFFFFFFFF),
    primaryButtonHoverBg: Color(0xFF282B33),
    secondaryButtonBg: Color(0x14181A1F),
    secondaryButtonHoverBg: Color(0x22181A1F),
    glassOverlay: Color(0xC9FFFFFF),
    accent: Color(0xFF2D6CDF),
    progressFill: Color(0xFF0F172A),
    progressTrack: Color(0x240F172A),
    warning: Color(0xFFC5841B),
    success: Color(0xFF238636),
    danger: Color(0xFFCF222E),
    successBadge: KonataBadgeColors(
      bg: Color(0x1F15803D),
      fg: Color(0xFF166534),
      border: Color(0x4215803D),
    ),
    accentBadge: KonataBadgeColors(
      bg: Color(0x1F1D4ED8),
      fg: Color(0xFF1E40AF),
      border: Color(0x421D4ED8),
    ),
    warningBadge: KonataBadgeColors(
      bg: Color(0x24B45309),
      fg: Color(0xFF92400E),
      border: Color(0x47B45309),
    ),
    dangerBadge: KonataBadgeColors(
      bg: Color(0x1FB91C1C),
      fg: Color(0xFF991B1B),
      border: Color(0x42B91C1C),
    ),
  );

  @override
  KonataPalette copyWith({
    bool? isDark,
    Color? canvas,
    Color? surface,
    Color? surfaceHover,
    Color? elevatedSurface,
    Color? softFill,
    Color? hairline,
    Color? hoverBorder,
    Color? posterBorder,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? primaryButtonBg,
    Color? primaryButtonFg,
    Color? primaryButtonHoverBg,
    Color? secondaryButtonBg,
    Color? secondaryButtonHoverBg,
    Color? glassOverlay,
    Color? accent,
    Color? progressFill,
    Color? progressTrack,
    Color? warning,
    Color? success,
    Color? danger,
    KonataBadgeColors? successBadge,
    KonataBadgeColors? accentBadge,
    KonataBadgeColors? warningBadge,
    KonataBadgeColors? dangerBadge,
  }) {
    return KonataPalette(
      isDark: isDark ?? this.isDark,
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      elevatedSurface: elevatedSurface ?? this.elevatedSurface,
      softFill: softFill ?? this.softFill,
      hairline: hairline ?? this.hairline,
      hoverBorder: hoverBorder ?? this.hoverBorder,
      posterBorder: posterBorder ?? this.posterBorder,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      primaryButtonBg: primaryButtonBg ?? this.primaryButtonBg,
      primaryButtonFg: primaryButtonFg ?? this.primaryButtonFg,
      primaryButtonHoverBg: primaryButtonHoverBg ?? this.primaryButtonHoverBg,
      secondaryButtonBg: secondaryButtonBg ?? this.secondaryButtonBg,
      secondaryButtonHoverBg:
          secondaryButtonHoverBg ?? this.secondaryButtonHoverBg,
      glassOverlay: glassOverlay ?? this.glassOverlay,
      accent: accent ?? this.accent,
      progressFill: progressFill ?? this.progressFill,
      progressTrack: progressTrack ?? this.progressTrack,
      warning: warning ?? this.warning,
      success: success ?? this.success,
      danger: danger ?? this.danger,
      successBadge: successBadge ?? this.successBadge,
      accentBadge: accentBadge ?? this.accentBadge,
      warningBadge: warningBadge ?? this.warningBadge,
      dangerBadge: dangerBadge ?? this.dangerBadge,
    );
  }

  @override
  KonataPalette lerp(ThemeExtension<KonataPalette>? other, double t) {
    if (other is! KonataPalette) return this;
    return KonataPalette(
      isDark: t < 0.5 ? isDark : other.isDark,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      elevatedSurface: Color.lerp(elevatedSurface, other.elevatedSurface, t)!,
      softFill: Color.lerp(softFill, other.softFill, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      hoverBorder: Color.lerp(hoverBorder, other.hoverBorder, t)!,
      posterBorder: Color.lerp(posterBorder, other.posterBorder, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      primaryButtonBg: Color.lerp(primaryButtonBg, other.primaryButtonBg, t)!,
      primaryButtonFg: Color.lerp(primaryButtonFg, other.primaryButtonFg, t)!,
      primaryButtonHoverBg: Color.lerp(
        primaryButtonHoverBg,
        other.primaryButtonHoverBg,
        t,
      )!,
      secondaryButtonBg: Color.lerp(
        secondaryButtonBg,
        other.secondaryButtonBg,
        t,
      )!,
      secondaryButtonHoverBg: Color.lerp(
        secondaryButtonHoverBg,
        other.secondaryButtonHoverBg,
        t,
      )!,
      glassOverlay: Color.lerp(glassOverlay, other.glassOverlay, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      progressFill: Color.lerp(progressFill, other.progressFill, t)!,
      progressTrack: Color.lerp(progressTrack, other.progressTrack, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      successBadge: KonataBadgeColors.lerp(successBadge, other.successBadge, t),
      accentBadge: KonataBadgeColors.lerp(accentBadge, other.accentBadge, t),
      warningBadge: KonataBadgeColors.lerp(warningBadge, other.warningBadge, t),
      dangerBadge: KonataBadgeColors.lerp(dangerBadge, other.dangerBadge, t),
    );
  }
}

/// 便捷读取当前上下文中的语义调色盘。
extension KonataPaletteContext on BuildContext {
  /// 获取当前主题激活的 [KonataPalette]。
  KonataPalette get palette =>
      Theme.of(this).extension<KonataPalette>() ?? KonataPalette.dark;
}
