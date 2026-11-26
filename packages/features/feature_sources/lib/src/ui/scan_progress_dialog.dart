import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/scrape_task_phase.dart';
import '../state/source_scrape_controller.dart';
import 'scan_progress_tabs.dart';

enum _ProgressTab { folders, review }

/// 实时扫描刮削进度监控与待复核快速处置毛玻璃弹窗。
Future<void> showScanProgressDialog(
  BuildContext context, {
  String? focusSourceId,
  int initialTabIndex = 0,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => _ScanProgressDialog(
      focusSourceId: focusSourceId,
      initialTabIndex: initialTabIndex,
    ),
  );
}

class _ScanProgressDialog extends ConsumerStatefulWidget {
  const _ScanProgressDialog({this.focusSourceId, this.initialTabIndex = 0});

  final String? focusSourceId;
  final int initialTabIndex;

  @override
  ConsumerState<_ScanProgressDialog> createState() =>
      _ScanProgressDialogState();
}

class _ScanProgressDialogState extends ConsumerState<_ScanProgressDialog> {
  late _ProgressTab _activeTab;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTabIndex == 1
        ? _ProgressTab.review
        : _ProgressTab.folders;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final scrapeController = ref.watch(sourceScrapeControllerProvider);
    final navigator = ref.watch(featureSourcesDependenciesProvider).navigator;
    final sources = ref.watch(mediaSourcesStreamProvider).value;

    return ListenableBuilder(
      listenable: scrapeController,
      builder: (context, _) {
        final phase = scrapeController.phase;
        final activeSourceId = widget.focusSourceId ?? phase.sourceId ?? '';
        var displayLabel = phase.sourceLabel;
        if (displayLabel.isEmpty &&
            activeSourceId.isNotEmpty &&
            sources != null) {
          for (final item in sources) {
            if (item.id == activeSourceId) {
              displayLabel = item.label;
              break;
            }
          }
        }
        final visited = phase.visitedFolders;
        final titleSuffix = displayLabel.isNotEmpty ? ' · $displayLabel' : '';

        if (activeSourceId.isEmpty) {
          return _buildDialogFrame(
            context,
            p: p,
            scrapeController: scrapeController,
            phase: phase,
            visited: visited,
            reviewItems: const <SourcePendingReviewWork>[],
            navigator: navigator,
            titleSuffix: titleSuffix,
          );
        }

        return StreamBuilder<List<SourcePendingReviewWork>>(
          stream: scrapeController.watchNeedsReviewForSource(activeSourceId),
          builder: (context, snapshot) {
            final reviewItems =
                snapshot.data ?? const <SourcePendingReviewWork>[];
            return _buildDialogFrame(
              context,
              p: p,
              scrapeController: scrapeController,
              phase: phase,
              visited: visited,
              reviewItems: reviewItems,
              navigator: navigator,
              titleSuffix: titleSuffix,
            );
          },
        );
      },
    );
  }

  Widget _buildDialogFrame(
    BuildContext context, {
    required KonataPalette p,
    required SourceScrapeController scrapeController,
    required ScrapeTaskPhase phase,
    required List<String> visited,
    required List<SourcePendingReviewWork> reviewItems,
    required AppNavigator navigator,
    required String titleSuffix,
  }) {
    return KonataGlassDialog(
      width: 780,
      maxHeight: 640,
      title: '扫描与刮削进度$titleSuffix',
      onClose: () => Navigator.of(context).pop(),
      actions: [
        if (phase.isActive)
          KonataPillButton.ghost(
            label: phase.cancelRequested ? '正在取消...' : '取消扫描',
            icon: Icons.stop_circle_outlined,
            compact: true,
            onPressed: phase.cancelRequested
                ? null
                : scrapeController.cancelActiveScan,
          ),
        KonataPillButton.secondary(
          label: '关闭',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabHeader = Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.15,
                child: KonataSegmentedCapsule<_ProgressTab>(
                  compact: true,
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
              ),
              Text(
                phase.selectedRoots.isNotEmpty
                    ? '局部范围 · ${phase.selectedRoots.length} 个目录'
                    : '全库作用域',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: KonataTheme.fontSizeCaption,
                ),
              ),
            ],
          );

          final paneCard = KonataSurfaceCard(
            padding: const EdgeInsets.all(12),
            child: KonataSmoothSectionSwitcher(
              switchKey: _activeTab,
              alignment: Alignment.topLeft,
              child: _activeTab == _ProgressTab.folders
                  ? ScanVisitedFoldersPane(
                      phase: phase,
                      visitedFolders: visited,
                    )
                  : ScanPendingReviewTab(
                      items: reviewItems,
                      onOpenWorkDetail: (workId) {
                        Navigator.of(context).pop();
                        navigator.openWorkDetail(WorkId.trusted(workId));
                      },
                      onGoToLibrary: () {
                        Navigator.of(context).pop();
                        navigator.switchNavSection('library');
                      },
                    ),
            ),
          );

          final scrollThreshold = constraints.maxWidth < 400 ? 440.0 : 300.0;
          if (constraints.maxHeight.isFinite &&
              constraints.maxHeight < scrollThreshold) {
            return KonataDraggableScrollbar(
              builder: (_, scrollCtrl) => SingleChildScrollView(
                controller: scrollCtrl,
                padding: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildSummaryCard(p, phase),
                    const SizedBox(height: 12),
                    tabHeader,
                    const SizedBox(height: 10),
                    SizedBox(height: 200, child: paneCard),
                  ],
                ),
              ),
            );
          }

          final targetH = constraints.maxHeight.isFinite
              ? math.min(468.0, constraints.maxHeight)
              : 468.0;
          return SizedBox(
            height: targetH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSummaryCard(p, phase),
                const SizedBox(height: 12),
                tabHeader,
                const SizedBox(height: 10),
                Expanded(child: paneCard),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSummaryCard(KonataPalette p, ScrapeTaskPhase phase) {
    final phaseTitle = phase.statusLabel;

    double? barValue;
    if (phase.stage == ScrapeTaskStage.completed) {
      barValue = 1.0;
    } else if (phase.stage == ScrapeTaskStage.running && phase.totalWorks > 0) {
      barValue = phase.fraction;
    } else if (!phase.isActive) {
      barValue = 0.0;
    }

    final hasDifficultyStats =
        phase.easyWorks > 0 || phase.mediumWorks > 0 || phase.hardWorks > 0;

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveResponsiveRow(
            minLeadingWidth: 160,
            estimatedTrailingWidth: 180,
            expandTrailingWhenStacked: true,
            leading: Text(
              phaseTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.textPrimary,
                fontSize: KonataTheme.fontSizeBodyMd,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing: phase.currentItemName.isNotEmpty
                ? Text(
                    phase.currentItemName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeBodyXs,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: KonataTheme.borderRadiusPill,
            child: LinearProgressIndicator(
              value: barValue,
              minHeight: 5,
              backgroundColor: p.progressTrack,
              valueColor: AlwaysStoppedAnimation<Color>(
                phase.stage == ScrapeTaskStage.failed
                    ? p.danger
                    : p.progressFill,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ScanProgressStatChip(label: '目录 ${phase.scannedDirectories}'),
              ScanProgressStatChip(label: '视频 ${phase.totalVideos}'),
              ScanProgressStatChip(label: '素材 ${phase.foundFiles}'),
              ScanProgressStatChip(
                label: '作品 ${phase.processedWorks}/${phase.totalWorks}',
              ),
              ScanProgressStatChip(
                label: '匹配 ${phase.matchedWorks}',
                badge: p.accentBadge,
              ),
              if (phase.reviewWorks > 0)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _activeTab = _ProgressTab.review),
                    child: ScanProgressStatChip(
                      label: '待复核 ${phase.reviewWorks} ↗',
                      badge: p.warningBadge,
                    ),
                  ),
                ),
              if (phase.unmatchedWorks > 0)
                ScanProgressStatChip(label: '未识别 ${phase.unmatchedWorks}'),
            ],
          ),
          if (hasDifficultyStats ||
              (phase.lastMatchedTitle != null &&
                  phase.lastMatchedTitle!.isNotEmpty)) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                if (hasDifficultyStats)
                  Text(
                    '分层识别：简单 ${phase.easyWorks} · 中等 ${phase.mediumWorks} · 困难 ${phase.hardWorks}'
                    '${phase.hardRescuedWorks > 0 ? '（联合救回 ${phase.hardRescuedWorks}）' : ''}',
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeCaptionSm,
                    ),
                  ),
                if (phase.lastMatchedTitle != null &&
                    phase.lastMatchedTitle!.isNotEmpty)
                  Text(
                    '最近匹配：${phase.lastMatchedTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.accent,
                      fontSize: KonataTheme.fontSizeCaptionSm,
                    ),
                  ),
              ],
            ),
          ],
          if (phase.errorMessage != null &&
              phase.errorMessage!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              NetworkErrorSanitizer.toUserMessage(phase.errorMessage!),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.danger,
                fontSize: KonataTheme.fontSizeCaption,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
