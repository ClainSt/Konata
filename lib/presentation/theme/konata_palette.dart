import 'package:flutter/material.dart';

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
    required this.warning,
    required this.success,
    required this.danger,
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

  /// 待复核/警示琥珀金。
  final Color warning;

  /// 成功态青绿。
  final Color success;

  /// 错误/危险态红色。
  final Color danger;

  /// 暗色模式调色盘（透明穿透底 + 5% 白叠色 + 9% 白微光描边）。
  static const KonataPalette dark = KonataPalette(
    isDark: true,
    canvas: Colors.transparent,
    surface: Color(0x0DFFFFFF), // Colors.white @ 0.05
    surfaceHover: Color(0x14FFFFFF), // Colors.white @ 0.08
    elevatedSurface: Color(0xD4161922), // 玻璃浮层/菜单自适应半透明底
    softFill: Color(0x14FFFFFF),
    hairline: Color(0x17FFFFFF), // Colors.white @ 0.09
    hoverBorder: Color(0x33FFFFFF),
    posterBorder: Color(0x24FFFFFF), // Colors.white @ 0.14
    textPrimary: Color(0xFFF4F5F8),
    textSecondary: Color(0x8CF4F5F8), // ~55% 透明度次级字
    textMuted: Color(0x66F4F5F8),
    primaryButtonBg: Color(0xFFF4F5F8),
    primaryButtonFg: Color(0xFF0B0C10),
    primaryButtonHoverBg: Color(0xFFFFFFFF),
    secondaryButtonBg: Color(0x14FFFFFF),
    secondaryButtonHoverBg: Color(0x24FFFFFF),
    glassOverlay: Color(0xA8161922),
    accent: Color(0xFF6BA6FF),
    warning: Color(0xFFE5A93B),
    success: Color(0xFF3FB950),
    danger: Color(0xFFE5534B),
  );

  /// 亮色模式调色盘（透明穿透底 + 62% 柔白叠色 + 85% 微光描边）。
  static const KonataPalette light = KonataPalette(
    isDark: false,
    canvas: Colors.transparent,
    surface: Color(0x9EFFFFFF), // Colors.white @ 0.62
    surfaceHover: Color(0xC7FFFFFF), // Colors.white @ 0.78
    elevatedSurface: Color(0xDEFFFFFF), // 亮色毛玻璃浮层/菜单底
    softFill: Color(0x7AFFFFFF),
    hairline: Color(0xD9FFFFFF), // Colors.white @ 0.85
    hoverBorder: Color(0xFFFFFFFF),
    posterBorder: Color(0x24FFFFFF), // Colors.white @ 0.14
    textPrimary: Color(0xFF181A1F),
    textSecondary: Color(0x8F181A1F), // 柔和深炭灰次级字
    textMuted: Color(0x66181A1F),
    primaryButtonBg: Color(0xFF181A1F),
    primaryButtonFg: Color(0xFFFFFFFF),
    primaryButtonHoverBg: Color(0xFF282B33),
    secondaryButtonBg: Color(0x12181A1F),
    secondaryButtonHoverBg: Color(0x1F181A1F),
    glassOverlay: Color(0xC2FFFFFF),
    accent: Color(0xFF2D6CDF),
    warning: Color(0xFFC5841B),
    success: Color(0xFF238636),
    danger: Color(0xFFCF222E),
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
    Color? warning,
    Color? success,
    Color? danger,
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
      warning: warning ?? this.warning,
      success: success ?? this.success,
      danger: danger ?? this.danger,
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
      warning: Color.lerp(warning, other.warning, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// 便捷读取当前上下文中的语义调色盘。
extension KonataPaletteContext on BuildContext {
  /// 获取当前主题激活的 [KonataPalette]。
  KonataPalette get palette =>
      Theme.of(this).extension<KonataPalette>() ?? KonataPalette.dark;
}
