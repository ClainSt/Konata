import 'dart:async';
import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import '../state/library_controller.dart';
import 'delete_work_dialog.dart';
import 'hidden_works_dialog.dart';
import 'library_header_bar.dart';
import 'manual_match_dialog.dart';
import 'poster_card.dart';
import 'review_dialog.dart';
import 'source_files_review_dialog.dart';
import 'work_merge_target_dialog.dart';

/// 媒体库全部作品海报墙页面组件。
class LibraryPage extends ConsumerStatefulWidget {
  /// 创建媒体库海报墙页面。
  const LibraryPage({super.key, this.slotContext, this.imageLoaderOverride});

  /// 宿主视图槽位上下文，可接收顶部搜索栏注入的搜索词参数。
  final ViewSlotContext? slotContext;

  /// 可选封面字节加载器覆盖，供单元测试注入模拟封面数据。
  final LibraryArtworkLoader? imageLoaderOverride;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  Timer? _scrollSettleTimer;
  bool _isFastScrolling = false;
  bool _searchExpanded = false;
  bool _filtersExpanded = false;

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
    final initialHostQuery = _hostSearchQuery;
    if (initialHostQuery != null && initialHostQuery.isNotEmpty) {
      _searchController.text = initialHostQuery;
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
    final prevRaw = oldWidget.slotContext?.arguments['searchQuery'];
    final prevHostQuery = prevRaw is String ? prevRaw : null;
    if (nextHostQuery != prevHostQuery && nextHostQuery != null) {
      if (_searchController.text != nextHostQuery) {
        _searchController.text = nextHostQuery;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(libraryControllerProvider).setSearchQuery(nextHostQuery);
      });
    }
  }

  @override
  void dispose() {
    _scrollSettleTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _openSearch() {
    final controller = ref.read(libraryControllerProvider);
    if (_searchController.text != controller.searchQuery) {
      _searchController.text = controller.searchQuery;
    }
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _closeSearch({bool clearQuery = false}) {
    if (clearQuery) {
      _searchController.clear();
      ref.read(libraryControllerProvider).setSearchQuery('');
    }
    _searchFocusNode.unfocus();
    setState(() => _searchExpanded = false);
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      if (!_isFastScrolling) {
        setState(() => _isFastScrolling = true);
        ref.read(libraryControllerProvider).setFastScrolling(true);
      }
      _scrollSettleTimer?.cancel();
      _scrollSettleTimer = Timer(const Duration(milliseconds: 140), () {
        if (!mounted) return;
        setState(() => _isFastScrolling = false);
        ref.read(libraryControllerProvider).setFastScrolling(false);
      });
    } else if (notification is ScrollEndNotification) {
      _scrollSettleTimer?.cancel();
      _scrollSettleTimer = Timer(const Duration(milliseconds: 60), () {
        if (!mounted) return;
        setState(() => _isFastScrolling = false);
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

    final action = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: const <KonataGlassMenuItem<String>>[
        KonataGlassMenuItem<String>(
          value: 'detail',
          label: '查看详情',
          icon: Icons.open_in_new_rounded,
        ),
        KonataGlassMenuItem<String>(
          value: 'rematch',
          label: '重新自动匹配',
          icon: Icons.auto_awesome_outlined,
        ),
        KonataGlassMenuItem<String>(
          value: 'match',
          label: '手动匹配元数据',
          icon: Icons.search_rounded,
        ),
        KonataGlassMenuItem<String>(
          value: 'files',
          label: '查看源文件与拆分',
          icon: Icons.video_library_outlined,
        ),
        KonataGlassMenuItem<String>(
          value: 'merge',
          label: '并入其他作品',
          icon: Icons.merge_type_rounded,
        ),
        KonataGlassMenuItem<String>(
          value: 'hide',
          label: '隐藏此作品',
          icon: Icons.visibility_off_outlined,
        ),
        KonataGlassMenuItem<String>(
          value: 'delete',
          label: '移出媒体库',
          icon: Icons.delete_outline_rounded,
          isDanger: true,
        ),
      ],
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'detail':
        await deps.navigator.openWorkDetail(WorkId.trusted(work.id));
      case 'rematch':
        try {
          final result = await mgmt.rematchReviewWork(work.id);
          await libraryController.reload();
          if (!mounted) return;
          switch (result.outcome) {
            case RematchWorkOutcome.matched:
            case RematchWorkOutcome.autoMerged:
              showKonataToast(context, '已重新匹配并更新元数据');
            case RematchWorkOutcome.needsReview:
              showKonataToast(context, '已更新候选列表，建议前往待复核中心确认');
            case RematchWorkOutcome.unmatched:
              showKonataToast(context, '未检索到更高置信候选，可使用手动匹配');
            case RematchWorkOutcome.networkError:
              showKonataToast(
                context,
                result.errorMessage ?? '网络波动导致自动匹配失败',
                isError: true,
              );
          }
        } catch (err) {
          if (!mounted) return;
          showKonataToast(context, '重新匹配失败：$err', isError: true);
        }
      case 'files':
        await showSourceFilesReviewDialog(context, work: work);
      case 'match':
        await showManualMatchDialog(context, work: work);
      case 'merge':
        final selection = await showWorkMergeSelectionDialog(
          context,
          sourceWork: work,
        );
        if (!mounted || selection == null) return;
        try {
          final outcome = await mgmt.mergeWorkIntoTarget(
            sourceWorkId: work.id,
            targetWorkId: selection.targetWork.id,
            categoryMode: selection.categoryMode,
          );
          await libraryController.reload();
          if (!mounted) return;
          showKonataToast(
            context,
            '已并入「${outcome.targetWork.title}」（迁移 ${outcome.movedVariantCount} 个文件）',
          );
        } catch (err) {
          if (!mounted) return;
          showKonataToast(context, '合并作品失败：$err', isError: true);
        }
      case 'hide':
        await mgmt.setWorkHidden(work.id, hidden: true);
        await libraryController.reload();
        if (!mounted) return;
        showKonataToast(context, '已隐藏「${work.title}」，可在右上角隐藏列表恢复');
      case 'delete':
        final confirm = await showDeleteWorkDialog(context, work: work);
        if (!mounted || confirm == null) return;
        await mgmt.deleteWork(
          work.id,
          ignoreFolderOnRescan: confirm.ignoreFolderOnRescan,
        );
        await libraryController.reload();
        if (!mounted) return;
        showKonataToast(context, '已从媒体库移除「${work.title}」（磁盘源文件已保留）');
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(featureLibraryDependenciesProvider);
    final controller = ref.watch(libraryControllerProvider);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compact =
        KonataAdaptiveTokens.isAndroid ||
        deps.platform == KonataPlatform.androidPhone ||
        screenWidth < KonataAdaptiveTokens.tabletBreakpoint;
    final horizontalPad = compact
        ? KonataAdaptiveTokens.horizontalInset
        : KonataTheme.pageHorizontalPadding;
    final topPad = compact ? 8.0 : KonataTheme.pageHeaderTopSpacing;
    final bottomHeaderPad = compact ? 10.0 : KonataTheme.pageHeaderBottomSpacing;
    final bottomClearance = KonataBottomClearanceScope.of(context);
    final gridBottomPad = math.max(
      compact ? 18.0 : 28.0,
      bottomClearance + 16.0,
    );

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.displayedItems;
        final totalCount = controller.allVisibleItems.length;
        final showFilterStrip =
            _filtersExpanded || controller.prefs.hasActiveFilters;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPad,
                topPad,
                horizontalPad,
                showFilterStrip ? 8 : bottomHeaderPad,
              ),
              child: LibraryHeaderBar(
                compact: compact,
                displayedCount: items.length,
                totalCount: totalCount,
                hiddenCount: controller.hiddenWorks.length,
                reviewCount: controller.reviewWorks.length,
                hasQuery: controller.searchQuery.trim().isNotEmpty,
                hasActiveFilters: controller.prefs.hasActiveFilters,
                showSearchButton: !_hasExternalDesktopSearchBar,
                searchExpanded: _searchExpanded && !_hasExternalDesktopSearchBar,
                filtersExpanded: showFilterStrip,
                searchController: _searchController,
                searchFocusNode: _searchFocusNode,
                onOpenSearch: _openSearch,
                onCloseSearch: () => _closeSearch(clearQuery: true),
                onSearchChanged: controller.setSearchQuery,
                onToggleFilters: () {
                  setState(() => _filtersExpanded = !_filtersExpanded);
                },
                onOpenHidden: () => showHiddenWorksDialog(context),
                onOpenReview: () => showReviewDialog(context),
              ),
            ),
            AnimatedSize(
              duration: KonataTheme.motionFast,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: showFilterStrip
                  ? Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPad,
                        0,
                        horizontalPad,
                        bottomHeaderPad,
                      ),
                      child: LibraryFilterSortStrip(
                        controller: controller,
                        compact: compact,
                        onClearAll: () {
                          _searchController.clear();
                          controller.resetFilters(clearSearch: true);
                          setState(() => _filtersExpanded = false);
                        },
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: _buildWallBody(
                context,
                deps: deps,
                controller: controller,
                items: items,
                compact: compact,
                horizontalPad: horizontalPad,
                gridBottomPad: gridBottomPad,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildWallBody(
    BuildContext context, {
    required FeatureLibraryDependencies deps,
    required LibraryController controller,
    required List<WorkLibraryItem> items,
    required bool compact,
    required double horizontalPad,
    required double gridBottomPad,
  }) {
    final p = context.palette;

    if (controller.isLoading && controller.allVisibleItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: p.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text('正在加载媒体库…', style: KonataTheme.captionStyle(p)),
          ],
        ),
      );
    }

    if (items.isEmpty) {
      final hasAnyVisible = controller.allVisibleItems.isNotEmpty;
      final reviewCount = controller.reviewWorks.length;
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            horizontalPad,
            24,
            horizontalPad,
            gridBottomPad,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  hasAnyVisible
                      ? Icons.search_off_rounded
                      : Icons.movie_filter_outlined,
                  size: 52,
                  color: p.textMuted,
                ),
                const SizedBox(height: 14),
                Text(
                  hasAnyVisible ? '未找到匹配的作品' : '媒体库暂无作品',
                  textAlign: TextAlign.center,
                  style: KonataTheme.cardTitleStyle(
                    p,
                    fontSize: KonataTheme.fontSizeTitleLg,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  hasAnyVisible
                      ? '请尝试调整搜索关键词、年份或压制组筛选条件'
                      : reviewCount > 0
                      ? '当前共有 $reviewCount 部新扫描作品等待人工复核绑定，确认后即可展示在海报墙'
                      : '请先前往媒体源添加本机目录或远程存储并发起扫描导入',
                  textAlign: TextAlign.center,
                  style: KonataTheme.captionStyle(
                    p,
                    fontSize: KonataTheme.fontSizeBodySm,
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    if (hasAnyVisible)
                      KonataPillButton.secondary(
                        label: '重置搜索与筛选',
                        icon: Icons.refresh_rounded,
                        onPressed: () {
                          _searchController.clear();
                          controller.resetFilters(clearSearch: true);
                        },
                      )
                    else ...<Widget>[
                      if (reviewCount > 0)
                        KonataPillButton.primary(
                          label: '处理待复核 ($reviewCount)',
                          icon: Icons.rule_folder_outlined,
                          onPressed: () => showReviewDialog(context),
                        ),
                      KonataPillButton.secondary(
                        label: '管理媒体源',
                        icon: Icons.folder_open_outlined,
                        onPressed: () =>
                            deps.navigator.switchNavSection('sources'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: KonataDraggableScrollbar(
        controller: _scrollController,
        builder: (context, scrollController) => AdaptiveCardGrid(
          controller: scrollController,
          padding: EdgeInsets.fromLTRB(
            horizontalPad,
            4,
            horizontalPad,
            gridBottomPad,
          ),
          minPhoneCardWidth: 108.0,
          minWideCardWidth: 158.0,
          coverAspectRatio: 2 / 3,
          footerBaseHeight: 0.0,
          twoLineTextBaseHeight: compact ? 44.0 : 50.0,
          crossAxisSpacing: compact ? 12.0 : 16.0,
          mainAxisSpacing: compact ? 16.0 : 20.0,
          itemCount: items.length,
          itemBuilder: (context, index, cardWidth) {
            final item = items[index];
            final isCompactCard = compact || cardWidth < 132.0;
            return PosterCard(
              key: ValueKey<String>(item.work.id),
              item: item,
              cardWidth: cardWidth,
              compactText: isCompactCard,
              badgeFontSize: isCompactCard ? 9.5 : KonataTheme.fontSizeBadge,
              titleFontSize: isCompactCard
                  ? KonataTheme.fontSizeBodySm
                  : KonataTheme.fontSizeBody,
              subtitleFontSize: isCompactCard
                  ? KonataTheme.fontSizeCaptionXs
                  : KonataTheme.fontSizeCaptionSm,
              suppressHoverCheck: () =>
                  _isFastScrolling || controller.videoPlaybackActive,
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
