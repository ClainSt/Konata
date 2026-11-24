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
    required this.testResult,
    required this.scanning,
    required this.anyScanning,
    required this.onScan,
    required this.onForceRescan,
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

  /// 本次会话内最近一次连通性测试结果。
  final SourceTestResult? testResult;

  /// 是否正在对本源执行扫库刮削。
  final bool scanning;

  /// 全局是否存在任意扫库任务进行中。
  final bool anyScanning;

  /// 点击发起扫库或查看当前进度的回调。
  final VoidCallback onScan;

  /// 点击忽略增量缓存强制全量重扫的回调。
  final VoidCallback onForceRescan;

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
        final includedFolders = sourcesController.readIncludedFolders(
          source.id,
        );
        final lastScannedAt = sourcesController.readLastScannedAt(source.id);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPickFolders,
          child: KonataSurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            enableHover: true,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final infoRow = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ProtocolIconBadge(kind: source.kind),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: EllipsisTextWithTooltip(
                                  text: source.label,
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: p.textPrimary,
                                    fontSize: KonataTheme.fontSizeTitleSm,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _SourceStatusPill(
                                scanning: scanning,
                                testing: testing,
                                testResult: testResult,
                                hasIndexed: stats.hasAnyIndexed,
                              ),
                            ],
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
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _ProtocolLabelChip(kind: source.kind),
                              KonataSpecBadge(
                                icon: Icons.video_library_outlined,
                                label: stats.hasAnyIndexed
                                    ? '${stats.workCount} 部 · ${stats.videoCount} 视频'
                                    : '尚未入库',
                              ),
                              KonataSpecBadge(
                                icon: Icons.account_tree_outlined,
                                label: includedFolders.isEmpty
                                    ? '全盘根目录'
                                    : '已限定 ${includedFolders.length} 个目录',
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
                              if (source.username != null &&
                                  source.username!.trim().isNotEmpty)
                                KonataSpecBadge(
                                  icon: Icons.person_outline_rounded,
                                  label: source.username!,
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
                                        .removeIgnoredFolder(
                                          source.id,
                                          folder,
                                        ),
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
                    label: scanning ? '查看进度' : '扫库刮削',
                    icon: scanning
                        ? Icons.hourglass_top_rounded
                        : Icons.radar_rounded,
                    compact: true,
                    onPressed: scanning
                        ? onScan
                        : (anyScanning ? null : onScan),
                  ),
                  KonataPillButton.secondary(
                    label: includedFolders.isEmpty
                        ? '目录范围'
                        : '范围 (${includedFolders.length})',
                    icon: Icons.folder_open_rounded,
                    compact: true,
                    onPressed: onPickFolders,
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
                  _SourceMoreMenuButton(
                    iconBtnSize: iconBtnSize,
                    onEdit: onEdit,
                    onPickFolders: onPickFolders,
                    onTestConnection: onTest,
                    onForceRescan: anyScanning ? null : onForceRescan,
                    onDelete: onDelete,
                  ),
                ];

                if (constraints.maxWidth >= 740) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: infoRow),
                      const SizedBox(width: 14),
                      actionWidgets[0],
                      const SizedBox(width: 8),
                      actionWidgets[1],
                      const SizedBox(width: 8),
                      actionWidgets[2],
                      const SizedBox(width: 6),
                      actionWidgets[3],
                      actionWidgets[4],
                      actionWidgets[5],
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
    final (icon, bg, border, fg) = switch (kind) {
      MediaSourceKind.local => (
        Icons.folder_outlined,
        p.softFill,
        p.hairline,
        p.textPrimary,
      ),
      MediaSourceKind.webdav => (
        Icons.cloud_outlined,
        p.accentBadge.bg,
        p.accentBadge.border,
        p.accentBadge.fg,
      ),
      MediaSourceKind.smb => (
        Icons.dns_outlined,
        p.successBadge.bg,
        p.successBadge.border,
        p.successBadge.fg,
      ),
    };

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: KonataTheme.borderRadiusControl,
        border: Border.all(color: border, width: 1),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 20, color: fg),
    );
  }
}

class _ProtocolLabelChip extends StatelessWidget {
  const _ProtocolLabelChip({required this.kind});

  final MediaSourceKind kind;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (label, badge) = switch (kind) {
      MediaSourceKind.local => ('本地磁盘', null),
      MediaSourceKind.webdav => ('WebDAV', p.accentBadge),
      MediaSourceKind.smb => ('SMB 共享', p.successBadge),
    };
    return ScanProgressStatChip(label: label, badge: badge);
  }
}

class _SourceStatusPill extends StatelessWidget {
  const _SourceStatusPill({
    required this.scanning,
    required this.testing,
    required this.testResult,
    required this.hasIndexed,
  });

  final bool scanning;
  final bool testing;
  final SourceTestResult? testResult;
  final bool hasIndexed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (label, dotColor, badge) = scanning
        ? ('扫库中', p.accent, p.accentBadge)
        : testing
        ? ('探测中', p.accent, p.accentBadge)
        : testResult != null
        ? (
            testResult!.success ? '连通正常' : '连接异常',
            testResult!.success ? p.success : p.danger,
            testResult!.success ? p.successBadge : p.dangerBadge,
          )
        : hasIndexed
        ? ('已索引', p.success, p.successBadge)
        : ('就绪', p.textMuted, null);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: badge?.bg ?? p.softFill,
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(color: badge?.border ?? p.hairline, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: badge?.fg ?? p.textSecondary,
              fontSize: KonataTheme.fontSizeBadge,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _IgnoredFolderChip extends StatefulWidget {
  const _IgnoredFolderChip({
    required this.folder,
    required this.onRestore,
  });

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
    return Tooltip(
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
              border: Border.all(
                color: _hovered ? p.hoverBorder : p.hairline,
              ),
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
                Icon(
                  Icons.close_rounded,
                  size: 13,
                  color: p.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceMoreMenuButton extends StatelessWidget {
  const _SourceMoreMenuButton({
    required this.iconBtnSize,
    required this.onEdit,
    required this.onPickFolders,
    required this.onTestConnection,
    required this.onForceRescan,
    required this.onDelete,
  });

  final double iconBtnSize;
  final VoidCallback onEdit;
  final VoidCallback onPickFolders;
  final VoidCallback onTestConnection;
  final VoidCallback? onForceRescan;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Builder(
      builder: (anchorContext) => KonataCapsuleIconButton(
        icon: Icons.more_horiz_rounded,
        tooltip: '更多媒体源操作',
        color: p.textSecondary,
        size: 18,
        fixedSize: iconBtnSize,
        padding: EdgeInsets.zero,
        onTap: () async {
          final picked = await showKonataGlassMenu<String>(
            anchorContext: anchorContext,
            items: [
              const KonataGlassMenuItem(
                value: 'edit',
                label: '编辑配置',
                icon: Icons.edit_outlined,
              ),
              const KonataGlassMenuItem(
                value: 'scope',
                label: '扫描目录作用域',
                icon: Icons.account_tree_outlined,
              ),
              const KonataGlassMenuItem(
                value: 'test',
                label: '测试连通性',
                icon: Icons.wifi_tethering_rounded,
              ),
              if (onForceRescan != null)
                const KonataGlassMenuItem(
                  value: 'force_rescan',
                  label: '忽略增量缓存重扫',
                  icon: Icons.refresh_rounded,
                ),
              const KonataGlassMenuItem(
                value: 'delete',
                label: '移除媒体源',
                icon: Icons.delete_outline_rounded,
                isDanger: true,
              ),
            ],
          );
          switch (picked) {
            case 'edit':
              onEdit();
            case 'scope':
              onPickFolders();
            case 'test':
              onTestConnection();
            case 'force_rescan':
              onForceRescan?.call();
            case 'delete':
              onDelete();
            default:
              break;
          }
        },
      ),
    );
  }
}
