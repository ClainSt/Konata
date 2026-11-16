import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/source_actions_provider.dart';
import '../../application/scraping/scrape_progress.dart';
import '../../domain/models/media_source.dart';
import '../audio/mini_audio_bar.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_page_header.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import 'delete_source_dialog.dart';
import 'scan_progress_dialog.dart';
import 'scrape_progress_banner.dart';
import 'source_editor_dialog.dart';
import 'source_folder_picker_dialog.dart';

/// 媒体源管理页面（支持本地目录 / WebDAV / SMB 增删改、连通测试与触发扫描）。
class SourcesPage extends ConsumerStatefulWidget {
  /// 创建媒体源管理页面。
  const SourcesPage({super.key});

  @override
  ConsumerState<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends ConsumerState<SourcesPage> {
  final ScrollController _scrollCtrl = ScrollController();
  String? _testingSourceId;
  bool _bannerDismissed = false;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection(MediaSource source) async {
    setState(() => _testingSourceId = source.id);
    final error = await ref
        .read(konataActionsProvider)
        .testMediaSourceConnection(source);
    if (!mounted) return;
    setState(() => _testingSourceId = null);
    showKonataToast(
      context,
      error ?? '「${source.label}」连通测试成功',
      isError: error != null,
    );
  }

  void _openEditor([MediaSource? existing]) {
    showKonataGlassDialog<void>(
      context: context,
      builder: (_) => SourceEditorDialog(
        existing: existing,
        onSave: (source, password, {clearPassword = false}) async {
          await ref.read(konataActionsProvider).saveMediaSource(
                source: source,
                password: password,
                clearPassword: clearPassword,
              );
        },
        onTestConnection: (
          draft, {
          passwordOverride,
          clearPassword = false,
        }) {
          return ref.read(konataActionsProvider).testMediaSourceConnection(
                draft,
                passwordOverride: passwordOverride,
                clearPassword: clearPassword,
              );
        },
      ),
    );
  }

  Future<void> _confirmDeleteSource(MediaSource source) async {
    final confirmed = await showDeleteSourceConfirmDialog(context, source);
    if (!confirmed || !mounted) return;
    await ref.read(konataActionsProvider).deleteMediaSource(source.id);
    if (!mounted) return;
    showKonataToast(
      context,
      '已移除媒体源「${source.label}」（原始媒体文件未受影响）',
    );
  }

  void _openProgressDialog() {
    showKonataGlassDialog<void>(
      context: context,
      builder: (_) => const ScanProgressDialog(),
    );
  }

  Future<void> _startScan(
    MediaSource source, {
    List<String>? scanRootsOverride,
  }) async {
    final notifier = ref.read(scrapeControllerProvider.notifier);
    if (ref.read(scrapeControllerProvider).isRunning) {
      _openProgressDialog();
      return;
    }
    if (mounted) {
      setState(() => _bannerDismissed = false);
      _openProgressDialog();
    }
    try {
      await notifier.scanSource(
        source,
        scanRootsOverride: scanRootsOverride,
      );
    } catch (_) {
      // 错误详情已同步写入 ScrapeProgress，通过进度卡片与弹窗展示。
    }
  }

  void _openFolderPicker(MediaSource source) {
    showKonataGlassDialog<void>(
      context: context,
      builder: (_) => SourceFolderPickerDialog(
        source: source,
        onScanSelected: (selectedPaths) => _startScan(
          source,
          scanRootsOverride: selectedPaths,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sourcesAsync = ref.watch(mediaSourcesProvider);
    final progress = ref.watch(scrapeControllerProvider);
    final bottomClearance = ref.watch(miniAudioBottomClearanceProvider);
    final showBanner = progress.phase != ScrapePhase.idle && !_bannerDismissed;

    ref.listen<ScrapeProgress>(scrapeControllerProvider, (prev, next) {
      if (_bannerDismissed && next.isRunning) {
        setState(() => _bannerDismissed = false);
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KonataPageHeader(
          title: '媒体源管理',
          actions: [
            KonataPillButton.primary(
              label: '添加媒体源',
              icon: Icons.add_rounded,
              onPressed: () => _openEditor(),
            ),
          ],
        ),
        Expanded(
          child: sourcesAsync.when(
            data: (sources) {
              if (sources.isEmpty && !showBanner) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_open_rounded,
                        size: 48,
                        color: p.textMuted,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '尚未配置任何媒体源',
                        style: KonataTheme.cardTitleStyle(p, fontSize: 16),
                      ),
                    ],
                  ),
                );
              }

              return KonataDraggableScrollbar(
                controller: _scrollCtrl,
                builder: (_, ctrl) => CustomScrollView(
                  controller: ctrl,
                  slivers: [
                    if (showBanner)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                          KonataTheme.pageHorizontalPadding,
                          0,
                          KonataTheme.pageHorizontalPadding,
                          14,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: ScrapeProgressBanner(
                            progress: progress,
                            onInspect: _openProgressDialog,
                            onCancel: progress.isRunning &&
                                    !progress.cancelRequested
                                ? () => ref
                                    .read(scrapeControllerProvider.notifier)
                                    .requestCancel()
                                : null,
                            onDismiss: progress.isRunning
                                ? null
                                : () =>
                                    setState(() => _bannerDismissed = true),
                          ),
                        ),
                      ),
                    if (sources.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.folder_open_rounded,
                                size: 48,
                                color: p.textMuted,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '尚未配置任何媒体源',
                                style: KonataTheme.cardTitleStyle(
                                  p,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          KonataTheme.pageHorizontalPadding,
                          0,
                          KonataTheme.pageHorizontalPadding,
                          28 + bottomClearance,
                        ),
                        sliver: SliverList.separated(
                          itemCount: sources.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, index) {
                            final source = sources[index];
                            final isScanningThis =
                                progress.isRunning &&
                                progress.sourceId == source.id;
                            return _SourceCard(
                              source: source,
                              testing: _testingSourceId == source.id,
                              scanning: isScanningThis,
                              onTest: () => _testConnection(source),
                              onPickFolders: () => _openFolderPicker(source),
                              onEdit: () => _openEditor(source),
                              onDelete: () => _confirmDeleteSource(source),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(
              child: Text(
                '加载媒体源失败: $err',
                style: TextStyle(color: p.danger),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.testing,
    required this.scanning,
    required this.onTest,
    required this.onPickFolders,
    required this.onEdit,
    required this.onDelete,
  });

  final MediaSource source;
  final bool testing;
  final bool scanning;
  final VoidCallback onTest;
  final VoidCallback onPickFolders;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final kindLabel = switch (source.kind) {
      MediaSourceKind.local => '本地目录',
      MediaSourceKind.webdav => 'WebDAV',
      MediaSourceKind.smb => 'SMB 共享',
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPickFolders,
      child: KonataSurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        enableHover: true,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: p.softFill,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                kindLabel,
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.label,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    source.location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            KonataPillButton.primary(
              label: scanning ? '扫描中...' : '选择目录',
              icon: Icons.folder_open_rounded,
              compact: true,
              onPressed: onPickFolders,
            ),
            const SizedBox(width: 8),
            KonataPillButton.secondary(
              label: testing ? '测试中...' : '测试连通',
              compact: true,
              onPressed: testing ? null : onTest,
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: '编辑',
              color: p.textSecondary,
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: '删除',
              color: p.textSecondary,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
