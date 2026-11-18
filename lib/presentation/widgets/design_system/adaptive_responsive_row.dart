import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';

/// 自适应智能换位行容器：基于可用宽度与文本缩放动态防止标题被压缩成细窄竖排单字列。
///
/// 当横向排布会导致左侧标题说明区可用宽度低于 [minLeadingWidth]（默认 `140dp` 并随字体缩放同步放大，
/// 确保不少于约 8 个中文字宽）时，自动由左右 [Row] 切换为上下 [Column] 纵向堆叠。
class AdaptiveResponsiveRow extends StatelessWidget {
  /// 创建智能换位行容器。
  const AdaptiveResponsiveRow({
    super.key,
    required this.leading,
    required this.trailing,
    this.estimatedTrailingWidth = 140.0,
    this.minLeadingWidth = 140.0,
    this.horizontalGap = 12.0,
    this.verticalGap = 8.0,
    this.rowCrossAxisAlignment = CrossAxisAlignment.center,
    this.stackedTrailingAlignment = Alignment.centerRight,
    this.expandTrailingWhenStacked = false,
  });

  /// 左侧标题与说明区组件。
  final Widget leading;

  /// 右侧控制组件（开关、下拉框、胶囊组或操作按钮）。
  final Widget trailing;

  /// 预估右侧控制区最小占用宽度（用于精确判别左侧剩余可读宽度）。
  final double estimatedTrailingWidth;

  /// 横向排布时左侧标题区允许的最小逻辑宽度（默认 `140dp`）。
  final double minLeadingWidth;

  /// 横向排布时的左右间距。
  final double horizontalGap;

  /// 自动换位为纵向堆叠时的上下间距。
  final double verticalGap;

  /// 横向模式垂直对齐方式。
  final CrossAxisAlignment rowCrossAxisAlignment;

  /// 纵向堆叠且不撑满时右侧控制区水平对齐位置。
  final AlignmentGeometry stackedTrailingAlignment;

  /// 纵向堆叠时是否让控制组件横向撑满整行（如分段胶囊或下拉选择框）。
  final bool expandTrailingWhenStacked;

  /// 判断当前可用宽度与字体缩放比例下是否应当换位为上下堆叠。
  static bool shouldStack({
    required double maxWidth,
    required double estimatedTrailingWidth,
    double minLeadingWidth = 140.0,
    double horizontalGap = 12.0,
    double textScaleFactor = 1.0,
  }) {
    if (!maxWidth.isFinite) return false;
    final effectiveScale = math.max(1.0, textScaleFactor).clamp(1.0, 1.45);
    final requiredLeading = math.max(
      minLeadingWidth,
      minLeadingWidth * effectiveScale,
    );
    final remaining = maxWidth - estimatedTrailingWidth - horizontalGap;
    return remaining < requiredLeading;
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14.0) / 14.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = shouldStack(
          maxWidth: constraints.maxWidth,
          estimatedTrailingWidth: estimatedTrailingWidth,
          minLeadingWidth: minLeadingWidth,
          horizontalGap: horizontalGap,
          textScaleFactor: scale,
        );
        if (!stack) {
          final effectiveScale = math.max(1.0, scale).clamp(1.0, 1.45);
          final requiredLeading = math.max(
            minLeadingWidth,
            minLeadingWidth * effectiveScale,
          );
          final maxTrailing = constraints.maxWidth.isFinite
              ? math.max(
                  0.0,
                  constraints.maxWidth - requiredLeading - horizontalGap,
                )
              : double.infinity;
          return Row(
            crossAxisAlignment: rowCrossAxisAlignment,
            children: [
              Expanded(child: leading),
              SizedBox(width: horizontalGap),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxTrailing),
                child: trailing,
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            SizedBox(height: verticalGap),
            if (expandTrailingWhenStacked)
              trailing
            else
              Align(alignment: stackedTrailingAlignment, child: trailing),
          ],
        );
      },
    );
  }
}

/// 标准自适应设置项行组件：基于 [AdaptiveResponsiveRow] 自动在窄列换位，消除挤字竖排。
class AdaptiveSettingTile extends StatelessWidget {
  /// 创建标准自适应设置项行组件。
  const AdaptiveSettingTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.trailing,
    this.estimatedTrailingWidth = 140.0,
    this.minLeadingWidth = 140.0,
    this.expandControlWhenStacked = false,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  /// 主标题文案。
  final String title;

  /// 可选辅助说明文案。
  final String? subtitle;

  /// 交互控件（Switch / 下拉框 / 分段胶囊 / 按钮）。
  final Widget trailing;

  /// 预估右侧控制区宽度。
  final double estimatedTrailingWidth;

  /// 横向排布时左侧标题区最小安全宽度。
  final double minLeadingWidth;

  /// 换位纵向堆叠时控件是否撑满全宽。
  final bool expandControlWhenStacked;

  /// 内边距。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final leading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: KonataTheme.textStyle(
            color: p.textPrimary,
            fontSize: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.settingsFontSize
                : 14,
            weight: 500,
          ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            subtitle!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.textMuted, fontSize: 12),
          ),
        ],
      ],
    );

    return Padding(
      padding: padding,
      child: AdaptiveResponsiveRow(
        leading: leading,
        trailing: trailing,
        estimatedTrailingWidth: estimatedTrailingWidth,
        minLeadingWidth: minLeadingWidth,
        expandTrailingWhenStacked: expandControlWhenStacked,
      ),
    );
  }
}
