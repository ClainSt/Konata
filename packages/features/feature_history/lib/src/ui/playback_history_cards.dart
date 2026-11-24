import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/history_timeline_models.dart';
import 'playback_history_sub_cards.dart';

/// 单日时间轴分区视图（展示 `今天` / `昨天` / 具体日期分组头及作品卡片列表）。
class HistoryDaySectionView extends StatelessWidget {
  /// 创建自然日时间轴分区组件。
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
    this.imageLoader,
  });

  /// 自然日分组数据。
  final HistoryDayGroup dayGroup;

  /// 判断某作品分组是否展开。
  final bool Function(String groupKey) isGroupExpanded;

  /// 切换分组展开状态回调。
  final ValueChanged<String> onToggleExpanded;

  /// 是否处于多选状态。
  final bool isSelectionMode;

  /// 多选状态下已选记录 ID 集合。
  final Set<String> selectedIds;

  /// 切换单条记录勾选状态。
  final ValueChanged<String> onToggleSelect;

  /// 续播指定条目。
  final ValueChanged<HistoryEntryView> onResumeItem;

  /// 打开关联作品详情。
  final ValueChanged<WorkId> onOpenWorkDetail;

  /// 删除单条记录。
  final ValueChanged<HistoryEntryView> onDeleteItem;

  /// 删除整组作品当天记录。
  final ValueChanged<HistoryWorkGroupEntry> onDeleteGroup;

  /// 可选封面图加载器。
  final HistoryArtworkLoader? imageLoader;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    final totalEntries = dayGroup.works.fold<int>(
      0,
      (sum, group) => sum + group.entryCount,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: tokens.accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  dayGroup.dayTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: tokens.textPrimary,
                  ),
                ),
                if (dayGroup.dateSubLabel != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    dayGroup.dateSubLabel!,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.softFill,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$totalEntries 条',
                    style: TextStyle(
                      fontSize: 11,
                      color: tokens.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final workGroup in dayGroup.works) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: HistoryWorkTimelineCard(
                group: workGroup,
                expanded: isGroupExpanded(workGroup.groupKey),
                onToggleExpanded: () => onToggleExpanded(workGroup.groupKey),
                isSelectionMode: isSelectionMode,
                selectedIds: selectedIds,
                onToggleSelect: onToggleSelect,
                onResumeItem: onResumeItem,
                onOpenWorkDetail: () => onOpenWorkDetail(workGroup.workId),
                onDeleteItem: onDeleteItem,
                onDeleteGroup: () => onDeleteGroup(workGroup),
                imageLoader: imageLoader,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单日内单部作品时间轴卡片（单条精简展示，多条可内联展开单集列表）。
class HistoryWorkTimelineCard extends StatelessWidget {
  /// 创建作品时间轴卡片。
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
    this.imageLoader,
  });

  /// 作品分组模型。
  final HistoryWorkGroupEntry group;

  /// 是否处于多集展开态。
  final bool expanded;

  /// 展开/收起回调。
  final VoidCallback onToggleExpanded;

  /// 是否处于多选状态。
  final bool isSelectionMode;

  /// 多选勾选集合。
  final Set<String> selectedIds;

  /// 切换单条勾选回调。
  final ValueChanged<String> onToggleSelect;

  /// 续播指定条目。
  final ValueChanged<HistoryEntryView> onResumeItem;

  /// 打开作品详情回调。
  final VoidCallback onOpenWorkDetail;

  /// 删除单条记录回调。
  final ValueChanged<HistoryEntryView> onDeleteItem;

  /// 删除整组当天记录回调。
  final VoidCallback onDeleteGroup;

  /// 可选封面加载器。
  final HistoryArtworkLoader? imageLoader;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    final latest = group.latestItem;
    final isGrouped = group.entryCount > 1;
    final singleSelected =
        !isGrouped && selectedIds.contains(latest.record.id);

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(14),
      borderColor: singleSelected ? tokens.accent : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (isSelectionMode) {
                if (isGrouped) {
                  onToggleExpanded();
                } else {
                  onToggleSelect(latest.record.id);
                }
                return;
              }
              if (isGrouped) {
                onToggleExpanded();
              } else {
                onResumeItem(latest);
              }
            },
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isSelectionMode && !isGrouped) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 6, top: 18),
                    child: Checkbox(
                      value: singleSelected,
                      onChanged: (_) => onToggleSelect(latest.record.id),
                    ),
                  ),
                ],
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onOpenWorkDetail,
                  child: HistoryThumbnail(
                    workId: group.workId,
                    isAudio: group.isAudioGroup,
                    imageLoader: imageLoader,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              group.workTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: tokens.textPrimary,
                              ),
                            ),
                          ),
                          if (isGrouped) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${group.entryCount} 条记录',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: tokens.accent,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isGrouped
                            ? group.collapsedSummary
                            : latest.episodeSubtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      HistoryProgressMetaRow(
                        item: latest,
                        showProgressBar: !isGrouped || !expanded,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isSelectionMode)
                      KonataPillButton.secondary(
                        label: '续播',
                        icon: Icons.play_arrow_rounded,
                        compact: true,
                        onPressed: () => onResumeItem(latest),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isGrouped)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onToggleExpanded,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(
                                expanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                size: 20,
                                color: tokens.textSecondary,
                              ),
                            ),
                          ),
                        if (!isSelectionMode)
                          Builder(
                            builder: (menuCtx) => GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _openCardMenu(
                                menuCtx,
                                isGrouped: isGrouped,
                                latest: latest,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(
                                  Icons.more_vert_rounded,
                                  size: 18,
                                  color: tokens.textSecondary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (isGrouped && expanded) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: tokens.hairline),
            for (final item in group.items)
              HistoryExpandedEpisodeRow(
                item: item,
                isSelectionMode: isSelectionMode,
                isSelected: selectedIds.contains(item.record.id),
                onResume: () => onResumeItem(item),
                onDelete: () => onDeleteItem(item),
                onToggleSelect: () => onToggleSelect(item.record.id),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _openCardMenu(
    BuildContext anchorContext, {
    required bool isGrouped,
    required HistoryEntryView latest,
  }) async {
    final choice = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: [
        const KonataGlassMenuItem(
          value: 'resume',
          label: '继续播放',
          icon: Icons.play_arrow_rounded,
        ),
        const KonataGlassMenuItem(
          value: 'detail',
          label: '查看作品详情',
          icon: Icons.info_outline_rounded,
        ),
        KonataGlassMenuItem(
          value: 'delete',
          label: isGrouped ? '删除当天全部记录' : '删除此条记录',
          icon: Icons.delete_outline_rounded,
          isDanger: true,
        ),
      ],
    );
    switch (choice) {
      case 'resume':
        onResumeItem(latest);
      case 'detail':
        onOpenWorkDetail();
      case 'delete':
        if (isGrouped) {
          onDeleteGroup();
        } else {
          onDeleteItem(latest);
        }
    }
  }
}
