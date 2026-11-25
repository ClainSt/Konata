import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
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
  late String _activeTab = widget.initialTabId;
  String _filter = 'all';
  String _query = '';

  void _resetScroll() {
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
  }

  bool _matches(String value) =>
      value.toLowerCase().contains(_query.trim().toLowerCase());

  String _cdGroup(MediaVariant v) {
    final parts = v.relativePath.replaceAll(r'\', '/').split('/');
    return parts.length > 1 ? parts[parts.length - 2] : '';
  }

  String _extraLabel(ExtraKind kind) => switch (kind) {
    ExtraKind.ncop => '无字幕片头',
    ExtraKind.nced => '无字幕片尾',
    ExtraKind.pv => '预告宣传',
    ExtraKind.menu => '光盘菜单',
    ExtraKind.mv => '音乐映像',
    ExtraKind.ova => 'OVA / OAD',
    ExtraKind.sp => '特别篇与花絮',
  };

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

    final externalTabs = widget.displayPreferences.showScanTab
        ? b.visibleTabs.where((t) => t.id == 'scan_viewer').toList()
        : <DetailTabContribution>[];
    final external = externalTabs.where((t) => t.id == _activeTab).firstOrNull;
    final filters = <({String id, String label, int count})>[];
    final groups = DetailSupplementaryHelper.groupMainBySeason(mains);
    if (_activeTab == DetailDrawerTabIds.episodes && multiSeason) {
      filters.add((id: 'all', label: '全部', count: mains.length));
      for (final g in groups) {
        filters.add((
          id: '${g.seasonNumber}',
          label: g.label,
          count: g.episodes.length,
        ));
      }
    } else if (_activeTab == DetailDrawerTabIds.extras) {
      filters.add((id: 'all', label: '全部', count: extras.length));
      for (final kind in ExtraKind.values) {
        final count = extras
            .where((e) => (e.extraType ?? ExtraKind.sp) == kind)
            .length;
        if (count > 0) {
          filters.add((id: kind.name, label: _extraLabel(kind), count: count));
        }
      }
    } else if (_activeTab == DetailDrawerTabIds.cd) {
      final counts = <String, int>{};
      for (final v in cds) {
        final group = _cdGroup(v);
        if (group.isNotEmpty) {
          counts.update(group, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      filters.add((id: 'all', label: '全部', count: cds.length));
      for (final entry in counts.entries) {
        filters.add((id: entry.key, label: entry.key, count: entry.value));
      }
    }
    final visibleCds = cds
        .where(
          (v) =>
              (_filter == 'all' || _cdGroup(v) == _filter) &&
              (_matches(v.fileName) || _matches(v.relativePath)),
        )
        .toList();
    final isExtra = _activeTab == DetailDrawerTabIds.extras;
    final visibleEpisodes = (isExtra ? extras : mains)
        .where(
          (e) =>
              (_filter == 'all' ||
                  (isExtra
                      ? (e.extraType ?? ExtraKind.sp).name == _filter
                      : '${e.seasonNumber}' == _filter)) &&
              (_matches(e.title ?? '') ||
                  _matches('${e.episodeNumber ?? ''}') ||
                  b.variantsForEpisode(e.id).any((v) => _matches(v.fileName))),
        )
        .toList();
    final screen = MediaQuery.sizeOf(context);
    final externalView = external?.viewBuilder(
      ViewSlotContext(
        platformContext: context,
        workId: WorkId.trusted(b.work.id),
        arguments: {
          'workTitle': b.work.title,
          'seriesId': b.work.seriesId,
          'inlineRail': false,
          'searchQuery': _query,
        },
      ),
    );

    return KonataGlassDialog(
      width: screen.width,
      height: screen.height,
      title: '${b.work.title} · 完整列表',
      headerTrailing: SizedBox(
        width: screen.width < 600 ? 150 : 260,
        child: KonataSearchField(
          key: const ValueKey('detail_full_list_search'),
          onChanged: (value) {
            _resetScroll();
            setState(() => _query = value);
          },
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailSecondaryFilterBar(
            activeTabId: _activeTab,
            mainEpisodeCount: mains.length,
            extraEpisodeCount: extras.length,
            cdCount: widget.displayPreferences.showCdTab ? cds.length : 0,
            externalTabs: externalTabs,
            scanCount: b.visibleScanCount,
            onDarkBackdrop: context.palette.isDark,
            compact: screen.width < 600,
            subFilterChips: filters,
            activeSubFilterId: _filter,
            onSelectTab: (id) {
              _resetScroll();
              setState(() {
                _activeTab = id;
                _filter = 'all';
              });
            },
            onSelectSubFilter: (id) {
              _resetScroll();
              setState(() => _filter = id);
            },
          ),
          const SizedBox(height: 12),
          Expanded(
            child: externalView is Widget
                ? externalView
                : _buildGrid(context, visibleEpisodes, visibleCds, multiSeason),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(
    BuildContext context,
    List<Episode> episodes,
    List<MediaVariant> cds,
    bool multiSeason,
  ) {
    final b = widget.bundle;
    final mains = b.mainEpisodes;
    if (_activeTab == DetailDrawerTabIds.cd) {
      final subdirHints = DetailSupplementaryHelper.buildCdSubdirHints(
        b.cdVariants,
      );
      return _buildRows<MediaVariant>(
        items: cds,
        maxExtent: 176,
        itemBuilder: (v) => CdDrawerCard(
          key: ValueKey('full_list_cd_${v.id}'),
          variant: v,
          source: b.sourcesById[v.sourceId],
          workId: b.work.id,
          workPosterPath: b.work.posterPath ?? b.work.bangumiPosterPath,
          imageLoader: widget.imageLoader,
          showSeriesSharedBadge: b.seriesMembers.length >= 2,
          directSubdirLabel: _filter == 'all' ? subdirHints[v.id] : null,
          showRawFileName: widget.displayPreferences.showRawVideoFilename,
          onDarkBackdrop: context.palette.isDark,
          cardWidth: double.infinity,
          onTap: () => widget.onTapCdVariant(v),
        ),
      );
    }
    return _buildRows<Episode>(
      items: episodes,
      maxExtent: 256,
      itemBuilder: (ep) => EpisodeDrawerCard(
        key: ValueKey('full_list_episode_${ep.id}'),
        episode: ep,
        variants: b.variantsForEpisode(ep.id),
        playback: b.playbackByEpisodeId[ep.id],
        imageLoader: widget.imageLoader,
        workTitle: b.work.title,
        workMediaType: b.work.tmdbMediaType,
        mainEpisodeCount: mains.length,
        showSeasonPrefix: multiSeason && ep.category == EpisodeCategory.main,
        showStillThumbnail:
            widget.displayPreferences.showEpisodeStillThumbnails,
        showOriginalFileName: widget.displayPreferences.showRawVideoFilename,
        workBackdropFallbackPath: b.effectiveHeroBackdropPath,
        workPosterFallbackPath: b.work.posterPath ?? b.work.bangumiPosterPath,
        workPosterOwnerId: b.effectiveHeroBackdropOwnerId,
        onDarkBackdrop: context.palette.isDark,
        cardWidth: double.infinity,
        onTap: () => widget.onTapEpisode(ep),
        onShowMediaInfo: () => widget.onInspectEpisodeInfo(ep),
      ),
    );
  }

  // 按真实卡片高度紧凑分行，避免固定网格比例造成文字裁切。
  Widget _buildRows<T>({
    required List<T> items,
    required double maxExtent,
    required Widget Function(T) itemBuilder,
  }) {
    if (items.isEmpty) {
      return const Center(child: Text('没有符合当前筛选条件的文件'));
    }
    return LayoutBuilder(
      builder: (_, constraints) {
        const rightPad = 16.0;
        const spacing = 12.0;
        final usableWidth = math.max(120.0, constraints.maxWidth - rightPad);
        final columns = math.max(
          1,
          ((usableWidth + spacing) / (maxExtent + spacing)).ceil(),
        );
        return KonataDraggableScrollbar(
          controller: _scrollCtrl,
          builder: (_, ctrl) => ListView.separated(
            key: ValueKey('detail_full_list_$_activeTab'),
            controller: ctrl,
            padding: const EdgeInsets.only(right: rightPad, bottom: 6),
            itemCount: (items.length + columns - 1) ~/ columns,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, row) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var col = 0; col < columns; col++) ...[
                  if (col > 0) const SizedBox(width: spacing),
                  Expanded(
                    child: row * columns + col < items.length
                        ? itemBuilder(items[row * columns + col])
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
