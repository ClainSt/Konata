import '../l10n/strings.dart';
import 'uniform_action_bar.dart';
import 'package:flutter/material.dart';
import '../core/scan_activity.dart';

/// Live scan inspector. The same dialog is available while running and after
/// completion; figures refer to direct video files in each visited folder.
class ScanProgressDialog {
  static Future<void> show(
    BuildContext context, {
    required String sourceId,
  }) => showDialog<void>(
    context: context,
    builder: (ctx) => AnimatedBuilder(
      animation: ScanActivityStore.instance,
      builder: (ctx, _) {
        final run = ScanActivityStore.instance.forSource(sourceId);
        final theme = Theme.of(ctx);
        final folders = run?.folderVideos.entries.toList() ?? [];
        folders.sort((a, b) => a.key.compareTo(b.key));
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
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.fact_check_outlined),
              SizedBox(width: 10),
              Expanded(child: Text(ctx.l10n.scanProgress)),
            ],
          ),
          content: SizedBox(
            width: 740,
            height: 520,
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
                                    ? run.metadataProcessed / run.metadataTotal
                                    : null,
                              ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 18,
                              runSpacing: 8,
                              children: [
                                Text(
                                  ctx.l10n.scannedFolderCount(
                                    run.completedFolders.length,
                                  ),
                                ),
                                Text(
                                  ctx.l10n.indexedVideoCount(run.videoCount),
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
                                    Text(
                                      ctx.l10n.videoCount(
                                        run.videosUnder(root),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
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
                          ],
                        ),
                      ),
                      if (folders.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: Text(ctx.l10n.noFoldersRead)),
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
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(ctx.l10n.closeWindow),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}
