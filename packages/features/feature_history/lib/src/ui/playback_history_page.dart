import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/history_timeline_models.dart';
import '../providers.dart';
import '../state/history_controller.dart';
import 'playback_history_cards.dart';
import 'playback_history_sub_cards.dart';

/// 播放记录日记式时间轴页面（纯设计系统组件实现，三端自适应）。
class PlaybackHistoryPage extends ConsumerWidget {
  /// 创建播放记录时间轴页面。
  const PlaybackHistoryPage({
    super.key,
    this.controller,
    this.imageLoader,
  });

  /// 可选直传控制器；为空时从 [historyControllerProvider] 读取。
  final HistoryController? controller;

  /// 可选作品封面异步加载器。
  final HistoryArtworkLoader? imageLoader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direct = controller;
    final HistoryController effectiveController =
        direct ?? ref.watch(historyControllerProvider);
    final effectiveImageLoader =
        imageLoader ??
        (direct == null
            ? ref.watch(featureHistoryDependenciesProvider).imageLoader
            : null);

    return _PlaybackHistoryContent(
      controller: effectiveController,
      imageLoader: effectiveImageLoader,
    );
  }
}

class _PlaybackHistoryContent extends StatelessWidget {
  const _PlaybackHistoryContent({
    required this.controller,
    this.imageLoader,
  });

  final HistoryController controller;
  final HistoryArtworkLoader? imageLoader;

  Future<void> _confirmClearAll(BuildContext context) async {
    final confirmed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (dialogCtx) => KonataGlassDialog(
        title: '清空播放记录',
        width: 420,
        actions: [
          KonataPillButton.ghost(
            label: '取消',
            compact: true,
            onPressed: () => Navigator.of(dialogCtx).pop(false),
          ),
          KonataPillButton.danger(
            label: '确认清空',
            compact: true,
            onPressed: () => Navigator.of(dialogCtx).pop(true),
          ),
        ],
        child: Text(
          '确认清空全部 ${controller.totalCount} 条播放记录？\n此操作仅清除播放历史并写入跨设备同步墓碑，不会删除本地或远端媒体文件。',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: dialogCtx.palette.textSecondary,
          ),
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

  Future<void> _confirmDeleteSelected(BuildContext context) async {
    final count = controller.selectedRecordIds.length;
    if (count == 0) {
      return;
    }
    final confirmed = await showKonataGlassDialog<bool>(
      context: context,
      builder: (dialogCtx) => KonataGlassDialog(
        title: '删除所选记录',
        width: 400,
        actions: [
          KonataPillButton.ghost(
            label: '取消',
            compact: true,
            onPressed: () => Navigator.of(dialogCtx).pop(false),
          ),
          KonataPillButton.danger(
            label: '删除',
            compact: true,
            onPressed: () => Navigator.of(dialogCtx).pop(true),
          ),
        ],
        child: Text(
          '确认删除选中的 $count 条播放记录？此操作不会删除任何媒体文件。',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: dialogCtx.palette.textSecondary,
          ),
        ),
      ),
    );
    if (confirmed == true) {
      controller.softDeleteSelected();
      if (context.mounted) {
        showKonataToast(context, '已删除 $count 条播放记录');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    final bottomClearance = KonataBottomClearanceScope.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final dayGroups = controller.dayGroups;
        final hasRecords = controller.hasAnyRecords;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: AdaptiveActionHeader(
                title: '播放记录',
                badge: controller.totalCount > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.softFill,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${controller.totalCount}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: tokens.textSecondary,
                          ),
                        ),
                      )
                    : null,
                searchQuery: controller.searchQuery,
                onSearchChanged: controller.setSearchQuery,
                searchHint: '搜索番剧名称、单集或文件名',
                primaryActions: [
                  if (hasRecords)
                    AdaptiveHeaderAction(
                      icon: controller.isSelectionMode
                          ? Icons.close_rounded
                          : Icons.checklist_rounded,
                      label: controller.isSelectionMode ? '退出多选' : '批量管理',
                      highlighted: controller.isSelectionMode,
                      onPressed: () {
                        if (controller.isSelectionMode) {
                          controller.exitSelectionMode();
                        } else {
                          controller.enterSelectionMode();
                        }
                      },
                    ),
                  if (hasRecords)
                    AdaptiveHeaderAction(
                      icon: Icons.delete_sweep_outlined,
                      label: '清空全部',
                      onPressed: () => _confirmClearAll(context),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  KonataSegmentedCapsule<HistoryMediaFilter>(
                    compact: true,
                    selected: controller.filter,
                    onChanged: controller.setFilter,
                    options: [
                      for (final mode in HistoryMediaFilter.values)
                        KonataSegmentOption(
                          value: mode,
                          label: switch (mode) {
                            HistoryMediaFilter.all =>
                              '全部 (${controller.totalCount})',
                            HistoryMediaFilter.video =>
                              '视频 (${controller.videoCount})',
                            HistoryMediaFilter.audio =>
                              '音频 (${controller.audioCount})',
                          },
                        ),
                    ],
                  ),
                  if (controller.isSelectionMode)
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '已选 ${controller.selectedRecordIds.length} 项',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: tokens.textSecondary,
                          ),
                        ),
                        KonataPillButton.ghost(
                          label: '全选',
                          compact: true,
                          onPressed: controller.selectAllVisible,
                        ),
                        KonataPillButton.danger(
                          label: '删除所选',
                          compact: true,
                          onPressed: controller.selectedRecordIds.isEmpty
                              ? null
                              : () => _confirmDeleteSelected(context),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: dayGroups.isEmpty
                  ? _EmptyHistoryView(
                      hasAnyRecords: hasRecords,
                      hasActiveFilter:
                          controller.searchQuery.trim().isNotEmpty ||
                          controller.filter != HistoryMediaFilter.all,
                      onClearFilter: () {
                        controller.setSearchQuery('');
                        controller.setFilter(HistoryMediaFilter.all);
                      },
                    )
                  : KonataDraggableScrollbar(
                      builder: (ctx, scrollController) => ListView.builder(
                        controller: scrollController,
                        padding: EdgeInsets.fromLTRB(
                          20,
                          8,
                          20,
                          28 + bottomClearance,
                        ),
                        itemCount: dayGroups.length,
                        itemBuilder: (ctx, index) {
                          final day = dayGroups[index];
                          return Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 920),
                              child: HistoryDaySectionView(
                                dayGroup: day,
                                isGroupExpanded: controller.isGroupExpanded,
                                onToggleExpanded: controller.toggleGroupExpanded,
                                isSelectionMode: controller.isSelectionMode,
                                selectedIds: controller.selectedRecordIds,
                                onToggleSelect: controller.toggleRecordSelected,
                                onResumeItem: controller.resumePlayback,
                                onOpenWorkDetail: controller.openWorkDetail,
                                onDeleteItem: (item) =>
                                    controller.softDeleteRecord(item.record.id),
                                onDeleteGroup: controller.softDeleteGroup,
                                imageLoader: imageLoader,
                              ),
                            ),
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

class _EmptyHistoryView extends StatelessWidget {
  const _EmptyHistoryView({
    required this.hasAnyRecords,
    required this.hasActiveFilter,
    required this.onClearFilter,
  });

  final bool hasAnyRecords;
  final bool hasActiveFilter;
  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasAnyRecords ? Icons.search_off_rounded : Icons.history_rounded,
              size: 46,
              color: tokens.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              hasAnyRecords ? '未找到匹配的播放记录' : '暂无播放记录',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
                color: tokens.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasAnyRecords
                  ? '请尝试调整搜索词或切换媒体类型筛选'
                  : '观看动画剧集或聆听特典 CD 后，记录会按日期汇总展示在这里',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: tokens.textSecondary,
              ),
            ),
            if (hasActiveFilter) ...[
              const SizedBox(height: 14),
              KonataPillButton.secondary(
                label: '重置筛选条件',
                compact: true,
                onPressed: onClearFilter,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
