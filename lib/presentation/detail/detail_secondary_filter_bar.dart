import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/konata_theme.dart';

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

/// 作品详情页底部抽屉/完整列表共用的深色高透二级筛选条。
///
/// 仅使用高透磨砂细边与纯白文字层级，严禁使用实心黑底或亮蓝色高亮。
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
    final barHeight = widget.compact ? 30.0 : 32.0;
    return Padding(
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
            children: [
              _SecondaryFilterChip(
                label: '全部 (${widget.totalCount})',
                selected: widget.selectedKey == null,
                compact: widget.compact,
                onTap: () => widget.onSelected(null),
              ),
              for (final item in widget.items) ...[
                const SizedBox(width: 8),
                _SecondaryFilterChip(
                  label: '${item.label} (${item.count})',
                  selected: widget.selectedKey == item.key,
                  compact: widget.compact,
                  onTap: () => widget.onSelected(item.key),
                ),
              ],
            ],
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
    final bgAlpha = widget.selected
        ? 0.24
        : (_hovered ? 0.16 : 0.08);
    final borderAlpha = widget.selected
        ? 0.48
        : (_hovered ? 0.30 : 0.16);
    final textAlpha = widget.selected ? 0.98 : (_hovered ? 0.90 : 0.76);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(
                horizontal: widget.compact ? 11 : 13,
                vertical: widget.compact ? 5 : 6,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: bgAlpha),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white.withValues(alpha: borderAlpha),
                  width: widget.selected ? 1.0 : 0.85,
                ),
              ),
              child: Text(
                widget.label,
                style: KonataTheme.detailTextStyle(
                  color: Colors.white.withValues(alpha: textAlpha),
                  fontSize: widget.compact ? 11.5 : 12,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
