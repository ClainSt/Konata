import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'delete_work_dialog.dart';
import 'manual_match_dialog.dart';
import 'review_work_item_card.dart';
import 'source_files_review_dialog.dart';

/// 弹出媒体库「待复核纠错中心」弹窗，集中处理重扫异常、候选选择与手动绑定。
Future<void> showReviewDialog(BuildContext context) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => const _ReviewDialog(),
  );
}

class _ReviewDialog extends ConsumerStatefulWidget {
  const _ReviewDialog();

  @override
  ConsumerState<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends ConsumerState<_ReviewDialog> {
  bool _batchRetrying = false;
  int _batchDone = 0;
  int _batchTotal = 0;

  Future<void> _retryNetworkFailedWorks(List<Work> networkWorks) async {
    if (_batchRetrying || networkWorks.isEmpty) return;
    setState(() {
      _batchRetrying = true;
      _batchDone = 0;
      _batchTotal = networkWorks.length;
    });
    final mgmt = ref.read(workManagementControllerProvider);
    var matchedCount = 0;
    for (final w in networkWorks) {
      if (!mounted) break;
      try {
        final res = await mgmt.rematchReviewWork(w.id);
        if (res.outcome == RematchWorkOutcome.matched ||
            res.outcome == RematchWorkOutcome.autoMerged) {
          matchedCount++;
        }
      } catch (_) {}
      if (mounted) {
        setState(() => _batchDone++);
      }
    }
    if (!mounted) return;
    setState(() => _batchRetrying = false);
    showKonataToast(
      context,
      '批量重试完成：${networkWorks.length} 部中有 $matchedCount 部成功自动匹配',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final libraryController = ref.watch(libraryControllerProvider);
    final mgmt = ref.watch(workManagementControllerProvider);
    final navigator = ref.watch(featureLibraryDependenciesProvider).navigator;
    final screen = MediaQuery.sizeOf(context);
    final bodyHeight = (screen.height * 0.68).clamp(260.0, 560.0);

    return ListenableBuilder(
      listenable: libraryController,
      builder: (context, _) {
        final reviewWorks = libraryController.reviewWorks;
        final networkFailed = reviewWorks
            .where((w) => ReviewReasonLabels.isNetworkError(w.reviewReason))
            .toList(growable: false);

        return KonataGlassDialog(
          title: '待复核作品 (${reviewWorks.length})',
          width: (screen.width - 28).clamp(300.0, 660.0),
          actions: [
            KonataPillButton.ghost(
              label: '前往媒体源重扫',
              icon: Icons.radar_rounded,
              onPressed: () {
                Navigator.of(context).pop();
                navigator.switchNavSection('sources');
              },
            ),
            KonataPillButton.primary(
              label: '完成',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
          child: SizedBox(
            height: bodyHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (networkFailed.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: p.warning.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: p.warning.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.wifi_off_rounded, size: 18, color: p.warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _batchRetrying
                                ? '正在批量重试网络异常条目 ($_batchDone / $_batchTotal)…'
                                : '检测到 ${networkFailed.length} 部作品因网络异常未能自动刮削，可一键重新识别。',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: p.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        KonataPillButton.secondary(
                          label: _batchRetrying ? '重试中…' : '批量重试',
                          compact: true,
                          onPressed: _batchRetrying
                              ? null
                              : () => _retryNetworkFailedWorks(networkFailed),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Expanded(
                  child: reviewWorks.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.verified_outlined,
                                size: 34,
                                color: p.success,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '所有作品均已核对完毕',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: p.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        )
                      : KonataDraggableScrollbar(
                          builder: (context, scrollCtrl) => ListView.separated(
                            controller: scrollCtrl,
                            padding: const EdgeInsets.only(right: 6),
                            itemCount: reviewWorks.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final work = reviewWorks[index];
                              return ReviewWorkItemCard(
                                work: work,
                                onRematch: () async {
                                  final res = await mgmt.rematchReviewWork(
                                    work.id,
                                  );
                                  if (!context.mounted) return;
                                  final msg = switch (res.outcome) {
                                    RematchWorkOutcome.matched =>
                                      '「${work.title}」已成功重新匹配',
                                    RematchWorkOutcome.autoMerged =>
                                      '已自动并入同源已存在作品',
                                    RematchWorkOutcome.needsReview =>
                                      '仍有多个近似候选，建议手动匹配',
                                    RematchWorkOutcome.unmatched =>
                                      '未自动命中条目，请尝试手动搜索',
                                    RematchWorkOutcome.networkError =>
                                      res.errorMessage ?? '网络请求依然失败，请检查代理配置',
                                  };
                                  showKonataToast(
                                    context,
                                    msg,
                                    isError:
                                        res.outcome ==
                                        RematchWorkOutcome.networkError,
                                  );
                                },
                                onManualMatch: () => showManualMatchDialog(
                                  context,
                                  work: work,
                                ),
                                onDismissReview: () async {
                                  await mgmt.dismissWorkReview(work.id);
                                  if (!context.mounted) return;
                                  showKonataToast(
                                    context,
                                    '已放行「${work.title}」并锁定条目',
                                  );
                                },
                                onInspectSourceFiles: () =>
                                    showSourceFilesReviewDialog(
                                      context,
                                      work: work,
                                    ),
                                onDeleteWork: () async {
                                  final confirm = await showDeleteWorkDialog(
                                    context,
                                    work: work,
                                  );
                                  if (!context.mounted || confirm == null) {
                                    return;
                                  }
                                  await mgmt.deleteWork(
                                    work.id,
                                    ignoreFolderOnRescan:
                                        confirm.ignoreFolderOnRescan,
                                  );
                                  if (!context.mounted) return;
                                  showKonataToast(
                                    context,
                                    '已从媒体库移出「${work.title}」',
                                  );
                                },
                                onApplyCandidate: (candidate) async {
                                  await mgmt.bindWorkToTmdb(
                                    workId: work.id,
                                    tmdbId: candidate.tmdbId,
                                    mediaType: candidate.mediaType,
                                  );
                                  if (!context.mounted) return;
                                  showKonataToast(
                                    context,
                                    '已为「${work.title}」绑定 ${candidate.title}',
                                  );
                                },
                              );
                            },
                          ),
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
