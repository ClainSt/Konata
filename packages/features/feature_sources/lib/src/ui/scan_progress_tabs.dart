import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../state/scrape_task_phase.dart';
import '../state/source_scrape_controller.dart';

/// 扫描进度弹窗内复用的数据统计胶囊。
class ScanProgressStatChip extends StatelessWidget {
  /// 创建统计胶囊。
  const ScanProgressStatChip({super.key, required this.label, this.badge});

  /// 胶囊文本。
  final String label;

  /// 可选语义徽章高对比度配色令牌。
  final KonataBadgeColors? badge;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: badge?.bg ?? p.softFill,
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(
          color: badge?.border ?? p.hairline,
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: badge?.fg ?? p.textSecondary,
          fontSize: KonataTheme.fontSizeCaptionSm,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 实时展示已勾选范围及每个已遍历目录视频统计的页签面板。
class ScanVisitedFoldersPane extends StatelessWidget {
  /// 创建已扫描目录列表面板。
  const ScanVisitedFoldersPane({
    super.key,
    required this.phase,
    required this.visitedFolders,
  });

  /// 当前实时扫描阶段快照。
  final ScrapeTaskPhase phase;

  /// 排序后的已访问目录路径集合。
  final List<String> visitedFolders;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (visitedFolders.isEmpty && phase.selectedRoots.isEmpty) {
      return Center(
        child: Text(
          phase.isActive ? '正在连接媒体源并读取目录...' : '暂无目录遍历记录',
          style: TextStyle(
            color: p.textSecondary,
            fontSize: KonataTheme.fontSizeBodySm,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (phase.selectedRoots.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: p.softFill,
              borderRadius: KonataTheme.borderRadiusControl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已勾选扫描作用域 (${phase.selectedRoots.length})',
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final root in phase.selectedRoots)
                      ScanProgressStatChip(
                        label: '$root · ${phase.videosUnderRoot(root)} 视频',
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        Expanded(
          child: visitedFolders.isEmpty
              ? Center(
                  child: Text(
                    '目录枚举等待中...',
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeBodySm,
                    ),
                  ),
                )
              : KonataDraggableScrollbar(
                  builder: (_, ctrl) => ListView.separated(
                    controller: ctrl,
                    padding: const EdgeInsets.only(right: 14),
                    itemCount: visitedFolders.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: p.hairline),
                    itemBuilder: (_, index) {
                      final folder = visitedFolders[index];
                      final done = phase.completedFolders.contains(folder);
                      final count = phase.folderVideoCounts[folder] ?? 0;
                      final display = folder.isEmpty ? '根目录' : folder;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              done
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.sync_rounded,
                              size: 16,
                              color: done ? p.accent : p.textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: EllipsisTextWithTooltip(
                                text: display,
                                maxLines: 1,
                                style: TextStyle(
                                  color: p.textPrimary,
                                  fontSize: KonataTheme.fontSizeBodyXs,
                                  fontFamily: 'Consolas',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$count 视频',
                              style: TextStyle(
                                color: count > 0 ? p.textSecondary : p.textMuted,
                                fontSize: KonataTheme.fontSizeCaptionSm,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// 扫库弹窗「本源待复核」标签页内容（零跨 Feature 导入，跳转由 `AppNavigator` 驱动）。
class ScanPendingReviewTab extends StatelessWidget {
  /// 构造本源待复核列表视图。
  const ScanPendingReviewTab({
    super.key,
    required this.items,
    required this.onOpenWorkDetail,
    required this.onGoToLibrary,
  });

  /// 当前媒体源下等待复核的作品摘要集合。
  final List<SourcePendingReviewWork> items;

  /// 点击单条作品打开详情页的回调。
  final ValueChanged<String> onOpenWorkDetail;

  /// 前往媒体库统一批量复核的回调。
  final VoidCallback onGoToLibrary;

  static const Map<String, String> _reasonLabels = <String, String>{
    'ambiguous_candidates': '多个候选分数接近，需人工核实',
    'close_candidates': '多个候选分数接近，需人工核实',
    'low_confidence': '整体匹配置信度不足',
    'no_match': '候选得分过低，需手动指定',
    'no_candidates': '未找到匹配候选',
    'media_type_mismatch': '剧集 / 剧场版类型冲突',
    'media_type_conflict': '剧集 / 剧场版类型冲突',
    'anthology_conflict': '目录含多作品合集冲突',
    'explicit_tmdb_mismatch': '与目录显式 TMDB 编号冲突',
    'explicit_id_mismatch': '与显式指定的 TMDB ID 不符',
  };

  static String _formatReason(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '待人工复核确认';
    final mapped = _reasonLabels[trimmed];
    if (mapped != null) return mapped;
    // 若底层已生成可读中文说明则直接保留，避免覆盖详细原因。
    if (RegExp(r'[\u4E00-\u9FFF]').hasMatch(trimmed)) {
      return trimmed;
    }
    return '候选匹配度待确认，请核对后锁定';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.verified_outlined,
                size: 32,
                color: p.success,
              ),
              const SizedBox(height: 8),
              Text(
                '当前媒体源下暂无需要人工复核的作品',
                style: TextStyle(
                  fontSize: KonataTheme.fontSizeBodySm,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '所有已扫描目录均已完成自动匹配或处于其他队列。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: KonataTheme.fontSizeCaption,
                  color: p.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveResponsiveRow(
          minLeadingWidth: 160,
          estimatedTrailingWidth: 120,
          leading: Text(
            '共 ${items.length} 部待确认条目，可打开详情核对或前往媒体库批量处置',
            style: TextStyle(
              fontSize: KonataTheme.fontSizeCaption,
              color: p.textSecondary,
            ),
          ),
          trailing: KonataPillButton.secondary(
            label: '去媒体库处理',
            icon: Icons.grid_view_rounded,
            compact: true,
            onPressed: onGoToLibrary,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: KonataDraggableScrollbar(
            builder: (context, scrollCtrl) => ListView.separated(
              controller: scrollCtrl,
              padding: const EdgeInsets.only(right: 12),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = items[index];
                final rawReason = item.work.reviewReason;
                final reasonText = rawReason != null && rawReason.trim().isNotEmpty
                    ? _formatReason(rawReason)
                    : null;

                return KonataSurfaceCard(
                  padding: const EdgeInsets.all(14),
                  enableHover: true,
                  child: AdaptiveResponsiveRow(
                    minLeadingWidth: 180,
                    estimatedTrailingWidth: 94,
                    leading: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: EllipsisTextWithTooltip(
                                text: item.work.title,
                                maxLines: 1,
                                style: KonataTheme.cardTitleStyle(
                                  p,
                                  fontSize: KonataTheme.fontSizeBody,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ScanProgressStatChip(
                              label: '${item.variantCount} 个文件',
                            ),
                          ],
                        ),
                        if (reasonText != null) ...[
                          const SizedBox(height: 6),
                          ScanProgressStatChip(
                            label: reasonText,
                            badge: p.warningBadge,
                          ),
                        ],
                        if (item.sampleRelativePath != null &&
                            item.sampleRelativePath!.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          EllipsisTextWithTooltip(
                            text: item.sampleRelativePath!,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: KonataTheme.fontSizeCaptionSm,
                              color: p.textMuted,
                              fontFamily: 'Consolas',
                            ),
                          ),
                        ],
                      ],
                    ),
                    trailing: KonataPillButton.secondary(
                      label: '查看详情',
                      compact: true,
                      onPressed: () => onOpenWorkDetail(item.work.id),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
