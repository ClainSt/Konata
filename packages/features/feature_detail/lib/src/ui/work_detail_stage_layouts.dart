import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_display_preferences.dart';
import '../state/detail_supplementary_view_data.dart';
import '../state/work_rescrape_state.dart';
import 'detail_bottom_drawer.dart';
import 'detail_gear_menu.dart';
import 'detail_hero_info.dart';
import 'inline_expandable_synopsis.dart';
import 'work_detail_sub_views.dart';

/// 桌面与平板横屏全幅 16:9 原画沉浸舞台布局。
class DetailWideOverlayStageLayout extends StatelessWidget {
  /// 创建宽屏沉浸详情舞台。
  const DetailWideOverlayStageLayout({
    super.key,
    required this.bundle,
    required this.displayPreferences,
    required this.rescrapeState,
    required this.imageLoader,
    required this.heroScrollController,
    required this.safePad,
    required this.bottomClearance,
    required this.drawerExpanded,
    required this.mergedExternalActions,
    required this.onBack,
    required this.onCollapseDrawer,
    required this.onDrawerExpandedChanged,
    required this.onPlayPrimary,
    required this.onSelectSeriesWork,
    required this.onDismissRescrape,
    required this.onBuiltInAction,
    required this.onInvokeExternalAction,
    required this.onTapEpisode,
    required this.onTapCdVariant,
    required this.onInspectEpisodeInfo,
    required this.onOpenFullList,
    required this.reviewBanner,
    this.initialTabId,
  });

  /// 作品详情聚合包。
  final WorkDetailBundle bundle;

  /// 展示偏好快照。
  final DetailDisplayPreferences displayPreferences;

  /// 重刮状态机快照。
  final WorkRescrapeState rescrapeState;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 主舞台信息区滚动控制器。
  final ScrollController heroScrollController;

  /// 系统安全区边距。
  final EdgeInsets safePad;

  /// 底部避让高度。
  final double bottomClearance;

  /// 底部抽屉当前是否展开。
  final bool drawerExpanded;

  /// 统一收口后的全部外部扩展动作列表。
  final List<DetailActionContribution> mergedExternalActions;

  /// 可选初始激活抽屉分类标识。
  final String? initialTabId;

  /// 待复核横幅组件（无须显示时传 `null`）。
  final Widget? reviewBanner;

  /// 返回上一页回调。
  final VoidCallback onBack;

  /// 点击背景原画收起选集抽屉回调。
  final VoidCallback onCollapseDrawer;

  /// 抽屉展开状态变化回调。
  final ValueChanged<bool> onDrawerExpandedChanged;

  /// 主播放按钮点击回调。
  final VoidCallback onPlayPrimary;

  /// 切换同系列成员回调。
  final ValueChanged<String> onSelectSeriesWork;

  /// 关闭重刮状态胶囊回调。
  final VoidCallback onDismissRescrape;

  /// 内置齿轮动作回调。
  final ValueChanged<DetailBuiltInGearAction> onBuiltInAction;

  /// 外部齿轮动作回调。
  final ValueChanged<DetailActionContribution> onInvokeExternalAction;

  /// 点击单集卡片回调。
  final ValueChanged<Episode> onTapEpisode;

  /// 点击 CD 专辑卡片回调。
  final ValueChanged<MediaVariant> onTapCdVariant;

  /// 查看单集媒体详情回调。
  final ValueChanged<Episode> onInspectEpisodeInfo;

  /// 打开完整列表弹窗回调。
  final ValueChanged<String> onOpenFullList;

  @override
  Widget build(BuildContext context) {
    final work = bundle.work;
    final effectiveBackdrop = bundle.effectiveHeroBackdrop;
    final hasBackdrop = effectiveBackdrop != null;
    final fallbackPoster = (work.posterPath?.trim().isNotEmpty ?? false)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim() ?? '');
    final bgPath = hasBackdrop ? effectiveBackdrop.path : fallbackPoster;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          key: const ValueKey<String>('detail_wide_backdrop_stage'),
          child: GestureDetector(
            key: const Key('detail_wide_backdrop_dismiss_area'),
            behavior: HitTestBehavior.translucent,
            onTap: drawerExpanded ? onCollapseDrawer : null,
            child: DetailWideBackdropStage(
              workId: work.id,
              backdropOwnerWorkId: hasBackdrop
                  ? effectiveBackdrop.ownerWorkId
                  : work.id,
              bgPath: bgPath,
              hasBackdrop: hasBackdrop,
              fallbackPosterPath: fallbackPoster,
              showHeroBackdrop: displayPreferences.showMainHeroBackdrop,
              isDrawerExpanded: drawerExpanded,
              imageLoader: imageLoader,
            ),
          ),
        ),
        Positioned.fill(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: safePad.top + 58),
              Expanded(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: SingleChildScrollView(
                    controller: heroScrollController,
                    hitTestBehavior: HitTestBehavior.deferToChild,
                    padding: const EdgeInsets.fromLTRB(36, 8, 36, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DetailHeroInfo(
                          bundle: bundle,
                          imageLoader: imageLoader,
                          rescrapeState: rescrapeState,
                          displayPreferences: displayPreferences,
                          compact: false,
                          showOverview: true,
                          onDarkBackdrop: true,
                          useSeriesBottomSheet: false,
                          onPlayPrimary: onPlayPrimary,
                          onSelectSeriesWork: onSelectSeriesWork,
                          onDismissRescrape: onDismissRescrape,
                          onBuiltInAction: onBuiltInAction,
                        ),
                        if (reviewBanner != null) ...[
                          const SizedBox(height: 12),
                          reviewBanner!,
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  36.0,
                  0,
                  36.0,
                  math.max(12.0, bottomClearance),
                ),
                child: DetailBottomDrawer(
                  bundle: bundle,
                  imageLoader: imageLoader,
                  displayPreferences: displayPreferences,
                  initialTabId: initialTabId,
                  expanded: drawerExpanded,
                  onExpandedChanged: onDrawerExpandedChanged,
                  showGearButton: true,
                  gearButton: DetailGearMenu(
                    work: work,
                    externalActions: mergedExternalActions,
                    onBuiltInAction: onBuiltInAction,
                    onInvokeExternalAction: onInvokeExternalAction,
                    compact: false,
                  ),
                  onDarkBackdrop: true,
                  compact: false,
                  inlineMode: false,
                  onTapEpisode: onTapEpisode,
                  onTapCdVariant: onTapCdVariant,
                  onInspectEpisodeInfo: onInspectEpisodeInfo,
                  onOpenFullList: onOpenFullList,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: safePad.top + 12,
          left: math.max(16.0, safePad.left + 12),
          right: math.max(16.0, safePad.right + 12),
          child: WorkDetailTopBar(onBack: onBack),
        ),
      ],
    );
  }
}

/// 手机纯竖屏与平板竖屏沉浸流式舞台布局（竖版无字原画吸色溶底 + 横向选集卡轨道 + 下置作品简介）。
class DetailPortraitStageLayout extends StatelessWidget {
  /// 创建竖屏流式详情舞台。
  const DetailPortraitStageLayout({
    super.key,
    required this.bundle,
    required this.displayPreferences,
    required this.rescrapeState,
    required this.imageLoader,
    required this.scrollController,
    required this.viewport,
    required this.safePad,
    required this.bottomClearance,
    required this.dissolveColor,
    required this.isPhone,
    required this.showDesktopChrome,
    required this.drawerExpanded,
    required this.mergedExternalActions,
    required this.onBack,
    required this.onDrawerExpandedChanged,
    required this.onPlayPrimary,
    required this.onSelectSeriesWork,
    required this.onDismissRescrape,
    required this.onBuiltInAction,
    required this.onInvokeExternalAction,
    required this.onTapEpisode,
    required this.onTapCdVariant,
    required this.onInspectEpisodeInfo,
    required this.onOpenFullList,
    required this.reviewBanner,
    this.initialTabId,
  });

  /// 作品详情聚合包。
  final WorkDetailBundle bundle;

  /// 展示偏好快照。
  final DetailDisplayPreferences displayPreferences;

  /// 重刮状态机快照。
  final WorkRescrapeState rescrapeState;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 竖屏主滚动控制器。
  final ScrollController scrollController;

  /// 当前视口尺寸。
  final Size viewport;

  /// 系统安全区边距。
  final EdgeInsets safePad;

  /// 底部避让高度。
  final double bottomClearance;

  /// 竖版原画底部吸色合成的主题溶底背景色。
  final Color dissolveColor;

  /// 是否处于手机形态（开启紧凑胶囊与底部系列抽屉）。
  final bool isPhone;

  /// 是否挂载桌面端窗口控制组件。
  final bool showDesktopChrome;

  /// 底部抽屉当前是否展开。
  final bool drawerExpanded;

  /// 统一收口后的全部外部扩展动作列表。
  final List<DetailActionContribution> mergedExternalActions;

  /// 可选初始激活抽屉分类标识。
  final String? initialTabId;

  /// 待复核横幅组件（无须显示时传 `null`）。
  final Widget? reviewBanner;

  /// 返回上一页回调。
  final VoidCallback onBack;

  /// 抽屉展开状态变化回调。
  final ValueChanged<bool> onDrawerExpandedChanged;

  /// 主播放按钮点击回调。
  final VoidCallback onPlayPrimary;

  /// 切换同系列成员回调。
  final ValueChanged<String> onSelectSeriesWork;

  /// 关闭重刮状态胶囊回调。
  final VoidCallback onDismissRescrape;

  /// 内置齿轮动作回调。
  final ValueChanged<DetailBuiltInGearAction> onBuiltInAction;

  /// 外部齿轮动作回调。
  final ValueChanged<DetailActionContribution> onInvokeExternalAction;

  /// 点击单集卡片回调。
  final ValueChanged<Episode> onTapEpisode;

  /// 点击 CD 专辑卡片回调。
  final ValueChanged<MediaVariant> onTapCdVariant;

  /// 查看单集媒体详情回调。
  final ValueChanged<Episode> onInspectEpisodeInfo;

  /// 打开完整列表弹窗回调。
  final ValueChanged<String> onOpenFullList;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = bundle.work;
    final padH = math.max(16.0, safePad.left + 12);
    final isCompactLayout = isPhone || viewport.width < 560;
    final useBottomSheetSeries = isPhone || viewport.width < 600;
    final isTabletPortrait = viewport.width >= 560;
    final heroHeight = isTabletPortrait
        ? (viewport.height * 0.46).clamp(300.0, 520.0)
        : (viewport.height * 0.48).clamp(290.0, 420.0);
    final artworkClearance = math.max(
      safePad.top + 88.0,
      heroHeight * 0.62,
    );
    final hasOverview =
        displayPreferences.showOverview &&
        work.overview != null &&
        work.overview!.trim().isNotEmpty;

    return Stack(
      fit: StackFit.expand,
      children: [
        SingleChildScrollView(
          key: const ValueKey<String>('detail_scrollable_stage'),
          controller: scrollController,
          padding: EdgeInsets.only(bottom: 24 + bottomClearance),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: DetailPortraitHeroHeader(
                      work: work,
                      imageLoader: imageLoader,
                      viewportWidth: viewport.width,
                      viewportHeight: viewport.height,
                      dissolveColor: dissolveColor,
                      showHeroBackdrop: displayPreferences.showMainHeroBackdrop,
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: artworkClearance),
                      Padding(
                        padding: EdgeInsets.fromLTRB(padH, 0, padH, 0),
                        child: DetailHeroInfo(
                          bundle: bundle,
                          imageLoader: imageLoader,
                          rescrapeState: rescrapeState,
                          displayPreferences: displayPreferences,
                          compact: isCompactLayout,
                          showOverview: false,
                          onDarkBackdrop: p.isDark,
                          useSeriesBottomSheet: useBottomSheetSeries,
                          onPlayPrimary: onPlayPrimary,
                          onSelectSeriesWork: onSelectSeriesWork,
                          onDismissRescrape: onDismissRescrape,
                          onBuiltInAction: onBuiltInAction,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (reviewBanner != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: padH),
                  child: reviewBanner!,
                ),
              ],
              const SizedBox(height: 14),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: padH),
                child: DetailBottomDrawer(
                  bundle: bundle,
                  imageLoader: imageLoader,
                  displayPreferences: displayPreferences,
                  initialTabId: initialTabId,
                  expanded: drawerExpanded,
                  onExpandedChanged: onDrawerExpandedChanged,
                  showGearButton: false,
                  onDarkBackdrop: p.isDark,
                  compact: isCompactLayout,
                  inlineMode: true,
                  onTapEpisode: onTapEpisode,
                  onTapCdVariant: onTapCdVariant,
                  onInspectEpisodeInfo: onInspectEpisodeInfo,
                  onOpenFullList: onOpenFullList,
                ),
              ),
              if (hasOverview) ...[
                const SizedBox(height: 18),
                Padding(
                  key: const Key('detail_portrait_synopsis_section'),
                  padding: EdgeInsets.symmetric(horizontal: padH),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '作品简介',
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: KonataTheme.fontSizeCaption,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      InlineExpandableSynopsis(
                        text: work.overview!,
                        collapsedMaxLines: 4,
                        maxExpandedHeight: 220,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Positioned(
          top: safePad.top + 10,
          left: padH,
          right: padH,
          child: WorkDetailTopBar(
            showDesktopChrome: showDesktopChrome,
            onBack: onBack,
            trailing: DetailGearMenu(
              work: work,
              externalActions: mergedExternalActions,
              onBuiltInAction: onBuiltInAction,
              onInvokeExternalAction: onInvokeExternalAction,
              compact: isCompactLayout,
            ),
          ),
        ),
      ],
    );
  }
}

/// 弹出「移出媒体库」二次确认毛玻璃弹窗，返回是否确认删除与是否加入忽略扫描名单。
Future<({bool confirmed, bool addToIgnore})?> showConfirmDeleteWorkDialog(
  BuildContext context, {
  required String workTitle,
}) async {
  var addToIgnore = false;
  final confirmed = await showKonataGlassDialog<bool>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final p = ctx.palette;
        return KonataGlassDialog(
          width: 440,
          title: '移出媒体库 · $workTitle',
          onClose: () => Navigator.of(ctx).pop(false),
          actions: [
            KonataPillButton.ghost(
              label: '取消',
              compact: true,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            KonataPillButton.danger(
              label: '确认移出',
              compact: true,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '此操作仅移除媒体库索引记录与本地海报缓存，绝不会删除网盘或磁盘上的任何原始视频文件。',
                style: KonataTheme.bodyLabelStyle(
                  p,
                  color: p.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  KonataSwitch(
                    value: addToIgnore,
                    onChanged: (v) => setDialogState(() => addToIgnore = v),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '同时将该目录加入忽略扫描名单',
                      style: KonataTheme.captionStyle(
                        p,
                      ).copyWith(color: p.textPrimary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
  if (confirmed != true) return null;
  return (confirmed: true, addToIgnore: addToIgnore);
}
