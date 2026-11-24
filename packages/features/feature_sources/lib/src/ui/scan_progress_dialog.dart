import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/source_scrape_controller.dart';
import 'scan_progress_tabs.dart';

/// 弹出扫库刮削进度与本源待复核联合弹窗。
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
  const _ScanProgressDialog({
    this.focusSourceId,
    this.initialTabIndex = 0,
  });

  final String? focusSourceId;
  final int initialTabIndex;

  @override
  ConsumerState<_ScanProgressDialog> createState() =>
      _ScanProgressDialogState();
}

class _ScanProgressDialogState extends ConsumerState<_ScanProgressDialog> {
  late int _tabIndex;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialTabIndex.clamp(0, 1);
  }

  @override
  Widget build(BuildContext context) {
    final scrapeController = ref.watch(sourceScrapeControllerProvider);
    final navigator = ref.watch(featureSourcesDependenciesProvider).navigator;
    final screen = MediaQuery.sizeOf(context);
    final bodyHeight = (screen.height * 0.62).clamp(260.0, 480.0);

    return ListenableBuilder(
      listenable: scrapeController,
      builder: (context, _) {
        final phase = scrapeController.phase;
        final activeSourceId =
            widget.focusSourceId ?? phase.sourceId ?? '';

        return KonataGlassDialog(
          title: phase.sourceLabel.isEmpty
              ? '扫库与刮削详情'
              : '${phase.sourceLabel} · 扫库进度',
          width: (screen.width - 32).clamp(300.0, 620.0),
          actions: [
            if (phase.isActive)
              KonataPillButton.ghost(
                label: phase.cancelRequested ? '正在停止…' : '取消扫描',
                onPressed: phase.cancelRequested
                    ? null
                    : scrapeController.cancelActiveScan,
              ),
            KonataPillButton.primary(
              label: '关闭',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
          child: SizedBox(
            height: bodyHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KonataSegmentedCapsule<int>(
                  selected: _tabIndex,
                  expand: true,
                  compact: true,
                  options: const [
                    KonataSegmentOption(
                      value: 0,
                      label: '实时进度',
                      icon: Icons.radar_rounded,
                    ),
                    KonataSegmentOption(
                      value: 1,
                      label: '本源待复核',
                      icon: Icons.rule_folder_outlined,
                    ),
                  ],
                  onChanged: (next) => setState(() => _tabIndex = next),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: KonataKeepAliveTabSwitcher(
                    activeIndex: _tabIndex,
                    children: [
                      ScanProgressLiveTab(
                        phase: phase,
                        onJumpToPendingReview: () =>
                            setState(() => _tabIndex = 1),
                      ),
                      activeSourceId.isEmpty
                          ? const ScanPendingReviewTab(
                              items: <SourcePendingReviewWork>[],
                              onOpenWorkDetail: _noopWorkTap,
                              onGoToLibrary: _noopVoid,
                            )
                          : StreamBuilder<List<SourcePendingReviewWork>>(
                              stream: scrapeController
                                  .watchNeedsReviewForSource(activeSourceId),
                              builder: (context, snapshot) {
                                final items =
                                    snapshot.data ??
                                    const <SourcePendingReviewWork>[];
                                return ScanPendingReviewTab(
                                  items: items,
                                  onOpenWorkDetail: (workId) {
                                    Navigator.of(context).pop();
                                    navigator.openWorkDetail(
                                      WorkId.trusted(workId),
                                    );
                                  },
                                  onGoToLibrary: () {
                                    Navigator.of(context).pop();
                                    navigator.switchNavSection('library');
                                  },
                                );
                              },
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

void _noopWorkTap(String _) {}
void _noopVoid() {}
