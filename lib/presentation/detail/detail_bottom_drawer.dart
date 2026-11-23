
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers/library_providers.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../theme/konata_adaptive_tokens.dart';
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

/// 详情页选集区在不同设备形态下的排版模式。
enum DetailDrawerLayoutMode {
  /// 桌面端与平板端底部叠加模式：左下分类胶囊 + 右下 `[⊞ ⌄ ⚙]`，展开后向上推开内容区。
  bottomOverlay,

  /// 手机竖屏流式分区模式：顶部运维胶囊由页面右上角顶栏统一渲染，此处呈现分类胶囊与横向轨道并位于简介上方。
  phonePortraitSection,

  /// 手机横屏全高选集模式：返回按钮、分类胶囊与右上 `[⊞ ⚙]` 顶部平齐一行，下方剧集轨道自适应高度显示完整标题与原名。
  phoneLandscapeRail,
}

/// Scan 扫图点击回调签名（可选携带当前二级分卷筛选键以承接灯箱翻页范围）。
typedef DetailScanTapCallback =
    void Function(MediaVariant variant, {String? volumeKey});

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
    this.onEpisodeMediaInfo,
    this.onEpisodePlayBuiltin,
    this.onEpisodePlayExternal,
    this.onEpisodeMarkCompleted,
    required this.onOpenManualMatch,
    required this.onOpenManualEdit,
    required this.onOpenPosterPicker,
    required this.onOpenBackdropPicker,
    this.onOpenLogoPicker,
    required this.onHideWork,
    required this.onDeleteWork,
    required this.onRescrape,
    this.onSyncBangumi,
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
    this.layoutMode = DetailDrawerLayoutMode.bottomOverlay,
    this.leadingBarWidget,
    this.hideOpsCapsuleInBar = false,
    this.hideSeriesSwitcherInBar = false,
    this.showOpsInPortraitBar = false,
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

  /// 右键/长按查看单集媒体信息弹窗回调。
  final ValueChanged<Episode>? onEpisodeMediaInfo;

  /// 右键快捷标为已看。
  final ValueChanged<Episode>? onEpisodeMarkCompleted;

  /// 齿轮菜单各项回调。
  final VoidCallback onOpenManualMatch;
  final VoidCallback onOpenManualEdit;
  final VoidCallback onOpenPosterPicker;
  final VoidCallback onOpenBackdropPicker;
  final VoidCallback? onOpenLogoPicker;
  final VoidCallback onHideWork;
  final VoidCallback onDeleteWork;
  final VoidCallback onRescrape;
  final VoidCallback? onSyncBangumi;
  final VoidCallback onOpenLocalDir;
  final VoidCallback? onOpenSeriesManage;
  final VoidCallback? onOpenMergeWork;

  /// 系列下拉切换、CD 播放与 Scan 浏览回调。
  final ValueChanged<String>? onSelectSeriesWork;
  final ValueChanged<MediaVariant>? onCdTap;
  final ValueChanged<MediaVariant>? onCdPlayImmersive;
  final ValueChanged<MediaVariant>? onCdPlayExternal;
  final DetailScanTapCallback? onScanTap;

  /// 是否在选集卡片下方显示原始视频文件名。
  final bool showRawVideoFilename;

  /// 是否在底部导航与完整列表中显示「CD」分类页签。
  final bool showCdTab;

  /// 是否在底部导航与完整列表中显示「Scan」分类页签。
  final bool showScanTab;

  /// 切换二级筛选标签时触发（可用于取消未完成的 Scan 缩略图加载队列）。
  final VoidCallback? onSecondaryFilterChanged;

  /// 当前设备形态下的排版模式。
  final DetailDrawerLayoutMode layoutMode;

  /// 手机横屏模式下置于分类胶囊左侧的返回按钮（使左箭头与分类长胶囊顶部平齐）。
  final Widget? leadingBarWidget;

  /// 是否在横屏选集栏顶部隐藏重复的操作胶囊（当顶部紧凑头图区已承载时启用）。
  final bool hideOpsCapsuleInBar;

  /// 是否隐藏分类栏左侧的系列切换下拉框（当主操作行已将其与播放按钮同行排布时启用）。
  final bool hideSeriesSwitcherInBar;

  /// 竖屏流式模式下是否在分类胶囊同一行最右侧展示运维齿轮胶囊（平板竖屏启用）。
  final bool showOpsInPortraitBar;

  @override
  State<DetailBottomDrawer> createState() => DetailBottomDrawerState();
}

/// [DetailBottomDrawer] 状态对象（向外暴露 [openCurrentFullList] 供手机竖屏右上角运维胶囊直接唤起当前分类完整列表）。
class DetailBottomDrawerState extends State<DetailBottomDrawer> {
  final ScrollController _railController = ScrollController();
  final Map<DetailDrawerTab, String?> _selectedSecondaryKeyByTab =
      <DetailDrawerTab, String?>{};
  DetailDrawerTab _lastComputedTab = DetailDrawerTab.main;
  String? _lastComputedSecondaryKey;
  int _lastComputedRawCount = 0;

  /// 由外部（如手机竖屏右上角「完整列表」按钮）按当前激活分类与二级筛选直接打开完整列表弹窗。
  Future<void> openCurrentFullList() {
    if (_lastComputedRawCount <= 0) {
      return Future<void>.value();
    }
    return _openFullList(
      context,
      _lastComputedTab,
      _lastComputedSecondaryKey,
    );
  }

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
      onEpisodeMediaInfo: widget.onEpisodeMediaInfo,
      onEpisodeMarkCompleted: widget.onEpisodeMarkCompleted,
      onCdTap: widget.onCdTap,
      onCdPlayImmersive: widget.onCdPlayImmersive,
      onCdPlayExternal: widget.onCdPlayExternal,
      onScanTap: widget.onScanTap,
    );
  }

  @override
  void dispose() {
    _railController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewData = DetailSupplementaryViewData.fromBundle(
      bundle: widget.bundle,
      showCdTab: widget.showCdTab,
      showScanTab: widget.showScanTab,
    );
    final mainEps = viewData.mainEpisodes;
    final extraEps = viewData.extraEpisodes;
    final cdList = viewData.cdList;
    final scanList = viewData.scanList;

    final isExpanded = widget.activeTab != null;
    var currentTab = widget.activeTab ?? widget.preferredTab;
    if ((currentTab == DetailDrawerTab.extra && extraEps.isEmpty) ||
        (currentTab == DetailDrawerTab.cd && cdList.isEmpty) ||
        (currentTab == DetailDrawerTab.scan && scanList.isEmpty)) {
      currentTab = DetailDrawerTab.main;
    }

    final extraKindByEpId = viewData.extraKindByEpId;
    final cdSummary = viewData.cdSummary;
    final scanSummary = viewData.scanSummary;
    final secondaryItems = switch (currentTab) {
      DetailDrawerTab.extra => viewData.extraSecondaryItems,
      DetailDrawerTab.cd => viewData.cdSecondaryItems,
      DetailDrawerTab.scan => viewData.scanSecondaryItems,
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
    _lastComputedTab = currentTab;
    _lastComputedSecondaryKey = activeSecondaryKey;
    _lastComputedRawCount = currentRawCount;

    final mqSize = MediaQuery.sizeOf(context);
    final isTabletViewport =
        mqSize.shortestSide >= KonataAdaptiveTokens.tabletBreakpoint;
    final isPhoneMode =
        widget.layoutMode != DetailDrawerLayoutMode.bottomOverlay &&
        !isTabletViewport;
    final screenW = mqSize.width;
    final compactDrawer =
        isPhoneMode ||
        (KonataAdaptiveTokens.isAndroid &&
            screenW < KonataAdaptiveTokens.tabletBreakpoint);
    final drawerPadH = isPhoneMode
        ? 14.0
        : (isTabletViewport &&
                  widget.layoutMode == DetailDrawerLayoutMode.phonePortraitSection
              ? 28.0
              : (compactDrawer ? 16.0 : 36.0));
    final openSeriesDownward =
        widget.layoutMode == DetailDrawerLayoutMode.phoneLandscapeRail;

    final leftTabCapsule = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.15,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.hideSeriesSwitcherInBar &&
                widget.bundle.seriesMembers.length >= 2 &&
                widget.onSelectSeriesWork != null) ...[
              SeriesSwitcherDropdown(
                activeWork: widget.bundle.work,
                seriesMembers: widget.bundle.seriesMembers,
                seriesGroup: widget.bundle.seriesGroup,
                onSelectWork: widget.onSelectSeriesWork!,
                compact: isPhoneMode,
                openDownward: openSeriesDownward,
              ),
              const SizedBox(width: 8),
            ],
            _FrostedNavCapsule(
              padding: EdgeInsets.all(isPhoneMode ? 3 : 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DetailDrawerTabChip(
                    label: '正片 (${mainEps.length})',
                    compact: isPhoneMode,
                    active: isExpanded && currentTab == DetailDrawerTab.main,
                    onTap: () => widget.onToggleTab(DetailDrawerTab.main),
                  ),
                  if (extraEps.isNotEmpty) ...[
                    SizedBox(width: isPhoneMode ? 2 : 4),
                    DetailDrawerTabChip(
                      label: '特典 (${extraEps.length})',
                      compact: isPhoneMode,
                      active: isExpanded && currentTab == DetailDrawerTab.extra,
                      onTap: () => widget.onToggleTab(DetailDrawerTab.extra),
                    ),
                  ],
                  if (cdList.isNotEmpty) ...[
                    SizedBox(width: isPhoneMode ? 2 : 4),
                    DetailDrawerTabChip(
                      label: 'CD (${cdList.length})',
                      compact: isPhoneMode,
                      active: isExpanded && currentTab == DetailDrawerTab.cd,
                      onTap: () => widget.onToggleTab(DetailDrawerTab.cd),
                    ),
                  ],
                  if (scanList.isNotEmpty) ...[
                    SizedBox(width: isPhoneMode ? 2 : 4),
                    DetailDrawerTabChip(
                      label: 'Scan (${scanList.length})',
                      compact: isPhoneMode,
                      active: isExpanded && currentTab == DetailDrawerTab.scan,
                      onTap: () => widget.onToggleTab(DetailDrawerTab.scan),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    DetailOpsCapsule buildOpsCapsule({
      required bool showCollapse,
      required bool openDownward,
    }) {
      return DetailOpsCapsule(
        isExpanded: isExpanded,
        hasContent: currentRawCount > 0,
        showCollapseButton: showCollapse,
        openDownward: openDownward,
        onOpenFullList: () =>
            _openFullList(context, currentTab, activeSecondaryKey),
        onCollapse: widget.onCollapse,
        onManualMatch: widget.onOpenManualMatch,
        onManualEdit: widget.onOpenManualEdit,
        onEditPoster: widget.onOpenPosterPicker,
        onEditBackdrop: widget.onOpenBackdropPicker,
        onEditLogo: widget.onOpenLogoPicker,
        onHideWork: widget.onHideWork,
        onDeleteWork: widget.onOpenDeleteWorkSafe(),
        onRescrape: widget.onRescrape,
        onSyncBangumi: widget.onSyncBangumi,
        onOpenLocalDir: widget.onOpenLocalDir,
        onManageSeries: widget.onOpenSeriesManage,
        onMergeWork: widget.onOpenMergeWork,
      );
    }

    if (widget.layoutMode == DetailDrawerLayoutMode.phoneLandscapeRail) {
      final baseRailH = widget.showRawVideoFilename ? 216.0 : 166.0;
      final landscapeRailH = currentTab == DetailDrawerTab.cd
          ? (widget.showRawVideoFilename ? 216.0 : 196.0)
          : (currentTab == DetailDrawerTab.scan ? 204.0 : baseRailH);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 2, 16, showSecondaryBar ? 0 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.leadingBarWidget != null) ...[
                  widget.leadingBarWidget!,
                  const SizedBox(width: 8),
                ],
                Expanded(child: leftTabCapsule),
                if (!widget.hideOpsCapsuleInBar) ...[
                  const SizedBox(width: 8),
                  buildOpsCapsule(showCollapse: false, openDownward: true),
                ],
              ],
            ),
          ),
          if (showSecondaryBar)
            DetailSecondaryFilterBar(
              items: secondaryItems,
              totalCount: currentRawCount,
              selectedKey: activeSecondaryKey,
              horizontalPadding: 16,
              compact: true,
              onSelected: (k) => _selectSecondaryKey(currentTab, k),
            ),
          SizedBox(
            height: landscapeRailH,
            child: _buildRailContent(
              currentCount: currentCount,
              tab: currentTab,
              episodes: currentEps,
              viewData: viewData,
              cdList: filteredCdList,
              scanList: filteredScanList,
              activeSecondaryKey: activeSecondaryKey,
              cardWidth: 208.0,
              railPadH: 16.0,
            ),
          ),
        ],
      );
    }

    if (widget.layoutMode == DetailDrawerLayoutMode.phonePortraitSection) {
      final portraitCardWidth = isTabletViewport ? 244.0 : 208.0;
      final basePortraitH = isTabletViewport
          ? (widget.showRawVideoFilename ? 228.0 : 182.0)
          : (widget.showRawVideoFilename ? 216.0 : 166.0);
      final portraitRailH = currentTab == DetailDrawerTab.cd
          ? (widget.showRawVideoFilename ? 218.0 : 198.0)
          : (currentTab == DetailDrawerTab.scan ? 208.0 : basePortraitH);
      final sectionPadH = isTabletViewport ? 28.0 : 16.0;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: sectionPadH),
            child: widget.showOpsInPortraitBar
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: leftTabCapsule),
                      const SizedBox(width: 12),
                      buildOpsCapsule(
                        showCollapse: true,
                        openDownward: false,
                      ),
                    ],
                  )
                : leftTabCapsule,
          ),
          AnimatedSize(
            duration: KonataTheme.motionMicro,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: !isExpanded
                ? const SizedBox.shrink()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: showSecondaryBar ? 2 : 10),
                      if (showSecondaryBar)
                        DetailSecondaryFilterBar(
                          items: secondaryItems,
                          totalCount: currentRawCount,
                          selectedKey: activeSecondaryKey,
                          horizontalPadding: sectionPadH,
                          compact: !isTabletViewport,
                          onSelected: (k) =>
                              _selectSecondaryKey(currentTab, k),
                        ),
                      SizedBox(
                        height: portraitRailH,
                        child: _buildRailContent(
                          currentCount: currentCount,
                          tab: currentTab,
                          episodes: currentEps,
                          viewData: viewData,
                          cdList: filteredCdList,
                          scanList: filteredScanList,
                          activeSecondaryKey: activeSecondaryKey,
                          cardWidth: portraitCardWidth,
                          railPadH: sectionPadH,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      );
    }

    final rightOpsCapsule = buildOpsCapsule(
      showCollapse: true,
      openDownward: false,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            drawerPadH,
            0,
            drawerPadH,
            isExpanded ? 14 : (compactDrawer ? 14 : 24),
          ),
          child: Row(
            children: [
              Expanded(child: leftTabCapsule),
              const SizedBox(width: 12),
              rightOpsCapsule,
            ],
          ),
        ),
        // 无框悬浮剧集卡片行：直接悬浮在底部渐暗背景之上，彻底取消深黑大底框
        AnimatedSize(
          duration: KonataTheme.motionMicro,
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
                          horizontalPadding: drawerPadH,
                          onSelected: (k) => _selectSecondaryKey(currentTab, k),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: SizedBox(
                        height: 226,
                        child: _buildRailContent(
                          currentCount: currentCount,
                          tab: currentTab,
                          episodes: currentEps,
                          viewData: viewData,
                          cdList: filteredCdList,
                          scanList: filteredScanList,
                          activeSecondaryKey: activeSecondaryKey,
                          cardWidth: 244.0,
                          railPadH: drawerPadH,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildRailContent({
    required int currentCount,
    required DetailDrawerTab tab,
    required List<Episode> episodes,
    required DetailSupplementaryViewData viewData,
    required List<MediaVariant> cdList,
    required List<MediaVariant> scanList,
    required String? activeSecondaryKey,
    required double cardWidth,
    required double railPadH,
  }) {
    if (currentCount == 0) {
      return Center(
        child: Text(
          '该分类下暂无内容',
          style: KonataTheme.detailTextStyle(
            palette: context.palette,
            color: KonataTheme.overlayWhiteTextMid,
            fontSize: KonataTheme.fontSizeBody,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    return _buildTabRail(
      tab: tab,
      episodes: episodes,
      viewData: viewData,
      cdList: cdList,
      scanList: scanList,
      activeSecondaryKey: activeSecondaryKey,
      cardWidth: cardWidth,
      showRawFilenameOverride: widget.showRawVideoFilename,
      railPadH: railPadH,
    );
  }

  Widget _buildTabRail({
    required DetailDrawerTab tab,
    required List<Episode> episodes,
    required DetailSupplementaryViewData viewData,
    required List<MediaVariant> cdList,
    required List<MediaVariant> scanList,
    required String? activeSecondaryKey,
    double cardWidth = 244.0,
    bool compactMeta = false,
    bool? showRawFilenameOverride,
    double? railPadH,
  }) {
    final showSharedBadge = widget.bundle.seriesMembers.length >= 2;
    return switch (tab) {
      DetailDrawerTab.main || DetailDrawerTab.extra => _buildWheelRail(
        railPadH: railPadH,
        itemCount: episodes.length,
        itemBuilder: (_, index) => _buildCard(
          episodes[index],
          viewData.mainEpisodes.length,
          displayTitleOverride: tab == DetailDrawerTab.extra
              ? viewData.extraDisplayTitleByEpId[episodes[index].id]
              : null,
          cardWidth: cardWidth,
          compactMeta: compactMeta,
          showRawFilenameOverride: showRawFilenameOverride,
        ),
      ),
      DetailDrawerTab.cd => _buildWheelRail(
        railPadH: railPadH,
        itemCount: cdList.length,
        itemBuilder: (_, index) {
          final v = cdList[index];
          final group = viewData.cdSummary.byVariantId[v.id];
          final showDirectSubdir =
              activeSecondaryKey == null &&
              viewData.cdSummary.hasMultipleSubdirs;
          final cdWidth = cardWidth <= 216.0 ? 132.0 : 144.0;
          return CdDrawerCard(
            variant: v,
            source: widget.bundle.sourcesById[v.sourceId],
            workId: widget.bundle.work.id,
            workPosterPath:
                widget.bundle.work.posterPath ??
                widget.bundle.work.bangumiPosterPath,
            imageLoader: widget.imageLoader,
            cardWidth: cdWidth,
            showSeriesSharedBadge: showSharedBadge,
            displayTitleOverride: viewData.cdTitleOverrideFor(v),
            showRawFileName:
                showRawFilenameOverride ?? widget.showRawVideoFilename,
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
        railPadH: railPadH,
        itemCount: scanList.length,
        itemBuilder: (_, index) {
          final v = scanList[index];
          final group = viewData.scanSummary.byVariantId[v.id];
          final showDirectSubdir =
              activeSecondaryKey == null &&
              viewData.scanSummary.hasMultipleSubdirs;
          final scanWidth = cardWidth <= 216.0 ? 168.0 : 186.0;
          return ScanDrawerCard(
            variant: v,
            cardWidth: scanWidth,
            frameAspectRatio: 4 / 3,
            source: widget.bundle.sourcesById[v.sourceId],
            workId: widget.bundle.work.id,
            workTitle: widget.bundle.work.title,
            showSeriesSharedBadge: showSharedBadge,
            directSubdirLabel: showDirectSubdir
                ? group?.directSubdirShort
                : null,
            onTap: () =>
                widget.onScanTap?.call(v, volumeKey: activeSecondaryKey),
          );
        },
      ),
    };
  }

  Widget _buildWheelRail({
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    double? railPadH,
  }) {
    final effectivePadH =
        railPadH ??
        (KonataAdaptiveTokens.isAndroid &&
                MediaQuery.sizeOf(context).width <
                    KonataAdaptiveTokens.tabletBreakpoint
            ? 16.0
            : 36.0);
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
        padding: EdgeInsets.symmetric(horizontal: effectivePadH),
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
    double cardWidth = 244.0,
    bool compactMeta = false,
    bool? showRawFilenameOverride,
  }) {
    final variants = widget.bundle.variantsForEpisode(ep.id);
    final playback = widget.bundle.playbackByEpisodeId[ep.id];
    final markHandler = widget.onEpisodeMarkCompleted;
    final work = widget.bundle.work;
    final hasWorkBackdrop =
        work.backdropPath != null && work.backdropPath!.trim().isNotEmpty;
    return EpisodeDrawerCard(
      episode: ep,
      variants: variants,
      cardWidth: cardWidth,
      compactMeta: compactMeta,
      fallbackBackdropPath: hasWorkBackdrop
          ? work.backdropPath
          : work.posterPath,
      fallbackIsPoster: !hasWorkBackdrop,
      imageLoader: widget.imageLoader,
      workTitle: widget.bundle.work.title,
      workMediaType: widget.bundle.work.tmdbMediaType,
      mainEpisodeCount: mainEpisodeCount,
      displayTitleOverride: displayTitleOverride,
      showRawFileName: showRawFilenameOverride ?? widget.showRawVideoFilename,
      onTap: () => widget.onEpisodeTap(ep),
      onPlayBuiltin: widget.onEpisodePlayBuiltin == null
          ? null
          : () => widget.onEpisodePlayBuiltin!(ep),
      onPlayExternal: widget.onEpisodePlayExternal == null
          ? null
          : () => widget.onEpisodePlayExternal!(ep),
      onAdjustSlot: () => widget.onEpisodeAdjustSlot(ep),
      onShowMediaInfo: widget.onEpisodeMediaInfo == null
          ? null
          : () => widget.onEpisodeMediaInfo!(ep),
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
      borderRadius: KonataTheme.borderRadiusPill,
      child: BackdropFilter(
        filter: KonataTheme.blurFilterMedium,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(p),
            borderRadius: KonataTheme.borderRadiusPill,
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
