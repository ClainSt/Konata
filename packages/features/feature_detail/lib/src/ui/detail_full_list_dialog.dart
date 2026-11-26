import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_cd_artwork.dart';
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
    this.cdCoverLoader,
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
  final DetailCdCoverLoader? cdCoverLoader;

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
  Size? _resizedSize;

  void _resetScroll() {
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
  }

  bool _matches(String value) =>
      value.toLowerCase().contains(_query.trim().toLowerCase());

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
    final cdGroups = SupplementarySubclassifier.groupCdVariants(cds);
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
      for (final kind in SupplementarySubclassifier.extraKindDisplayOrder) {
        final count = extras
            .where(
              (e) => DetailSupplementaryHelper.resolvedExtraKind(b, e) == kind,
            )
            .length;
        if (count > 0) {
          filters.add((
            id: kind.name,
            label: DetailSupplementaryHelper.extraKindLabel(kind),
            count: count,
          ));
        }
      }
    } else if (_activeTab == DetailDrawerTabIds.cd) {
      filters.add((id: 'all', label: '全部', count: cds.length));
      for (final chip in cdGroups.chips) {
        filters.add((id: chip.key, label: chip.label, count: chip.count));
      }
    }
    final visibleCds = cds
        .where(
          (v) =>
              (_filter == 'all' ||
                  cdGroups.byVariantId[v.id]?.albumKey == _filter) &&
              (_matches(v.fileName) || _matches(v.relativePath)),
        )
        .toList();
    final isExtra = _activeTab == DetailDrawerTabIds.extras;
    final visibleEpisodes = (isExtra ? extras : mains)
        .where(
          (e) =>
              (_filter == 'all' ||
                  (isExtra
                      ? DetailSupplementaryHelper.resolvedExtraKind(
                              b,
                              e,
                            ).name ==
                            _filter
                      : '${e.seasonNumber}' == _filter)) &&
              (_matches(e.title ?? '') ||
                  _matches('${e.episodeNumber ?? ''}') ||
                  b.variantsForEpisode(e.id).any((v) => _matches(v.fileName))),
        )
        .toList();
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final maxWidth = math.max(240.0, screen.width - safe.horizontal - 24);
    final maxHeight = math.max(200.0, screen.height - safe.vertical - 24);
    final compact = screen.width < 600 || screen.height < 500;
    final minWidth = math.min(620.0, maxWidth);
    final minHeight = math.min(480.0, maxHeight);
    final defaultWidth = compact
        ? maxWidth
        : (screen.width * 0.84).clamp(minWidth, math.min(1180.0, maxWidth));
    final defaultHeight = compact
        ? maxHeight
        : (screen.height * 0.82).clamp(minHeight, math.min(820.0, maxHeight));
    final dialogWidth = compact
        ? defaultWidth
        : (_resizedSize?.width ?? defaultWidth).clamp(minWidth, maxWidth);
    final dialogHeight = compact
        ? defaultHeight
        : (_resizedSize?.height ?? defaultHeight).clamp(minHeight, maxHeight);
    final canResize = !compact && !KonataAdaptiveTokens.isAndroid;
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
      width: dialogWidth.toDouble(),
      height: dialogHeight.toDouble(),
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
          if (canResize)
            Align(
              alignment: Alignment.centerRight,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeDownRight,
                child: GestureDetector(
                  key: const ValueKey('detail_full_list_resize_handle'),
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => setState(() => _resizedSize = null),
                  onPanUpdate: (details) => setState(() {
                    _resizedSize = Size(
                      (dialogWidth + details.delta.dx * 2).clamp(
                        minWidth,
                        maxWidth,
                      ),
                      (dialogHeight + details.delta.dy * 2).clamp(
                        minHeight,
                        maxHeight,
                      ),
                    );
                  }),
                  child: KonataTooltip(
                    message: '调整大小',
                    child: SizedBox(
                      width: 28,
                      height: 20,
                      child: Icon(
                        Icons.drag_handle_rounded,
                        size: 18,
                        color: context.palette.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
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
      return _buildRows<MediaVariant>(
        items: cds,
        maxExtent: 176,
        itemBuilder: (v) => CdDrawerCard(
          key: ValueKey('full_list_cd_${v.id}'),
          variant: v,
          coverLoader: widget.cdCoverLoader,
          source: b.sourcesById[v.sourceId],
          workId: b.work.id,
          workPosterPath: b.work.posterPath ?? b.work.bangumiPosterPath,
          imageLoader: widget.imageLoader,
          showSeriesSharedBadge: b.seriesMembers.length >= 2,
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
    return KonataDraggableScrollbar(
      controller: _scrollCtrl,
      builder: (_, ctrl) => LayoutBuilder(
        builder: (_, constraints) {
          const spacing = 12.0;
          final usableWidth = math.max(120.0, constraints.maxWidth);
          final columns = math.max(
            1,
            ((usableWidth + spacing) / (maxExtent + spacing)).ceil(),
          );
          return ListView.separated(
            key: ValueKey('detail_full_list_$_activeTab'),
            controller: ctrl,
            padding: const EdgeInsets.only(bottom: 6),
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
          );
        },
      ),
    );
  }
}
