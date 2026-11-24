import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../state/scrape_task_phase.dart';
import '../state/source_scrape_controller.dart';

/// 扫库弹窗「实时进度」标签页内容。
class ScanProgressLiveTab extends StatelessWidget {
  /// 构造扫库实时进度视图。
  const ScanProgressLiveTab({
    super.key,
    required this.phase,
    required this.onJumpToPendingReview,
  });

  /// 当前扫库阶段快照。
  final ScrapeTaskPhase phase;

  /// 点击跳转本弹窗「本源待复核」标签页的回调。
  final VoidCallback onJumpToPendingReview;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ratio = phase.progressRatio;
    final accentColor = switch (phase.stage) {
      ScrapeTaskStage.completed => p.success,
      ScrapeTaskStage.cancelled => p.warning,
      ScrapeTaskStage.failed => p.danger,
      _ => p.accent,
    };

    return KonataDraggableScrollbar(
      builder: (context, scrollCtrl) => ListView(
        controller: scrollCtrl,
        padding: const EdgeInsets.only(right: 6),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accentColor.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (phase.isActive)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              accentColor,
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        phase.statusLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    if (ratio != null)
                      Text(
                        '${(ratio * 100).round()}%',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: accentColor,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  phase.detailLabel,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: p.textSecondary,
                    height: 1.4,
                  ),
                ),
                if (phase.isActive || ratio != null) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 6,
                      backgroundColor: p.hairline,
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricTile(label: '已扫描目录', value: '${phase.scannedDirectories}'),
              _MetricTile(label: '发现文件', value: '${phase.foundFiles}'),
              _MetricTile(label: '识别作品', value: '${phase.totalWorks}'),
              _MetricTile(
                label: '自动匹配',
                value: '${phase.matchedWorks}',
                valueColor: p.success,
              ),
              _MetricTile(
                label: '待复核',
                value: '${phase.reviewWorks}',
                valueColor: phase.reviewWorks > 0 ? p.warning : null,
                onTap: phase.reviewWorks > 0 ? onJumpToPendingReview : null,
              ),
              _MetricTile(
                label: '未匹配',
                value: '${phase.unmatchedWorks}',
                valueColor: phase.unmatchedWorks > 0 ? p.danger : null,
              ),
            ],
          ),
          if (phase.easyWorks > 0 ||
              phase.mediumWorks > 0 ||
              phase.hardWorks > 0) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.elevatedSurface.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '刮削难度分层统计',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '简单直出：${phase.easyWorks} · 中等消歧：${phase.mediumWorks} · 困难纠偏：${phase.hardWorks}（联合救回 ${phase.hardRescuedWorks}）',
                    style: TextStyle(
                      fontSize: 12,
                      color: p.textSecondary,
                      height: 1.45,
                    ),
                  ),
                  if (phase.lastMatchedTitle != null &&
                      phase.lastMatchedTitle!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '最近匹配：${phase.lastMatchedTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.accent),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (phase.selectedRoots.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.elevatedSurface.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '本次扫描限定子目录 (${phase.selectedRoots.length})',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final root in phase.selectedRoots)
                        KonataSpecBadge(label: root),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
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
                '本媒体源暂无待复核作品',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '当前媒体源下所有已扫描目录均已完成自动匹配或处于其他队列。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: p.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '共 ${items.length} 部待确认条目，可前往详情或媒体库集中人工纠偏',
                style: TextStyle(fontSize: 12, color: p.textSecondary),
              ),
            ),
            const SizedBox(width: 8),
            KonataPillButton.secondary(
              label: '去媒体库处理',
              icon: Icons.grid_view_rounded,
              compact: true,
              onPressed: onGoToLibrary,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: KonataDraggableScrollbar(
            builder: (context, scrollCtrl) => ListView.separated(
              controller: scrollCtrl,
              padding: const EdgeInsets.only(right: 6),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = items[index];
                final reason = item.work.reviewReason?.trim();
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.elevatedSurface.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.work.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: p.textPrimary,
                              ),
                            ),
                            if (reason != null && reason.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                reason,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: p.warning,
                                ),
                              ),
                            ],
                            const SizedBox(height: 4),
                            Text(
                              item.sampleRelativePath ??
                                  '${item.variantCount} 个物理文件',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: p.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      KonataPillButton.secondary(
                        label: '查看详情',
                        compact: true,
                        onPressed: () => onOpenWorkDetail(item.work.id),
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

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    this.valueColor,
    this.onTap,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final box = Container(
      constraints: const BoxConstraints(minWidth: 112),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: p.elevatedSurface.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: p.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: valueColor ?? p.textPrimary,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return box;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: box,
    );
  }
}
