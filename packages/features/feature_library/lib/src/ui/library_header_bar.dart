import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../state/library_controller.dart';

/// 媒体库顶栏标题、数量统计徽标与待复核操作组。
class LibraryHeaderBar extends StatelessWidget {
  /// 创建媒体库顶栏组件。
  const LibraryHeaderBar({
    super.key,
    required this.compact,
    required this.displayedCount,
    required this.totalCount,
    required this.reviewCount,
    required this.hasQuery,
    required this.hasActiveFilters,
    required this.showSearchButton,
    required this.searchExpanded,
    required this.filtersExpanded,
    required this.searchController,
    required this.searchFocusNode,
    required this.onOpenSearch,
    required this.onCloseSearch,
    required this.onToggleFilters,
    required this.onOpenReview,
  });

  /// 是否处于手机端窄屏紧凑排布模式。
  final bool compact;

  /// 当前筛选与搜索后实际展示的作品数。
  final int displayedCount;

  /// 媒体库未过滤前的可见作品总数。
  final int totalCount;

  /// 待复核队列条目总数。
  final int reviewCount;

  /// 是否存在非空搜索词。
  final bool hasQuery;

  /// 是否存在激活中的维度过滤条件。
  final bool hasActiveFilters;

  /// 是否在顶栏展示内置搜索唤醒按钮（桌面宽度接管顶栏搜时隐藏）。
  final bool showSearchButton;

  /// 是否正处于全宽内联搜索展开态。
  final bool searchExpanded;

  /// 是否正处于多维筛选条展开态。
  final bool filtersExpanded;

  /// 内联搜索框文本控制器。
  final TextEditingController searchController;

  /// 内联搜索框焦点节点。
  final FocusNode searchFocusNode;

  /// 展开内联搜索栏回调。
  final VoidCallback onOpenSearch;

  /// 收起内联搜索栏回调。
  final VoidCallback onCloseSearch;

  /// 展开或收起筛选与排序条回调。
  final VoidCallback onToggleFilters;

  /// 打开待复核队列中心弹窗回调。
  final VoidCallback onOpenReview;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    if (searchExpanded) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) onCloseSearch();
        },
        child: Focus(
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              onCloseSearch();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SizedBox(
            height: KonataTheme.pageHeaderHeight,
            child: Row(
              children: <Widget>[
                KonataCapsuleIconButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: '收起搜索',
                  color: p.textSecondary,
                  onTap: onCloseSearch,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: KonataSearchField(
                    controller: searchController,
                    focusNode: searchFocusNode,
                    height: 36,
                    onClear: () {
                      searchController.clear();
                      searchFocusNode.requestFocus();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final countText = (hasQuery || hasActiveFilters)
        ? '$displayedCount / $totalCount 部'
        : '$totalCount 部';

    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            '全部作品',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: compact
                ? KonataTheme.h2Style(p).copyWith(fontSize: 22)
                : KonataTheme.h1Style(p),
          ),
        ),
        if (totalCount > 0) SizedBox(width: compact ? 8 : 12),
        if (totalCount > 0)
          Container(
            key: const Key('library_works_count_pill'),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            decoration: BoxDecoration(
              color: p.softFill,
              borderRadius: KonataTheme.borderRadiusPill,
              border: Border.all(color: p.hairline),
            ),
            child: Text(
              countText,
              style: KonataTheme.textStyle(
                color: p.textSecondary,
                fontSize: KonataTheme.fontSizeCaption,
                weight: KonataTheme.weightActive,
                tabularFigures: true,
              ),
            ),
          ),
      ],
    );

    final actionGap = compact ? 6.0 : 8.0;
    final actions = <Widget>[
      if (showSearchButton)
        _HeaderIconPill(
          icon: Icons.search_rounded,
          tooltip: '搜索作品',
          highlighted: hasQuery,
          compact: compact,
          onTap: onOpenSearch,
        ),
      if (totalCount > 0)
        _HeaderIconPill(
          icon: Icons.tune_rounded,
          tooltip: '筛选与排序',
          highlighted: filtersExpanded || hasActiveFilters,
          compact: compact,
          onTap: onToggleFilters,
        ),
      if (reviewCount > 0)
        _ReviewHeaderPill(
          count: reviewCount,
          compact: compact,
          onTap: onOpenReview,
        ),
    ];

    final actionsRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: actionGap),
          actions[i],
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final veryNarrow = constraints.maxWidth < 430 && reviewCount > 0;
        if (veryNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                height: 38,
                child: Align(alignment: Alignment.centerLeft, child: titleRow),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: actionGap,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ),
            ],
          );
        }

        return SizedBox(
          height: KonataTheme.pageHeaderHeight,
          child: Row(
            children: <Widget>[
              Expanded(child: titleRow),
              const SizedBox(width: 12),
              actionsRow,
            ],
          ),
        );
      },
    );
  }
}

/// 折叠展开式媒体库排序与筛选控制条。
class LibraryFilterSortStrip extends StatelessWidget {
  /// 创建排序与多维筛选条。
  const LibraryFilterSortStrip({
    super.key,
    required this.controller,
    required this.compact,
    required this.onClearAll,
  });

  /// 媒体库主控制器。
  final LibraryController controller;

  /// 是否使用手机窄屏紧凑按钮。
  final bool compact;

  /// 清空全部搜索与筛选状态回调。
  final VoidCallback onClearAll;

  static String _sortModeLabel(LibrarySortMode mode) => switch (mode) {
    LibrarySortMode.libraryOrder => '默认顺序',
    LibrarySortMode.title => '名称拼音',
    LibrarySortMode.year => '发行年份',
    LibrarySortMode.score => '评分高低',
    LibrarySortMode.recent => '最近入库',
  };

  @override
  Widget build(BuildContext context) {
    final prefs = controller.prefs;
    final years = controller.availableYears;
    final groups = controller.availableReleaseGroups;
    final sources = controller.sources;
    String? sourceLabel;
    if (prefs.sourceIdFilter != null) {
      for (final src in sources) {
        if (src.id == prefs.sourceIdFilter) {
          sourceLabel = src.label;
          break;
        }
      }
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Builder(
          builder: (btnCtx) => _FilterChipMenuTrigger(
            label: '排序：${_sortModeLabel(prefs.sortMode)}',
            icon: Icons.sort_rounded,
            active: prefs.sortMode != LibrarySortMode.libraryOrder,
            onTap: () async {
              final picked = await showKonataGlassMenu<LibrarySortMode>(
                anchorContext: btnCtx,
                items: <KonataGlassMenuItem<LibrarySortMode>>[
                  for (final mode in LibrarySortMode.values)
                    KonataGlassMenuItem<LibrarySortMode>(
                      value: mode,
                      label: _sortModeLabel(mode),
                      icon: prefs.sortMode == mode
                          ? Icons.check_rounded
                          : Icons.sort_rounded,
                    ),
                ],
              );
              if (picked != null) controller.setSortMode(picked);
            },
          ),
        ),
        _FilterChipMenuTrigger(
          label: prefs.sortOrder == LibrarySortOrder.descending ? '降序' : '升序',
          icon: prefs.sortOrder == LibrarySortOrder.descending
              ? Icons.arrow_downward_rounded
              : Icons.arrow_upward_rounded,
          active: prefs.sortOrder != LibrarySortOrder.ascending,
          onTap: controller.toggleSortOrder,
        ),
        if (years.isNotEmpty)
          Builder(
            builder: (btnCtx) => _FilterChipMenuTrigger(
              label: prefs.yearFilter == null ? '年份' : '年份：${prefs.yearFilter}',
              icon: Icons.calendar_today_outlined,
              active: prefs.yearFilter != null,
              onTap: () async {
                final picked = await showKonataGlassMenu<int>(
                  anchorContext: btnCtx,
                  items: <KonataGlassMenuItem<int>>[
                    const KonataGlassMenuItem<int>(
                      value: -1,
                      label: '全部年份',
                      icon: Icons.clear_all_rounded,
                    ),
                    for (final year in years)
                      KonataGlassMenuItem<int>(
                        value: year,
                        label: '$year 年',
                        icon: prefs.yearFilter == year
                            ? Icons.check_rounded
                            : null,
                      ),
                  ],
                );
                if (picked != null) {
                  controller.setYearFilter(picked == -1 ? null : picked);
                }
              },
            ),
          ),
        if (groups.isNotEmpty)
          Builder(
            builder: (btnCtx) => _FilterChipMenuTrigger(
              label: prefs.releaseGroupFilter == null
                  ? '压制/字幕组'
                  : prefs.releaseGroupFilter!,
              icon: Icons.subtitles_outlined,
              active: prefs.releaseGroupFilter != null,
              onTap: () async {
                final picked = await showKonataGlassMenu<String>(
                  anchorContext: btnCtx,
                  items: <KonataGlassMenuItem<String>>[
                    const KonataGlassMenuItem<String>(
                      value: '',
                      label: '全部字幕/压制组',
                      icon: Icons.clear_all_rounded,
                    ),
                    for (final g in groups)
                      KonataGlassMenuItem<String>(
                        value: g,
                        label: g,
                        icon: prefs.releaseGroupFilter == g
                            ? Icons.check_rounded
                            : null,
                      ),
                  ],
                );
                if (picked != null) {
                  controller.setReleaseGroupFilter(
                    picked.isEmpty ? null : picked,
                  );
                }
              },
            ),
          ),
        if (sources.length > 1)
          Builder(
            builder: (btnCtx) => _FilterChipMenuTrigger(
              label: sourceLabel == null ? '媒体源' : '源：$sourceLabel',
              icon: Icons.storage_rounded,
              active: prefs.sourceIdFilter != null,
              onTap: () async {
                final picked = await showKonataGlassMenu<String>(
                  anchorContext: btnCtx,
                  items: <KonataGlassMenuItem<String>>[
                    const KonataGlassMenuItem<String>(
                      value: '',
                      label: '全部媒体源',
                      icon: Icons.clear_all_rounded,
                    ),
                    for (final s in sources)
                      KonataGlassMenuItem<String>(
                        value: s.id,
                        label: s.label,
                        icon: prefs.sourceIdFilter == s.id
                            ? Icons.check_rounded
                            : null,
                      ),
                  ],
                );
                if (picked != null) {
                  controller.setSourceIdFilter(picked.isEmpty ? null : picked);
                }
              },
            ),
          ),
        _FilterChipMenuTrigger(
          label: '仅多版本',
          icon: Icons.layers_outlined,
          active: prefs.onlyMultiSource,
          onTap: () => controller.setOnlyMultiSource(!prefs.onlyMultiSource),
        ),
        if (prefs.hasActiveFilters ||
            controller.searchQuery.trim().isNotEmpty ||
            prefs.sortMode != LibrarySortMode.libraryOrder ||
            prefs.sortOrder != LibrarySortOrder.ascending)
          KonataPillButton.ghost(
            label: compact ? '重置' : '重置全部',
            icon: Icons.refresh_rounded,
            compact: true,
            onPressed: onClearAll,
          ),
      ],
    );
  }
}

class _HeaderIconPill extends StatefulWidget {
  const _HeaderIconPill({
    required this.icon,
    required this.tooltip,
    required this.highlighted,
    required this.compact,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool highlighted;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_HeaderIconPill> createState() => _HeaderIconPillState();
}

class _HeaderIconPillState extends State<_HeaderIconPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bg = widget.highlighted
        ? p.accentBadge.bg
        : (_hovered ? p.surfaceHover : p.softFill);
    final borderColor = widget.highlighted
        ? p.accentBadge.border
        : (_hovered ? p.hoverBorder : p.hairline);
    final fg = widget.highlighted ? p.accentBadge.fg : p.textSecondary;

    return KonataTooltip(
      message: widget.tooltip,
      waitDuration: KonataTheme.tooltipWaitDuration,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: KonataTheme.motionMicro,
            height: widget.compact ? 36 : 34,
            width: widget.compact ? 36 : 34,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: KonataTheme.borderRadiusPill,
              border: Border.all(color: borderColor),
            ),
            child: Icon(widget.icon, size: 16, color: fg),
          ),
        ),
      ),
    );
  }
}

class _ReviewHeaderPill extends StatefulWidget {
  const _ReviewHeaderPill({
    required this.count,
    required this.compact,
    required this.onTap,
  });

  final int count;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_ReviewHeaderPill> createState() => _ReviewHeaderPillState();
}

class _ReviewHeaderPillState extends State<_ReviewHeaderPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          height: widget.compact ? 36 : 34,
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 11 : 13),
          decoration: BoxDecoration(
            gradient: KonataTheme.opticalSheenGradient(p, hovered: _hovered),
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(
              color: p.warning.withValues(alpha: _hovered ? 0.54 : 0.34),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.warning,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                widget.compact ? '复核 ${widget.count}' : '待复核 · ${widget.count}',
                style: KonataTheme.textStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeCaption,
                  weight: KonataTheme.weightActive,
                  tabularFigures: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChipMenuTrigger extends StatefulWidget {
  const _FilterChipMenuTrigger({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_FilterChipMenuTrigger> createState() => _FilterChipMenuTriggerState();
}

class _FilterChipMenuTriggerState extends State<_FilterChipMenuTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bg = widget.active
        ? p.accentBadge.bg
        : (_hovered ? p.surfaceHover : p.softFill);
    final border = widget.active
        ? p.accentBadge.border
        : (_hovered ? p.hoverBorder : p.hairline);
    final fg = widget.active
        ? p.accentBadge.fg
        : (_hovered ? p.textPrimary : p.textSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(widget.icon, size: 14, color: fg),
              const SizedBox(width: 5),
              Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: KonataTheme.textStyle(
                  color: fg,
                  fontSize: KonataTheme.fontSizeCaption,
                  weight: widget.active
                      ? KonataTheme.weightActive
                      : KonataTheme.weightRegularLabel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
