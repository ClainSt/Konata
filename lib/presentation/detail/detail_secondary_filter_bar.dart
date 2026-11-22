
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';

/// 详情页二级分类筛选条上的单条筛选项数据。
class DetailSecondaryFilterItem {
  /// 创建二级筛选项。
  const DetailSecondaryFilterItem({
    required this.key,
    required this.label,
    required this.count,
  });

  /// 筛选项唯一键（例如特典类型名、专辑 key、分卷 key）。
  final String key;

  /// 展示标签文本。
  final String label;

  /// 当前分组包含的条目数量。
  final int count;
}

/// 作品详情页底部抽屉/完整列表共用的高透二级筛选条。
class DetailSecondaryFilterBar extends StatefulWidget {
  /// 创建二级筛选条。
  const DetailSecondaryFilterBar({
    super.key,
    required this.items,
    required this.totalCount,
    required this.selectedKey,
    required this.onSelected,
    this.horizontalPadding = 36,
    this.compact = false,
  });

  /// 具体二级分类选项列表。
  final List<DetailSecondaryFilterItem> items;

  /// 全部分类条目总数。
  final int totalCount;

  /// 当前选中的二级键，`null` 代表「全部」。
  final String? selectedKey;

  /// 选中或切换二级选项时的回调。
  final ValueChanged<String?> onSelected;

  /// 左右内边距（详情页底部轨道默认为 36，完整列表弹窗可调小）。
  final double horizontalPadding;

  /// 是否使用紧凑尺寸（用于弹窗内部）。
  final bool compact;

  @override
  State<DetailSecondaryFilterBar> createState() =>
      _DetailSecondaryFilterBarState();
}

class _DetailSecondaryFilterBarState extends State<DetailSecondaryFilterBar> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final isPhone =
        KonataAdaptiveTokens.isAndroid &&
        screenSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint;
    final effectiveCompact = widget.compact || isPhone;
    final barHeight = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : (effectiveCompact ? 30.0 : 32.0);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
        child: SizedBox(
          height: barHeight,
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent && _scrollController.hasClients) {
                final delta = event.scrollDelta.dy != 0
                    ? event.scrollDelta.dy
                    : event.scrollDelta.dx;
                final pos = _scrollController.position;
                final target = (_scrollController.offset + delta).clamp(
                  pos.minScrollExtent,
                  pos.maxScrollExtent,
                );
                _scrollController.jumpTo(target);
              }
            },
            child: ListView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              // 显式归零内边距，防止横屏刘海安全区在外部已避让后被 ListView 二次重复注入导致左侧错位。
              padding: EdgeInsets.zero,
              children: [
                _SecondaryFilterChip(
                  label: '全部',
                  selected: widget.selectedKey == null,
                  compact: effectiveCompact,
                  onTap: () => widget.onSelected(null),
                ),
                for (final item in widget.items) ...[
                  SizedBox(width: isPhone ? 6 : 8),
                  _SecondaryFilterChip(
                    label: item.label,
                    selected: widget.selectedKey == item.key,
                    compact: effectiveCompact,
                    onTap: () => widget.onSelected(item.key),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryFilterChip extends StatefulWidget {
  const _SecondaryFilterChip({
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_SecondaryFilterChip> createState() => _SecondaryFilterChipState();
}

class _SecondaryFilterChipState extends State<_SecondaryFilterChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bgColor = KonataPlaybackTokens.secondaryFilterPillBg(
      p,
      selected: widget.selected,
      hovered: _hovered,
    );
    final borderColor = KonataPlaybackTokens.secondaryFilterPillBorder(
      p,
      selected: widget.selected,
    );
    final textColor = KonataPlaybackTokens.secondaryFilterPillText(
      p,
      selected: widget.selected,
      hovered: _hovered,
    );

    final pill = ClipRRect(
      borderRadius: KonataTheme.borderRadiusPill,
      child: BackdropFilter(
        filter: KonataTheme.blurFilterSubtle,
        child: AnimatedContainer(
          duration: KonataTheme.motionStandard,
          curve: Curves.easeOutCubic,
          constraints: BoxConstraints(
            minWidth: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.touchTarget
                : 0,
            maxWidth: widget.compact ? 210 : 280,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 11 : 13,
            vertical: widget.compact ? 5.5 : 6,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(
              color: borderColor,
              width: widget.selected ? 1.0 : 0.85,
            ),
          ),
          child: Center(
            widthFactor: 1.0,
            heightFactor: 1.0,
            child: EllipsisTextWithTooltip(
              text: widget.label,
              maxLines: 1,
              style: KonataTheme.detailTextStyle(
                palette: p,
                color: textColor,
                fontSize: widget.compact ? 11.5 : 12,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: KonataAdaptiveTokens.isAndroid
            ? ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: KonataAdaptiveTokens.touchTarget,
                  minHeight: KonataAdaptiveTokens.touchTarget,
                ),
                child: Center(widthFactor: 1.0, heightFactor: 1.0, child: pill),
              )
            : pill,
      ),
    );
  }
}
