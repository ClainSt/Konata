import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/scrape_task_phase.dart';
import 'delete_source_dialog.dart';
import 'scan_progress_dialog.dart';
import 'scrape_progress_banner.dart';
import 'source_editor_dialog.dart';
import 'source_folder_picker_dialog.dart';
import 'tmdb_scrape_guard.dart';

/// 媒体源管理与扫库触发主页面（三端自适应、零 `material.dart` 依赖）。
class SourcesPage extends ConsumerStatefulWidget {
  /// 构造媒体源主页面。
  const SourcesPage({super.key});

  @override
  ConsumerState<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends ConsumerState<SourcesPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _openAddSource() async {
    final saved = await showSourceEditorDialog(context);
    if (!mounted || saved == null) return;
    showKonataToast(context, '已添加媒体源「${saved.label}」');
  }

  Future<void> _openEditSource(MediaSource source) async {
    final saved = await showSourceEditorDialog(context, existingSource: source);
    if (!mounted || saved == null) return;
    showKonataToast(context, '已保存媒体源「${saved.label}」');
  }

  Future<void> _pickSourceFolders(MediaSource source) async {
    final sourcesController = ref.read(sourcesControllerProvider);
    final selected = await showSourceFolderPickerDialog(
      context,
      sourceId: source.id,
      kind: source.kind,
      location: source.location,
      username: source.username,
      initialSelected: sourcesController.readIncludedFolders(source.id),
    );
    if (!mounted || selected == null) return;
    await sourcesController.updateIncludedFolders(source.id, selected);
    if (!mounted) return;
    showKonataToast(
      context,
      selected.isEmpty
          ? '「${source.label}」已切换为全盘根目录扫描'
          : '「${source.label}」已限定 ${selected.length} 个扫库子目录',
    );
  }

  Future<void> _testSource(MediaSource source) async {
    final res = await ref
        .read(sourcesControllerProvider)
        .testConnection(
          sourceId: source.id,
          kind: source.kind,
          location: source.location,
          username: source.username,
        );
    if (!mounted) return;
    showKonataToast(
      context,
      res.success ? '「${source.label}」${res.message}' : res.message,
      isError: !res.success,
    );
  }

  Future<void> _scanSingleSource(
    MediaSource source, {
    bool forceFullRescan = false,
  }) async {
    final deps = ref.read(featureSourcesDependenciesProvider);
    final proceed = await confirmScrapeWithoutTmdbIfNeeded(
      context,
      isTmdbConfigured:
          deps.httpClient.config.credentialKind != TmdbCredentialKind.none,
      onOpenNetworkSettings: () => deps.navigator.openSettings(
        sectionId: 'network',
      ),
    );
    if (!mounted || !proceed) return;

    final scrapeController = ref.read(sourceScrapeControllerProvider);
    final phase = await scrapeController.scanSource(
      source,
      forceFullRescan: forceFullRescan,
    );
    if (!mounted) return;
    if (phase is ScrapeCompletedPhase) {
      showKonataToast(
        context,
        '「${source.label}」扫库完成：匹配 ${phase.matchedWorks} · 待复核 ${phase.reviewWorks}',
      );
    } else if (phase is ScrapeFailedPhase) {
      showKonataToast(
        context,
        phase.errorMessage ?? '扫库失败',
        isError: true,
      );
    }
  }

  Future<void> _scanAllSources() async {
    final deps = ref.read(featureSourcesDependenciesProvider);
    final scrapeController = ref.read(sourceScrapeControllerProvider);
    if (scrapeController.isBusy) {
      await showScanProgressDialog(context);
      return;
    }

    final proceed = await confirmScrapeWithoutTmdbIfNeeded(
      context,
      isTmdbConfigured:
          deps.httpClient.config.credentialKind != TmdbCredentialKind.none,
      onOpenNetworkSettings: () => deps.navigator.openSettings(
        sectionId: 'network',
      ),
    );
    if (!mounted || !proceed) return;

    await scrapeController.scanAllSources();
  }

  Future<void> _deleteSource(MediaSource source) async {
    final confirmed = await showDeleteSourceDialog(context, source: source);
    if (!mounted || !confirmed) return;
    await ref.read(sourcesControllerProvider).deleteSource(source.id);
    if (!mounted) return;
    showKonataToast(context, '已从媒体库移除「${source.label}」');
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(featureSourcesDependenciesProvider);
    final scrapeController = ref.watch(sourceScrapeControllerProvider);
    final sourcesAsync = ref.watch(mediaSourcesStreamProvider);
    final sources = sourcesAsync.value ?? const <MediaSource>[];
    final isLoading = sourcesAsync.isLoading && !sourcesAsync.hasValue;
    final bottomClearance = KonataBottomClearanceScope.of(context);
    final horizontalPad = MediaQuery.sizeOf(context).width < 600 ? 16.0 : 28.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: scrapeController,
            builder: (context, _) => AdaptiveActionHeader(
              title: '媒体源',
              badge: sources.isEmpty
                  ? null
                  : KonataSpecBadge(label: '${sources.length} 个源'),
              primaryActions: [
                if (sources.isNotEmpty)
                  AdaptiveHeaderAction(
                    buttonKey: const Key('sources_scan_all_button'),
                    icon: Icons.radar_rounded,
                    label: scrapeController.isBusy ? '查看进度' : '全部扫描',
                    onPressed: _scanAllSources,
                  ),
                AdaptiveHeaderAction(
                  buttonKey: const Key('sources_add_button'),
                  icon: Icons.add_rounded,
                  label: '添加媒体源',
                  highlighted: true,
                  onPressed: _openAddSource,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (deps.httpClient.config.credentialKind == TmdbCredentialKind.none) ...[
            TmdbScrapeGuardBanner(
              onConfigureTap: () => deps.navigator.openSettings(
                sectionId: 'network',
              ),
            ),
            const SizedBox(height: 12),
          ],
          ListenableBuilder(
            listenable: scrapeController,
            builder: (context, _) {
              final phase = scrapeController.phase;
              if (phase is ScrapeIdlePhase) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ScrapeProgressBanner(
                  phase: phase,
                  onInspectDetail: () => showScanProgressDialog(
                    context,
                    focusSourceId: phase.sourceId,
                  ),
                  onCancelScan: scrapeController.cancelActiveScan,
                  onDismissTerminal: scrapeController.dismissTerminalBanner,
                ),
              );
            },
          ),
          Expanded(
            child: _buildBody(
              context,
              sources: sources,
              isLoading: isLoading,
              bottomPadding: 28 + bottomClearance,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required List<MediaSource> sources,
    required bool isLoading,
    required double bottomPadding,
  }) {
    final p = context.palette;
    if (isLoading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (sources.isEmpty) {
      return SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: KonataSurfaceCard(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.drive_folder_upload_outlined,
                    size: 42,
                    color: p.accent,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '尚未添加任何动画媒体源',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '支持添加本地磁盘文件夹、WebDAV 网盘或局域网 SMB 共享目录。所有媒体源均以严格只读方式索引，绝不改写你的原始文件。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: p.textSecondary,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 18),
                  KonataPillButton.primary(
                    label: '立即添加媒体源',
                    icon: Icons.add_rounded,
                    onPressed: _openAddSource,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return KonataDraggableScrollbar(
      controller: _scrollController,
      builder: (context, scrollCtrl) => ListView.separated(
        controller: scrollCtrl,
        padding: EdgeInsets.only(bottom: bottomPadding),
        itemCount: sources.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _MediaSourceCard(
          source: sources[index],
          onEdit: () => _openEditSource(sources[index]),
          onPickFolders: () => _pickSourceFolders(sources[index]),
          onTestConnection: () => _testSource(sources[index]),
          onScan: () => _scanSingleSource(sources[index]),
          onForceRescan: () => _scanSingleSource(
            sources[index],
            forceFullRescan: true,
          ),
          onDelete: () => _deleteSource(sources[index]),
        ),
      ),
    );
  }
}

class _MediaSourceCard extends ConsumerWidget {
  const _MediaSourceCard({
    required this.source,
    required this.onEdit,
    required this.onPickFolders,
    required this.onTestConnection,
    required this.onScan,
    required this.onForceRescan,
    required this.onDelete,
  });

  final MediaSource source;
  final VoidCallback onEdit;
  final VoidCallback onPickFolders;
  final VoidCallback onTestConnection;
  final VoidCallback onScan;
  final VoidCallback onForceRescan;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final sourcesController = ref.watch(sourcesControllerProvider);
    final scrapeController = ref.watch(sourceScrapeControllerProvider);
    final ignoredAsync = ref.watch(ignoredFoldersStreamProvider(source.id));
    final ignoredFolders = ignoredAsync.value ?? const <String>[];
    final compact = MediaQuery.sizeOf(context).width < 600;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        sourcesController,
        scrapeController,
      ]),
      builder: (context, _) {
        final isScanningThis =
            scrapeController.phase.isActive &&
            scrapeController.phase.sourceId == source.id;
        final isAnyBusy = scrapeController.isBusy;
        final includedFolders = sourcesController.readIncludedFolders(
          source.id,
        );
        final lastScannedAt = sourcesController.readLastScannedAt(source.id);

        return KonataSurfaceCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ProtocolBadge(kind: source.kind),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          source.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: p.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          source.location,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SourceMoreMenuButton(
                    onEdit: onEdit,
                    onPickFolders: onPickFolders,
                    onTestConnection: onTestConnection,
                    onForceRescan: isAnyBusy ? null : onForceRescan,
                    onDelete: onDelete,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  KonataSpecBadge(
                    icon: Icons.account_tree_outlined,
                    label: includedFolders.isEmpty
                        ? '全盘根目录'
                        : '已限定 ${includedFolders.length} 个目录',
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
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: p.elevatedSurface.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '已忽略目录 (${ignoredFolders.length})',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: p.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final folder in ignoredFolders)
                            InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: () => ref
                                  .read(sourcesControllerProvider)
                                  .removeIgnoredFolder(source.id, folder),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: p.softFill,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: p.hairline),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 220,
                                      ),
                                      child: Text(
                                        folder,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
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
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: compact ? WrapAlignment.start : WrapAlignment.end,
                children: [
                  KonataPillButton.ghost(
                    label: '范围',
                    icon: Icons.folder_copy_outlined,
                    compact: true,
                    onPressed: onPickFolders,
                  ),
                  KonataPillButton.ghost(
                    label: '测试',
                    icon: Icons.wifi_tethering_rounded,
                    compact: true,
                    onPressed: onTestConnection,
                  ),
                  KonataPillButton.secondary(
                    label: '编辑',
                    icon: Icons.edit_outlined,
                    compact: true,
                    onPressed: onEdit,
                  ),
                  KonataPillButton.primary(
                    label: isScanningThis ? '查看进度' : '扫库刮削',
                    icon: isScanningThis
                        ? Icons.hourglass_top_rounded
                        : Icons.radar_rounded,
                    compact: true,
                    onPressed: isScanningThis
                        ? () => showScanProgressDialog(
                            context,
                            focusSourceId: source.id,
                          )
                        : (isAnyBusy ? null : onScan),
                  ),
                ],
              ),
            ],
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

class _ProtocolBadge extends StatelessWidget {
  const _ProtocolBadge({required this.kind});

  final MediaSourceKind kind;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (kind) {
      MediaSourceKind.local => ('本地', Icons.folder_rounded),
      MediaSourceKind.webdav => ('WebDAV', Icons.cloud_rounded),
      MediaSourceKind.smb => ('SMB', Icons.dns_rounded),
    };
    return KonataSpecBadge(
      label: label,
      icon: icon,
      highlighted: true,
    );
  }
}

class _SourceMoreMenuButton extends StatelessWidget {
  const _SourceMoreMenuButton({
    required this.onEdit,
    required this.onPickFolders,
    required this.onTestConnection,
    required this.onForceRescan,
    required this.onDelete,
  });

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
        padding: const EdgeInsets.all(6),
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
