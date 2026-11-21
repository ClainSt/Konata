import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/source_actions_provider.dart';
import '../../application/scraping/scrape_progress.dart';
import '../../domain/models/media_source.dart';
import '../audio/mini_audio_bar.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/adaptive_action_header.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import 'delete_source_dialog.dart';
import 'scan_progress_dialog.dart';
import 'scrape_progress_banner.dart';
import 'source_editor_dialog.dart';
import 'source_folder_picker_dialog.dart';
import 'tmdb_scrape_guard.dart';

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
          await ref
              .read(konataActionsProvider)
              .saveMediaSource(
                source: source,
                password: password,
                clearPassword: clearPassword,
              );
        },
        onTestConnection: (draft, {passwordOverride, clearPassword = false}) {
          return ref
              .read(konataActionsProvider)
              .testMediaSourceConnection(
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
    showKonataToast(context, '已移除媒体源「${source.label}」（原始媒体文件未受影响）');
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
    if (!await ensureTmdbConfiguredForScrape(
      context,
      ref,
      allowBangumiFallback: true,
    )) {
      return;
    }
    if (mounted) {
      setState(() => _bannerDismissed = false);
      _openProgressDialog();
    }
    try {
      await notifier.scanSource(source, scanRootsOverride: scanRootsOverride);
    } catch (error) {
      // 错误详情已同步写入 ScrapeProgress，通过进度卡片与弹窗展示。
      developer.log('可恢复异常已记录', name: 'konata.sources_page', error: error);
    }
  }

  void _openFolderPicker(MediaSource source) {
    showKonataGlassDialog<void>(
      context: context,
      builder: (_) => SourceFolderPickerDialog(
        source: source,
        onScanSelected: (selectedPaths) =>
            _startScan(source, scanRootsOverride: selectedPaths),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sourcesAsync = ref.watch(mediaSourcesProvider);
    final scanState = ref.watch(
      scrapeControllerProvider.select(
        (s) => (
          active: s.phase != ScrapePhase.idle,
          isRunning: s.isRunning,
          sourceId: s.sourceId,
        ),
      ),
    );
    final bottomClearance = KonataBottomClearanceScope.resolve(context, ref);
    final showBanner = scanState.active && !_bannerDismissed;
    final screenW = MediaQuery.sizeOf(context).width;
    final padH =
        KonataAdaptiveTokens.isAndroid &&
            screenW < KonataAdaptiveTokens.tabletBreakpoint
        ? KonataAdaptiveTokens.horizontalInset
        : KonataTheme.pageHorizontalPadding;

    ref.listen<bool>(scrapeControllerProvider.select((s) => s.isRunning), (
      prev,
      isRunning,
    ) {
      if (_bannerDismissed && isRunning) {
        setState(() => _bannerDismissed = false);
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdaptiveActionHeader(
          title: '媒体源管理',
          primaryActions: [
            AdaptiveHeaderAction(
              icon: Icons.add_rounded,
              label: '添加媒体源',
              highlighted: true,
              preserveWideWidgetOnNarrow: true,
              wideWidget: KonataPillButton.primary(
                label: '添加媒体源',
                icon: Icons.add_rounded,
                onPressed: () => _openEditor(),
              ),
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
                        style: KonataTheme.cardTitleStyle(p, fontSize: KonataTheme.fontSizeTitle),
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
                        padding: EdgeInsets.fromLTRB(padH, 0, padH, 14),
                        sliver: SliverToBoxAdapter(
                          child: RepaintBoundary(
                            child: _LiveScrapeProgressBanner(
                              onInspect: _openProgressDialog,
                              onDismiss: () =>
                                  setState(() => _bannerDismissed = true),
                            ),
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
                                  fontSize: KonataTheme.fontSizeTitle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          padH,
                          0,
                          padH,
                          28 + bottomClearance,
                        ),
                        sliver: SliverList.separated(
                          itemCount: sources.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, index) {
                            final source = sources[index];
                            final isScanningThis =
                                scanState.isRunning &&
                                scanState.sourceId == source.id;
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
              child: Text('加载媒体源失败: $err', style: TextStyle(color: p.danger)),
            ),
          ),
        ),
      ],
    );
  }
}

class _LiveScrapeProgressBanner extends ConsumerWidget {
  const _LiveScrapeProgressBanner({
    required this.onInspect,
    required this.onDismiss,
  });

  final VoidCallback onInspect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(scrapeControllerProvider);
    return ScrapeProgressBanner(
      progress: progress,
      onInspect: onInspect,
      onCancel: progress.isRunning && !progress.cancelRequested
          ? () => ref.read(scrapeControllerProvider.notifier).requestCancel()
          : null,
      onDismiss: progress.isRunning ? null : onDismiss,
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
    final kindIcon = switch (source.kind) {
      MediaSourceKind.local => Icons.folder_outlined,
      MediaSourceKind.webdav => Icons.cloud_outlined,
      MediaSourceKind.smb => Icons.dns_outlined,
    };

    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final iconSize = isAndroid ? KonataAdaptiveTokens.touchTarget : 34.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPickFolders,
      child: KonataSurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        enableHover: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final infoRow = Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: p.softFill,
                    borderRadius: KonataTheme.borderRadiusPill,
                    border: Border.all(color: p.hairline, width: 0.9),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(kindIcon, size: 13.5, color: p.textSecondary),
                      const SizedBox(width: 5),
                      Text(
                        kindLabel,
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: KonataTheme.fontSizeCaption,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: KonataTheme.fontSizeTitleSm,
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
                          fontSize: KonataTheme.fontSizeBodyXs,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );

            final actionWidgets = <Widget>[
              KonataPillButton.primary(
                label: scanning ? '扫描中...' : '选择目录',
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
                fixedSize: iconSize,
                onTap: onEdit,
              ),
              KonataCapsuleIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: '删除',
                color: p.textSecondary,
                size: 18,
                fixedSize: iconSize,
                onTap: onDelete,
              ),
            ];

            if (constraints.maxWidth >= 560) {
              return Row(
                children: [
                  Expanded(child: infoRow),
                  const SizedBox(width: 12),
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
  }
}
