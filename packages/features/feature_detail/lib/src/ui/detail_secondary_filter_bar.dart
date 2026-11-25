import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 详情页底部抽屉内置稳定标签标识常量。
abstract final class DetailDrawerTabIds {
  /// 正片选集标签页标识。
  static const String episodes = 'episodes';

  /// 特典与附加映像标签页标识。
  static const String extras = 'extras';

  /// 音乐 CD 专辑标签页标识。
  static const String cd = 'cd';
}

/// 详情页分集、特典、CD 与动态扩展标签页聚合胶囊切换栏。
///
/// 三端统一收拢为单条毛玻璃分类胶囊，并在任一分类展开时从胶囊最右端自然弹性伸出 `⊞` 完整列表入口，彻底移除 `⌄` 收起按钮。
class DetailSecondaryFilterBar extends StatelessWidget {
  /// 创建详情页次级标签与筛选胶囊栏。
  const DetailSecondaryFilterBar({
    super.key,
    required this.activeTabId,
    required this.mainEpisodeCount,
    required this.extraEpisodeCount,
    required this.cdCount,
    required this.externalTabs,
    required this.onSelectTab,
    this.expanded = true,
    this.canOpenFullList = false,
    this.onOpenFullList,
    this.subFilterChips = const <({String id, String label, int count})>[],
    this.activeSubFilterId,
    this.onSelectSubFilter,
    this.trailingGear,
    this.onDarkBackdrop = true,
    this.compact = false,
    this.scanCount,
  });

  /// 当前高亮或上次选中的标签页唯一标识。
  final String activeTabId;

  /// 正片剧集数量。
  final int mainEpisodeCount;

  /// 特典数量。
  final int extraEpisodeCount;

  /// 音乐 CD 数量。
  final int cdCount;

  /// 由其他功能包通过 `DetailTabContribution` 注入的可见扩展标签页清单。
  final List<DetailTabContribution> externalTabs;

  /// 点击分类切换或再次点击当前分类收起时的回调。
  final ValueChanged<String> onSelectTab;

  /// 抽屉轨道当前是否处于展开状态。
  final bool expanded;

  /// 当前展开分类是否支持弹出完整网格/列表页。
  final bool canOpenFullList;

  /// 点击胶囊右端弹性 `⊞` 按钮触发完整列表弹窗回调。
  final VoidCallback? onOpenFullList;

  /// 当前标签下的二级细分筛选筹码列表。
  final List<({String id, String label, int count})> subFilterChips;

  /// 当前选中的二级细分筛选项标识。
  final String? activeSubFilterId;

  /// 二级细分筛选切换回调。
  final ValueChanged<String>? onSelectSubFilter;

  /// 可选底栏最右侧独立 `⚙` 管理按钮（仅宽屏与平板横屏底部栏挂载）。
  final Widget? trailingGear;

  /// 是否悬浮于深色原画舞台之上（决定浅色主题时胶囊明暗配色）。
  final bool onDarkBackdrop;

  /// 是否紧凑排布。
  final bool compact;

  /// 扫图分类的可见数量。
  final int? scanCount;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final options = <({String id, String label, int? count})>[
      if (mainEpisodeCount > 0 ||
          (extraEpisodeCount == 0 && cdCount == 0 && externalTabs.isEmpty))
        (id: DetailDrawerTabIds.episodes, label: '正片', count: mainEpisodeCount),
      if (extraEpisodeCount > 0)
        (id: DetailDrawerTabIds.extras, label: '特典', count: extraEpisodeCount),
      if (cdCount > 0) (id: DetailDrawerTabIds.cd, label: 'CD', count: cdCount),
      for (final ext in externalTabs)
        (
          id: ext.id,
          label: ext.id == 'scan_viewer' ? 'Scan' : ext.label,

          count: ext.id == 'scan_viewer' ? scanCount : null,
        ),
    ];

    final useDarkGlass = onDarkBackdrop || p.isDark;
    final capsuleBg = useDarkGlass
        ? const Color(0x6612151D)
        : KonataPlaybackTokens.glassSurface(p);
    final capsuleBorder = useDarkGlass
        ? KonataTheme.overlayWhiteBorderStrong
        : KonataPlaybackTokens.glassBorder(p);
    final dividerColor = useDarkGlass
        ? KonataTheme.overlayWhiteBorderStrong
        : p.hairline;
    final showFullListReveal =
        expanded && canOpenFullList && onOpenFullList != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: ClipRRect(
                  borderRadius: KonataTheme.borderRadiusPill,
                  child: BackdropFilter(
                    filter: KonataTheme.blurFilterControl,
                    child: Container(
                      key: const Key('detail_category_capsule'),
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: capsuleBg,
                        borderRadius: KonataTheme.borderRadiusPill,
                        border: Border.all(color: capsuleBorder, width: 1.0),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < options.length; i++) ...[
                            if (i > 0) const SizedBox(width: 4),
                            _TabSegmentButton(
                              key: ValueKey<String>(
                                'detail_tab_${options[i].id}',
                              ),
                              label: options[i].count != null
                                  ? '${options[i].label} ${options[i].count}'
                                  : options[i].label,

                              selected:
                                  expanded && activeTabId == options[i].id,
                              onDarkBackdrop: useDarkGlass,
                              compact: compact,
                              onTap: () => onSelectTab(options[i].id),
                            ),
                          ],
                          AnimatedSize(
                            duration: KonataTheme.motionNormal,
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.centerLeft,
                            child: showFullListReveal
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 1,
                                        height: 18,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        color: dividerColor,
                                      ),
                                      _CapsuleFullListButton(
                                        key: const Key(
                                          'detail_drawer_view_all_button',
                                        ),
                                        onDarkBackdrop: useDarkGlass,
                                        compact: compact,
                                        onTap: onOpenFullList!,
                                      ),
                                    ],
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (trailingGear != null) ...[
              const SizedBox(width: 10),
              trailingGear!,
            ],
          ],
        ),
        if (expanded && subFilterChips.length > 1 && onSelectSubFilter != null)
          DetailSubFilterBar(
            chips: subFilterChips,
            activeId: activeSubFilterId,
            onSelected: onSelectSubFilter!,
            onDarkBackdrop: onDarkBackdrop,
          ),
      ],
    );
  }
}

/// 独立的二级分类筛选条，可置于固定高度的轨道内容区内。
class DetailSubFilterBar extends StatelessWidget {
  /// 创建横向二级筛选条。
  const DetailSubFilterBar({
    super.key,
    required this.chips,
    required this.activeId,
    required this.onSelected,
    required this.onDarkBackdrop,
  });

  /// 筛选项。
  final List<({String id, String label, int count})> chips;

  /// 当前筛选标识。
  final String? activeId;

  /// 筛选回调。
  final ValueChanged<String> onSelected;

  /// 深色原画背景。
  final bool onDarkBackdrop;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _SubFilterChip(
                label: '${chips[i].label} (${chips[i].count})',
                selected: activeId == chips[i].id,
                onDarkBackdrop: onDarkBackdrop || p.isDark,
                palette: p,
                onTap: () => onSelected(chips[i].id),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TabSegmentButton extends StatefulWidget {
  const _TabSegmentButton({
    super.key,
    required this.label,

    required this.selected,
    required this.onDarkBackdrop,
    required this.compact,
    required this.onTap,
  });

  final String label;

  final bool selected;
  final bool onDarkBackdrop;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_TabSegmentButton> createState() => _TabSegmentButtonState();
}

class _TabSegmentButtonState extends State<_TabSegmentButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = widget.selected;
    final bg = selected
        ? (widget.onDarkBackdrop
              ? KonataTheme.pureWhite.withValues(alpha: 0.20)
              : p.primaryButtonBg)
        : (_hovered
              ? (widget.onDarkBackdrop
                    ? KonataTheme.overlayWhiteSubtle
                    : p.softFill)
              : const Color(0x00000000));
    final fg = selected
        ? (widget.onDarkBackdrop
              ? KonataTheme.overlayWhiteTextHigh
              : p.primaryButtonFg)
        : (widget.onDarkBackdrop
              ? KonataTheme.overlayWhiteTextMid
              : p.textSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 11 : 14,
            vertical: widget.compact ? 6.5 : 7.5,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: KonataTheme.borderRadiusPill,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  color: fg,
                  fontSize: widget.compact
                      ? KonataTheme.fontSizeCaption
                      : KonataTheme.fontSizeBodySm,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapsuleFullListButton extends StatefulWidget {
  const _CapsuleFullListButton({
    super.key,
    required this.onDarkBackdrop,
    required this.compact,
    required this.onTap,
  });

  final bool onDarkBackdrop;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_CapsuleFullListButton> createState() => _CapsuleFullListButtonState();
}

class _CapsuleFullListButtonState extends State<_CapsuleFullListButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = widget.onDarkBackdrop
        ? KonataTheme.overlayWhiteTextHigh
        : p.textPrimary;
    final hoverBg = widget.onDarkBackdrop
        ? KonataTheme.overlayWhiteMuted
        : p.softFill;

    return KonataTooltip(
      message: '查看全部',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: KonataTheme.motionMicro,
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 9 : 10,
              vertical: widget.compact ? 6.5 : 7.5,
            ),
            decoration: BoxDecoration(
              color: _hovered ? hoverBg : const Color(0x00000000),
              borderRadius: KonataTheme.borderRadiusPill,
            ),
            child: Icon(
              Icons.grid_view_rounded,
              size: widget.compact ? 16 : 17,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _SubFilterChip extends StatelessWidget {
  const _SubFilterChip({
    required this.label,
    required this.selected,
    required this.onDarkBackdrop,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool onDarkBackdrop;
  final KonataPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final bg = selected
        ? (onDarkBackdrop ? KonataTheme.overlayWhiteMuted : p.softFill)
        : (onDarkBackdrop
              ? const Color(0x4012151D)
              : KonataPlaybackTokens.glassSurface(p));
    final fg = selected
        ? (onDarkBackdrop ? KonataTheme.pureWhite : p.textPrimary)
        : (onDarkBackdrop ? KonataTheme.overlayWhiteTextDim : p.textSecondary);
    final border = selected
        ? (onDarkBackdrop
              ? KonataTheme.overlayWhiteBorderStrong
              : p.hoverBorder)
        : (onDarkBackdrop ? KonataTheme.overlayWhiteBorder : p.hairline);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(color: border, width: 0.9),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: KonataTheme.fontSizeCaptionXs,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
