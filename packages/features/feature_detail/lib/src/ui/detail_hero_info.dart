import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_display_preferences.dart';
import '../state/detail_supplementary_view_data.dart';
import '../state/work_rescrape_state.dart';
import 'detail_gear_menu.dart';
import 'detail_rescrape_progress_pill.dart';
import 'detail_stylized_title_block.dart';
import 'inline_expandable_synopsis.dart';
import 'series_switcher_dropdown.dart';

/// 详情页主舞台信息区：承载标题/透明徽标、评分、剧情简介与统一双胶囊主操作行（开始/继续播放 + 系列胶囊）。
class DetailHeroInfo extends StatelessWidget {
  /// 创建详情主舞台信息区。
  const DetailHeroInfo({
    super.key,
    required this.bundle,
    required this.imageLoader,
    required this.rescrapeState,
    required this.displayPreferences,
    required this.onPlayPrimary,
    required this.onSelectSeriesWork,
    required this.onBuiltInAction,
    this.onDismissRescrape,
    this.compact = false,
    this.showOverview = true,
    this.onDarkBackdrop = true,
    this.useSeriesBottomSheet = false,
  });

  /// 当前作品详情聚合包。
  final WorkDetailBundle bundle;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 单作重刮进度状态机快照。
  final WorkRescrapeState rescrapeState;

  /// 展示偏好快照。
  final DetailDisplayPreferences displayPreferences;

  /// 点击主播放/继续播放按钮回调。
  final VoidCallback? onPlayPrimary;

  /// 切换同系列成员作品回调。
  final ValueChanged<String> onSelectSeriesWork;

  /// 触发内置编辑动作回调（如点击徽标直达换徽标）。
  final ValueChanged<DetailBuiltInGearAction> onBuiltInAction;

  /// 点击关闭完成/失败重刮胶囊回调。
  final VoidCallback? onDismissRescrape;

  /// 是否处于手机/窄屏紧凑模式。
  final bool compact;

  /// 是否在信息区内部渲染剧情简介（竖屏布局改为置于底部选集轨道下方时传 `false`）。
  final bool showOverview;

  /// 是否处于深色原画护字暗晕之上（影响浅色模式下主标题与元信息胶囊配色）。
  final bool onDarkBackdrop;

  /// 点击系列胶囊时是否优先使用底部全宽毛玻璃抽屉。
  final bool useSeriesBottomSheet;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = bundle.work;
    final resumePlan = bundle.resumePlan;
    final metaParts = <String>[
      if (work.year != null && work.year! > 0) '${work.year}',
      if (bundle.mainEpisodes.isNotEmpty) '${bundle.mainEpisodes.length} 话',
      if (work.bangumiScore != null && work.bangumiScore! > 0)
        'Bangumi ${work.bangumiScore!.toStringAsFixed(1)}',
    ];

    final playButtonText = resumePlan?.buttonLabel ?? '开始播放';
    final useLightInk = !onDarkBackdrop && !p.isDark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rescrapeState is! WorkRescrapeIdle) ...[
          DetailRescrapeProgressPill(
            state: rescrapeState,
            onDismiss: onDismissRescrape,
          ),
          const SizedBox(height: 10),
        ],
        DetailStylizedTitleBlock(
          work: work,
          imageLoader: imageLoader,
          isCompactViewport: compact,
          showTitleLogo: displayPreferences.showTitleLogo,
          onDarkBackdrop: onDarkBackdrop,
          onTapEditLogo: () =>
              onBuiltInAction(DetailBuiltInGearAction.editLogo),
        ),
        if (metaParts.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            metaParts.join(' · '),
            key: const ValueKey('detail_hero_metadata'),
            style: KonataTheme.detailHeroTitleStyle(
              fontSize: KonataTheme.fontSizeBody,
              weight: KonataTheme.weightH1,
              letterSpacing: 0.4,
              color: useLightInk
                  ? p.textPrimary
                  : KonataTheme.overlayWhiteTextHigh,
              shadows: useLightInk
                  ? KonataTheme.lightDetailTextShadows
                  : KonataTheme.detailTextShadows,
            ),
          ),
        ],
        if (showOverview &&
            displayPreferences.showOverview &&
            work.overview != null &&
            work.overview!.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: compact ? double.infinity : 496,
            ),
            child: InlineExpandableSynopsis(
              text: work.overview!,
              collapsedMaxLines: 3,
              maxExpandedHeight: compact ? 156 : 196,
              style: useLightInk
                  ? null
                  : KonataTheme.detailTextStyle(
                      fontSize: KonataTheme.fontSizeSubtitle,
                      fontWeight: FontWeight.w500,
                      height: 1.65,
                      letterSpacing: 0.35,
                      palette: p,
                      color: KonataTheme.overlayWhiteTextHigh,
                    ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (bundle.episodes.isNotEmpty)
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: KonataPillButton.primary(
                    key: const Key('detail_primary_play_button'),
                    borderColor: onDarkBackdrop
                        ? KonataTheme.overlayWhiteBorderStrong
                        : null,
                    label: playButtonText,
                    icon: Icons.play_arrow_rounded,
                    compact: compact,
                    onPressed: onPlayPrimary,
                  ),
                ),
              )
            else if (bundle.cdVariants.isNotEmpty)
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: KonataPillButton.primary(
                    key: const Key('detail_primary_audio_button'),
                    borderColor: onDarkBackdrop
                        ? KonataTheme.overlayWhiteBorderStrong
                        : null,
                    label: '播放音乐专辑',
                    icon: Icons.album_rounded,
                    compact: compact,
                    onPressed: onPlayPrimary,
                  ),
                ),
              ),
            if (bundle.seriesMembers.length >= 2) ...[
              if (bundle.episodes.isNotEmpty || bundle.cdVariants.isNotEmpty)
                const SizedBox(width: 10),
              Flexible(
                child: SeriesSwitcherDropdown(
                  activeWork: work,
                  members: bundle.seriesMembers,
                  seriesGroup: bundle.seriesGroup,
                  imageLoader: imageLoader,
                  onSelectWork: onSelectSeriesWork,
                  onDarkBackdrop: onDarkBackdrop,
                  compact: compact,
                  useBottomSheet: useSeriesBottomSheet,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
