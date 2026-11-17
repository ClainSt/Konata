import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../application/providers/library_providers.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/managed_image.dart';
import 'detail_full_list_dialog.dart';
import 'detail_gear_menu.dart';
import 'detail_secondary_filter_bar.dart';
import 'episode_drawer_card.dart';
import 'series_switcher_dropdown.dart';
import 'supplementary_asset_cards.dart';

/// 详情页底部选集分页（正片、特典，以及有内容时动态显示的 CD / Scan）。
enum DetailDrawerTab { main, extra, cd, scan }

/// 详情页无黑框左右分置毛玻璃导航胶囊与悬浮剧集卡片轨道。
class DetailBottomDrawer extends StatefulWidget {
  /// 创建无黑框底部选集与控制胶囊栏。
  const DetailBottomDrawer({
    super.key,
    required this.bundle,
    required this.activeTab,
    required this.imageLoader,
    required this.onToggleTab,
    required this.onCollapse,
    required this.onEpisodeTap,
    required this.onEpisodeAdjustSlot,
    this.onEpisodePlayBuiltin,
    this.onEpisodePlayExternal,
    this.onEpisodeMarkCompleted,
    required this.onOpenManualMatch,
    required this.onOpenManualEdit,
    required this.onOpenPosterPicker,
    required this.onOpenBackdropPicker,
    required this.onHideWork,
    required this.onDeleteWork,
    required this.onRescrape,
    required this.onOpenLocalDir,
    this.onOpenSeriesManage,
    this.onOpenMergeWork,
    this.onSelectSeriesWork,
    this.onCdTap,
    this.onCdPlayImmersive,
    this.onCdPlayExternal,
    this.onScanTap,
    this.preferredTab = DetailDrawerTab.main,
    this.showRawVideoFilename = true,
    this.showCdTab = true,
    this.showScanTab = true,
    this.onSecondaryFilterChanged,
  });

  /// 作品完整数据包。
  final WorkDetailBundle bundle;

  /// 当前展开的选集分类（`null` 表示收起剧集缩略图仅展示控制胶囊）。
  final DetailDrawerTab? activeTab;

  /// 收起态时记忆的上次分页（用于一键展开恢复）。
  final DetailDrawerTab preferredTab;

  /// 图片加载回调。
  final ManagedImageLoader imageLoader;

  /// 切换选集分类或从收起态展开指定分类。
  final ValueChanged<DetailDrawerTab> onToggleTab;

  /// 收起剧集缩略图轨道。
  final VoidCallback onCollapse;

  /// 点击具体剧集/特典卡片。
  final ValueChanged<Episode> onEpisodeTap;

  /// 右键内置播放器播放回调。
  final ValueChanged<Episode>? onEpisodePlayBuiltin;

  /// 右键外部播放器播放回调。
  final ValueChanged<Episode>? onEpisodePlayExternal;

  /// 右键微调单集季号/集号。
  final ValueChanged<Episode> onEpisodeAdjustSlot;

  /// 右键快捷标为已看。
  final ValueChanged<Episode>? onEpisodeMarkCompleted;

  /// 齿轮菜单各项回调。
  final VoidCallback onOpenManualMatch;
  final VoidCallback onOpenManualEdit;
  final VoidCallback onOpenPosterPicker;
  final VoidCallback onOpenBackdropPicker;
  final VoidCallback onHideWork;
  final VoidCallback onDeleteWork;
  final VoidCallback onRescrape;
  final VoidCallback onOpenLocalDir;
  final VoidCallback? onOpenSeriesManage;
  final VoidCallback? onOpenMergeWork;

  /// 系列下拉切换、CD 播放与 Scan 浏览回调。
  final ValueChanged<String>? onSelectSeriesWork;
  final ValueChanged<MediaVariant>? onCdTap;
  final ValueChanged<MediaVariant>? onCdPlayImmersive;
  final ValueChanged<MediaVariant>? onCdPlayExternal;
  final ValueChanged<MediaVariant>? onScanTap;

  /// 是否在选集卡片下方显示原始视频文件名。
  final bool showRawVideoFilename;

  /// 是否在底部导航与完整列表中显示「CD」分类页签。
  final bool showCdTab;

  /// 是否在底部导航与完整列表中显示「Scan」分类页签。
  final bool showScanTab;

  /// 切换二级筛选标签时触发（可用于取消未完成的 Scan 缩略图加载队列）。
  final VoidCallback? onSecondaryFilterChanged;

  @override
  State<DetailBottomDrawer> createState() => _DetailBottomDrawerState();
}

class _DetailBottomDrawerState extends State<DetailBottomDrawer> {
  final ScrollController _railController = ScrollController();
  final LayerLink _gearLink = LayerLink();
  final Map<DetailDrawerTab, String?> _selectedSecondaryKeyByTab =
      <DetailDrawerTab, String?>{};
  OverlayEntry? _gearMenuEntry;

  @override
  void didUpdateWidget(covariant DetailBottomDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bundle.work.id != widget.bundle.work.id) {
      _selectedSecondaryKeyByTab.clear();
      if (_railController.hasClients) {
        _railController.jumpTo(0);
      }
      return;
    }
    if (oldWidget.activeTab != widget.activeTab && _railController.hasClients) {
      _railController.jumpTo(0);
    }
  }

  void _selectSecondaryKey(DetailDrawerTab tab, String? key) {
    if (_selectedSecondaryKeyByTab[tab] == key) return;
    setState(() => _selectedSecondaryKeyByTab[tab] = key);
    if (_railController.hasClients) {
      _railController.jumpTo(0);
    }
    widget.onSecondaryFilterChanged?.call();
  }

  Future<void> _openFullList(
    BuildContext context,
    DetailDrawerTab tab,
    String? secondaryKey,
  ) {
    return DetailFullListDialog.show(
      context,
      bundle: widget.bundle,
      imageLoader: widget.imageLoader,
      initialTab: tab,
      initialSecondaryFilterKey: secondaryKey,
      showRawVideoFilename: widget.showRawVideoFilename,
      showCdTab: widget.showCdTab,
      showScanTab: widget.showScanTab,
      onEpisodeTap: widget.onEpisodeTap,
      onEpisodePlayBuiltin: widget.onEpisodePlayBuiltin,
      onEpisodePlayExternal: widget.onEpisodePlayExternal,
      onEpisodeAdjustSlot: widget.onEpisodeAdjustSlot,
      onEpisodeMarkCompleted: widget.onEpisodeMarkCompleted,
      onCdTap: widget.onCdTap,
      onCdPlayImmersive: widget.onCdPlayImmersive,
      onCdPlayExternal: widget.onCdPlayExternal,
      onScanTap: widget.onScanTap,
    );
  }

  @override
  void dispose() {
    _closeGearMenu();
    _railController.dispose();
    super.dispose();
  }

  void _scrollRailBy(double delta) {
    if (!_railController.hasClients) return;
    final pos = _railController.position;
    final target = (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
    _railController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _closeGearMenu() {
    _gearMenuEntry?.remove();
    _gearMenuEntry = null;
  }

  void _toggleGearMenu() {
    if (_gearMenuEntry != null) {
      _closeGearMenu();
      setState(() {});
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    _gearMenuEntry = OverlayEntry(
      builder: (ctx) => DetailGearMenuOverlay(
        link: _gearLink,
        onDismiss: () {
          _closeGearMenu();
          if (mounted) setState(() {});
        },
        onSelect: (action) {
          _closeGearMenu();
          if (mounted) setState(() {});
          action();
        },
        onManualMatch: widget.onOpenManualMatch,
        onManualEdit: widget.onOpenManualEdit,
        onEditPoster: widget.onOpenPosterPicker,
        onEditBackdrop: widget.onOpenBackdropPicker,
        onHideWork: widget.onHideWork,
        onDeleteWork: widget.onOpenDeleteWorkSafe(),
        onRescrape: widget.onRescrape,
        onOpenLocalDir: widget.onOpenLocalDir,
        onManageSeries: widget.onOpenSeriesManage,
        onMergeWork: widget.onOpenMergeWork,
      ),
    );
    overlay.insert(_gearMenuEntry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final episodes = widget.bundle.episodes;
    final mainEps = episodes
        .where((e) => e.category == EpisodeCategory.main)
        .toList();
    final extraEps = episodes
        .where((e) => e.category == EpisodeCategory.extra)
        .toList();
    final cdList = widget.showCdTab
        ? widget.bundle.cdVariants
              .where((v) => !CueVariantResolver.isCueSheetFile(v.fileName))
              .toList(growable: false)
        : const <MediaVariant>[];
    final scanList = widget.showScanTab
        ? widget.bundle.scanVariants
        : const <MediaVariant>[];

    final isExpanded = widget.activeTab != null;
    var currentTab = widget.activeTab ?? widget.preferredTab;
    if ((currentTab == DetailDrawerTab.cd && cdList.isEmpty) ||
        (currentTab == DetailDrawerTab.scan && scanList.isEmpty)) {
      currentTab = DetailDrawerTab.main;
    }

    // 预计算特典二级分类与决策点 2 展示标题
    final extraKindByEpId = <String, ExtraKind>{};
    final extraCountByKind = <ExtraKind, int>{};
    final extraDisplayTitleByEpId = <String, String>{};
    for (final ep in extraEps) {
      final variants = widget.bundle.variantsForEpisode(ep.id);
      final firstVar = variants.isNotEmpty ? variants.first : null;
      final kind = firstVar != null
          ? SupplementarySubclassifier.classifyExtraVideo(
              fileName: firstVar.fileName,
              relativePath: firstVar.relativePath,
              fallbackExtraType: ep.extraType,
            )
          : (ep.extraType ?? ExtraKind.sp);
      extraKindByEpId[ep.id] = kind;
      extraCountByKind[kind] = (extraCountByKind[kind] ?? 0) + 1;
      final defaultTitle = EpisodeTitleFormatter.formatCardTitle(
        episode: ep,
        workTitle: widget.bundle.work.title,
        workMediaType: widget.bundle.work.tmdbMediaType,
        mainEpisodeCount: mainEps.length,
      );
      extraDisplayTitleByEpId[ep.id] =
          SupplementarySubclassifier.formatExtraDisplayTitle(
            episode: ep,
            episodeVariants: variants,
            allWorkVariants: widget.bundle.variants,
            defaultFormattedTitle: defaultTitle,
          );
    }

    final cdSummary = SupplementarySubclassifier.groupCdVariants(cdList);
    final scanSummary = SupplementarySubclassifier.groupScanVariants(scanList);

    final secondaryItems = switch (currentTab) {
      DetailDrawerTab.extra =>
        SupplementarySubclassifier.extraKindDisplayOrder
            .where((k) => (extraCountByKind[k] ?? 0) > 0)
            .map(
              (k) => DetailSecondaryFilterItem(
                key: k.name,
                label: SupplementarySubclassifier.extraKindLabel(k),
                count: extraCountByKind[k] ?? 0,
              ),
            )
            .toList(growable: false),
      DetailDrawerTab.cd =>
        cdSummary.chips
            .map(
              (c) => DetailSecondaryFilterItem(
                key: c.key,
                label: c.label,
                count: c.count,
              ),
            )
            .toList(growable: false),
      DetailDrawerTab.scan =>
        scanSummary.chips
            .map(
              (c) => DetailSecondaryFilterItem(
                key: c.key,
                label: c.label,
                count: c.count,
              ),
            )
            .toList(growable: false),
      DetailDrawerTab.main => const <DetailSecondaryFilterItem>[],
    };

    final showSecondaryBar = secondaryItems.length >= 2;
    final storedKey = _selectedSecondaryKeyByTab[currentTab];
    final activeSecondaryKey =
        showSecondaryBar &&
            storedKey != null &&
            secondaryItems.any((i) => i.key == storedKey)
        ? storedKey
        : null;

    final filteredMainEps = mainEps;
    final filteredExtraEps =
        (currentTab == DetailDrawerTab.extra && activeSecondaryKey != null)
        ? extraEps
              .where((e) => extraKindByEpId[e.id]?.name == activeSecondaryKey)
              .toList(growable: false)
        : extraEps;
    final filteredCdList =
        (currentTab == DetailDrawerTab.cd && activeSecondaryKey != null)
        ? cdList
              .where(
                (v) =>
                    cdSummary.byVariantId[v.id]?.albumKey == activeSecondaryKey,
              )
              .toList(growable: false)
        : cdList;
    final filteredScanList =
        (currentTab == DetailDrawerTab.scan && activeSecondaryKey != null)
        ? scanList
              .where(
                (v) =>
                    scanSummary.byVariantId[v.id]?.volumeKey ==
                    activeSecondaryKey,
              )
              .toList(growable: false)
        : scanList;

    final currentEps = currentTab == DetailDrawerTab.extra
        ? filteredExtraEps
        : filteredMainEps;
    final currentRawCount = switch (currentTab) {
      DetailDrawerTab.main => mainEps.length,
      DetailDrawerTab.extra => extraEps.length,
      DetailDrawerTab.cd => cdList.length,
      DetailDrawerTab.scan => scanList.length,
    };
    final currentCount = switch (currentTab) {
      DetailDrawerTab.main => filteredMainEps.length,
      DetailDrawerTab.extra => filteredExtraEps.length,
      DetailDrawerTab.cd => filteredCdList.length,
      DetailDrawerTab.scan => filteredScanList.length,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 选集控制顶栏：左右两端各悬一枚磨砂胶囊，与下方卡片左右边距 36px 严格齐平
        Padding(
          padding: EdgeInsets.fromLTRB(36, 0, 36, isExpanded ? 14 : 24),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.bundle.seriesMembers.length >= 2 &&
                          widget.onSelectSeriesWork != null) ...[
                        SeriesSwitcherDropdown(
                          activeWork: widget.bundle.work,
                          seriesMembers: widget.bundle.seriesMembers,
                          seriesGroup: widget.bundle.seriesGroup,
                          onSelectWork: widget.onSelectSeriesWork!,
                        ),
                        const SizedBox(width: 8),
                      ],
                      _FrostedNavCapsule(
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DetailDrawerTabChip(
                              label: '正片 (${mainEps.length})',
                              active:
                                  isExpanded &&
                                  currentTab == DetailDrawerTab.main,
                              onTap: () =>
                                  widget.onToggleTab(DetailDrawerTab.main),
                            ),
                            const SizedBox(width: 4),
                            DetailDrawerTabChip(
                              label: '特典 (${extraEps.length})',
                              active:
                                  isExpanded &&
                                  currentTab == DetailDrawerTab.extra,
                              onTap: () =>
                                  widget.onToggleTab(DetailDrawerTab.extra),
                            ),
                            if (cdList.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              DetailDrawerTabChip(
                                label: 'CD (${cdList.length})',
                                active:
                                    isExpanded &&
                                    currentTab == DetailDrawerTab.cd,
                                onTap: () =>
                                    widget.onToggleTab(DetailDrawerTab.cd),
                              ),
                            ],
                            if (scanList.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              DetailDrawerTabChip(
                                label: 'Scan (${scanList.length})',
                                active:
                                    isExpanded &&
                                    currentTab == DetailDrawerTab.scan,
                                onTap: () =>
                                    widget.onToggleTab(DetailDrawerTab.scan),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _FrostedNavCapsule(
                padding: isExpanded
                    ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
                    : const EdgeInsets.all(4),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isExpanded) ...[
                        DetailDrawerHeaderButton(
                          icon: Icons.grid_view_rounded,
                          tooltip: '完整列表',
                          enabled: currentRawCount > 0,
                          onPressed: () => _openFullList(
                            context,
                            currentTab,
                            activeSecondaryKey,
                          ),
                        ),
                        const SizedBox(width: 2),
                        DetailDrawerHeaderButton(
                          icon: Icons.chevron_left_rounded,
                          tooltip: '向左翻页',
                          enabled: currentCount > 1,
                          onPressed: () => _scrollRailBy(-520),
                        ),
                        const SizedBox(width: 2),
                        DetailDrawerHeaderButton(
                          icon: Icons.chevron_right_rounded,
                          tooltip: '向右翻页',
                          enabled: currentCount > 1,
                          onPressed: () => _scrollRailBy(520),
                        ),
                        const SizedBox(width: 2),
                        DetailDrawerHeaderButton(
                          icon: Icons.keyboard_arrow_down_rounded,
                          tooltip: '收起剧集 (Esc)',
                          onPressed: widget.onCollapse,
                        ),
                        const SizedBox(width: 2),
                      ],
                      CompositedTransformTarget(
                        link: _gearLink,
                        child: DetailDrawerHeaderButton(
                          icon: Icons.settings_rounded,
                          tooltip: '作品管理选项',
                          active: _gearMenuEntry != null,
                          onPressed: _toggleGearMenu,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // 无框悬浮剧集卡片行：直接悬浮在底部渐暗背景之上，彻底取消深黑大底框
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !isExpanded
              ? const SizedBox.shrink()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showSecondaryBar)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: DetailSecondaryFilterBar(
                          items: secondaryItems,
                          totalCount: currentRawCount,
                          selectedKey: activeSecondaryKey,
                          onSelected: (k) => _selectSecondaryKey(currentTab, k),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: SizedBox(
                        height: 222,
                        child: currentCount == 0
                            ? Center(
                                child: Text(
                                  '该分类下暂无内容',
                                  style: KonataTheme.detailTextStyle(
                                    palette: context.palette,
                                    color: Colors.white.withValues(alpha: 0.82),
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              )
                            : _buildTabRail(
                                tab: currentTab,
                                episodes: currentEps,
                                mainEpisodeCount: mainEps.length,
                                cdList: filteredCdList,
                                scanList: filteredScanList,
                                extraDisplayTitleByEpId:
                                    extraDisplayTitleByEpId,
                                cdSummary: cdSummary,
                                scanSummary: scanSummary,
                                activeSecondaryKey: activeSecondaryKey,
                              ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildTabRail({
    required DetailDrawerTab tab,
    required List<Episode> episodes,
    required int mainEpisodeCount,
    required List<MediaVariant> cdList,
    required List<MediaVariant> scanList,
    required Map<String, String> extraDisplayTitleByEpId,
    required CdAlbumGroupSummary cdSummary,
    required ScanVolumeGroupSummary scanSummary,
    required String? activeSecondaryKey,
  }) {
    final showSharedBadge = widget.bundle.seriesMembers.length >= 2;
    return switch (tab) {
      DetailDrawerTab.main || DetailDrawerTab.extra => _buildWheelRail(
        itemCount: episodes.length,
        itemBuilder: (_, index) => _buildCard(
          episodes[index],
          mainEpisodeCount,
          displayTitleOverride: tab == DetailDrawerTab.extra
              ? extraDisplayTitleByEpId[episodes[index].id]
              : null,
        ),
      ),
      DetailDrawerTab.cd => _buildWheelRail(
        itemCount: cdList.length,
        itemBuilder: (_, index) {
          final v = cdList[index];
          final group = cdSummary.byVariantId[v.id];
          final showDirectSubdir =
              activeSecondaryKey == null && cdSummary.hasMultipleSubdirs;
          final dot = v.fileName.lastIndexOf('.');
          final stem = dot > 0 ? v.fileName.substring(0, dot) : v.fileName;
          final titleOverride =
              (CueVariantResolver.isGenericDiscImageStem(stem) &&
                  group != null &&
                  group.chipLabel.isNotEmpty &&
                  group.chipLabel != 'CD')
              ? group.chipLabel
              : null;
          return CdDrawerCard(
            variant: v,
            showSeriesSharedBadge: showSharedBadge,
            displayTitleOverride: titleOverride,
            directSubdirLabel: showDirectSubdir
                ? group?.directSubdirShort
                : null,
            onTap: () => widget.onCdTap?.call(v),
            onPlayImmersive: widget.onCdPlayImmersive == null
                ? null
                : () => widget.onCdPlayImmersive!(v),
            onPlayExternal: widget.onCdPlayExternal == null
                ? null
                : () => widget.onCdPlayExternal!(v),
          );
        },
      ),
      DetailDrawerTab.scan => _buildWheelRail(
        itemCount: scanList.length,
        itemBuilder: (_, index) {
          final v = scanList[index];
          final group = scanSummary.byVariantId[v.id];
          final showDirectSubdir =
              activeSecondaryKey == null && scanSummary.hasMultipleSubdirs;
          return ScanDrawerCard(
            variant: v,
            source: widget.bundle.sourcesById[v.sourceId],
            workId: widget.bundle.work.id,
            workTitle: widget.bundle.work.title,
            showSeriesSharedBadge: showSharedBadge,
            directSubdirLabel: showDirectSubdir
                ? group?.directSubdirShort
                : null,
            onTap: () => widget.onScanTap?.call(v),
          );
        },
      ),
    };
  }

  Widget _buildWheelRail({
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && _railController.hasClients) {
          final delta = event.scrollDelta.dy != 0
              ? event.scrollDelta.dy
              : event.scrollDelta.dx;
          final target = (_railController.offset + delta).clamp(
            0.0,
            _railController.position.maxScrollExtent,
          );
          _railController.jumpTo(target);
        }
      },
      child: ListView.separated(
        controller: _railController,
        padding: const EdgeInsets.symmetric(horizontal: 36),
        scrollDirection: Axis.horizontal,
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: itemBuilder,
      ),
    );
  }

  Widget _buildCard(
    Episode ep,
    int mainEpisodeCount, {
    String? displayTitleOverride,
  }) {
    final variants = widget.bundle.variantsForEpisode(ep.id);
    final playback = widget.bundle.playbackByEpisodeId[ep.id];
    final markHandler = widget.onEpisodeMarkCompleted;
    return EpisodeDrawerCard(
      episode: ep,
      variants: variants,
      fallbackBackdropPath:
          widget.bundle.work.backdropPath ?? widget.bundle.work.posterPath,
      imageLoader: widget.imageLoader,
      workTitle: widget.bundle.work.title,
      workMediaType: widget.bundle.work.tmdbMediaType,
      mainEpisodeCount: mainEpisodeCount,
      displayTitleOverride: displayTitleOverride,
      showRawFileName: widget.showRawVideoFilename,
      onTap: () => widget.onEpisodeTap(ep),
      onPlayBuiltin: widget.onEpisodePlayBuiltin == null
          ? null
          : () => widget.onEpisodePlayBuiltin!(ep),
      onPlayExternal: widget.onEpisodePlayExternal == null
          ? null
          : () => widget.onEpisodePlayExternal!(ep),
      onAdjustSlot: () => widget.onEpisodeAdjustSlot(ep),
      playback: playback,
      onMarkCompleted: markHandler == null ? null : () => markHandler(ep),
    );
  }
}

extension on DetailBottomDrawer {
  VoidCallback onOpenDeleteWorkSafe() => onDeleteWork;
}

class _FrostedNavCapsule extends StatelessWidget {
  const _FrostedNavCapsule({required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(p),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: KonataPlaybackTokens.glassBorder(p),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
