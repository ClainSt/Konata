import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/history_timeline_models.dart';
import '../providers.dart';
import '../state/history_controller.dart';
import 'playback_history_cards.dart';
import 'playback_history_sub_cards.dart';

/// 播放记录时间轴页面组件（按自然日与作品分组呈现跨介质观看/收听轨迹）。
class PlaybackHistoryPage extends ConsumerStatefulWidget {
  /// 创建播放记录页面。
  const PlaybackHistoryPage({
    super.key,
    this.slotContext,
    this.imageLoaderOverride,
    this.pathArtworkLoaderOverride,
  });

  /// 宿主视图槽位上下文参数。
  final ViewSlotContext? slotContext;

  /// 可选作品封面字节加载器覆盖（测试或宿主解耦注入）。
  final HistoryArtworkLoader? imageLoaderOverride;

  /// 可选分集剧照相对路径字节加载器覆盖。
  final HistoryPathArtworkLoader? pathArtworkLoaderOverride;

  @override
  ConsumerState<PlaybackHistoryPage> createState() =>
      _PlaybackHistoryPageState();
}

class _PlaybackHistoryPageState extends ConsumerState<PlaybackHistoryPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _confirmClearAll(
    BuildContext context,
    HistoryController controller,
  ) async {
    final p = context.palette;
    final confirmed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (dlgCtx) => KonataGlassDialog(
        width: 440,
        title: '清空播放记录',
        onClose: () => Navigator.of(dlgCtx).pop(false),
        actions: <Widget>[
          KonataPillButton.ghost(
            label: '取消',
            onPressed: () => Navigator.of(dlgCtx).pop(false),
          ),
          KonataPillButton.danger(
            label: '确认清空',
            onPressed: () => Navigator.of(dlgCtx).pop(true),
          ),
        ],
        child: Text(
          '确定清空全部观看与收听记录吗？该操作仅记录同步删除标记，不会删除任何磁盘上的视频或音频文件。',
          style: KonataTheme.bodyLabelStyle(p).copyWith(height: 1.55),
        ),
      ),
    );
    if (confirmed == true) {
      controller.clearAllHistory();
      if (context.mounted) {
        showKonataToast(context, '已清空全部播放记录');
      }
    }
  }

  Future<void> _confirmDeleteSelected(
    BuildContext context,
    HistoryController controller,
  ) async {
    final p = context.palette;
    final count = controller.selectedRecordIds.length;
    if (count == 0) return;
    final confirmed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (dlgCtx) => KonataGlassDialog(
        width: 420,
        title: '清理所选播放记录',
        onClose: () => Navigator.of(dlgCtx).pop(false),
        actions: <Widget>[
          KonataPillButton.ghost(
            label: '取消',
            onPressed: () => Navigator.of(dlgCtx).pop(false),
          ),
          KonataPillButton.danger(
            label: '确认清理 ($count)',
            onPressed: () => Navigator.of(dlgCtx).pop(true),
          ),
        ],
        child: Text(
          '确定将选中的 $count 条播放记录从时间轴移除吗？媒体源磁盘文件不受任何影响。',
          style: KonataTheme.bodyLabelStyle(p).copyWith(height: 1.55),
        ),
      ),
    );
    if (confirmed == true) {
      controller.softDeleteSelected();
      if (context.mounted) {
        showKonataToast(context, '已清理 $count 条播放记录');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(featureHistoryDependenciesProvider);
    final controller = ref.watch(historyControllerProvider);
    final imageLoader = widget.imageLoaderOverride ?? deps.imageLoader;
    final pathLoader =
        widget.pathArtworkLoaderOverride ?? deps.pathArtworkLoader;
    final compact =
        KonataAdaptiveTokens.isAndroid ||
        deps.platform == KonataPlatform.androidPhone ||
        MediaQuery.sizeOf(context).width < KonataAdaptiveTokens.tabletBreakpoint;
    final horizontalPad = compact
        ? KonataAdaptiveTokens.horizontalInset
        : KonataTheme.pageHorizontalPadding;
    final bottomClearance = KonataBottomClearanceScope.of(context);
    final listBottomPad = math.max(
      compact ? 18.0 : 28.0,
      bottomClearance + 16.0,
    );

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final p = context.palette;
        final dayGroups = controller.dayGroups;
        final hasAny = controller.hasAnyRecords;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPad,
                compact ? 8.0 : KonataTheme.pageHeaderTopSpacing,
                horizontalPad,
                compact ? 10.0 : KonataTheme.pageHeaderBottomSpacing,
              ),
              child: AdaptiveActionHeader(
                title: '播放记录',
                badge: KonataSegmentedCapsule<HistoryMediaFilter>(
                  compact: true,
                  selected: controller.filter,
                  onChanged: controller.setFilter,
                  options: <KonataSegmentOption<HistoryMediaFilter>>[
                    for (final f in HistoryMediaFilter.values)
                      KonataSegmentOption<HistoryMediaFilter>(
                        value: f,
                        label: f.label,
                      ),
                  ],
                ),
                searchQuery: controller.searchQuery,
                onSearchChanged: controller.setSearchQuery,
                searchHint: '搜索动画名称、单集或专辑',
                primaryActions: <AdaptiveHeaderAction>[
                  if (hasAny && !controller.isSelectionMode) ...<
                    AdaptiveHeaderAction
                  >[
                    AdaptiveHeaderAction(
                      icon: Icons.done_all_rounded,
                      label: '标记为已看/已听',
                      tooltip: '批量标记已完播',
                      onPressed: () => controller.enterSelectionMode(
                        action: HistorySelectionAction.markCompleted,
                      ),
                    ),
                    AdaptiveHeaderAction(
                      icon: Icons.checklist_rounded,
                      label: '批量清理',
                      tooltip: '进入多选批量删除',
                      onPressed: () => controller.enterSelectionMode(
                        action: HistorySelectionAction.deleteRecords,
                      ),
                    ),
                    AdaptiveHeaderAction(
                      icon: Icons.delete_sweep_outlined,
                      label: '清空全部',
                      tooltip: '清空播放记录',
                      onPressed: () => _confirmClearAll(context, controller),
                    ),
                  ],
                ],
                overflowActions: <AdaptiveHeaderAction>[
                  if (hasAny && controller.isSelectionMode)
                    AdaptiveHeaderAction(
                      icon: Icons.close_rounded,
                      label: '退出多选',
                      onPressed: controller.exitSelectionMode,
                    ),
                ],
              ),
            ),
            if (controller.isSelectionMode)
              Padding(
                padding: EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, 12),
                child: _HistorySelectionToolbar(
                  controller: controller,
                  onDeleteSelected: () =>
                      _confirmDeleteSelected(context, controller),
                  onMarkCompleted: () {
                    final count = controller.selectedRecordIds.length;
                    controller.markSelectedCompleted();
                    if (count > 0 && context.mounted) {
                      showKonataToast(context, '已将 $count 条记录标记为已完成');
                    }
                  },
                ),
              ),
            Expanded(
              child: dayGroups.isEmpty
                  ? _EmptyHistoryView(
                      hasAnyRecords: hasAny,
                      palette: p,
                      horizontalPad: horizontalPad,
                      bottomPad: listBottomPad,
                      onResetFilters: () {
                        controller.setFilter(HistoryMediaFilter.all);
                        controller.setSearchQuery('');
                      },
                    )
                  : KonataDraggableScrollbar(
                      controller: _scrollController,
                      builder: (context, scrollController) =>
                          ListView.builder(
                            controller: scrollController,
                            padding: EdgeInsets.fromLTRB(
                              horizontalPad,
                              4,
                              horizontalPad,
                              listBottomPad,
                            ),
                            itemCount: dayGroups.length,
                            itemBuilder: (context, index) {
                              final dayGroup = dayGroups[index];
                              return HistoryDaySectionView(
                                key: ValueKey<String>(dayGroup.dateKey),
                                dayGroup: dayGroup,
                                isGroupExpanded: controller.isGroupExpanded,
                                onToggleExpanded:
                                    controller.toggleGroupExpanded,
                                isSelectionMode: controller.isSelectionMode,
                                selectedIds: controller.selectedRecordIds,
                                onToggleSelect: controller.toggleRecordSelected,
                                onResumeItem: controller.resumePlayback,
                                onOpenWorkDetail: controller.openWorkDetail,
                                onDeleteItem: (item) =>
                                    controller.softDeleteRecord(item.record.id),
                                onDeleteGroup: controller.softDeleteGroup,
                                onMarkItemCompleted: (item) => controller
                                    .markRecordCompleted(item.record.id),
                                onMarkGroupCompleted:
                                    controller.markGroupCompleted,
                                imageLoader: imageLoader,
                                pathArtworkLoader: pathLoader,
                              );
                            },
                          ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _HistorySelectionToolbar extends StatelessWidget {
  const _HistorySelectionToolbar({
    required this.controller,
    required this.onDeleteSelected,
    required this.onMarkCompleted,
  });

  final HistoryController controller;
  final VoidCallback onDeleteSelected;
  final VoidCallback onMarkCompleted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final count = controller.selectedRecordIds.length;
    final preferMark =
        controller.selectionAction == HistorySelectionAction.markCompleted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: p.softFill,
        borderRadius: KonataTheme.borderRadiusControl,
        border: Border.all(color: p.hairline),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            count > 0 ? '已选中 $count 条记录' : '请点选下方记录条目以批量处理',
            style: KonataTheme.textStyle(
              color: p.textPrimary,
              fontSize: KonataTheme.fontSizeBodySm,
              weight: KonataTheme.weightActive,
              tabularFigures: true,
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              KonataPillButton.ghost(
                label: '全选当前',
                compact: true,
                onPressed: controller.selectAllVisible,
              ),
              if (preferMark) ...<Widget>[
                KonataPillButton.danger(
                  label: '删除 ($count)',
                  compact: true,
                  onPressed: count == 0 ? null : onDeleteSelected,
                ),
                KonataPillButton.primary(
                  label: '标为已完播 ($count)',
                  icon: Icons.done_all_rounded,
                  compact: true,
                  onPressed: count == 0 ? null : onMarkCompleted,
                ),
              ] else ...<Widget>[
                KonataPillButton.secondary(
                  label: '标为已完播 ($count)',
                  icon: Icons.done_all_rounded,
                  compact: true,
                  onPressed: count == 0 ? null : onMarkCompleted,
                ),
                KonataPillButton.danger(
                  label: '确认删除 ($count)',
                  icon: Icons.delete_outline_rounded,
                  compact: true,
                  onPressed: count == 0 ? null : onDeleteSelected,
                ),
              ],
              KonataPillButton.ghost(
                label: '取消',
                compact: true,
                onPressed: controller.exitSelectionMode,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyHistoryView extends StatelessWidget {
  const _EmptyHistoryView({
    required this.hasAnyRecords,
    required this.palette,
    required this.horizontalPad,
    required this.bottomPad,
    required this.onResetFilters,
  });

  final bool hasAnyRecords;
  final KonataPalette palette;
  final double horizontalPad;
  final double bottomPad;
  final VoidCallback onResetFilters;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(horizontalPad, 24, horizontalPad, bottomPad),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                hasAnyRecords
                    ? Icons.search_off_rounded
                    : Icons.history_toggle_off_rounded,
                size: 52,
                color: p.textMuted,
              ),
              const SizedBox(height: 14),
              Text(
                hasAnyRecords ? '未找到匹配的播放记录' : '暂无播放记录',
                textAlign: TextAlign.center,
                style: KonataTheme.cardTitleStyle(
                  p,
                  fontSize: KonataTheme.fontSizeTitleLg,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hasAnyRecords
                    ? '请调整顶栏介质过滤或搜索关键词'
                    : '开始观看番剧或播放原声 CD 后，系统会自动按天记录你的足迹',
                textAlign: TextAlign.center,
                style: KonataTheme.captionStyle(
                  p,
                  fontSize: KonataTheme.fontSizeBodySm,
                ),
              ),
              if (hasAnyRecords) ...<Widget>[
                const SizedBox(height: 16),
                KonataPillButton.secondary(
                  label: '重置筛选条件',
                  icon: Icons.refresh_rounded,
                  onPressed: onResetFilters,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
