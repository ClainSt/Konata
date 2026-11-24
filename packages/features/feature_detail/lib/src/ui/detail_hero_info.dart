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
    final mainCount = bundle.mainEpisodes.length;
    final extraCount = bundle.extraEpisodes.length;
    final cdCount = bundle.cdVariants.length;

    final primaryActionLabel = resumePlan?.buttonLabel ?? '开始播放';
    final primarySubLabel = _buildResumeSubLabel(bundle);
    final playButtonText = primarySubLabel != null
        ? '$primaryActionLabel · $primarySubLabel'
        : primaryActionLabel;
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
          showTitleText: displayPreferences.showTitleText,
          showTitleLogo: displayPreferences.showTitleLogo,
          onDarkBackdrop: onDarkBackdrop,
          onTapEditLogo: () => onBuiltInAction(DetailBuiltInGearAction.editLogo),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (work.bangumiScore != null && work.bangumiScore! > 0)
              BangumiScoreWordmarkBadge(score: work.bangumiScore!),
            if (work.year != null && work.year! > 0)
              _InfoMetaChip(
                label: '${work.year}',
                onDarkBackdrop: onDarkBackdrop,
              ),
            if (mainCount > 0)
              _InfoMetaChip(
                label: '$mainCount 集正片',
                onDarkBackdrop: onDarkBackdrop,
              ),
            if (extraCount > 0)
              _InfoMetaChip(
                label: '$extraCount 项特典',
                onDarkBackdrop: onDarkBackdrop,
              ),
            if (cdCount > 0)
              _InfoMetaChip(
                label: '$cdCount 张 CD',
                onDarkBackdrop: onDarkBackdrop,
              ),
            if (work.isManualLocked)
              _InfoMetaChip(
                label: '已人工锁定',
                icon: Icons.lock_outline_rounded,
                onDarkBackdrop: onDarkBackdrop,
              ),
          ],
        ),
        if (showOverview &&
            displayPreferences.showOverview &&
            work.overview != null &&
            work.overview!.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? double.infinity : 680),
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

  String? _buildResumeSubLabel(WorkDetailBundle bundle) {
    final plan = bundle.resumePlan;
    if (plan == null) return null;
    final ep = plan.targetEpisode;
    if (ep.episodeNumber == null) return null;
    if (bundle.work.tmdbMediaType == TmdbMediaType.movie &&
        bundle.mainEpisodes.length <= 1) {
      return null;
    }
    return '第 ${ep.episodeNumber} 话';
  }
}

class _InfoMetaChip extends StatelessWidget {
  const _InfoMetaChip({
    required this.label,
    this.icon,
    this.onDarkBackdrop = true,
  });

  final String label;
  final IconData? icon;
  final bool onDarkBackdrop;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final useDarkStyle = onDarkBackdrop || p.isDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
      decoration: BoxDecoration(
        color: useDarkStyle
            ? const Color(0x30141820)
            : KonataPlaybackTokens.glassSurface(p),
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(
          color: useDarkStyle
              ? KonataTheme.overlayWhiteBorderStrong
              : KonataPlaybackTokens.glassBorder(p),
          width: 0.9,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 12.5,
              color: useDarkStyle
                  ? KonataTheme.overlayWhiteTextSub
                  : p.textSecondary,
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: useDarkStyle
                  ? KonataTheme.overlayWhiteTextHigh
                  : p.textPrimary,
              fontSize: KonataTheme.fontSizeBadge,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
