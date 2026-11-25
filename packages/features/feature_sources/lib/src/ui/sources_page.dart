import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/scrape_task_phase.dart';
import '../state/sources_controller.dart';
import 'delete_source_dialog.dart';
import 'scan_progress_dialog.dart';
import 'scrape_progress_banner.dart';
import 'source_card.dart';
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
  String? _testingSourceId;
  bool _bannerDismissed = false;

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
      sourceLabel: source.label,
      initialSelected: sourcesController.readIncludedFolders(source.id),
      onForceScanSelected: (selectedPaths) async {
        if (!mounted) return;
        await sourcesController.updateIncludedFolders(source.id, selectedPaths);
        if (!mounted) return;
        await _scanSingleSource(
          source,
          scanRootsOverride: selectedPaths,
          forceFullRescan: true,
          openProgressDialog: true,
        );
      },
      onScanSelected: (selectedPaths) async {
        if (!mounted) return;
        await sourcesController.updateIncludedFolders(source.id, selectedPaths);
        if (!mounted) return;
        await _scanSingleSource(
          source,
          scanRootsOverride: selectedPaths,
          openProgressDialog: true,
        );
      },
    );
    if (!mounted || selected == null) return;
    await sourcesController.updateIncludedFolders(source.id, selected);
  }

  Future<void> _testSource(MediaSource source) async {
    if (_testingSourceId != null) return;
    setState(() => _testingSourceId = source.id);
    final res = await ref
        .read(sourcesControllerProvider)
        .testConnection(
          sourceId: source.id,
          kind: source.kind,
          location: source.location,
          username: source.username,
        );
    if (!mounted) return;
    setState(() {
      _testingSourceId = null;
    });
    showKonataToast(
      context,
      res.success ? '「${source.label}」${res.message}' : res.message,
      isError: !res.success,
    );
  }

  Future<void> _scanSingleSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
    bool forceFullRescan = false,
    bool openProgressDialog = false,
  }) async {
    final scrapeController = ref.read(sourceScrapeControllerProvider);
    if (scrapeController.isBusy) {
      await showScanProgressDialog(context, focusSourceId: source.id);
      return;
    }

    final deps = ref.read(featureSourcesDependenciesProvider);
    final proceed = await confirmScrapeWithoutTmdbIfNeeded(
      context,
      isTmdbConfigured:
          deps.httpClient.config.credentialKind != TmdbCredentialKind.none,
      onOpenNetworkSettings: () =>
          deps.navigator.openSettings(sectionId: 'network'),
    );
    if (!mounted || !proceed) return;

    setState(() => _bannerDismissed = false);
    if (openProgressDialog) {
      // 不阻塞等待弹窗关闭，后台扫库状态机与进度弹窗实时联动。
      unawaited(showScanProgressDialog(context, focusSourceId: source.id));
    }

    final phase = await scrapeController.scanSource(
      source,
      scanRootsOverride: scanRootsOverride,
      forceFullRescan: forceFullRescan,
    );
    if (!mounted) return;
    if (phase is ScrapeCompletedPhase) {
      showKonataToast(
        context,
        '「${source.label}」扫库完成：匹配 ${phase.matchedWorks} · 待复核 ${phase.reviewWorks}',
      );
    } else if (phase is ScrapeFailedPhase) {
      showKonataToast(context, phase.errorMessage ?? '扫库失败', isError: true);
    }
  }

  Future<void> _deleteSource(MediaSource source) async {
    final confirmed = await showDeleteSourceDialog(context, source: source);
    if (!mounted || !confirmed) return;
    await ref.read(sourcesControllerProvider).deleteSource(source.id);
    if (!mounted) return;
    showKonataToast(context, '已移除媒体源「${source.label}」（原始媒体文件未受影响）');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final deps = ref.watch(featureSourcesDependenciesProvider);
    final scrapeController = ref.watch(sourceScrapeControllerProvider);
    final sourcesAsync = ref.watch(mediaSourcesStreamProvider);
    final statsMap =
        ref.watch(sourceStatsStreamProvider).value ??
        const <String, SourceLibraryStats>{};
    final sources = friendlySourceLabels(
      sourcesAsync.value ?? const <MediaSource>[],
    );
    final isLoading = sourcesAsync.isLoading && !sourcesAsync.hasValue;
    final bottomClearance = KonataBottomClearanceScope.of(context);
    final screenW = MediaQuery.sizeOf(context).width;
    final padH = screenW < 620.0
        ? KonataAdaptiveTokens.horizontalInset
        : KonataTheme.pageHorizontalPadding;
    final tmdbMissing =
        deps.httpClient.config.credentialKind == TmdbCredentialKind.none;

    return ListenableBuilder(
      listenable: scrapeController,
      builder: (context, _) {
        final phase = scrapeController.phase;
        if (_bannerDismissed && phase.isActive) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _bannerDismissed) {
              setState(() => _bannerDismissed = false);
            }
          });
        }
        final showBanner = phase is! ScrapeIdlePhase && !_bannerDismissed;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AdaptiveActionHeader(
              title: '媒体源管理',
              primaryActions: [
                AdaptiveHeaderAction(
                  buttonKey: const Key('sources_add_button'),
                  icon: Icons.add_rounded,
                  label: '添加媒体源',
                  highlighted: true,
                  preserveWideWidgetOnNarrow: true,
                  wideWidget: KonataPillButton.primary(
                    key: const Key('sources_add_button'),
                    label: '添加媒体源',
                    icon: Icons.add_rounded,
                    compact: true,
                    onPressed: _openAddSource,
                  ),
                  onPressed: _openAddSource,
                ),
              ],
            ),
            Expanded(
              child: _buildBody(
                context,
                p: p,
                sources: sources,
                statsMap: statsMap,
                phase: phase,
                isLoading: isLoading,
                hasLoadError: sourcesAsync.hasError,
                loadError: sourcesAsync.error,
                tmdbMissing: tmdbMissing,
                showBanner: showBanner,
                padH: padH,
                bottomClearance: bottomClearance,
                onOpenSettingsNetwork: () =>
                    deps.navigator.openSettings(sectionId: 'network'),
                onInspectProgress: () => showScanProgressDialog(
                  context,
                  focusSourceId: phase.sourceId,
                ),
                onCancelScan: scrapeController.cancelActiveScan,
                onDismissBanner: () {
                  setState(() => _bannerDismissed = true);
                  scrapeController.dismissTerminalBanner();
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required KonataPalette p,
    required List<MediaSource> sources,
    required Map<String, SourceLibraryStats> statsMap,
    required ScrapeTaskPhase phase,
    required bool isLoading,
    required bool hasLoadError,
    required Object? loadError,
    required bool tmdbMissing,
    required bool showBanner,
    required double padH,
    required double bottomClearance,
    required VoidCallback onOpenSettingsNetwork,
    required VoidCallback onInspectProgress,
    required VoidCallback onCancelScan,
    required VoidCallback onDismissBanner,
  }) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (hasLoadError && sources.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: padH),
          child: Text('加载媒体源失败: $loadError', style: TextStyle(color: p.danger)),
        ),
      );
    }

    if (sources.isEmpty && !showBanner && !tmdbMissing) {
      return _EmptySourcesState(onAddSource: _openAddSource);
    }

    return KonataDraggableScrollbar(
      controller: _scrollController,
      builder: (_, ctrl) => CustomScrollView(
        controller: ctrl,
        slivers: [
          if (tmdbMissing)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padH, 0, padH, 12),
              sliver: SliverToBoxAdapter(
                child: TmdbScrapeGuardBanner(
                  onConfigureTap: onOpenSettingsNetwork,
                ),
              ),
            ),
          if (showBanner)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padH, 0, padH, 14),
              sliver: SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: ScrapeProgressBanner(
                    phase: phase,
                    onInspectDetail: onInspectProgress,
                    onCancelScan: onCancelScan,
                    onDismissTerminal: onDismissBanner,
                  ),
                ),
              ),
            ),
          if (sources.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptySourcesState(onAddSource: _openAddSource),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padH, 0, padH, 28 + bottomClearance),
              sliver: SliverList.separated(
                itemCount: sources.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, index) {
                  final source = sources[index];
                  final isScanningThis =
                      phase.isActive && phase.sourceId == source.id;
                  return MediaSourceCard(
                    source: source,
                    stats: statsMap[source.id] ?? const SourceLibraryStats(),
                    testing: _testingSourceId == source.id,
                    scanning: isScanningThis,
                    anyScanning: phase.isActive,
                    onScan: () =>
                        _scanSingleSource(source, openProgressDialog: true),
                    onInspectPendingReview: () => showScanProgressDialog(
                      context,
                      focusSourceId: source.id,
                      initialTabIndex: 1,
                    ),
                    onTest: () => _testSource(source),
                    onPickFolders: () => _pickSourceFolders(source),
                    onEdit: () => _openEditSource(source),
                    onDelete: () => _deleteSource(source),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptySourcesState extends StatelessWidget {
  const _EmptySourcesState({required this.onAddSource});

  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open_rounded, size: 48, color: p.textMuted),
              const SizedBox(height: 12),
              Text(
                '尚未配置任何媒体源',
                style: KonataTheme.cardTitleStyle(
                  p,
                  fontSize: KonataTheme.fontSizeTitle,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '支持添加本地磁盘目录、WebDAV 网盘或局域网 SMB 共享。所有媒体源均严格只读，绝不修改或删除你的原始媒体文件。',
                textAlign: TextAlign.center,
                style: KonataTheme.captionStyle(
                  p,
                  fontSize: KonataTheme.fontSizeBodyXs,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 18),
              KonataPillButton.primary(
                label: '立即添加媒体源',
                icon: Icons.add_rounded,
                onPressed: onAddSource,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
