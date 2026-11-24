import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_filter_prefs.dart';
import '../data/library_models.dart';
import '../providers.dart';
import '../state/library_controller.dart';
import 'delete_work_dialog.dart';
import 'hidden_works_dialog.dart';
import 'manual_match_dialog.dart';
import 'poster_card.dart';
import 'review_dialog.dart';
import 'source_files_review_dialog.dart';
import 'work_merge_target_dialog.dart';

/// 媒体库海报墙、多维检索筛选与作品管理主页面（三端自适应、零 `material.dart` 依赖）。
class LibraryPage extends ConsumerStatefulWidget {
  /// 构造媒体库主页面。
  const LibraryPage({
    super.key,
    this.slotContext,
    this.imageLoaderOverride,
  });

  /// 宿主通过扩展槽传入的上下文（桌面端携带顶栏实时 `arguments['searchQuery']`）。
  final ViewSlotContext? slotContext;

  /// 可选图像加载覆盖回调（供测试或自定义渲染场景直传字节）。
  final LibraryArtworkLoader? imageLoaderOverride;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final ScrollController _scrollController = ScrollController();
  Timer? _scrollCooldownTimer;
  bool _isFastScrolling = false;
  String? _lastHostQuery;

  String? get _hostSearchQuery {
    final raw = widget.slotContext?.arguments['searchQuery'];
    return raw is String ? raw : null;
  }

  bool get _hasExternalDesktopSearchBar {
    final args = widget.slotContext?.arguments;
    if (args == null || !args.containsKey('searchQuery')) return false;
    final platform = ref.read(featureLibraryDependenciesProvider).platform;
    return platform == KonataPlatform.windows &&
        MediaQuery.sizeOf(context).width >= 840;
  }

  @override
  void initState() {
    super.initState();
    _lastHostQuery = _hostSearchQuery;
    final initialHostQuery = _lastHostQuery;
    if (initialHostQuery != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(libraryControllerProvider).setSearchQuery(initialHostQuery);
      });
    }
  }

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextHostQuery = _hostSearchQuery;
    if (nextHostQuery != _lastHostQuery) {
      _lastHostQuery = nextHostQuery;
      if (nextHostQuery != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(libraryControllerProvider).setSearchQuery(nextHostQuery);
        });
      }
    }
  }

  @override
  void dispose() {
    _scrollCooldownTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification) {
      if (!_isFastScrolling) {
        _isFastScrolling = true;
      }
      _scrollCooldownTimer?.cancel();
      _scrollCooldownTimer = Timer(const Duration(milliseconds: 140), () {
        if (!mounted) return;
        _isFastScrolling = false;
        ref.read(libraryControllerProvider).setFastScrolling(false);
      });
    } else if (notification is ScrollEndNotification) {
      _scrollCooldownTimer?.cancel();
      _scrollCooldownTimer = Timer(const Duration(milliseconds: 140), () {
        if (!mounted) return;
        _isFastScrolling = false;
        ref.read(libraryControllerProvider).setFastScrolling(false);
      });
    }
    return false;
  }

  Future<void> _openCardContextMenu(
    BuildContext anchorContext,
    WorkLibraryItem item,
  ) async {
    final deps = ref.read(featureLibraryDependenciesProvider);
    final libraryController = ref.read(libraryControllerProvider);
    final mgmt = ref.read(workManagementControllerProvider);
    final work = item.work;

    final picked = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: const [
        KonataGlassMenuItem(
          value: 'detail',
          label: '打开详情',
          icon: Icons.open_in_new_rounded,
        ),
        KonataGlassMenuItem(
          value: 'files',
          label: '查看源文件',
          icon: Icons.description_outlined,
        ),
        KonataGlassMenuItem(
          value: 'match',
          label: '手动匹配纠偏',
          icon: Icons.manage_search_rounded,
        ),
        KonataGlassMenuItem(
          value: 'merge',
          label: '合并到其他作品',
          icon: Icons.merge_rounded,
        ),
        KonataGlassMenuItem(
          value: 'hide',
          label: '从海报墙隐藏',
          icon: Icons.visibility_off_outlined,
        ),
        KonataGlassMenuItem(
          value: 'delete',
          label: '从媒体库移出',
          icon: Icons.delete_outline_rounded,
          isDanger: true,
        ),
      ],
    );
    if (!mounted || picked == null) return;

    switch (picked) {
      case 'detail':
        await deps.navigator.openWorkDetail(WorkId.trusted(work.id));
      case 'files':
        await showSourceFilesReviewDialog(context, work: work);
      case 'match':
        await showManualMatchDialog(context, work: work);
      case 'merge':
        final target = await showWorkMergeTargetDialog(
          context,
          sourceWork: work,
          candidates: libraryController.allVisibleItems,
        );
        if (!mounted || target == null) return;
        final outcome = await mgmt.mergeWorkIntoTarget(
          sourceWorkId: work.id,
          targetWorkId: target.id,
        );
        if (!mounted) return;
        showKonataToast(
          context,
          '已将 ${outcome.movedVariantCount} 个文件并入「${outcome.targetWork.title}」',
        );
      case 'hide':
        await mgmt.setWorkHidden(work.id, hidden: true, keepHidden: true);
        if (!mounted) return;
        showKonataToast(context, '已隐藏「${work.title}」');
      case 'delete':
        final confirm = await showDeleteWorkDialog(context, work: work);
        if (!mounted || confirm == null) return;
        await mgmt.deleteWork(
          work.id,
          ignoreFolderOnRescan: confirm.ignoreFolderOnRescan,
        );
        if (!mounted) return;
        showKonataToast(context, '已移出「${work.title}」');
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(featureLibraryDependenciesProvider);
    final controller = ref.watch(libraryControllerProvider);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final horizontalPad = screenWidth < 600 ? 14.0 : 28.0;
    final bottomClearance = KonataBottomClearanceScope.of(context);
    final showInlineSearch = !_hasExternalDesktopSearchBar;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.displayedItems;
        final totalCount = controller.allVisibleItems.length;
        final reviewCount = controller.reviewWorks.length;
        final hiddenCount = controller.hiddenWorks.length;
        final prefs = controller.prefs;

        return Padding(
          padding: EdgeInsets.fromLTRB(horizontalPad, 14, horizontalPad, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdaptiveActionHeader(
                title: '媒体库',
                badge: totalCount == 0
                    ? null
                    : KonataSpecBadge(
                        label: items.length == totalCount
                            ? '$totalCount 部'
                            : '${items.length} / $totalCount 部',
                      ),
                searchQuery: showInlineSearch ? controller.searchQuery : null,
                onSearchChanged: showInlineSearch
                    ? controller.setSearchQuery
                    : null,
                searchHint: '搜标题 / 压制组 / tmdb: / bgm:',
                primaryActions: [
                  if (reviewCount > 0)
                    AdaptiveHeaderAction(
                      buttonKey: const Key('library_review_button'),
                      icon: Icons.rule_folder_outlined,
                      label: '待复核 ($reviewCount)',
                      highlighted: true,
                      onPressed: () => showReviewDialog(context),
                    ),
                ],
                overflowActions: [
                  AdaptiveHeaderAction(
                    buttonKey: const Key('library_review_overflow_action'),
                    icon: Icons.rule_folder_outlined,
                    label: reviewCount > 0 ? '待复核 ($reviewCount)' : '待复核中心',
                    onPressed: () => showReviewDialog(context),
                  ),
                  AdaptiveHeaderAction(
                    buttonKey: const Key('library_hidden_button'),
                    icon: Icons.visibility_off_outlined,
                    label: hiddenCount > 0 ? '已隐藏 ($hiddenCount)' : '已隐藏作品',
                    onPressed: () => showHiddenWorksDialog(context),
                  ),
                  AdaptiveHeaderAction(
                    buttonKey: const Key('library_sources_shortcut'),
                    icon: Icons.folder_special_outlined,
                    label: '管理媒体源',
                    onPressed: () => deps.navigator.switchNavSection('sources'),
                  ),
                ],
              ),
              if (totalCount > 0 || prefs.hasActiveFilters) ...[
                const SizedBox(height: 10),
                _FilterAndSortBar(
                  controller: controller,
                  prefs: prefs,
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: _buildWallBody(
                  context,
                  deps: deps,
                  controller: controller,
                  items: items,
                  totalCount: totalCount,
                  dpr: dpr,
                  textScaler: textScaler,
                  bottomPadding: 28 + bottomClearance,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWallBody(
    BuildContext context, {
    required FeatureLibraryDependencies deps,
    required LibraryController controller,
    required List<WorkLibraryItem> items,
    required int totalCount,
    required double dpr,
    required TextScaler textScaler,
    required double bottomPadding,
  }) {
    final p = context.palette;

    if (controller.isLoading && items.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }

    if (totalCount == 0) {
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
                    Icons.video_library_outlined,
                    size: 42,
                    color: p.accent,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '媒体库暂时还没有番剧作品',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    controller.reviewWorks.isNotEmpty
                        ? '检测到有 ${controller.reviewWorks.length} 部扫描到的条目等待人工确认，也可继续添加或扫描媒体源。'
                        : '请先在媒体源页添加本地磁盘、WebDAV 或 SMB 目录并执行扫库刮削。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: p.textSecondary,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      KonataPillButton.primary(
                        key: const Key('library_empty_go_sources'),
                        label: '前往媒体源',
                        icon: Icons.folder_open_rounded,
                        onPressed: () =>
                            deps.navigator.switchNavSection('sources'),
                      ),
                      if (controller.reviewWorks.isNotEmpty)
                        KonataPillButton.secondary(
                          label: '处理待复核 (${controller.reviewWorks.length})',
                          icon: Icons.rule_folder_outlined,
                          onPressed: () => showReviewDialog(context),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_alt_off_outlined, size: 36, color: p.textMuted),
            const SizedBox(height: 10),
            Text(
              '没有符合当前搜索或筛选条件的番剧',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            KonataPillButton.secondary(
              label: '重置所有筛选与搜索',
              compact: true,
              onPressed: () => controller.resetFilters(clearSearch: true),
            ),
          ],
        ),
      );
    }

    final enableKeepAlive =
        deps.platform == KonataPlatform.windows &&
        controller.shouldEnableDesktopKeepAlive;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: KonataDraggableScrollbar(
        controller: _scrollController,
        builder: (context, scrollCtrl) => AdaptiveCardGrid(
          controller: scrollCtrl,
          padding: EdgeInsets.only(bottom: bottomPadding, right: 6),
          itemCount: items.length,
          addAutomaticKeepAlives: enableKeepAlive,
          itemBuilder: (context, index, cardWidth) {
            final item = items[index];
            return PosterCard(
              key: ValueKey<String>(item.work.id),
              item: item,
              cardWidth: cardWidth,
              devicePixelRatio: dpr,
              textScaler: textScaler,
              suppressHoverCheck: () => _isFastScrolling,
              imageLoaderOverride: widget.imageLoaderOverride,
              onTap: () =>
                  deps.navigator.openWorkDetail(WorkId.trusted(item.work.id)),
              onOpenMenu: (anchorCtx) => _openCardContextMenu(anchorCtx, item),
            );
          },
        ),
      ),
    );
  }
}

class _FilterAndSortBar extends StatelessWidget {
  const _FilterAndSortBar({
    required this.controller,
    required this.prefs,
  });

  final LibraryController controller;
  final LibraryPrefsState prefs;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final years = controller.availableYears;
    final groups = controller.availableReleaseGroups;
    final sources = controller.sources;
    String? selectedSourceLabel;
    if (prefs.sourceIdFilter != null) {
      for (final s in sources) {
        if (s.id == prefs.sourceIdFilter) {
          selectedSourceLabel = s.label;
          break;
        }
      }
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Builder(
          builder: (anchorContext) => KonataPillButton.secondary(
            label: switch (prefs.sortMode) {
              LibrarySortMode.title => '排序：拼音标题',
              LibrarySortMode.year => '排序：发行年份',
              LibrarySortMode.score => '排序：社区评分',
              LibrarySortMode.recent => '排序：最近更新',
            },
            icon: Icons.sort_rounded,
            compact: true,
            onPressed: () async {
              final next = await showKonataGlassMenu<LibrarySortMode>(
                anchorContext: anchorContext,
                items: const [
                  KonataGlassMenuItem(
                    value: LibrarySortMode.title,
                    label: '按拼音标题',
                    icon: Icons.sort_by_alpha_rounded,
                  ),
                  KonataGlassMenuItem(
                    value: LibrarySortMode.year,
                    label: '按发行年份',
                    icon: Icons.calendar_today_outlined,
                  ),
                  KonataGlassMenuItem(
                    value: LibrarySortMode.score,
                    label: '按评分高低',
                    icon: Icons.star_outline_rounded,
                  ),
                  KonataGlassMenuItem(
                    value: LibrarySortMode.recent,
                    label: '按最近更新',
                    icon: Icons.update_rounded,
                  ),
                ],
              );
              if (next != null) controller.setSortMode(next);
            },
          ),
        ),
        KonataCapsuleIconButton(
          icon: prefs.sortOrder == LibrarySortOrder.ascending
              ? Icons.arrow_upward_rounded
              : Icons.arrow_downward_rounded,
          tooltip: prefs.sortOrder == LibrarySortOrder.ascending
              ? '当前升序（点击切为降序）'
              : '当前降序（点击切为升序）',
          color: p.textSecondary,
          size: 16,
          padding: const EdgeInsets.all(7),
          onTap: controller.toggleSortOrder,
        ),
        if (years.isNotEmpty)
          Builder(
            builder: (anchorContext) => KonataPillButton.ghost(
              label: prefs.yearFilter == null ? '年份' : '${prefs.yearFilter} 年',
              icon: Icons.event_outlined,
              compact: true,
              borderColor: prefs.yearFilter == null ? null : p.accent,
              onPressed: () async {
                final picked = await showKonataGlassMenu<int?>(
                  anchorContext: anchorContext,
                  items: [
                    const KonataGlassMenuItem<int?>(
                      value: -1,
                      label: '全部年份',
                    ),
                    for (final y in years.take(24))
                      KonataGlassMenuItem<int?>(value: y, label: '$y 年'),
                  ],
                );
                if (picked == null) return;
                controller.setYearFilter(picked == -1 ? null : picked);
              },
            ),
          ),
        if (groups.isNotEmpty)
          Builder(
            builder: (anchorContext) => KonataPillButton.ghost(
              label: prefs.releaseGroupFilter ?? '压制组',
              icon: Icons.subtitles_outlined,
              compact: true,
              borderColor: prefs.releaseGroupFilter == null ? null : p.accent,
              onPressed: () async {
                final picked = await showKonataGlassMenu<String>(
                  anchorContext: anchorContext,
                  items: [
                    const KonataGlassMenuItem<String>(
                      value: '__ALL__',
                      label: '全部压制组',
                    ),
                    for (final g in groups.take(30))
                      KonataGlassMenuItem<String>(value: g, label: g),
                  ],
                );
                if (picked == null) return;
                controller.setReleaseGroupFilter(
                  picked == '__ALL__' ? null : picked,
                );
              },
            ),
          ),
        if (sources.length > 1)
          Builder(
            builder: (anchorContext) => KonataPillButton.ghost(
              label: selectedSourceLabel ?? '媒体源',
              icon: Icons.storage_outlined,
              compact: true,
              borderColor: prefs.sourceIdFilter == null ? null : p.accent,
              onPressed: () async {
                final picked = await showKonataGlassMenu<String>(
                  anchorContext: anchorContext,
                  items: [
                    const KonataGlassMenuItem<String>(
                      value: '__ALL__',
                      label: '全部媒体源',
                    ),
                    for (final s in sources)
                      KonataGlassMenuItem<String>(value: s.id, label: s.label),
                  ],
                );
                if (picked == null) return;
                controller.setSourceIdFilter(
                  picked == '__ALL__' ? null : picked,
                );
              },
            ),
          ),
        KonataPillButton.ghost(
          label: '多版本',
          icon: Icons.layers_outlined,
          compact: true,
          borderColor: prefs.onlyMultiSource ? p.accent : null,
          onPressed: () => controller.setOnlyMultiSource(!prefs.onlyMultiSource),
        ),
        if (prefs.hasActiveFilters)
          KonataPillButton.ghost(
            label: '重置',
            icon: Icons.close_rounded,
            compact: true,
            onPressed: () => controller.resetFilters(),
          ),
      ],
    );
  }
}
