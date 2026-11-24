import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../audio/mini_audio_bar.dart';
import '../detail/work_detail_page.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/adaptive_card_grid.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/playback/konata_playback_capsule.dart';
import 'hidden_works_dialog.dart';
import 'poster_card.dart';
import 'review_dialog.dart';

/// 高密度媒体库海报墙主页（全端统一「遮眼在左 + 待复核最右」秩序与双行搜索顶替交互）。
class LibraryPage extends ConsumerStatefulWidget {
  /// 创建媒体库主页。
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final ScrollController _gridCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _mobileSearchDebounce;
  String _lastDispatchedQuery = '';
  bool _searchBarOpen = false;
  bool _searchHasText = false;

  @override
  void initState() {
    super.initState();
    final initialQuery = ref.read(librarySearchQueryProvider);
    _lastDispatchedQuery = initialQuery;
    if (initialQuery.isNotEmpty) {
      _searchCtrl.text = initialQuery;
      _searchBarOpen = true;
      _searchHasText = true;
    }
    _searchCtrl.addListener(_onSearchCtrlTextChanged);
  }

  void _onSearchCtrlTextChanged() {
    if (!KonataAdaptiveTokens.isAndroid) return;
    final hasText = _searchCtrl.text.isNotEmpty;
    if (mounted && hasText != _searchHasText) {
      setState(() => _searchHasText = hasText);
    }
  }

  void _dispatchMobileSearchQuery(String query) {
    if (_lastDispatchedQuery == query) return;
    _lastDispatchedQuery = query;
    ref.read(librarySearchQueryProvider.notifier).state = query;
  }

  void _handleMobileSearchChanged(String value) {
    final composing = _searchCtrl.value.composing;
    if (composing.isValid && !composing.isCollapsed && value.isNotEmpty) {
      return;
    }
    _mobileSearchDebounce?.cancel();
    if (value.isEmpty) {
      _mobileSearchDebounce = null;
      _dispatchMobileSearchQuery('');
      return;
    }
    _mobileSearchDebounce = Timer(KonataTheme.searchInputDebounce, () {
      _mobileSearchDebounce = null;
      if (!mounted) return;
      _dispatchMobileSearchQuery(_searchCtrl.text);
    });
  }

  @override
  void dispose() {
    _mobileSearchDebounce?.cancel();
    _mobileSearchDebounce = null;
    _searchCtrl.removeListener(_onSearchCtrlTextChanged);
    _gridCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _openMobileSearch() {
    setState(() => _searchBarOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _clearMobileSearchOnly() {
    _mobileSearchDebounce?.cancel();
    _mobileSearchDebounce = null;
    _searchCtrl.clear();
    _dispatchMobileSearchQuery('');
    if (mounted) {
      _searchFocusNode.requestFocus();
    }
  }

  void _closeMobileSearch() {
    _mobileSearchDebounce?.cancel();
    _mobileSearchDebounce = null;
    _searchCtrl.clear();
    _dispatchMobileSearchQuery('');
    _searchFocusNode.unfocus();
    setState(() => _searchBarOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final filteredAsync = ref.watch(filteredLibraryItemsProvider);
    final totalCount = ref.watch(
      worksCountProvider.select((async) => async.value ?? 0),
    );
    final reviewCount = ref.watch(
      needsReviewItemsProvider.select((async) => async.value?.length ?? 0),
    );
    final hiddenCount = ref.watch(
      hiddenWorksProvider.select((async) => async.value?.length ?? 0),
    );
    final searchQuery = ref.watch(librarySearchQueryProvider);
    final filteredCount = filteredAsync.value?.length;
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final bottomClearance = KonataBottomClearanceScope.resolve(context, ref);

    // 桌面端由顶栏独立搜索框驱动，跳过隐藏移动搜索控制器同步，避免每次过滤触发二次整页重建。
    if (KonataAdaptiveTokens.isAndroid &&
        searchQuery != _lastDispatchedQuery &&
        searchQuery != _searchCtrl.text) {
      _lastDispatchedQuery = searchQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final current = ref.read(librarySearchQueryProvider);
        if (current != _searchCtrl.text) {
          _searchCtrl.value = TextEditingValue(
            text: current,
            selection: TextSelection.collapsed(offset: current.length),
          );
          if (current.isNotEmpty && !_searchBarOpen) {
            setState(() => _searchBarOpen = true);
          }
        }
      });
    }

    final isLibraryActive = ref.watch(
      selectedNavSectionProvider.select((s) => s == KonataNavSection.library),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LibraryHeaderBar(
          totalCount: totalCount,
          filteredCount: filteredCount,
          hiddenCount: hiddenCount,
          reviewCount: reviewCount,
          searchQuery: searchQuery,
          searchOpen: _searchBarOpen,
          interceptSystemBack: isLibraryActive,
          searchController: _searchCtrl,
          searchFocusNode: _searchFocusNode,
          onOpenHidden: () => showHiddenWorksDialog(context),
          onOpenReview: () => showReviewDialog(context),
          onOpenSearch: _openMobileSearch,
          onSearchChanged: _handleMobileSearchChanged,
          onClearSearch: _clearMobileSearchOnly,
          onCloseSearch: _closeMobileSearch,
        ),
        Expanded(
          child: filteredAsync.when(
            data: (items) {
              if (items.isEmpty) {
                return _EmptyLibraryState(
                  isSearching: searchQuery.trim().isNotEmpty,
                  onGoSources: () {
                    ref.read(selectedNavSectionProvider.notifier).state =
                        KonataNavSection.sources;
                  },
                );
              }
              return LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final compact =
                      KonataAdaptiveTokens.isAndroid &&
                      width < KonataAdaptiveTokens.tabletBreakpoint;
                  final padH = compact
                      ? KonataAdaptiveTokens.horizontalInset
                      : KonataTheme.pageHorizontalPadding;
                  return KonataDraggableScrollbar(
                    controller: _gridCtrl,
                    builder: (_, ctrl) => AdaptiveCardGrid(
                      controller: ctrl,
                      padding: EdgeInsets.fromLTRB(
                        padH,
                        0,
                        padH,
                        28 + bottomClearance,
                      ),
                      minPhoneCardWidth: 108.0,
                      minWideCardWidth: 158.0,
                      crossAxisSpacing: compact ? 12.0 : 16.0,
                      mainAxisSpacing: compact ? 16.0 : 20.0,
                      twoLineTextBaseHeight: 50.0,
                      itemCount: items.length,
                      itemBuilder: (_, index, _) {
                        final item = items[index];
                        return PosterCard(
                          key: ValueKey<String>(item.work.id),
                          item: item,
                          imageLoader: imageLoader,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    WorkDetailPage(workId: item.work.id),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(
              child: Text('加载媒体库失败: $err', style: TextStyle(color: p.danger)),
            ),
          ),
        ),
      ],
    );
  }
}

class _LibraryHeaderBar extends StatelessWidget {
  const _LibraryHeaderBar({
    required this.totalCount,
    required this.filteredCount,
    required this.hiddenCount,
    required this.reviewCount,
    required this.searchQuery,
    required this.searchOpen,
    required this.interceptSystemBack,
    required this.searchController,
    required this.searchFocusNode,
    required this.onOpenHidden,
    required this.onOpenReview,
    required this.onOpenSearch,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onCloseSearch,
  });

  final int totalCount;
  final int? filteredCount;
  final int hiddenCount;
  final int reviewCount;
  final String searchQuery;
  final bool searchOpen;
  final bool interceptSystemBack;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final VoidCallback onOpenHidden;
  final VoidCallback onOpenReview;
  final VoidCallback onOpenSearch;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onCloseSearch;

  double _measureLabelWidth(
    BuildContext context,
    String text,
    TextStyle style, {
    double? clampScaleFactor,
  }) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final scaler = clampScaleFactor != null
        ? MediaQuery.textScalerOf(
            context,
          ).clamp(maxScaleFactor: clampScaleFactor)
        : MediaQuery.textScalerOf(context);
    final painter = TextPainter(
      text: TextSpan(text: text, style: effectiveStyle),
      maxLines: 1,
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      textScaler: scaler,
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasQuery = searchQuery.trim().isNotEmpty;
    final countText = hasQuery && filteredCount != null
        ? '$filteredCount / $totalCount 部'
        : '$totalCount 部';
    final countTextStyle = KonataTheme.textStyle(
      color: p.textSecondary,
      fontSize: KonataTheme.fontSizeBodySm,
      weight: KonataTheme.weightActive,
    );
    final countBadge = (totalCount > 0 || hasQuery)
        ? Container(
            key: const ValueKey('library_works_count_pill'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: p.softFill,
              borderRadius: KonataTheme.borderRadiusPill,
              border: Border.all(color: p.hairline, width: 1),
            ),
            child: Text(countText, style: countTextStyle),
          )
        : null;

    if (!KonataAdaptiveTokens.isAndroid) {
      final desktopRightActions = (hiddenCount > 0 || reviewCount > 0)
          ? Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (hiddenCount > 0)
                  _HiddenWorksHeaderButton(
                    key: const ValueKey('library_hidden_works_button'),
                    count: hiddenCount,
                    onTap: onOpenHidden,
                  ),
                if (hiddenCount > 0 && reviewCount > 0)
                  const SizedBox(width: 6),
                if (reviewCount > 0)
                  _ReviewHeaderPill(
                    key: const ValueKey('library_review_pill'),
                    count: reviewCount,
                    onTap: onOpenReview,
                  ),
              ],
            )
          : null;

      return Padding(
        padding: const EdgeInsets.fromLTRB(
          KonataTheme.pageHorizontalPadding,
          KonataTheme.pageHeaderTopSpacing,
          KonataTheme.pageHorizontalPadding,
          KonataTheme.pageHeaderBottomSpacing,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      '全部作品',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.h1Style(p),
                    ),
                  ),
                  if (countBadge != null) ...[
                    const SizedBox(width: 12),
                    countBadge,
                  ],
                ],
              ),
            ),
            if (desktopRightActions != null) ...[
              const SizedBox(width: 12),
              desktopRightActions,
            ],
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < KonataAdaptiveTokens.tabletBreakpoint;
        final padH = compact
            ? KonataAdaptiveTokens.horizontalInset
            : KonataTheme.pageHorizontalPadding;
        final h1Style = compact
            ? KonataTheme.h1Style(p).copyWith(fontSize: KonataTheme.fontSizeDisplaySm)
            : KonataTheme.h1Style(p);
        final searchExpanded = searchOpen || hasQuery;

        if (searchExpanded) {
          return PopScope(
            canPop: !interceptSystemBack,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && interceptSystemBack) {
                onCloseSearch();
              }
            },
            child: Material(
              type: MaterialType.transparency,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  padH,
                  KonataAdaptiveTokens.safeGap,
                  padH,
                  10,
                ),
                child: SizedBox(
                  height: KonataAdaptiveTokens.touchTarget,
                  child: Row(
                    key: const ValueKey('library_header_search_row'),
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      KonataCapsuleIconButton(
                        key: const ValueKey('library_header_search_close'),
                        icon: Icons.arrow_back_rounded,
                        tooltip: '关闭搜索',
                        color: p.textPrimary,
                        size: 20,
                        fixedSize: KonataAdaptiveTokens.touchTarget,
                        onTap: onCloseSearch,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: CallbackShortcuts(
                          bindings: {
                            const SingleActivator(LogicalKeyboardKey.escape):
                                onCloseSearch,
                          },
                          child: KonataSoftTextField(
                            controller: searchController,
                            focusNode: searchFocusNode,
                            height: 42,
                            prefixIcon: Icons.search_rounded,
                            hintText: '搜索番剧名称、原名、压制组或 TMDB ID',
                            suffix: searchController.text.isNotEmpty
                                ? IconButton(
                                    key: const ValueKey(
                                      'library_header_search_clear',
                                    ),
                                    tooltip: '清空搜索',
                                    constraints: const BoxConstraints.tightFor(
                                      width: 36,
                                      height: 36,
                                    ),
                                    padding: EdgeInsets.zero,
                                    icon: Icon(
                                      Icons.close_rounded,
                                      size: 18,
                                      color: p.textSecondary,
                                    ),
                                    onPressed: onClearSearch,
                                  )
                                : null,
                            onChanged: onSearchChanged,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final availWidth = math.max(0.0, constraints.maxWidth - padH * 2);
        final titleWidth = _measureLabelWidth(context, '全部作品', h1Style) + 2.0;
        final badgeWidth = countBadge == null
            ? 0.0
            : _measureLabelWidth(
                    context,
                    countText,
                    countTextStyle,
                    clampScaleFactor: 1.15,
                  ) +
                  22.0;
        const searchBtnWidth = KonataAdaptiveTokens.touchTarget;
        final hiddenBtnWidth = hiddenCount > 0
            ? KonataAdaptiveTokens.touchTarget
            : 0.0;
        final reviewBtnWidth = reviewCount > 0
            ? math.max(
                KonataAdaptiveTokens.touchTarget,
                _measureLabelWidth(
                      context,
                      '待复核 · $reviewCount',
                      const TextStyle(
                        fontSize: KonataTheme.fontSizeBodyXs,
                        fontWeight: FontWeight.w500,
                      ),
                      clampScaleFactor: 1.15,
                    ) +
                    34.0,
              )
            : 0.0;
        final rightClusterWithSearchWidth =
            searchBtnWidth + hiddenBtnWidth + reviewBtnWidth;

        final leftWithBadgeWidth =
            titleWidth + (badgeWidth > 0 ? 6.0 + badgeWidth : 0.0);
        final fitsSingleRow =
            leftWithBadgeWidth + 6.0 + rightClusterWithSearchWidth <=
            availWidth;
        final fitsSearchInFirstRow =
            titleWidth + 6.0 + rightClusterWithSearchWidth <= availWidth;
        final moveBadgeBelow = countBadge != null && !fitsSingleRow;
        final moveSearchBelow = !fitsSingleRow && !fitsSearchInFirstRow;

        final searchIconButton = KonataCapsuleIconButton(
          key: const ValueKey('library_header_search_button'),
          icon: Icons.search_rounded,
          tooltip: '搜索作品',
          color: p.textPrimary,
          size: 20,
          fixedSize: KonataAdaptiveTokens.touchTarget,
          onTap: onOpenSearch,
        );

        final firstRowRightWidgets = <Widget>[
          if (!moveSearchBelow) searchIconButton,
          if (hiddenCount > 0)
            _HiddenWorksHeaderButton(
              key: const ValueKey('library_hidden_works_button'),
              count: hiddenCount,
              onTap: onOpenHidden,
            ),
          if (reviewCount > 0)
            _ReviewHeaderPill(
              key: const ValueKey('library_review_pill'),
              count: reviewCount,
              onTap: onOpenReview,
            ),
        ];

        final showSecondRow = moveBadgeBelow || moveSearchBelow;

        return Padding(
          padding: EdgeInsets.fromLTRB(
            padH,
            KonataAdaptiveTokens.safeGap,
            padH,
            10,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: KonataAdaptiveTokens.touchTarget,
                child: Row(
                  key: const ValueKey('library_header_title_row'),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              '全部作品',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: h1Style,
                            ),
                          ),
                          if (countBadge != null && !moveBadgeBelow) ...[
                            const SizedBox(width: 6),
                            MediaQuery.withClampedTextScaling(
                              maxScaleFactor: 1.15,
                              child: countBadge,
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (firstRowRightWidgets.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.15,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: firstRowRightWidgets,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (showSecondRow) ...[
                const SizedBox(height: 4),
                Row(
                  key: const ValueKey('library_header_second_row'),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (moveBadgeBelow)
                      MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.15,
                        child: countBadge,
                      ),
                    const Spacer(),
                    if (moveSearchBelow) searchIconButton,
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _HiddenWorksHeaderButton extends StatefulWidget {
  const _HiddenWorksHeaderButton({
    super.key,
    required this.count,
    required this.onTap,
  });

  final int count;
  final VoidCallback onTap;

  @override
  State<_HiddenWorksHeaderButton> createState() =>
      _HiddenWorksHeaderButtonState();
}

class _HiddenWorksHeaderButtonState extends State<_HiddenWorksHeaderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 0) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final tooltip = '已隐藏作品 (${widget.count})';

    return Tooltip(
      message: tooltip,
      waitDuration: KonataTheme.tooltipWaitDuration,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.touchTarget
                : 32,
            height: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.touchTarget
                : 32,
            child: Center(
              child: Icon(
                Icons.visibility_off_outlined,
                size: 18,
                color: _hovered ? p.textPrimary : p.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewHeaderPill extends StatefulWidget {
  const _ReviewHeaderPill({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  State<_ReviewHeaderPill> createState() => _ReviewHeaderPillState();
}

class _ReviewHeaderPillState extends State<_ReviewHeaderPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasPending = widget.count > 0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ConstrainedBox(
          constraints: KonataAdaptiveTokens.isAndroid
              ? const BoxConstraints(
                  minWidth: KonataAdaptiveTokens.touchTarget,
                  minHeight: KonataAdaptiveTokens.touchTarget,
                )
              : const BoxConstraints(),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: AnimatedContainer(
              duration: KonataTheme.motionFast,
              padding: EdgeInsets.symmetric(
                horizontal: KonataAdaptiveTokens.isAndroid ? 10 : 13,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                gradient: KonataTheme.opticalSheenGradient(
                  p,
                  hovered: _hovered,
                  baseColor: _hovered ? p.surfaceHover : p.surface,
                ),
                borderRadius: KonataTheme.borderRadiusPill,
                border: Border.all(
                  color: _hovered ? p.hoverBorder : p.hairline,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasPending) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: p.warning,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    hasPending ? '待复核 · ${widget.count}' : '待复核',
                    style: TextStyle(
                      color: hasPending ? p.textPrimary : p.textMuted,
                      fontSize: KonataTheme.fontSizeBodyXs,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyLibraryState extends StatelessWidget {
  const _EmptyLibraryState({
    required this.isSearching,
    required this.onGoSources,
  });

  final bool isSearching;
  final VoidCallback onGoSources;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSearching
                    ? Icons.search_off_rounded
                    : Icons.video_library_outlined,
                size: 48,
                color: p.textMuted,
              ),
              const SizedBox(height: 12),
              Text(
                isSearching ? '没有匹配当前筛选条件的作品' : '媒体库尚未入库任何作品',
                textAlign: TextAlign.center,
                style: KonataTheme.cardTitleStyle(
                  p,
                  fontSize: KonataTheme.fontSizeTitle,
                ),
              ),
              if (isSearching) ...[
                const SizedBox(height: 6),
                Text(
                  '可尝试按日文原名、压制组或 TMDB ID 检索',
                  textAlign: TextAlign.center,
                  style: KonataTheme.captionStyle(
                    p,
                    fontSize: KonataTheme.fontSizeBodyMd,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 18),
                KonataPillButton.primary(
                  label: '前往添加媒体源',
                  icon: Icons.add_rounded,
                  onPressed: onGoSources,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
