import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_display_preferences.dart';
import '../state/detail_supplementary_view_data.dart';
import 'detail_secondary_filter_bar.dart';
import 'episode_drawer_card.dart';
import 'supplementary_asset_cards.dart';

/// 详情页底部内容抽屉：聚合正片（支持分季）、特典（支持按类型细分）、CD 专辑与动态扩展标签页视图。
class DetailBottomDrawer extends StatefulWidget {
  /// 创建详情页底部内容抽屉。
  const DetailBottomDrawer({
    super.key,
    required this.bundle,
    required this.imageLoader,
    required this.displayPreferences,
    required this.onTapEpisode,
    required this.onTapCdVariant,
    required this.onInspectEpisodeInfo,
    required this.onOpenFullList,
    this.initialTabId,
    this.compact = false,
    this.inlineMode = false,
  });

  /// 作品详情聚合包。
  final WorkDetailBundle bundle;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 展示偏好快照。
  final DetailDisplayPreferences displayPreferences;

  /// 初始高亮标签页标识（外部深链跳转时使用）。
  final String? initialTabId;

  /// 点击正片或特典卡片回调。
  final ValueChanged<Episode> onTapEpisode;

  /// 点击音乐 CD 专辑卡片回调。
  final ValueChanged<MediaVariant> onTapCdVariant;

  /// 右键/更多查看单集物理变体技术信息回调。
  final ValueChanged<Episode> onInspectEpisodeInfo;

  /// 点击「查看全部」打开网格完整列表回调（传入当前内置标签页标识）。
  final ValueChanged<String> onOpenFullList;

  /// 是否紧凑视觉尺寸。
  final bool compact;

  /// 是否为手机竖屏内联流式模式（高度自适应而非横向单轨定高）。
  final bool inlineMode;

  @override
  State<DetailBottomDrawer> createState() => _DetailBottomDrawerState();
}

class _DetailBottomDrawerState extends State<DetailBottomDrawer> {
  final ScrollController _trackScrollCtrl = ScrollController();
  late String _activeTabId;
  String? _activeSeasonFilterId;
  String? _activeExtraKindFilterId;

  @override
  void initState() {
    super.initState();
    _activeTabId = _resolveInitialTabId(widget.initialTabId);
    _syncDefaultSubFilters();
  }

  @override
  void didUpdateWidget(covariant DetailBottomDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bundle.work.id != widget.bundle.work.id ||
        oldWidget.initialTabId != widget.initialTabId) {
      _activeTabId = _resolveInitialTabId(widget.initialTabId);
      _syncDefaultSubFilters();
    } else if (!_isTabCurrentlyAvailable(_activeTabId)) {
      _activeTabId = _resolveInitialTabId(null);
      _syncDefaultSubFilters();
    }
  }

  @override
  void dispose() {
    _trackScrollCtrl.dispose();
    super.dispose();
  }

  bool _isTabCurrentlyAvailable(String tabId) {
    final b = widget.bundle;
    if (tabId == DetailDrawerTabIds.episodes) {
      return b.mainEpisodes.isNotEmpty ||
          (b.extraEpisodes.isEmpty && b.cdVariants.isEmpty);
    }
    if (tabId == DetailDrawerTabIds.extras) {
      return b.extraEpisodes.isNotEmpty;
    }
    if (tabId == DetailDrawerTabIds.cd) {
      return b.cdVariants.isNotEmpty;
    }
    return b.visibleTabs.any((t) => t.id == tabId);
  }

  String _resolveInitialTabId(String? requested) {
    if (requested != null &&
        requested.isNotEmpty &&
        _isTabCurrentlyAvailable(requested)) {
      return requested;
    }
    if (widget.bundle.mainEpisodes.isNotEmpty) {
      return DetailDrawerTabIds.episodes;
    }
    if (widget.bundle.extraEpisodes.isNotEmpty) {
      return DetailDrawerTabIds.extras;
    }
    if (widget.bundle.cdVariants.isNotEmpty) {
      return DetailDrawerTabIds.cd;
    }
    if (widget.bundle.visibleTabs.isNotEmpty) {
      return widget.bundle.visibleTabs.first.id;
    }
    return DetailDrawerTabIds.episodes;
  }

  void _syncDefaultSubFilters() {
    final seasons = DetailSupplementaryHelper.groupMainBySeason(
      widget.bundle.mainEpisodes,
    );
    _activeSeasonFilterId = seasons.isNotEmpty
        ? 's_${seasons.first.seasonNumber}'
        : null;
    _activeExtraKindFilterId = 'all';
  }

  DetailTabContribution? _findExternalTab(String id) {
    for (final tab in widget.bundle.visibleTabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bundle;
    final mains = b.mainEpisodes;
    final extras = b.extraEpisodes;
    final cds = b.cdVariants;
    final seasonGroups = DetailSupplementaryHelper.groupMainBySeason(mains);
    final multiSeason = seasonGroups.length > 1;

    final subFilters = <({String id, String label, int count})>[];
    String? activeSubId;
    if (_activeTabId == DetailDrawerTabIds.episodes && multiSeason) {
      subFilters.add((id: 'all', label: '全部分季', count: mains.length));
      for (final g in seasonGroups) {
        subFilters.add((
          id: 's_${g.seasonNumber}',
          label: g.label,
          count: g.episodes.length,
        ));
      }
      activeSubId = _activeSeasonFilterId ?? 'all';
    } else if (_activeTabId == DetailDrawerTabIds.extras && extras.isNotEmpty) {
      final byKind = <ExtraKind, List<Episode>>{};
      for (final e in extras) {
        final k = e.extraType ?? ExtraKind.sp;
        byKind.putIfAbsent(k, () => <Episode>[]).add(e);
      }
      if (byKind.length > 1) {
        subFilters.add((id: 'all', label: '全部特典', count: extras.length));
        for (final entry in byKind.entries) {
          subFilters.add((
            id: entry.key.name,
            label: entry.key.name.toUpperCase(),
            count: entry.value.length,
          ));
        }
        activeSubId = _activeExtraKindFilterId ?? 'all';
      }
    }

    final isExternal = _findExternalTab(_activeTabId) != null;
    final canOpenFullList =
        !isExternal &&
        ((_activeTabId == DetailDrawerTabIds.episodes && mains.isNotEmpty) ||
            (_activeTabId == DetailDrawerTabIds.extras && extras.isNotEmpty) ||
            (_activeTabId == DetailDrawerTabIds.cd && cds.isNotEmpty));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSecondaryFilterBar(
          activeTabId: _activeTabId,
          mainEpisodeCount: mains.length,
          extraEpisodeCount: extras.length,
          cdCount: cds.length,
          externalTabs: b.visibleTabs,
          subFilterChips: subFilters,
          activeSubFilterId: activeSubId,
          compact: widget.compact,
          onSelectTab: (tabId) {
            if (_activeTabId == tabId) return;
            setState(() => _activeTabId = tabId);
          },
          onSelectSubFilter: (subId) {
            setState(() {
              if (_activeTabId == DetailDrawerTabIds.episodes) {
                _activeSeasonFilterId = subId;
              } else if (_activeTabId == DetailDrawerTabIds.extras) {
                _activeExtraKindFilterId = subId;
              }
            });
          },
          trailing: canOpenFullList
              ? KonataPillButton.ghost(
                  key: const Key('detail_drawer_view_all_button'),
                  label: '查看全部',
                  icon: Icons.grid_view_rounded,
                  compact: true,
                  onPressed: () => widget.onOpenFullList(_activeTabId),
                )
              : null,
        ),
        const SizedBox(height: 12),
        _buildActiveContent(
          context,
          mains: mains,
          extras: extras,
          cds: cds,
          multiSeason: multiSeason,
        ),
      ],
    );
  }

  Widget _buildActiveContent(
    BuildContext context, {
    required List<Episode> mains,
    required List<Episode> extras,
    required List<MediaVariant> cds,
    required bool multiSeason,
  }) {
    final extTab = _findExternalTab(_activeTabId);
    if (extTab != null) {
      final slotResult = extTab.viewBuilder(
        ViewSlotContext(
          platformContext: context,
          workId: WorkId.trusted(widget.bundle.work.id),
          arguments: <String, Object?>{
            'workTitle': widget.bundle.work.title,
            'seriesId': widget.bundle.work.seriesId,
          },
        ),
      );
      if (slotResult is Widget) {
        return ConstrainedBox(
          key: ValueKey<String>('detail_external_tab_slot_${extTab.id}'),
          constraints: BoxConstraints(
            minHeight: widget.inlineMode ? 180 : 210,
            maxHeight: widget.inlineMode ? 420 : 256,
          ),
          child: slotResult,
        );
      }
      return const SizedBox.shrink();
    }

    if (_activeTabId == DetailDrawerTabIds.cd) {
      return _buildCdTrack(context, cds);
    }

    final List<Episode> displayed;
    if (_activeTabId == DetailDrawerTabIds.extras) {
      final filter = _activeExtraKindFilterId;
      displayed = (filter == null || filter == 'all')
          ? extras
          : extras
                .where((e) => (e.extraType ?? ExtraKind.sp).name == filter)
                .toList(growable: false);
    } else {
      final filter = _activeSeasonFilterId;
      if (filter == null || filter == 'all' || !multiSeason) {
        displayed = mains;
      } else {
        final seasonNum = int.tryParse(filter.replaceFirst('s_', ''));
        displayed = seasonNum == null
            ? mains
            : mains
                  .where((e) => e.seasonNumber == seasonNum)
                  .toList(growable: false);
      }
    }

    if (displayed.isEmpty) {
      return _buildEmptyPlaceholder(
        context,
        _activeTabId == DetailDrawerTabIds.extras ? '暂无特典视频' : '暂无可播放正片剧集',
      );
    }

    return _buildEpisodeTrack(
      context,
      displayed,
      multiSeason: multiSeason,
      mainCount: mains.length,
    );
  }

  Widget _buildEpisodeTrack(
    BuildContext context,
    List<Episode> episodes, {
    required bool multiSeason,
    required int mainCount,
  }) {
    final b = widget.bundle;
    final cardWidth = widget.compact ? 196.0 : 228.0;
    final cardHeight =
        cardWidth * 9 / 16 +
        (widget.displayPreferences.showOriginalSubtitlesOnCards ? 54.0 : 34.0);

    return SizedBox(
      height: cardHeight,
      child: Scrollbar(
        controller: _trackScrollCtrl,
        thumbVisibility: true,
        interactive: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        child: ListView.separated(
          controller: _trackScrollCtrl,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 10),
          itemCount: episodes.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (_, index) {
            final ep = episodes[index];
            return EpisodeDrawerCard(
              key: ValueKey<String>('episode_card_${ep.id}'),
              episode: ep,
              variants: b.variantsForEpisode(ep.id),
              playback: b.playbackByEpisodeId[ep.id],
              imageLoader: widget.imageLoader,
              workTitle: b.work.title,
              workMediaType: b.work.tmdbMediaType,
              mainEpisodeCount: mainCount,
              showSeasonPrefix: multiSeason && ep.category == EpisodeCategory.main,
              showStillThumbnail:
                  widget.displayPreferences.showEpisodeStillThumbnails,
              showOriginalFileName:
                  widget.displayPreferences.showOriginalSubtitlesOnCards,
              workBackdropFallbackPath: b.effectiveHeroBackdropPath,
              workPosterFallbackPath:
                  b.work.posterPath ?? b.work.bangumiPosterPath,
              workPosterOwnerId: b.effectiveHeroBackdropOwnerId,
              cardWidth: cardWidth,
              onTap: () => widget.onTapEpisode(ep),
              onShowMediaInfo: () => widget.onInspectEpisodeInfo(ep),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCdTrack(BuildContext context, List<MediaVariant> cds) {
    if (cds.isEmpty) {
      return _buildEmptyPlaceholder(context, '暂无音乐 CD 专辑');
    }
    final b = widget.bundle;
    final cardWidth = widget.compact ? 132.0 : 148.0;
    final cardHeight =
        cardWidth +
        (widget.displayPreferences.showOriginalSubtitlesOnCards ? 62.0 : 42.0);
    final subdirHints = DetailSupplementaryHelper.buildCdSubdirHints(cds);

    return SizedBox(
      height: cardHeight,
      child: Scrollbar(
        controller: _trackScrollCtrl,
        thumbVisibility: true,
        interactive: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        child: ListView.separated(
          controller: _trackScrollCtrl,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 10),
          itemCount: cds.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (_, index) {
            final v = cds[index];
            return CdDrawerCard(
              key: ValueKey<String>('cd_card_${v.id}'),
              variant: v,
              source: b.sourcesById[v.sourceId],
              workId: b.work.id,
              workPosterPath: b.work.posterPath ?? b.work.bangumiPosterPath,
              imageLoader: widget.imageLoader,
              showSeriesSharedBadge: b.seriesMembers.length >= 2,
              directSubdirLabel: subdirHints[v.id],
              showRawFileName:
                  widget.displayPreferences.showOriginalSubtitlesOnCards,
              cardWidth: cardWidth,
              onTap: () => widget.onTapCdVariant(v),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmptyPlaceholder(BuildContext context, String message) {
    final p = context.palette;
    return SizedBox(
      height: 112,
      child: Center(
        child: Text(
          message,
          style: TextStyle(
            color: p.textMuted,
            fontSize: KonataTheme.fontSizeBodySm,
          ),
        ),
      ),
    );
  }
}
