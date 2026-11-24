import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_display_preferences.dart';
import '../state/detail_supplementary_view_data.dart';
import '../state/work_rescrape_state.dart';
import 'detail_gear_menu.dart';
import 'detail_rescrape_progress_pill.dart';
import 'detail_stylized_title_block.dart';
import 'inline_expandable_synopsis.dart';
import 'series_switcher_dropdown.dart';

/// 详情页主舞台信息区：承载标题/透明徽标、评分、剧情简介、主播放按钮、动态扩展动作及齿轮菜单。
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
    required this.onInvokeExternalAction,
    this.onDismissRescrape,
    this.compact = false,
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

  /// 触发内置菜单或工具按钮动作回调。
  final ValueChanged<DetailBuiltInGearAction> onBuiltInAction;

  /// 触发外部通过 `DetailActionContribution` 注入的动作回调。
  final ValueChanged<DetailActionContribution> onInvokeExternalAction;

  /// 点击关闭完成/失败重刮胶囊回调。
  final VoidCallback? onDismissRescrape;

  /// 是否处于手机/窄屏紧凑模式。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final work = bundle.work;
    final resumePlan = bundle.resumePlan;
    final isRescrapeRunning = rescrapeState is WorkRescrapeRunning;
    final mainCount = bundle.mainEpisodes.length;
    final extraCount = bundle.extraEpisodes.length;
    final cdCount = bundle.cdVariants.length;

    final primaryActionLabel = resumePlan?.buttonLabel ?? '开始播放';
    final primarySubLabel = _buildResumeSubLabel(bundle);

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
              _InfoMetaChip(label: '${work.year}'),
            if (mainCount > 0) _InfoMetaChip(label: '$mainCount 集正片'),
            if (extraCount > 0) _InfoMetaChip(label: '$extraCount 项特典'),
            if (cdCount > 0) _InfoMetaChip(label: '$cdCount 张 CD'),
            if (work.isManualLocked)
              const _InfoMetaChip(
                label: '已人工锁定',
                icon: Icons.lock_outline_rounded,
              ),
          ],
        ),
        if (work.overview != null && work.overview!.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? double.infinity : 680),
            child: InlineExpandableSynopsis(
              text: work.overview!,
              collapsedMaxLines: compact ? 3 : 3,
              maxExpandedHeight: compact ? 156 : 196,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (bundle.episodes.isNotEmpty)
              KonataPillButton.primary(
                key: const Key('detail_primary_play_button'),
                label: primarySubLabel != null
                    ? '$primaryActionLabel · $primarySubLabel'
                    : primaryActionLabel,
                icon: Icons.play_arrow_rounded,
                compact: compact,
                onPressed: onPlayPrimary,
              )
            else if (bundle.cdVariants.isNotEmpty)
              KonataPillButton.primary(
                key: const Key('detail_primary_audio_button'),
                label: '播放音乐专辑',
                icon: Icons.album_rounded,
                compact: compact,
                onPressed: onPlayPrimary,
              ),
            if (bundle.seriesMembers.length >= 2)
              SeriesSwitcherDropdown(
                activeWork: work,
                seriesMembers: bundle.seriesMembers,
                seriesGroup: bundle.seriesGroup,
                onSelectWork: onSelectSeriesWork,
                compact: compact,
              ),
            for (final action in bundle.primaryBarActions)
              KonataPillButton.secondary(
                key: ValueKey<String>('detail_ext_primary_${action.id}'),
                label: action.label,
                icon: KonataIconRegistry.resolve(action.iconKey),
                compact: compact,
                onPressed: () => onInvokeExternalAction(action),
              ),
            KonataPillButton.secondary(
              key: const Key('detail_rescrape_button'),
              label: isRescrapeRunning ? '重刮中...' : '刷新元数据',
              icon: Icons.refresh_rounded,
              compact: compact,
              onPressed: isRescrapeRunning
                  ? null
                  : () => onBuiltInAction(DetailBuiltInGearAction.rescrape),
            ),
            DetailGearMenu(
              work: work,
              externalActions: bundle.gearMenuActions,
              onBuiltInAction: onBuiltInAction,
              onInvokeExternalAction: onInvokeExternalAction,
              compact: compact,
            ),
          ],
        ),
        if (bundle.folderPath != null &&
            bundle.folderPath!.trim().isNotEmpty &&
            displayPreferences.showOriginalSubtitlesOnCards) ...[
          const SizedBox(height: 8),
          Text(
            bundle.folderPath!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: KonataTheme.detailTextStyle(
              palette: p,
              fontSize: KonataTheme.fontSizeBadge,
              fontWeight: FontWeight.w500,
              color: p.isDark
                  ? KonataTheme.overlayWhiteTextMuted
                  : KonataTheme.detailSecondaryTextColor(p),
            ),
          ),
        ],
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
  const _InfoMetaChip({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
      decoration: BoxDecoration(
        color: KonataPlaybackTokens.glassSurface(p),
        borderRadius: KonataTheme.borderRadiusPill,
        border: Border.all(
          color: KonataPlaybackTokens.glassBorder(p),
          width: 0.9,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12.5, color: p.textSecondary),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: p.textPrimary,
              fontSize: KonataTheme.fontSizeBadge,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
