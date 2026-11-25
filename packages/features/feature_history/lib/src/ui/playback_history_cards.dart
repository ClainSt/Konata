import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/history_timeline_models.dart';
import 'playback_history_sub_cards.dart';

/// 播放记录自然日时间轴分段组件（左侧发光节点 + 连续细线轨道 + 响应式双栏卡片网格）。
class HistoryDaySectionView extends StatelessWidget {
  /// 创建单个自然日时间轴分段视图。
  const HistoryDaySectionView({
    super.key,
    required this.dayGroup,
    required this.isGroupExpanded,
    required this.onToggleExpanded,
    required this.isSelectionMode,
    required this.selectedIds,
    required this.onToggleSelect,
    required this.onResumeItem,
    required this.onOpenWorkDetail,
    required this.onDeleteItem,
    required this.onDeleteGroup,
    required this.imageLoader,
    this.onMarkItemCompleted,
    this.onMarkGroupCompleted,
    this.pathArtworkLoader,
    this.entryArtworkLoader,
  });

  /// 按自然日聚合的时间轴数据。
  final HistoryDayGroup dayGroup;

  /// 判断作品分组是否展开回调。
  final bool Function(String groupKey) isGroupExpanded;

  /// 切换分组展开状态回调。
  final ValueChanged<String> onToggleExpanded;

  /// 是否处于批量多选编辑模式。
  final bool isSelectionMode;

  /// 已选中的播放记录主键集合。
  final Set<String> selectedIds;

  /// 切换单条记录选择态回调。
  final ValueChanged<String> onToggleSelect;

  /// 点击续播某条记录回调。
  final ValueChanged<HistoryEntryView> onResumeItem;

  /// 点击查看关联作品详情页回调。
  final ValueChanged<WorkId> onOpenWorkDetail;

  /// 删除单条播放记录回调。
  final ValueChanged<HistoryEntryView> onDeleteItem;

  /// 删除整个当日作品分组回调。
  final ValueChanged<HistoryWorkGroupEntry> onDeleteGroup;

  /// 作品封面加载器。
  final HistoryArtworkLoader? imageLoader;

  /// 可选标记单条已完播回调。
  final ValueChanged<HistoryEntryView>? onMarkItemCompleted;

  /// 可选标记作品分组已完播回调。
  final ValueChanged<HistoryWorkGroupEntry>? onMarkGroupCompleted;

  /// 可选按路径加载剧照字节的回调。
  final HistoryPathArtworkLoader? pathArtworkLoader;

  /// 记录级图片加载器。
  final HistoryEntryArtworkLoader? entryArtworkLoader;

  static const double _timelineRailWidth = 22.0;
  static const double _twoColumnWorkBreakpoint = 860.0;
  static const double _workColumnGap = 12.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final compact =
        KonataAdaptiveTokens.isAndroid ||
        MediaQuery.sizeOf(context).width <
            KonataAdaptiveTokens.tabletBreakpoint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: _timelineRailWidth,
              child: Center(
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.accent,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: p.accent.withValues(alpha: 0.28),
                        blurRadius: 6,
                        spreadRadius: 2.5,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              dayGroup.dateKey.replaceAll('-', '.'),
              style: KonataTheme.textStyle(
                color: p.textSecondary,
                fontSize: 14,
                weight: KonataTheme.weightActive,
                tabularFigures: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _timelineRailWidth,
              child: Center(child: Container(width: 1.5, color: p.hairline)),
            ),
            Padding(
              padding: const EdgeInsets.only(
                left: _timelineRailWidth + 8,
                bottom: 18,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final useTwoColumns =
                      constraints.maxWidth >= _twoColumnWorkBreakpoint;
                  final works = dayGroup.works;
                  if (!useTwoColumns) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (var i = 0; i < works.length; i++) ...<Widget>[
                          if (i > 0) const SizedBox(height: 10),
                          _buildCard(works[i], compact),
                        ],
                      ],
                    );
                  }

                  final rows = <Widget>[];
                  for (var i = 0; i < works.length; i += 2) {
                    if (i > 0) rows.add(const SizedBox(height: 12));
                    final left = works[i];
                    final right = i + 1 < works.length ? works[i + 1] : null;
                    rows.add(
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(child: _buildCard(left, compact)),
                          const SizedBox(width: _workColumnGap),
                          Expanded(
                            child: right == null
                                ? const SizedBox.shrink()
                                : _buildCard(right, compact),
                          ),
                        ],
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: rows,
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCard(HistoryWorkGroupEntry group, bool compact) {
    return HistoryWorkTimelineCard(
      key: ValueKey<String>(group.groupKey),
      group: group,
      expanded: isGroupExpanded(group.groupKey),
      onToggleExpanded: () => onToggleExpanded(group.groupKey),
      isSelectionMode: isSelectionMode,
      selectedIds: selectedIds,
      onToggleSelect: onToggleSelect,
      onResumeItem: onResumeItem,
      onOpenWorkDetail: () => onOpenWorkDetail(group.workId),
      onDeleteItem: onDeleteItem,
      onDeleteGroup: () => onDeleteGroup(group),
      onMarkItemCompleted: onMarkItemCompleted,
      onMarkGroupCompleted: onMarkGroupCompleted == null
          ? null
          : () => onMarkGroupCompleted!(group),
      imageLoader: imageLoader,
      pathArtworkLoader: pathArtworkLoader,
      entryArtworkLoader: entryArtworkLoader,
      compact: compact,
    );
  }
}

/// 同一天同作品的折叠/可展开时间轴主卡片组件（支持 16:9 与 1:1 横向剧照抽屉）。
class HistoryWorkTimelineCard extends StatefulWidget {
  /// 创建单作品时间轴分组卡片。
  const HistoryWorkTimelineCard({
    super.key,
    required this.group,
    required this.expanded,
    required this.onToggleExpanded,
    required this.isSelectionMode,
    required this.selectedIds,
    required this.onToggleSelect,
    required this.onResumeItem,
    required this.onOpenWorkDetail,
    required this.onDeleteItem,
    required this.onDeleteGroup,
    required this.imageLoader,
    this.onMarkItemCompleted,
    this.onMarkGroupCompleted,
    this.pathArtworkLoader,
    this.entryArtworkLoader,
    this.compact = false,
  });

  /// 当日同作品播放聚合条目。
  final HistoryWorkGroupEntry group;

  /// 多条记录抽屉是否处于展开状态。
  final bool expanded;

  /// 展开或收起抽屉回调。
  final VoidCallback onToggleExpanded;

  /// 是否处于批量多选模式。
  final bool isSelectionMode;

  /// 全局选中的记录 ID 集合。
  final Set<String> selectedIds;

  /// 切换单条记录勾选态回调。
  final ValueChanged<String> onToggleSelect;

  /// 点击续播某条记录回调。
  final ValueChanged<HistoryEntryView> onResumeItem;

  /// 点击跳转作品详情页回调。
  final VoidCallback onOpenWorkDetail;

  /// 删除单条记录回调。
  final ValueChanged<HistoryEntryView> onDeleteItem;

  /// 删除整组记录回调。
  final VoidCallback onDeleteGroup;

  /// 作品封面加载器。
  final HistoryArtworkLoader? imageLoader;

  /// 可选标记单条已完播回调。
  final ValueChanged<HistoryEntryView>? onMarkItemCompleted;

  /// 可选标记整组已完播回调。
  final VoidCallback? onMarkGroupCompleted;

  /// 可选剧照按路径加载回调。
  final HistoryPathArtworkLoader? pathArtworkLoader;

  /// 记录级图片加载器。
  final HistoryEntryArtworkLoader? entryArtworkLoader;

  /// 是否使用手机端紧凑尺寸。
  final bool compact;

  @override
  State<HistoryWorkTimelineCard> createState() =>
      _HistoryWorkTimelineCardState();
}

class _HistoryWorkTimelineCardState extends State<HistoryWorkTimelineCard> {
  final ScrollController _drawerScrollController = ScrollController();

  @override
  void dispose() {
    _drawerScrollController.dispose();
    super.dispose();
  }

  Future<void> _openCardMenu(
    BuildContext anchorContext,
    HistoryEntryView latest,
    bool isGrouped,
  ) async {
    final choice = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: <KonataGlassMenuItem<String>>[
        const KonataGlassMenuItem<String>(
          value: 'resume',
          label: '继续播放最新进度',
          icon: Icons.play_arrow_rounded,
        ),
        const KonataGlassMenuItem<String>(
          value: 'detail',
          label: '打开作品详情',
          icon: Icons.open_in_new_rounded,
        ),
        if (widget.onMarkGroupCompleted != null &&
            widget.group.items.any((e) => !e.isCompleted))
          KonataGlassMenuItem<String>(
            value: 'complete',
            label: latest.isAudio ? '标为已听完' : '标为已看完',
            icon: Icons.done_all_rounded,
          ),
        KonataGlassMenuItem<String>(
          value: 'delete',
          label: isGrouped ? '删除当日全部记录' : '删除此条记录',
          icon: Icons.delete_outline_rounded,
          isDanger: true,
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'resume':
        widget.onResumeItem(latest);
      case 'detail':
        widget.onOpenWorkDetail();
      case 'complete':
        widget.onMarkGroupCompleted?.call();
      case 'delete':
        if (isGrouped) {
          widget.onDeleteGroup();
        } else {
          widget.onDeleteItem(latest);
        }
    }
  }

  void _toggleGroupSelection(bool allSelected) {
    for (final item in widget.group.items) {
      final selected = widget.selectedIds.contains(item.record.id);
      if (allSelected == selected) {
        widget.onToggleSelect(item.record.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final group = widget.group;
    final latest = group.latestItem;
    final isGrouped = group.entryCount > 1;
    final compact =
        widget.compact ||
        MediaQuery.sizeOf(context).width <
            KonataAdaptiveTokens.tabletBreakpoint;

    final allSelected =
        group.items.isNotEmpty &&
        group.items.every((e) => widget.selectedIds.contains(e.record.id));
    final anySelected = group.items.any(
      (e) => widget.selectedIds.contains(e.record.id),
    );
    final coverW = compact ? 52.0 : 60.0;
    final coverH = compact ? 76.0 : 88.0;

    return KonataSurfaceCard(
      enableHover: !widget.expanded,
      padding: EdgeInsets.zero,
      borderColor: (widget.isSelectionMode && anySelected)
          ? KonataTheme.activeControlBorder(p)
          : (widget.expanded ? p.accent.withValues(alpha: 0.34) : null),
      child: ClipRRect(
        borderRadius: KonataTheme.borderRadiusCard,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (widget.isSelectionMode) {
                    _toggleGroupSelection(allSelected);
                    return;
                  }
                  widget.onToggleExpanded();
                },
                onSecondaryTap: () => _openCardMenu(context, latest, isGrouped),
                onLongPress: () => _openCardMenu(context, latest, isGrouped),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 10 : 12,
                    vertical: 10,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      if (widget.isSelectionMode) ...<Widget>[
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: Checkbox(
                            value: allSelected,
                            tristate: true,
                            activeColor: p.accent,
                            onChanged: (_) =>
                                _toggleGroupSelection(allSelected),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.isSelectionMode
                            ? () => _toggleGroupSelection(allSelected)
                            : widget.onOpenWorkDetail,
                        child: HistoryThumbnail(
                          workId: group.workId,
                          isAudio: false,
                          imageLoader: widget.imageLoader,
                          width: coverW,
                          height: coverH,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              group.workTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: KonataTheme.textStyle(
                                color: p.textPrimary,
                                fontSize: compact ? 14.8 : 16.0,
                                weight: 700,
                                height: 1.24,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              group.collapsedSummary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: KonataTheme.textStyle(
                                color: p.textSecondary,
                                fontSize: KonataTheme.fontSizeBodyXs,
                                tabularFigures: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: KonataTheme.tabSwitchDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: (widget.expanded || widget.isSelectionMode)
                  ? _ExpandedHistoryWorkEntries(
                      items: group.items,
                      isAudioGroup: group.isAudioGroup,
                      compact: compact,
                      scrollController: _drawerScrollController,
                      isSelectionMode: widget.isSelectionMode,
                      selectedIds: widget.selectedIds,
                      onToggleSelect: widget.onToggleSelect,
                      onResumeItem: widget.onResumeItem,
                      onDeleteItem: widget.onDeleteItem,
                      onMarkItemCompleted: widget.onMarkItemCompleted,
                      imageLoader: widget.imageLoader,
                      pathArtworkLoader: widget.pathArtworkLoader,
                      entryArtworkLoader: widget.entryArtworkLoader,
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 同一作品下多条观看/收听记录的横向可拖拽抽屉区。
class _ExpandedHistoryWorkEntries extends StatelessWidget {
  const _ExpandedHistoryWorkEntries({
    required this.items,
    required this.isAudioGroup,
    required this.compact,
    required this.scrollController,
    required this.isSelectionMode,
    required this.selectedIds,
    required this.onToggleSelect,
    required this.onResumeItem,
    required this.onDeleteItem,
    required this.imageLoader,
    this.onMarkItemCompleted,
    this.pathArtworkLoader,
    this.entryArtworkLoader,
  });

  final List<HistoryEntryView> items;
  final bool isAudioGroup;
  final bool compact;
  final ScrollController scrollController;
  final bool isSelectionMode;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelect;
  final ValueChanged<HistoryEntryView> onResumeItem;
  final ValueChanged<HistoryEntryView> onDeleteItem;
  final ValueChanged<HistoryEntryView>? onMarkItemCompleted;
  final HistoryArtworkLoader? imageLoader;
  final HistoryPathArtworkLoader? pathArtworkLoader;

  /// 记录级图片加载器。
  final HistoryEntryArtworkLoader? entryArtworkLoader;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final trayBg = p.isDark
        ? KonataTheme.scrimBlackHairline
        : p.secondaryButtonBg;
    final drawerHeight = isAudioGroup
        ? (compact ? 84.0 : 92.0)
        : (compact ? 88.0 : 96.0);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: trayBg,
        border: Border(
          top: BorderSide(color: KonataTheme.subtleOutlineBorder(p)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth;
          final subCardWidth = items.length <= 1
              ? available
              : available >= 500 && items.length == 2
              ? (available - 10) / 2
              : available >= 500
              ? ((available - 20) / 2.22).clamp(248.0, 310.0)
              : math.min(available, (available * 0.82).clamp(180.0, 296.0));

          return Listener(
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent && scrollController.hasClients) {
                final delta = signal.scrollDelta.dy != 0
                    ? signal.scrollDelta.dy
                    : signal.scrollDelta.dx;
                final maxScroll = scrollController.position.maxScrollExtent;
                final next = (scrollController.offset + delta).clamp(
                  0.0,
                  maxScroll,
                );
                if (next != scrollController.offset) {
                  scrollController.jumpTo(next);
                }
              }
            },
            child: ScrollConfiguration(
              behavior: const _HistoryHorizontalDragScrollBehavior(),
              child: SizedBox(
                height: drawerHeight,
                child: ListView.separated(
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final entry = items[index];
                    return HistoryExpandedEpisodeRow(
                      item: entry,
                      compact: compact,
                      cardWidth: subCardWidth,
                      isSelectionMode: isSelectionMode,
                      isSelected: selectedIds.contains(entry.record.id),
                      onToggleSelect: () => onToggleSelect(entry.record.id),
                      onResume: () => onResumeItem(entry),
                      onDelete: () => onDeleteItem(entry),
                      onMarkCompleted: onMarkItemCompleted == null
                          ? null
                          : () => onMarkItemCompleted!(entry),
                      imageLoader: imageLoader,
                      pathArtworkLoader: pathArtworkLoader,
                      entryArtworkLoader: entryArtworkLoader,
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 允许鼠标左键及触屏设备平滑横向拖拽滑动抽屉的滚动行为。
class _HistoryHorizontalDragScrollBehavior extends ScrollBehavior {
  const _HistoryHorizontalDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
