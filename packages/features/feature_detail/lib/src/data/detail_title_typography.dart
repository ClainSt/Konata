import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 详情页无徽标降级时的纯排版自适应结果。
class DetailStylizedTitlePlan {
  /// 创建无徽标降级标题排版方案。
  const DetailStylizedTitlePlan({
    required this.primaryText,
    required this.secondaryText,
    required this.primaryFontSize,
    required this.primaryLetterSpacing,
    required this.primaryLineHeight,
    required this.primaryMaxLines,
    required this.useCondensedWeight,
  });

  /// 主标题（作品中文或本地常用名）。
  final String primaryText;

  /// 副标题（可选原语言标题，当与主标题不同时展示以强化海报级排版纵深）。
  final String? secondaryText;

  /// 自动收敛后的主标题字号（逻辑像素）。
  final double primaryFontSize;

  /// 主标题字距。
  final double primaryLetterSpacing;

  /// 主标题行高倍率。
  final double primaryLineHeight;

  /// 主标题最大行数上限。
  final int primaryMaxLines;

  /// 超长外文标题时自动降重至偏紧凑字重防视觉臃肿。
  final bool useCondensedWeight;
}

/// 详情页无透明徽标降级排版预算引擎。
///
/// 根据可用舞台宽度与标题长度（`rune` 与中/英/日宽窄差异）通过真实 `TextPainter`
/// 测量收敛到最佳字号，确保短片名气场充沛、超长轻小说/剧场版长副标题不裁断且不遮挡主动作栏。
abstract final class DetailTitleTypographyResolver {
  static final RegExp _wideCjkPattern = RegExp(
    r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]',
  );

  /// 估算显示宽度权重（CJK 全角字符计 `1.8`，ASCII/窄标点计 `1.0`）。
  static double estimateDisplayUnits(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    var units = 0.0;
    for (final rune in trimmed.runes) {
      final ch = String.fromCharCode(rune);
      units += _wideCjkPattern.hasMatch(ch) ? 1.8 : 1.0;
    }
    return units;
  }

  /// 按容器可用宽度与视口尺寸计算无徽标文字主标题的排版参数。
  static DetailStylizedTitlePlan resolve({
    required String title,
    String? originalTitle,
    required double maxWidth,
    required bool isCompactViewport,
    TextScaler textScaler = TextScaler.noScaling,
    Locale? locale,
  }) {
    final cleanTitle = title.trim().isEmpty ? '未命名作品' : title.trim();
    final rawOrig = originalTitle?.trim() ?? '';
    final secondary =
        rawOrig.isNotEmpty && rawOrig.toLowerCase() != cleanTitle.toLowerCase()
        ? rawOrig
        : null;

    final safeMaxWidth = math.max(140.0, maxWidth);
    final baseMaxFont = isCompactViewport
        ? 30.0
        : (safeMaxWidth >= 520 ? 34.0 : 32.0);
    final baseMinFont = isCompactViewport ? 20.0 : 24.0;
    final units = estimateDisplayUnits(cleanTitle);
    final maxLines = isCompactViewport ? 2 : 2;
    final letterSpacing = units > 36 ? -0.35 : (units > 22 ? -0.15 : 0.25);
    final useCondensedWeight = units > 30;
    final fontWeight = useCondensedWeight ? FontWeight.w700 : FontWeight.w800;

    var chosenSize = baseMaxFont;
    for (var size = baseMaxFont; size >= baseMinFont; size -= 2.0) {
      final lineHeight = size >= 34 ? 1.12 : 1.18;
      final painter = TextPainter(
        text: TextSpan(
          text: cleanTitle,
          style: TextStyle(
            fontFamily: KonataTheme.uiFontFamily,
            fontFamilyFallback: KonataTheme.uiFontFamilyFallback,
            fontSize: size,
            fontWeight: fontWeight,
            height: lineHeight,
            letterSpacing: letterSpacing,
          ),
        ),
        maxLines: maxLines,
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        locale: locale,
      )..layout(maxWidth: safeMaxWidth);

      chosenSize = size;
      if (!painter.didExceedMaxLines) {
        break;
      }
    }

    final finalLineHeight = chosenSize >= 34 ? 1.12 : 1.18;
    return DetailStylizedTitlePlan(
      primaryText: cleanTitle,
      secondaryText: secondary,
      primaryFontSize: chosenSize,
      primaryLetterSpacing: letterSpacing,
      primaryLineHeight: finalLineHeight,
      primaryMaxLines: maxLines,
      useCondensedWeight: useCondensedWeight,
    );
  }
}
