import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/scraping/scrape_progress.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_surface_card.dart';
import 'scan_progress_tabs.dart';

enum _ProgressTab { folders, review }

/// 实时扫描刮削进度监控与待复核快速处置毛玻璃弹窗。
class ScanProgressDialog extends ConsumerStatefulWidget {
  /// 创建刮削进度详情弹窗。
  const ScanProgressDialog({super.key});

  @override
  ConsumerState<ScanProgressDialog> createState() => _ScanProgressDialogState();
}

class _ScanProgressDialogState extends ConsumerState<ScanProgressDialog> {
  _ProgressTab _activeTab = _ProgressTab.folders;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final progress = ref.watch(scrapeControllerProvider);
    final reviewAsync = ref.watch(needsReviewItemsProvider);
    final visited = progress.visitedFolders;

    final reviewItems = reviewAsync.maybeWhen(
      data: (items) {
        final sid = progress.sourceId;
        if (sid == null) return items;
        return items
            .where((item) => item.variants.any((v) => v.sourceId == sid))
            .toList(growable: false);
      },
      orElse: () => const <WorkLibraryItem>[],
    );

    final titleSuffix = progress.sourceLabel.isNotEmpty
        ? ' · ${progress.sourceLabel}'
        : '';

    return KonataGlassDialog(
      width: 780,
      maxHeight: 640,
      title: '扫描与刮削进度$titleSuffix',
      onClose: () => Navigator.of(context).pop(),
      actions: [
        if (progress.isRunning)
          KonataPillButton.ghost(
            label: progress.cancelRequested ? '正在取消...' : '取消扫描',
            icon: Icons.stop_circle_outlined,
            compact: true,
            onPressed: progress.cancelRequested
                ? null
                : () => ref.read(scrapeControllerProvider.notifier).requestCancel(),
          ),
        KonataPillButton.secondary(
          label: '关闭',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: SizedBox(
        height: 468,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSummaryCard(p, progress),
            const SizedBox(height: 12),
            Row(
              children: [
                KonataSegmentedCapsule<_ProgressTab>(
                  selected: _activeTab,
                  onChanged: (tab) => setState(() => _activeTab = tab),
                  options: [
                    KonataSegmentOption(
                      value: _ProgressTab.folders,
                      label: '已扫目录 (${visited.length})',
                    ),
                    KonataSegmentOption(
                      value: _ProgressTab.review,
                      label: '待复核条目 (${reviewItems.length})',
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  progress.selectedRoots.isNotEmpty
                      ? '局部范围 · ${progress.selectedRoots.length} 个目录'
                      : '全库作用域',
                  style: TextStyle(color: p.textSecondary, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: KonataSurfaceCard(
                padding: const EdgeInsets.all(12),
                child: KonataSmoothSectionSwitcher(
                  switchKey: _activeTab,
                  alignment: Alignment.topLeft,
                  child: _activeTab == _ProgressTab.folders
                      ? ScanVisitedFoldersPane(
                          progress: progress,
                          visitedFolders: visited,
                        )
                      : ScanPendingReviewPane(items: reviewItems),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(KonataPalette p, ScrapeProgress progress) {
    final phaseTitle = switch (progress.phase) {
      ScrapePhase.idle => '当前无活动扫描任务',
      ScrapePhase.scanning => '正在遍历媒体源目录...',
      ScrapePhase.grouping => '后台 Isolate 归组与 BDRip 词法解析中...',
      ScrapePhase.scraping =>
        '正在匹配 TMDB 元数据 (${progress.processedWorks}/${progress.totalWorks})',
      ScrapePhase.completed => '本次扫描与刮削已完成',
      ScrapePhase.cancelled => '已根据请求中止扫描任务',
      ScrapePhase.failed => '扫描或刮削过程中发生异常',
    };

    double? barValue;
    if (progress.phase == ScrapePhase.completed) {
      barValue = 1.0;
    } else if (progress.phase == ScrapePhase.scraping &&
        progress.totalWorks > 0) {
      barValue = progress.fraction;
    } else if (!progress.isRunning) {
      barValue = 0.0;
    }

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  phaseTitle,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (progress.currentItemName.isNotEmpty)
                Flexible(
                  child: Text(
                    progress.currentItemName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.textSecondary, fontSize: 12.5),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: barValue,
              minHeight: 5,
              backgroundColor: p.progressTrack,
              valueColor: AlwaysStoppedAnimation<Color>(
                progress.phase == ScrapePhase.failed ? p.danger : p.progressFill,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ScanProgressStatChip(label: '目录 ${progress.scannedDirectories}'),
              ScanProgressStatChip(label: '视频 ${progress.totalVideos}'),
              ScanProgressStatChip(label: '素材 ${progress.foundFiles}'),
              ScanProgressStatChip(
                label: '作品 ${progress.processedWorks}/${progress.totalWorks}',
              ),
              ScanProgressStatChip(
                label: '匹配 ${progress.matchedWorks}',
                badge: p.accentBadge,
              ),
              if (progress.reviewWorks > 0)
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () =>
                      setState(() => _activeTab = _ProgressTab.review),
                  child: ScanProgressStatChip(
                    label: '待复核 ${progress.reviewWorks} ↗',
                    badge: p.warningBadge,
                  ),
                ),
              if (progress.unmatchedWorks > 0)
                ScanProgressStatChip(
                  label: '未识别 ${progress.unmatchedWorks}',
                ),
            ],
          ),
          if (progress.errorMessage != null &&
              progress.errorMessage!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              progress.errorMessage!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.danger, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
