import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_display_preferences.dart';
import '../state/detail_supplementary_view_data.dart';
import 'detail_secondary_filter_bar.dart';
import 'episode_drawer_card.dart';
import 'supplementary_asset_cards.dart';

/// 详情页「查看全部」全量选集 / 特典 / CD 网格毛玻璃弹窗。
class DetailFullListDialog extends StatefulWidget {
  /// 创建完整列表弹窗。
  const DetailFullListDialog({
    super.key,
    required this.bundle,
    required this.initialTabId,
    required this.imageLoader,
    required this.displayPreferences,
    required this.onTapEpisode,
    required this.onTapCdVariant,
    required this.onInspectEpisodeInfo,
  });

  /// 当前作品详情数据包。
  final WorkDetailBundle bundle;

  /// 初始选中内置标签页。
  final String initialTabId;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 展示偏好快照。
  final DetailDisplayPreferences displayPreferences;

  /// 点击播放剧集回调。
  final ValueChanged<Episode> onTapEpisode;

  /// 点击播放 CD 回调。
  final ValueChanged<MediaVariant> onTapCdVariant;

  /// 查看单集技术参数回调。
  final ValueChanged<Episode> onInspectEpisodeInfo;

  @override
  State<DetailFullListDialog> createState() => _DetailFullListDialogState();
}

class _DetailFullListDialogState extends State<DetailFullListDialog> {
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bundle;
    final mains = b.mainEpisodes;
    final extras = b.extraEpisodes;
    final cds = b.cdVariants;
    final multiSeason =
        DetailSupplementaryHelper.groupMainBySeason(mains).length > 1;

    final title = switch (widget.initialTabId) {
      DetailDrawerTabIds.extras => '${b.work.title} · 全部特典 (${extras.length})',
      DetailDrawerTabIds.cd => '${b.work.title} · 全部 CD (${cds.length})',
      _ => '${b.work.title} · 全部正片 (${mains.length})',
    };

    return KonataGlassDialog(
      width: 920,
      maxHeight: 680,
      title: title,
      child: KonataDraggableScrollbar(
        controller: _scrollCtrl,
        builder: (_, ctrl) {
          if (widget.initialTabId == DetailDrawerTabIds.cd) {
            final subdirHints = DetailSupplementaryHelper.buildCdSubdirHints(
              cds,
            );
            return GridView.builder(
              controller: ctrl,
              padding: const EdgeInsets.only(right: 12, bottom: 8),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 176,
                mainAxisSpacing: 16,
                crossAxisSpacing: 14,
                childAspectRatio: 0.68,
              ),
              itemCount: cds.length,
              itemBuilder: (_, index) {
                final v = cds[index];
                return CdDrawerCard(
                  variant: v,
                  source: b.sourcesById[v.sourceId],
                  workId: b.work.id,
                  workPosterPath: b.work.posterPath ?? b.work.bangumiPosterPath,
                  imageLoader: widget.imageLoader,
                  showSeriesSharedBadge: b.seriesMembers.length >= 2,
                  directSubdirLabel: subdirHints[v.id],
                  showRawFileName:
                      widget.displayPreferences.showOriginalSubtitlesOnCards,
                  onDarkBackdrop: context.palette.isDark,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onTapCdVariant(v);
                  },
                );
              },
            );
          }

          final items = widget.initialTabId == DetailDrawerTabIds.extras
              ? extras
              : mains;
          return GridView.builder(
            controller: ctrl,
            padding: const EdgeInsets.only(right: 12, bottom: 8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 260,
              mainAxisSpacing: 16,
              crossAxisSpacing: 14,
              childAspectRatio: 1.18,
            ),
            itemCount: items.length,
            itemBuilder: (_, index) {
              final ep = items[index];
              return EpisodeDrawerCard(
                episode: ep,
                variants: b.variantsForEpisode(ep.id),
                playback: b.playbackByEpisodeId[ep.id],
                imageLoader: widget.imageLoader,
                workTitle: b.work.title,
                workMediaType: b.work.tmdbMediaType,
                mainEpisodeCount: mains.length,
                showSeasonPrefix:
                    multiSeason && ep.category == EpisodeCategory.main,
                showStillThumbnail:
                    widget.displayPreferences.showEpisodeStillThumbnails,
                showOriginalFileName:
                    widget.displayPreferences.showOriginalSubtitlesOnCards,
                workBackdropFallbackPath: b.effectiveHeroBackdropPath,
                workPosterFallbackPath:
                    b.work.posterPath ?? b.work.bangumiPosterPath,
                workPosterOwnerId: b.effectiveHeroBackdropOwnerId,
                onDarkBackdrop: context.palette.isDark,
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onTapEpisode(ep);
                },
                onShowMediaInfo: () => widget.onInspectEpisodeInfo(ep),
              );
            },
          );
        },
      ),
    );
  }
}
