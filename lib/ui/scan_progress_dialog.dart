import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/scan_activity.dart';
import '../l10n/strings.dart';
import '../main.dart' show WorkPage, showManualMatchDialog;
import 'uniform_action_bar.dart';

/// Live scan inspector. The same dialog is available while running and after
/// completion; figures refer to direct video files in each visited folder, and
/// any `needs_review` works can be confirmed or rematched in place, or opened
/// explicitly on demand.
class ScanProgressDialog {
  static String _workFolderLabel(Map<String, Object?> work) {
    final id = work['id']?.toString() ?? '';
    final base = id.split(':classified:').first;
    if (base.startsWith('work:')) {
      final first = base.indexOf(':');
      final second = base.indexOf(':', first + 1);
      if (second > 0 && second + 1 < base.length) {
        try {
          return Uri.decodeComponent(
            base.substring(second + 1),
          ).replaceAll('\\', '/');
        } on FormatException {
          // Fall through to title below.
        }
      }
    }
    return work['title']?.toString() ?? '';
  }

  static Future<void> show(
    BuildContext context, {
    required String sourceId,
    void Function(String workId)? onOpenWork,
    Future<bool> Function(BuildContext context, Map<String, Object?> work)?
    onMatchWork,
  }) {
    var showReviewList = false;
    var sawSourceWorks = false;
    final confirmingWorkIds = <String>{};
    return showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AnimatedBuilder(
          animation: Listenable.merge([
            ScanActivityStore.instance,
            Catalog.instance,
          ]),
          builder: (ctx, _) {
            final run = ScanActivityStore.instance.forSource(sourceId);
            final theme = Theme.of(ctx);
            final folders = run?.folderVideos.entries.toList() ?? [];
            folders.sort((a, b) => a.key.compareTo(b.key));
            final sourcePrefix = 'work:$sourceId:';
            final sourceWorks = Catalog.instance.works
                .where(
                  (w) => w['id']?.toString().startsWith(sourcePrefix) == true,
                )
                .toList();
            if (sourceWorks.isNotEmpty) {
              sawSourceWorks = true;
            }
            final pendingWorks =
                sourceWorks.where((w) => w['needs_review'] == 1).toList()..sort(
                  (a, b) => (a['title']?.toString() ?? '').compareTo(
                    b['title']?.toString() ?? '',
                  ),
                );
            final pendingReviewCount = sawSourceWorks
                ? pendingWorks.length
                : (run?.needsReview ?? 0);
            final hasReviewItems =
                pendingWorks.isNotEmpty ||
                (!sawSourceWorks && (run?.needsReview ?? 0) > 0) ||
                showReviewList;
            final activeReviewTab = showReviewList && hasReviewItems;
            final isActive =
                run?.phase == ScanPhase.scanning ||
                run?.phase == ScanPhase.scraping;
            final stage = switch (run?.phase) {
              ScanPhase.scanning => ctx.l10n.scanFolders,
              ScanPhase.scraping => ctx.l10n.scanMetadata,
              ScanPhase.complete => ctx.l10n.scanComplete,
              ScanPhase.cancelled => ctx.l10n.scanCancelled,
              ScanPhase.failed => ctx.l10n.scanFailed,
              null => ctx.l10n.noScan,
            };
            final screenSize = MediaQuery.sizeOf(ctx);
            final dialogWidth = screenSize.width < 820
                ? screenSize.width - 48
                : 740.0;
            final dialogHeight = (screenSize.height * 0.65).clamp(260.0, 520.0);

            Future<void> confirmReview(String workId) async {
              if (!confirmingWorkIds.add(workId)) return;
              setDialogState(() {});
              try {
                await Catalog.instance.confirmWorkReview(workId);
              } catch (_) {
                if (ctx.mounted) {
                  ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                    SnackBar(content: Text(ctx.reviewActionFailed)),
                  );
                }
              } finally {
                confirmingWorkIds.remove(workId);
                if (ctx.mounted) setDialogState(() {});
              }
            }

            Future<void> rematchWork(Map<String, Object?> work) async {
              final matcher = onMatchWork ?? showManualMatchDialog;
              await matcher(ctx, work);
            }

            Future<void> openDetails(String workId) async {
              Tooltip.dismissAllToolTips();
              if (onOpenWork != null) {
                Navigator.pop(dialogCtx);
                onOpenWork(workId);
                return;
              }
              await Navigator.of(dialogCtx).push(
                MaterialPageRoute<void>(
                  builder: (_) => WorkPage(workId: workId),
                ),
              );
              if (dialogCtx.mounted) {
                setDialogState(() {});
              }
            }

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.fact_check_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      ctx.l10n.scanProgress,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: dialogWidth,
                height: dialogHeight,
                child: run == null
                    ? Center(child: Text(ctx.l10n.noScanHint))
                    : CustomScrollView(
                        key: const ValueKey('scan-progress-folder-list'),
                        slivers: [
                          SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isActive && run.cancelRequested
                                      ? ctx.l10n.scanStopping
                                      : stage,
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                if (isActive)
                                  LinearProgressIndicator(
                                    value:
                                        run.phase == ScanPhase.scraping &&
                                            run.metadataTotal > 0
                                        ? run.metadataProcessed /
                                              run.metadataTotal
                                        : null,
                                  ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 18,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      ctx.l10n.scannedFolderCount(
                                        run.completedFolders.length,
                                      ),
                                    ),
                                    Text(
                                      ctx.l10n.indexedVideoCount(
                                        run.videoCount,
                                      ),
                                    ),
                                    if (run.phase != ScanPhase.scanning) ...[
                                      Text(
                                        ctx.l10n.scanMetadataCount(
                                          run.metadataProcessed,
                                          run.metadataTotal,
                                        ),
                                      ),
                                      Text(
                                        ctx.l10n.scanSummary(
                                          run.matched,
                                          run.needsReview,
                                          run.metadataErrors,
                                        ),
                                      ),
                                      if (hasReviewItems)
                                        ActionChip(
                                          key: const ValueKey(
                                            'scan-progress-review-chip',
                                          ),
                                          visualDensity: VisualDensity.compact,
                                          avatar: Icon(
                                            activeReviewTab
                                                ? Icons.folder_outlined
                                                : Icons.rate_review_outlined,
                                            size: 16,
                                          ),
                                          label: Text(
                                            '${ctx.l10n.pendingReviewItems} ($pendingReviewCount)',
                                          ),
                                          onPressed: () => setDialogState(
                                            () => showReviewList =
                                                !activeReviewTab,
                                          ),
                                        ),
                                    ],
                                  ],
                                ),
                                if (run.error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: SelectableText(
                                      run.error!,
                                      style: TextStyle(
                                        color: theme.colorScheme.error,
                                      ),
                                    ),
                                  ),
                                if (run.currentFolder != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      ctx.l10n.currentScanFolder(
                                        run.currentFolder!,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                const SizedBox(height: 12),
                                const Divider(height: 1),
                                const SizedBox(height: 8),
                                if (hasReviewItems) ...[
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      ChoiceChip(
                                        key: const ValueKey(
                                          'scan-progress-tab-folders',
                                        ),
                                        selected: !activeReviewTab,
                                        label: Text(
                                          '${ctx.l10n.visitedFolders} (${folders.length})',
                                        ),
                                        onSelected: (_) => setDialogState(
                                          () => showReviewList = false,
                                        ),
                                      ),
                                      ChoiceChip(
                                        key: const ValueKey(
                                          'scan-progress-tab-review',
                                        ),
                                        selected: activeReviewTab,
                                        label: Text(
                                          '${ctx.l10n.pendingReviewItems} ($pendingReviewCount)',
                                        ),
                                        onSelected: (_) => setDialogState(
                                          () => showReviewList = true,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                if (!activeReviewTab) ...[
                                  Text(
                                    ctx.l10n.scanScope,
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 5),
                                  for (final root in run.selectedRoots)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 3),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              root.isEmpty ? '/' : root,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            ctx.l10n.videoCount(
                                              run.videosUnder(root),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (!hasReviewItems) ...[
                                    const Divider(height: 18),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            ctx.l10n.visitedFolders,
                                            style: theme.textTheme.titleSmall,
                                          ),
                                        ),
                                        Text(ctx.l10n.itemCount(folders.length)),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                  ] else
                                    const Divider(height: 14),
                                ],
                              ],
                            ),
                          ),
                          if (activeReviewTab)
                            if (pendingWorks.isEmpty)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(
                                  child: Text(ctx.l10n.noPendingReviewItems),
                                ),
                              )
                            else
                              SliverList(
                                delegate: SliverChildBuilderDelegate((ctx, i) {
                                  final work = pendingWorks[i];
                                  final workId = work['id'].toString();
                                  final title =
                                      work['title']?.toString() ?? workId;
                                  final folderPath = _workFolderLabel(work);
                                  final hasPoster =
                                      (work['poster']
                                              ?.toString()
                                              .trim()
                                              .isNotEmpty ??
                                          false) ||
                                      (work['poster_fallback']
                                              ?.toString()
                                              .trim()
                                              .isNotEmpty ??
                                          false);
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _PendingReviewTile(
                                      key: ValueKey('pending-review-$workId'),
                                      workId: workId,
                                      title: title,
                                      folderPath: folderPath,
                                      hasPoster: hasPoster,
                                      confirming: confirmingWorkIds.contains(
                                        workId,
                                      ),
                                      onConfirm: () => confirmReview(workId),
                                      onRematch: () => rematchWork(work),
                                      onOpenDetails: () => openDetails(workId),
                                    ),
                                  );
                                }, childCount: pendingWorks.length),
                              )
                          else if (folders.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: Text(ctx.l10n.noFoldersRead),
                              ),
                            )
                          else
                            SliverList(
                              delegate: SliverChildBuilderDelegate((ctx, i) {
                                final entry = folders[i];
                                final current = entry.key == run.currentFolder;
                                final complete = run.completedFolders.contains(
                                  entry.key,
                                );
                                final compact =
                                    MediaQuery.sizeOf(ctx).width < 600 ||
                                    MediaQuery.textScalerOf(ctx).scale(1) > 1.3;
                                final count = Text(
                                  '${ctx.l10n.videoCount(entry.value)}${current ? ' · ${ctx.l10n.scanningShort}' : ''}',
                                );
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    current
                                        ? Icons.sync
                                        : complete
                                        ? Icons.folder_outlined
                                        : Icons.pending_outlined,
                                    size: 21,
                                  ),
                                  title: Text(
                                    entry.key.isEmpty ? '/' : entry.key,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: compact ? count : null,
                                  trailing: compact ? null : count,
                                );
                              }, childCount: folders.length),
                            ),
                        ],
                      ),
              ),
              actions: [
                UniformActionBar(
                  children: [
                    if (isActive && run != null)
                      OutlinedButton(
                        onPressed: run.cancelRequested
                            ? null
                            : () => ScanActivityStore.instance.requestCancel(
                                sourceId,
                              ),
                        child: Text(ctx.l10n.cancelScan),
                      ),
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx),
                      child: Text(ctx.l10n.closeWindow),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PendingReviewTile extends StatelessWidget {
  const _PendingReviewTile({
    super.key,
    required this.workId,
    required this.title,
    required this.folderPath,
    required this.hasPoster,
    required this.confirming,
    required this.onConfirm,
    required this.onRematch,
    required this.onOpenDetails,
  });

  final String workId;
  final String title;
  final String folderPath;
  final bool hasPoster;
  final bool confirming;
  final VoidCallback onConfirm;
  final VoidCallback onRematch;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = hasPoster
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    final statusLabel = hasPoster
        ? context.l10n.reviewCandidatePoster
        : context.l10n.reviewUnmatched;
    final textScale = MediaQuery.textScalerOf(context).scale(1);

    final confirmButton = hasPoster
        ? FilledButton.tonalIcon(
            key: ValueKey('pending-review-confirm-$workId'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            onPressed: confirming ? null : onConfirm,
            icon: confirming
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded, size: 16),
            label: Text(context.confirmAdoptAction),
          )
        : OutlinedButton.icon(
            key: ValueKey('pending-review-confirm-$workId'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            onPressed: confirming ? null : onConfirm,
            icon: confirming
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded, size: 16),
            label: Text(context.confirmAdoptAction),
          );

    final rematchButton = OutlinedButton.icon(
      key: ValueKey('pending-review-rematch-$workId'),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      onPressed: confirming ? null : onRematch,
      icon: const Icon(Icons.manage_search_outlined, size: 16),
      label: Text(context.rematchAction),
    );

    final detailButton = IconButton(
      key: ValueKey('pending-review-detail-$workId'),
      tooltip: context.viewDetailsTooltip,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.open_in_new_outlined, size: 18),
      onPressed: onOpenDetails,
    );

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: confirming ? null : onRematch,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 560 && textScale <= 1.2;
              final infoColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: wide ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    folderPath,
                    maxLines: wide ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              );

              final leadingIcon = Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  hasPoster ? Icons.image_search_outlined : Icons.help_outline,
                  size: 21,
                  color: statusColor,
                ),
              );

              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    leadingIcon,
                    const SizedBox(width: 10),
                    Expanded(child: infoColumn),
                    const SizedBox(width: 10),
                    confirmButton,
                    const SizedBox(width: 8),
                    rematchButton,
                    const SizedBox(width: 4),
                    detailButton,
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      leadingIcon,
                      const SizedBox(width: 10),
                      Expanded(child: infoColumn),
                      detailButton,
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [confirmButton, rematchButton],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
