import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart'
    show DiagnosticSubsystem, WorkId;
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'review_work_item_card.dart';

/// 弹出待复核中心对话框，集中核对模糊匹配、跨季歧义及网络波动条目。
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
  final ScrollController _scrollController = ScrollController();
  final Map<String, String> _folderLabels = <String, String>{};
  final Map<String, int> _variantCounts = <String, int>{};
  final Map<String, List<ScrapeCandidateSummary>> _candidatesByWork =
      <String, List<ScrapeCandidateSummary>>{};
  final Set<String> _loadingCandidateIds = <String>{};
  final Set<String> _busyWorkIds = <String>{};

  bool _loadingMeta = false;
  String _loadedFingerprint = '';
  String? _failedFingerprint;
  bool _batchRetrying = false;
  int _batchDone = 0;
  int _batchTotal = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _fingerprint(List<Work> pending) =>
      pending.map((w) => '${w.id}:${w.reviewReason ?? ""}').join('|');

  Future<void> _syncWorkSummaries(
    List<Work> pending, {
    bool retry = false,
  }) async {
    final fingerprint = _fingerprint(pending);
    if (_loadingMeta ||
        fingerprint == _loadedFingerprint ||
        (!retry && fingerprint == _failedFingerprint)) {
      return;
    }
    setState(() {
      _loadingMeta = true;
      _failedFingerprint = null;
    });
    try {
      final mgmt = ref.read(workManagementControllerProvider);
      final sourcesById = await mgmt.loadSourcesById();
      final nextFolders = <String, String>{};
      final nextCounts = <String, int>{};
      final nextCands = <String, List<ScrapeCandidateSummary>>{};
      for (final w in pending) {
        final variants = await mgmt.getVariantsByWork(w.id);
        nextFolders[w.id] = MediaDisplayFormatter.summarizeWorkFolderLabel(
          variants,
          sourcesById: sourcesById,
        );
        nextCounts[w.id] = variants.length;
        nextCands[w.id] = await mgmt.getScrapeCandidates(w.id);
      }
      if (!mounted ||
          fingerprint !=
              _fingerprint(ref.read(libraryControllerProvider).reviewWorks)) {
        return;
      }
      setState(() {
        _loadedFingerprint = fingerprint;
        _folderLabels
          ..clear()
          ..addAll(nextFolders);
        _variantCounts
          ..clear()
          ..addAll(nextCounts);
        _candidatesByWork
          ..clear()
          ..addAll(nextCands);
      });
    } catch (error, stack) {
      if (!mounted) return;
      ref
          .read(featureLibraryDependenciesProvider)
          .diagnosticLog
          .logError(
            subsystem: DiagnosticSubsystem.ui,
            code: 'review_summary_load_failed',
            message: '待复核信息读取失败',
            error: error,
            stackTrace: stack,
          );
      setState(() => _failedFingerprint = fingerprint);
    } finally {
      if (mounted) setState(() => _loadingMeta = false);
    }
  }

  Future<void> _ensureCandidatesLoaded(String workId) async {
    if (_loadingCandidateIds.contains(workId)) return;
    setState(() => _loadingCandidateIds.add(workId));
    try {
      final list = await ref
          .read(workManagementControllerProvider)
          .getScrapeCandidates(workId);
      if (!mounted) return;
      setState(() => _candidatesByWork[workId] = list);
    } catch (error, stack) {
      if (!mounted) return;
      ref
          .read(featureLibraryDependenciesProvider)
          .diagnosticLog
          .logError(
            subsystem: DiagnosticSubsystem.ui,
            code: 'review_candidates_load_failed',
            message: '复核候选读取失败',
            error: error,
            stackTrace: stack,
          );
      showKonataToast(context, '候选读取失败，请重试', isError: true);
    } finally {
      if (mounted) {
        setState(() => _loadingCandidateIds.remove(workId));
      }
    }
  }

  Future<void> _runForWork(
    String workId,
    Future<void> Function() action,
  ) async {
    if (_busyWorkIds.contains(workId)) return;
    setState(() => _busyWorkIds.add(workId));
    try {
      await action();
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, '操作失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busyWorkIds.remove(workId));
      }
    }
  }

  Future<void> _retryNetworkDegraded(List<Work> targets) async {
    if (_batchRetrying || targets.isEmpty) return;
    setState(() {
      _batchRetrying = true;
      _batchDone = 0;
      _batchTotal = targets.length;
    });

    final mgmt = ref.read(workManagementControllerProvider);
    final library = ref.read(libraryControllerProvider);
    var successCount = 0;
    for (final work in targets) {
      if (!mounted) break;
      try {
        final result = await mgmt.rematchReviewWork(work.id);
        if (result.outcome == RematchWorkOutcome.matched ||
            result.outcome == RematchWorkOutcome.autoMerged) {
          successCount++;
        } else {
          final updatedCands = await mgmt.getScrapeCandidates(work.id);
          if (mounted) {
            setState(() => _candidatesByWork[work.id] = updatedCands);
          }
        }
      } catch (_) {}
      if (mounted) {
        setState(() => _batchDone++);
      }
    }
    await library.reload();
    if (!mounted) return;
    setState(() => _batchRetrying = false);
    showKonataToast(
      context,
      '批量重试完成：$successCount / ${targets.length} 条已自动完成匹配',
    );
  }

  Future<void> _handleRematch(Work work) async {
    await _runForWork(work.id, () async {
      final mgmt = ref.read(workManagementControllerProvider);
      final library = ref.read(libraryControllerProvider);
      final result = await mgmt.rematchReviewWork(work.id);
      final freshCands = await mgmt.getScrapeCandidates(work.id);
      if (mounted) {
        setState(() => _candidatesByWork[work.id] = freshCands);
      }
      await library.reload();
      if (!mounted) return;
      switch (result.outcome) {
        case RematchWorkOutcome.matched:
          showKonataToast(
            context,
            '已重新匹配「${result.work?.title ?? work.title}」',
          );
        case RematchWorkOutcome.autoMerged:
          showKonataToast(
            context,
            '检测到同源作品，已自动归并至「${result.work?.title ?? work.title}」',
          );
        case RematchWorkOutcome.needsReview:
          showKonataToast(context, '已刷新候选（${result.candidateCount} 条），请展开核对');
        case RematchWorkOutcome.unmatched:
          showKonataToast(context, '仍未找到高置信条目，请尝试手动搜索');
        case RematchWorkOutcome.networkError:
          showKonataToast(
            context,
            result.errorMessage ?? '网络或接口异常导致重新匹配失败',
            isError: true,
          );
      }
    });
  }

  Future<void> _handleManualMatch(Work work) async {
    final matched = await ref
        .read(workManageDialogPortProvider)
        .showManualMatchDialog(context, workId: WorkId.trusted(work.id));
    if (matched && mounted) {
      await ref.read(libraryControllerProvider).reload();
    }
  }

  Future<void> _handleMerge(Work work) async {
    await _runForWork(work.id, () async {
      final changed = await ref
          .read(workManageDialogPortProvider)
          .showWorkMergeDialog(context, sourceWorkId: WorkId.trusted(work.id));
      if (changed && mounted) {
        await ref.read(libraryControllerProvider).reload();
      }
    });
  }

  Future<void> _handleSourceFiles(Work work) async {
    final changed = await ref
        .read(workManageDialogPortProvider)
        .showSourceFilesReviewDialog(context, workId: WorkId.trusted(work.id));
    if (changed && mounted) await ref.read(libraryControllerProvider).reload();
  }

  Future<void> _handleDismiss(Work work) async {
    await _runForWork(work.id, () async {
      await ref
          .read(workManagementControllerProvider)
          .dismissWorkReview(work.id);
      await ref.read(libraryControllerProvider).reload();
      if (!mounted) return;
      showKonataToast(context, '已保留「${work.title}」并移出待复核');
    });
  }

  Future<void> _handleAcceptCandidate(
    Work work,
    ScrapeCandidateSummary candidate,
  ) async {
    await _runForWork(work.id, () async {
      await ref
          .read(workManagementControllerProvider)
          .bindWorkToTmdb(
            workId: work.id,
            tmdbId: candidate.tmdbId,
            mediaType: candidate.mediaType,
          );
      await ref.read(libraryControllerProvider).reload();
      if (!mounted) return;
      showKonataToast(context, '已绑定「${candidate.title}」');
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final controller = ref.watch(libraryControllerProvider);
    final dialogMaxHeight = MediaQuery.sizeOf(context).height * 0.84;

    return ListenableBuilder(
      listenable: controller,
      builder: (_, _) {
        final pending = controller.reviewWorks;
        final summaryFailed = _failedFingerprint == _fingerprint(pending);
        if (pending.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _syncWorkSummaries(pending);
          });
        }
        final networkWorks = pending
            .where(
              (w) => ReviewReasonLabels.isNetworkDegradedReason(w.reviewReason),
            )
            .toList(growable: false);

        return KonataGlassDialog(
          width: 820,
          maxHeight: dialogMaxHeight,
          title: '待复核队列',
          headerTrailing: pending.isEmpty
              ? null
              : Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: p.warningBadge.bg,
                    borderRadius: KonataTheme.borderRadiusPill,
                    border: Border.all(color: p.warningBadge.border),
                  ),
                  child: Text(
                    '${pending.length} 项',
                    style: KonataTheme.textStyle(
                      color: p.warningBadge.fg,
                      fontSize: KonataTheme.fontSizeCaption,
                      weight: KonataTheme.weightActive,
                      tabularFigures: true,
                    ),
                  ),
                ),
          onClose: () => Navigator.of(context).pop(),
          actions: <Widget>[
            KonataPillButton.secondary(
              label: '关闭',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
          child: pending.isEmpty
              ? SingleChildScrollView(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 42),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.check_circle_outline_rounded,
                            size: 44,
                            color: p.success,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '所有扫描作品均已完成精确匹配',
                            style: KonataTheme.cardTitleStyle(
                              p,
                              fontSize: KonataTheme.fontSizeBodyMd,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '当前没有等待人工确认的待复核条目',
                            style: KonataTheme.captionStyle(p),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (_failedFingerprint ==
                        _fingerprint(pending)) ...<Widget>[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '复核信息读取失败',
                              style: KonataTheme.captionStyle(p),
                            ),
                          ),
                          KonataPillButton.secondary(
                            label: '重新读取',
                            compact: true,
                            onPressed: _loadingMeta
                                ? null
                                : () =>
                                      _syncWorkSummaries(pending, retry: true),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (networkWorks.isNotEmpty) ...<Widget>[
                      _ReviewNetworkBatchRetryBar(
                        count: networkWorks.length,
                        retrying: _batchRetrying,
                        done: _batchDone,
                        total: _batchTotal,
                        onRetry: () => _retryNetworkDegraded(networkWorks),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Flexible(
                      child: KonataDraggableScrollbar(
                        controller: _scrollController,
                        builder: (_, sc) => ListView.separated(
                          controller: sc,
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: pending.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, index) {
                            final work = pending[index];
                            final busy =
                                _batchRetrying ||
                                _busyWorkIds.contains(work.id);
                            return ReviewWorkItemCard(
                              work: work,
                              folderLabel:
                                  _folderLabels[work.id] ??
                                  (summaryFailed ? '目录未读取' : '正在读取目录…'),
                              variantCount: _variantCounts[work.id] ?? 0,
                              candidates:
                                  _candidatesByWork[work.id] ??
                                  const <ScrapeCandidateSummary>[],
                              isLoadingCandidates: _loadingCandidateIds
                                  .contains(work.id),
                              isBusy: busy,
                              onEnsureCandidatesLoaded: () =>
                                  _ensureCandidatesLoaded(work.id),
                              onRematch: () => _handleRematch(work),
                              onManualMatch: () => _handleManualMatch(work),
                              onInspectSourceFiles: () =>
                                  _handleSourceFiles(work),
                              onMergeIntoExisting: () => _handleMerge(work),
                              onDismissReview: () => _handleDismiss(work),
                              onAcceptCandidate: (candidate) =>
                                  _handleAcceptCandidate(work, candidate),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// 网络波动或接口限流复核项的批量重试提示横幅。
class _ReviewNetworkBatchRetryBar extends StatelessWidget {
  const _ReviewNetworkBatchRetryBar({
    required this.count,
    required this.retrying,
    required this.done,
    required this.total,
    required this.onRetry,
  });

  final int count;
  final bool retrying;
  final int done;
  final int total;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: p.warningBadge.bg,
        borderRadius: KonataTheme.borderRadiusControl,
        border: Border.all(color: p.warningBadge.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.wifi_off_rounded, size: 16, color: p.warningBadge.fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              retrying
                  ? '正在重连匹配网络异常条目（$done / $total）…'
                  : '有 $count 项因网络波动、证书校验或接口限流未能自动刮削，可直接批量重试',
              style: KonataTheme.textStyle(
                color: p.warningBadge.fg,
                fontSize: KonataTheme.fontSizeCaption,
                weight: KonataTheme.weightActive,
                tabularFigures: true,
              ),
            ),
          ),
          const SizedBox(width: 10),
          KonataPillButton.secondary(
            label: retrying ? '重试中…' : '重试网络项 ($count)',
            icon: Icons.refresh_rounded,
            compact: true,
            onPressed: retrying ? null : onRetry,
          ),
        ],
      ),
    );
  }
}
