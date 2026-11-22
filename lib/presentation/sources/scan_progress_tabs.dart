import 'package:material_ui/material_ui.dart';

import '../../application/providers/library_providers.dart';
import '../../application/scraping/scrape_progress.dart';
import '../library/review_work_item_card.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../theme/konata_theme.dart';

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
    required this.progress,
    required this.visitedFolders,
  });

  /// 当前实时扫描进度快照。
  final ScrapeProgress progress;

  /// 排序后的已访问目录路径集合。
  final List<String> visitedFolders;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (visitedFolders.isEmpty && progress.selectedRoots.isEmpty) {
      return Center(
        child: Text(
          progress.isRunning ? '正在连接媒体源并读取目录...' : '暂无目录遍历记录',
          style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (progress.selectedRoots.isNotEmpty) ...[
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
                  '已勾选扫描作用域 (${progress.selectedRoots.length})',
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
                    for (final root in progress.selectedRoots)
                      ScanProgressStatChip(
                        label: '$root · ${progress.videosUnderRoot(root)} 视频',
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
                    style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
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
                      final done = progress.completedFolders.contains(folder);
                      final count = progress.folderVideoCounts[folder] ?? 0;
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
                              child: Text(
                                display,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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

/// 进度弹窗内嵌的待复核条目快速处置面板（复用完整待复核卡片能力）。
class ScanPendingReviewPane extends StatelessWidget {
  /// 创建待复核列表面板。
  const ScanPendingReviewPane({super.key, required this.items});

  /// 当前媒体源下的待复核作品集合。
  final List<WorkLibraryItem> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (items.isEmpty) {
      return Center(
        child: Text(
          '当前媒体源下暂无需要人工复核的作品',
          style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
        ),
      );
    }

    return KonataDraggableScrollbar(
      builder: (_, ctrl) => ListView.separated(
        controller: ctrl,
        padding: const EdgeInsets.only(right: 14),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, index) => ReviewWorkItemCard(item: items[index]),
      ),
    );
  }
}
