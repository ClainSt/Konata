import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/formatting/detail_title_typography.dart';
import '../../domain/models/work.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';

/// 详情页全端统一的「剧场典藏排版铭牌」风格化文字标题组件。
///
/// 统一承接无透明徽标兜底、透明徽标加载失败回退与文字并列伴随展示：
/// - 释放内置双可变字体展示字重（`660 ~ 760`），按视觉当量长度四档分级并在窄屏自动软退档；
/// - 叠放于原画背景之上时自动开启局部椭圆柔晕与三层校准光学投影，彻底隔离浅色主题清空阴影影响；
/// - 主推「条件语义眉标 + 极细水平渐隐装饰线」，并严守中文主标题不重复展示日文原名的契约。
class DetailStylizedTitleBlock extends StatelessWidget {
  /// 创建详情页风格化文字标题块。
  const DetailStylizedTitleBlock({
    super.key,
    required this.work,
    this.viewport = DetailTitleViewportProfile.desktop,
    this.mode = DetailTitlePresentationMode.heroEmblem,
    this.onBackdrop = true,
  });

  /// 目标作品实体。
  final Work work;

  /// 当前视口形态档位（控制各端最大宽度、字号阶梯与行高上限）。
  final DetailTitleViewportProfile viewport;

  /// 视觉呈现模式（无徽标主视觉铭牌或徽标伴随文字）。
  final DetailTitlePresentationMode mode;

  /// 是否直接叠放于高动态原画背景之上（为 `true` 时附加局部椭圆柔晕以保障亮底可读性）。
  final bool onBackdrop;

  @override
  Widget build(BuildContext context) {
    final trimmedTitle = work.title.trim();
    if (trimmedTitle.isEmpty) {
      return const SizedBox.shrink();
    }

    final rawScaler = MediaQuery.textScalerOf(context);
    final clampedScale = rawScaler
        .scale(1.0)
        .clamp(1.0, KonataTheme.detailHeroMaxTextScale);
    final clampedScaler = TextScaler.linear(clampedScale);
    final highContrast = MediaQuery.highContrastOf(context);
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final locale = Localizations.maybeLocaleOf(context);

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: clampedScaler),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final boundedW = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : null;
          final spec = DetailTitleTypographyResolver.resolve(
            work: work,
            viewport: viewport,
            mode: mode,
            availableWidth: boundedW,
          );
          final effectiveMaxWidth = boundedW != null
              ? math.min(boundedW, spec.maxWidth)
              : spec.maxWidth;

          final resolvedFontSize = _resolveAdaptiveFontSize(
            title: trimmedTitle,
            spec: spec,
            maxWidth: effectiveMaxWidth,
            textScaler: clampedScaler,
            textDirection: direction,
            locale: locale,
          );

          final titleShadows = mode == DetailTitlePresentationMode.heroEmblem
              ? KonataTheme.detailHeroTitleShadows
              : KonataTheme.detailTextShadows;
          final titleStyle = KonataTheme.detailHeroTitleStyle(
            fontSize: resolvedFontSize,
            weight: spec.titleWeight,
            color: KonataTheme.pureWhite,
            letterSpacing: spec.titleLetterSpacing,
            height: spec.titleLineHeight,
            shadows: titleShadows,
          );

          final Widget rawTitleText = EllipsisTextWithTooltip(
            text: trimmedTitle,
            maxLines: spec.titleMaxLines,
            style: titleStyle,
          );

          final bool useOpticalSheen =
              mode == DetailTitlePresentationMode.heroEmblem && !highContrast;
          final Widget renderedTitle = useOpticalSheen
              ? ShaderMask(
                  blendMode: BlendMode.modulate,
                  shaderCallback: (bounds) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: KonataTheme.detailHeroTitleSheenColors,
                  ).createShader(bounds),
                  child: rawTitleText,
                )
              : rawTitleText;

          final hasSubtitle =
              spec.subtitleText != null && spec.subtitleText!.isNotEmpty;
          final hasKicker =
              spec.kickerText != null && spec.kickerText!.isNotEmpty;
          final isCompactLandscape =
              viewport == DetailTitleViewportProfile.phoneLandscape;

          final Widget content = ConstrainedBox(
            constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
            child: Column(
              key: const ValueKey('detail_stylized_title_block'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasKicker) ...[
                  _TitleKickerRow(
                    label: spec.kickerText!,
                    fontSize: spec.kickerFontSize,
                    letterSpacing: spec.kickerLetterSpacing,
                    barWidth: spec.kickerBarWidth,
                  ),
                  SizedBox(height: isCompactLandscape ? 4 : 6),
                ],
                renderedTitle,
                if (spec.showHairline) ...[
                  SizedBox(
                    height: hasSubtitle
                        ? (isCompactLandscape ? 5 : 8)
                        : (isCompactLandscape ? 6 : 9),
                  ),
                  _TitleFadeHairline(
                    width: spec.hairlineWidth,
                    thickness: spec.hairlineThickness,
                  ),
                ],
                if (hasSubtitle) ...[
                  SizedBox(
                    height: spec.showHairline
                        ? (isCompactLandscape ? 4 : 7)
                        : 5,
                  ),
                  EllipsisTextWithTooltip(
                    text: spec.subtitleText!,
                    maxLines: 1,
                    style: KonataTheme.detailHeroTitleStyle(
                      fontSize: spec.subtitleFontSize,
                      weight: KonataTheme.weightRegularLabel,
                      color: KonataTheme.detailHeroSubtitleColor,
                      letterSpacing: spec.subtitleLetterSpacing,
                      height: 1.25,
                      shadows: KonataTheme.detailTextShadows,
                    ),
                  ),
                ],
              ],
            ),
          );

          if (!onBackdrop || mode != DetailTitlePresentationMode.heroEmblem) {
            return content;
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: -KonataTheme.detailHeroBackdropHaloHorizontalOverflow,
                right: -KonataTheme.detailHeroBackdropHaloHorizontalOverflow,
                top: -KonataTheme.detailHeroBackdropHaloVerticalOverflow,
                bottom: -KonataTheme.detailHeroBackdropHaloVerticalOverflow,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('detail_stylized_title_backdrop_halo'),
                    decoration: const BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment(-0.22, 0.08),
                        radius: 0.92,
                        stops: KonataTheme.detailHeroBackdropHaloStops,
                        colors: KonataTheme.detailHeroBackdropHaloColors,
                      ),
                    ),
                  ),
                ),
              ),
              content,
            ],
          );
        },
      ),
    );
  }

  /// 通过轻量文本布局试算，在标题超出目标行数或槽位高度预算时最多向下软退两档以减少过早截断。
  double _resolveAdaptiveFontSize({
    required String title,
    required DetailTitleTypographySpec spec,
    required double maxWidth,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required Locale? locale,
  }) {
    if (maxWidth <= 0 || !maxWidth.isFinite) {
      return spec.titleFontSize;
    }
    var size = spec.titleFontSize;
    for (var step = 0; step <= KonataTheme.detailHeroTitleMaxStepDowns; step++) {
      final probe = TextPainter(
        text: TextSpan(
          text: title,
          style: KonataTheme.detailHeroTitleStyle(
            fontSize: size,
            weight: spec.titleWeight,
            letterSpacing: spec.titleLetterSpacing,
            height: spec.titleLineHeight,
          ),
        ),
        maxLines: spec.titleMaxLines,
        textDirection: textDirection,
        textScaler: textScaler,
        locale: locale,
      )..layout(maxWidth: maxWidth);

      final fitsLines = !probe.didExceedMaxLines;
      final fitsBudget = probe.height <= spec.heightBudget;
      if (fitsLines && fitsBudget) {
        return size;
      }
      if (size <= spec.minTitleFontSize) {
        return spec.minTitleFontSize;
      }
      size = math.max(
        spec.minTitleFontSize,
        size - KonataTheme.detailHeroTitleStepDownDelta,
      );
    }
    return size;
  }
}

class _TitleKickerRow extends StatelessWidget {
  const _TitleKickerRow({
    required this.label,
    required this.fontSize,
    required this.letterSpacing,
    required this.barWidth,
  });

  final String label;
  final double fontSize;
  final double letterSpacing;
  final double barWidth;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('detail_stylized_title_kicker'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: barWidth,
          height: 1.5,
          decoration: BoxDecoration(
            color: KonataTheme.detailHeroKickerBarColor,
            borderRadius: KonataTheme.borderRadiusPill,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: KonataTheme.detailHeroTitleStyle(
              fontSize: fontSize,
              weight: KonataTheme.weightH1,
              color: KonataTheme.detailHeroKickerTextColor,
              letterSpacing: letterSpacing,
              height: 1.15,
              shadows: KonataTheme.detailTextShadows,
            ),
          ),
        ),
      ],
    );
  }
}

class _TitleFadeHairline extends StatelessWidget {
  const _TitleFadeHairline({required this.width, required this.thickness});

  final double width;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('detail_stylized_title_hairline'),
      width: width,
      height: thickness,
      decoration: const BoxDecoration(
        borderRadius: KonataTheme.borderRadiusPill,
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: KonataTheme.detailHeroHairlineStops,
          colors: KonataTheme.detailHeroHairlineColors,
        ),
      ),
    );
  }
}
