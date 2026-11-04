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
          ScanPhase.scanning => '正在扫描文件夹',
          ScanPhase.scraping => '正在自动刮削 TMDB / Bangumi',
          ScanPhase.complete => '扫描及自动刮削已完成',
          ScanPhase.failed => '扫描或自动刮削遇到错误',
          null => '尚无扫描记录',
        };
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.fact_check_outlined),
              SizedBox(width: 10),
              Expanded(child: Text('扫描进度')),
            ],
          ),
          content: SizedBox(
            width: 740,
            height: 520,
            child: run == null
                ? const Center(child: Text('还没有扫描过这个媒体源，选择文件夹后即可查看进度。'))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(stage, style: theme.textTheme.titleMedium),
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
                          Text('已扫描目录：${run.completedFolders.length}'),
                          Text('索引视频：${run.videoCount}'),
                          if (run.phase != ScanPhase.scanning)
                            Text(
                              '元数据：${run.metadataProcessed}/${run.metadataTotal}',
                            ),
                          if (run.phase != ScanPhase.scanning)
                            Text(
                              '成功：${run.matched} · 待复核：${run.needsReview} · 失败：${run.metadataErrors}',
                            ),
                        ],
                      ),
                      if (run.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: SelectableText(
                            run.error!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      if (run.currentFolder != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '当前目录：NaN',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      Text(
                        '本次选中的扫描范围（含子目录视频）',
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
                              Text('${run.videosUnder(root)} 个视频'),
                            ],
                          ),
                        ),
                      const Divider(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '具体已访问目录（仅统计该目录内视频）',
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          Text('${folders.length} 个'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: folders.isEmpty
                            ? const Center(child: Text('尚未读取到目录'))
                            : ListView.builder(
                                key: const ValueKey(
                                  'scan-progress-folder-list',
                                ),
                                itemCount: folders.length,
                                itemBuilder: (ctx, i) {
                                  final entry = folders[i];
                                  final current =
                                      entry.key == run.currentFolder;
                                  final complete = run.completedFolders
                                      .contains(entry.key);
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
                                    trailing: Text(
                                      '${entry.value} 个视频${current ? ' · 扫描中' : ''}',
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}
