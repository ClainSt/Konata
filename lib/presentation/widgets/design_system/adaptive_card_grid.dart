import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';

/// 弹性网格布局计算快照。
@immutable
class AdaptiveGridMetrics {
  /// 创建网格计算快照。
  const AdaptiveGridMetrics({
    required this.columns,
    required this.cardWidth,
    required this.mainAxisExtent,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
  });

  /// 自动换算后的列数。
  final int columns;

  /// 实际单卡物理逻辑宽度。
  final double cardWidth;

  /// 含动态字号补偿的网格行总高度（彻底消除卡片底部溢出）。
  final double mainAxisExtent;

  /// 水平列间距。
  final double crossAxisSpacing;

  /// 垂直行间距。
  final double mainAxisSpacing;

  /// 生成 Flutter 原生固定行数代理。
  SliverGridDelegateWithFixedCrossAxisCount toGridDelegate() {
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
      mainAxisExtent: mainAxisExtent,
    );
  }
}

/// 自适应海报/资产卡片弹性网格：严禁写死固定列数或刚性 `childAspectRatio`。
///
/// 按实际净宽结合手机最小卡片宽度（`108~125dp`，平板/桌面自动增宽）动态计算列数，
/// 并结合系统 `textScaler` 精确补偿底部 2 行文字及边距像素高度，杜绝卡片底部裁切与溢出。
class AdaptiveCardGrid extends StatelessWidget {
  /// 创建自适应卡片网格。
  const AdaptiveCardGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding = EdgeInsets.zero,
    this.minPhoneCardWidth = 108.0,
    this.minWideCardWidth = 158.0,
    this.coverAspectRatio = 2 / 3,
    this.footerBaseHeight = 14.0,
    this.twoLineTextBaseHeight = 52.0,
    this.crossAxisSpacing = 12.0,
    this.mainAxisSpacing = 14.0,
    this.shrinkWrap = false,
    this.physics,
  });

  /// 卡片总数。
  final int itemCount;

  /// 卡片项构建器（透传当前项索引与已算定的单卡宽度）。
  final Widget Function(BuildContext context, int index, double cardWidth)
  itemBuilder;

  /// 显式绑定的滚动控制器。
  final ScrollController? controller;

  /// 外围内边距。
  final EdgeInsets padding;

  /// 手机端（`< 600dp`）最小卡片宽度（推荐 `108~125dp`）。
  final double minPhoneCardWidth;

  /// 平板及桌面端最小卡片宽度。
  final double minWideCardWidth;

  /// 封面主图宽高比（海报标准为 `2 / 3`）。
  final double coverAspectRatio;

  /// 底部文字区域固定内边距与圆角余量高度。
  final double footerBaseHeight;

  /// `1.0x` 基准字号下两行文本+副标题行的像素高度预算。
  final double twoLineTextBaseHeight;

  /// 水平列间距。
  final double crossAxisSpacing;

  /// 垂直行间距。
  final double mainAxisSpacing;

  /// 是否按内容收缩高度。
  final bool shrinkWrap;

  /// 可选滚动物理属性。
  final ScrollPhysics? physics;

  /// 计算指定视口宽度与文本缩放因子下的精确弹性网格参数。
  static AdaptiveGridMetrics computeMetrics({
    required double usableWidth,
    required double shortestSide,
    required double textScaleFactor,
    double minPhoneCardWidth = 108.0,
    double minWideCardWidth = 158.0,
    double coverAspectRatio = 2 / 3,
    double footerBaseHeight = 14.0,
    double twoLineTextBaseHeight = 52.0,
    double crossAxisSpacing = 12.0,
    double mainAxisSpacing = 14.0,
  }) {
    final isCompact = shortestSide < KonataAdaptiveTokens.tabletBreakpoint;
    final minWidth = isCompact ? minPhoneCardWidth : minWideCardWidth;
    final safeWidth = math.max(180.0, usableWidth);
    final columns = math.max(
      2,
      ((safeWidth + crossAxisSpacing) / (minWidth + crossAxisSpacing)).floor(),
    );
    final cardWidth =
        (safeWidth - crossAxisSpacing * (columns - 1)) / columns;
    final coverHeight = cardWidth / coverAspectRatio;
    final clampedScale = math.max(1.0, textScaleFactor).clamp(1.0, 2.0);
    final narrowExtra = cardWidth < 132.0 ? 6.0 : 0.0;
    final mainAxisExtent =
        coverHeight +
        footerBaseHeight +
        (twoLineTextBaseHeight * clampedScale) +
        narrowExtra;

    return AdaptiveGridMetrics(
      columns: columns,
      cardWidth: cardWidth,
      mainAxisExtent: mainAxisExtent,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final scale = MediaQuery.textScalerOf(context).scale(14.0) / 14.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final rawW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final metrics = computeMetrics(
          usableWidth: math.max(180.0, rawW - padding.horizontal),
          shortestSide: shortest,
          textScaleFactor: scale,
          minPhoneCardWidth: minPhoneCardWidth,
          minWideCardWidth: minWideCardWidth,
          coverAspectRatio: coverAspectRatio,
          footerBaseHeight: footerBaseHeight,
          twoLineTextBaseHeight: twoLineTextBaseHeight,
          crossAxisSpacing: crossAxisSpacing,
          mainAxisSpacing: mainAxisSpacing,
        );

        return GridView.builder(
          controller: controller,
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: padding,
          gridDelegate: metrics.toGridDelegate(),
          itemCount: itemCount,
          itemBuilder: (ctx, index) =>
              itemBuilder(ctx, index, metrics.cardWidth),
        );
      },
    );
  }
}
