import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/sources_controller.dart';
import 'scan_progress_tabs.dart';

/// 媒体源主列表单卡视图（含协议差异化徽标、连接与入库状态、忽略目录与三端响应式操作胶囊）。
class MediaSourceCard extends ConsumerWidget {
  /// 创建媒体源信息与操作卡片。
  const MediaSourceCard({
    super.key,
    required this.source,
    required this.stats,
    required this.testing,
    required this.scanning,
    required this.anyScanning,
    required this.onScan,
    required this.onInspectPendingReview,
    required this.onTest,
    required this.onPickFolders,
    required this.onEdit,
    required this.onDelete,
  });

  /// 当前展示的媒体源实体。
  final MediaSource source;

  /// 该媒体源对应的本地库作品与文件统计摘要。
  final SourceLibraryStats stats;

  /// 是否正在探测本源连通性。
  final bool testing;

  /// 是否正在对本源执行扫库刮削。
  final bool scanning;

  /// 全局是否存在任意扫库任务进行中。
  final bool anyScanning;

  /// 点击发起扫库或查看当前进度的回调。
  final VoidCallback onScan;

  /// 点击待复核角标打开本源待复核清单的回调。
  final VoidCallback onInspectPendingReview;

  /// 点击测试连通性的回调。
  final VoidCallback onTest;

  /// 点击打开目录范围选择器的回调。
  final VoidCallback onPickFolders;

  /// 点击打开源编辑弹窗的回调。
  final VoidCallback onEdit;

  /// 点击打开移除确认弹窗的回调。
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final sourcesController = ref.watch(sourcesControllerProvider);
    final ignoredFolders =
        ref.watch(ignoredFoldersStreamProvider(source.id)).value ??
        const <String>[];
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final iconBtnSize = isAndroid ? KonataAdaptiveTokens.touchTarget : 34.0;

    return ListenableBuilder(
      listenable: sourcesController,
      builder: (context, _) {
        final lastScannedAt = sourcesController.readLastScannedAt(source.id);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPickFolders,
          child: KonataSurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            enableHover: true,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final infoRow = Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _ProtocolIconBadge(kind: source.kind),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          EllipsisTextWithTooltip(
                            text: source.label,
                            maxLines: 1,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: KonataTheme.fontSizeTitleSm,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          EllipsisTextWithTooltip(
                            text: source.location,
                            maxLines: 1,
                            style: TextStyle(
                              color: p.textSecondary,
                              fontSize: KonataTheme.fontSizeBodyXs,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              KonataSpecBadge(
                                icon: Icons.video_library_outlined,
                                label: stats.hasAnyIndexed
                                    ? '${stats.workCount} 部 · ${stats.videoCount} 视频'
                                    : '尚未入库',
                              ),
                              if (stats.reviewCount > 0)
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: onInspectPendingReview,
                                    child: ScanProgressStatChip(
                                      label: '待复核 ${stats.reviewCount} ↗',
                                      badge: p.warningBadge,
                                    ),
                                  ),
                                ),
                              if (lastScannedAt != null)
                                KonataSpecBadge(
                                  icon: Icons.schedule_rounded,
                                  label: '上次扫描：${_formatTime(lastScannedAt)}',
                                ),
                            ],
                          ),
                          if (ignoredFolders.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  '已忽略 (${ignoredFolders.length})：',
                                  style: TextStyle(
                                    fontSize: KonataTheme.fontSizeCaptionSm,
                                    color: p.textMuted,
                                  ),
                                ),
                                for (final folder in ignoredFolders)
                                  _IgnoredFolderChip(
                                    folder: folder,
                                    onRestore: () => ref
                                        .read(sourcesControllerProvider)
                                        .removeIgnoredFolder(source.id, folder),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );

                final actionWidgets = <Widget>[
                  KonataPillButton.primary(
                    label: scanning ? '查看进度' : '选择目录',
                    icon: Icons.folder_open_rounded,
                    compact: true,
                    onPressed: scanning
                        ? onScan
                        : (anyScanning ? null : onPickFolders),
                  ),
                  KonataPillButton.secondary(
                    label: testing ? '测试中...' : '测试连通',
                    compact: true,
                    onPressed: testing ? null : onTest,
                  ),
                  KonataCapsuleIconButton(
                    icon: Icons.edit_outlined,
                    tooltip: '编辑',
                    color: p.textSecondary,
                    size: 18,
                    fixedSize: iconBtnSize,
                    onTap: onEdit,
                  ),
                  KonataCapsuleIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: '删除',
                    color: p.textSecondary,
                    size: 18,
                    fixedSize: iconBtnSize,
                    onTap: onDelete,
                  ),
                ];

                if (constraints.maxWidth >= 640) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: infoRow),
                      const SizedBox(width: 14),
                      actionWidgets[0],
                      const SizedBox(width: 8),
                      actionWidgets[1],
                      const SizedBox(width: 6),
                      actionWidgets[2],
                      actionWidgets[3],
                    ],
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    infoRow,
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: actionWidgets,
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  static String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$m-$d $hh:$mm';
  }
}

class _ProtocolIconBadge extends StatelessWidget {
  const _ProtocolIconBadge({required this.kind});

  final MediaSourceKind kind;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (icon, label) = switch (kind) {
      MediaSourceKind.local => (Icons.folder_outlined, '本地磁盘'),
      MediaSourceKind.webdav => (Icons.cloud_outlined, 'WebDAV'),
      MediaSourceKind.smb => (Icons.dns_outlined, 'SMB 共享'),
      MediaSourceKind.cloudDrive => (Icons.cloud_outlined, '云盘'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: p.softFill,
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: p.hairline, width: 0.9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13.5, color: p.textSecondary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _IgnoredFolderChip extends StatefulWidget {
  const _IgnoredFolderChip({required this.folder, required this.onRestore});

  final String folder;
  final VoidCallback onRestore;

  @override
  State<_IgnoredFolderChip> createState() => _IgnoredFolderChipState();
}

class _IgnoredFolderChipState extends State<_IgnoredFolderChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataTooltip(
      message: '点击恢复扫描目录「${widget.folder}」',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onRestore,
          child: AnimatedContainer(
            duration: KonataTheme.motionFast,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceHover : p.softFill,
              borderRadius: KonataTheme.borderRadiusPill,
              border: Border.all(color: _hovered ? p.hoverBorder : p.hairline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    widget.folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: KonataTheme.fontSizeCaptionSm,
                      color: p.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.close_rounded, size: 13, color: p.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
