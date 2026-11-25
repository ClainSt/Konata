import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_display_preferences.dart';
import '../state/detail_supplementary_view_data.dart';
import 'detail_secondary_filter_bar.dart';
import 'episode_drawer_card.dart';
import 'supplementary_asset_cards.dart';

/// 详情页底部内容抽屉：聚合正片（支持分季）、特典（支持按类型细分）、CD 专辑与动态扩展标签页视图。
///
/// 三端统一保留单条毛玻璃分类胶囊（右端展开时自然弹性伸出 `⊞`）、彻底移除 `⌄`，并在展开态统一呈现横向大剧照选集卡轨道。
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
    this.expanded,
    this.onExpandedChanged,
    this.showGearButton = false,
    this.gearButton,
    this.onDarkBackdrop = true,
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

  /// 受控展开状态（为空时由抽屉内部托管展开/收起切换）。
  final bool? expanded;

  /// 展开状态变更回调（点击当前激活分类标签时触发收起）。
  final ValueChanged<bool>? onExpandedChanged;

  /// 点击正片或特典卡片回调。
  final ValueChanged<Episode> onTapEpisode;

  /// 点击音乐 CD 专辑卡片回调。
  final ValueChanged<MediaVariant> onTapCdVariant;

  /// 右键/更多查看单集物理变体技术信息回调。
  final ValueChanged<Episode> onInspectEpisodeInfo;

  /// 点击胶囊右端弹性 `⊞` 打开完整列表回调（传入当前内置标签页标识）。
  final ValueChanged<String> onOpenFullList;

  /// 是否在底栏最右侧展示唯一独立 `⚙` 按钮（桌面端 / 平板横屏传 `true`）。
  final bool showGearButton;

  /// 底栏右侧挂载的 `DetailGearMenu` 实例。
  final Widget? gearButton;

  /// 当前轨道是否处于深色背景或深色遮罩之上。
  final bool onDarkBackdrop;

  /// 是否紧凑视觉尺寸。
  final bool compact;

  /// 预留字段（三端统一保留横向选集卡轨道）。
  final bool inlineMode;

  @override
  State<DetailBottomDrawer> createState() => _DetailBottomDrawerState();
}

class _DetailBottomDrawerState extends State<DetailBottomDrawer> {
  final ScrollController _trackScrollCtrl = ScrollController();
  late String _activeTabId;
  late bool _localExpanded;
  String? _activeSeasonFilterId;
  String? _activeExtraKindFilterId;

  bool get _isExpanded => widget.expanded ?? _localExpanded;

  @override
  void initState() {
    super.initState();
    _localExpanded = widget.initialTabId?.trim().isNotEmpty ?? false;
    _activeTabId = _resolveInitialTabId(widget.initialTabId);
    _syncDefaultSubFilters();
  }

  @override
  void didUpdateWidget(covariant DetailBottomDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bundle.work.id != widget.bundle.work.id ||
        oldWidget.initialTabId != widget.initialTabId) {
      _localExpanded = widget.initialTabId?.trim().isNotEmpty ?? false;
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

  bool _isScanContribution(DetailTabContribution tab) {
    final id = tab.id.toLowerCase();
    final iconKey = tab.iconKey.toLowerCase();
    final label = tab.label.toLowerCase();
    return id.contains('scan') ||
        iconKey.contains('scan') ||
        label.contains('scan') ||
        label.contains('扫图');
  }

  List<DetailTabContribution> _visibleExternalTabs() {
    final raw = widget.bundle.visibleTabs;
    if (widget.displayPreferences.showScanTab) return raw;
    return raw
        .where((tab) => !_isScanContribution(tab))
        .toList(growable: false);
  }

  List<MediaVariant> _visibleCdVariants() {
    if (!widget.displayPreferences.showCdTab) return const <MediaVariant>[];
    return widget.bundle.cdVariants;
  }

  bool _isTabCurrentlyAvailable(String tabId) {
    final b = widget.bundle;
    final visibleCds = _visibleCdVariants();
    final visibleTabs = _visibleExternalTabs();
    if (tabId == DetailDrawerTabIds.episodes) {
      return b.mainEpisodes.isNotEmpty ||
          (b.extraEpisodes.isEmpty &&
              visibleCds.isEmpty &&
              visibleTabs.isEmpty);
    }
    if (tabId == DetailDrawerTabIds.extras) {
      return b.extraEpisodes.isNotEmpty;
    }
    if (tabId == DetailDrawerTabIds.cd) {
      return visibleCds.isNotEmpty;
    }
    return visibleTabs.any((t) => t.id == tabId);
  }

  String _resolveInitialTabId(String? requested) {
    final visibleCds = _visibleCdVariants();
    final visibleTabs = _visibleExternalTabs();
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
    if (visibleCds.isNotEmpty) {
      return DetailDrawerTabIds.cd;
    }
    if (visibleTabs.isNotEmpty) {
      return visibleTabs.first.id;
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
    for (final tab in _visibleExternalTabs()) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  void _handleSelectTab(String tabId) {
    if (_isExpanded && _activeTabId == tabId) {
      if (widget.onExpandedChanged != null) {
        widget.onExpandedChanged!(false);
      } else {
        setState(() => _localExpanded = false);
      }
      return;
    }
    setState(() {
      _activeTabId = tabId;
      _localExpanded = true;
    });
    widget.onExpandedChanged?.call(true);
  }

  void _handleTrackPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_trackScrollCtrl.hasClients) return;
    final pos = _trackScrollCtrl.position;
    final delta = event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;
    final nextOffset = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (nextOffset != pos.pixels) {
      _trackScrollCtrl.jumpTo(nextOffset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bundle;
    final mains = b.mainEpisodes;
    final extras = b.extraEpisodes;
    final cds = _visibleCdVariants();
    final externalTabs = _visibleExternalTabs();
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
            label: DetailSupplementaryHelper.extraKindLabel(entry.key),
            count: entry.value.length,
          ));
        }
        activeSubId = _activeExtraKindFilterId ?? 'all';
      }
    }

    final isExternal = _findExternalTab(_activeTabId) != null;
    final canOpenFullList = (isExternal
        ? _activeTabId == 'scan_viewer'
        : ((_activeTabId == DetailDrawerTabIds.episodes && mains.isNotEmpty) ||
              (_activeTabId == DetailDrawerTabIds.extras &&
                  extras.isNotEmpty) ||
              (_activeTabId == DetailDrawerTabIds.cd && cds.isNotEmpty)));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSecondaryFilterBar(
          activeTabId: _activeTabId,
          mainEpisodeCount: mains.length,
          extraEpisodeCount: extras.length,
          cdCount: cds.length,
          externalTabs: externalTabs,
          scanCount: b.visibleScanCount,
          expanded: _isExpanded,
          canOpenFullList: canOpenFullList,
          onOpenFullList: canOpenFullList
              ? () => widget.onOpenFullList(_activeTabId)
              : null,
          trailingGear: widget.showGearButton ? widget.gearButton : null,
          onDarkBackdrop: widget.onDarkBackdrop,
          compact: widget.compact,
          onSelectTab: _handleSelectTab,
        ),
        AnimatedSize(
          duration: KonataTheme.motionNormal,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _isExpanded
              ? SizedBox(
                  key: const Key('detail_drawer_expanded_body'),
                  height: widget.compact ? 240 : 256,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (subFilters.length > 1)
                        DetailSubFilterBar(
                          chips: subFilters,
                          activeId: activeSubId,
                          onDarkBackdrop: widget.onDarkBackdrop,
                          onSelected: (subId) {
                            if (_trackScrollCtrl.hasClients) {
                              _trackScrollCtrl.jumpTo(0);
                            }
                            setState(() {
                              if (_activeTabId == DetailDrawerTabIds.episodes) {
                                _activeSeasonFilterId = subId;
                              } else if (_activeTabId ==
                                  DetailDrawerTabIds.extras) {
                                _activeExtraKindFilterId = subId;
                              }
                            });
                          },
                        ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: _buildActiveContent(
                            context,
                            mains: mains,
                            extras: extras,
                            cds: cds,
                            multiSeason: multiSeason,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(key: Key('detail_drawer_collapsed_body')),
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
            'inlineRail': true,
          },
        ),
      );
      if (slotResult is Widget) {
        return ConstrainedBox(
          key: ValueKey<String>('detail_external_tab_slot_${extTab.id}'),
          constraints: const BoxConstraints.expand(),
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
    final showRawFileName = widget.displayPreferences.showRawVideoFilename;
    final cardWidth = widget.compact ? 196.0 : 228.0;
    final cardHeight = cardWidth * 9 / 16 + (showRawFileName ? 66.0 : 46.0);

    return Listener(
      onPointerSignal: _handleTrackPointerSignal,
      child: SizedBox(
        height: cardHeight,
        child: ListView.separated(
          controller: _trackScrollCtrl,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
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
              showSeasonPrefix:
                  multiSeason && ep.category == EpisodeCategory.main,
              showStillThumbnail:
                  widget.displayPreferences.showEpisodeStillThumbnails,
              showOriginalFileName: showRawFileName,
              workBackdropFallbackPath: b.effectiveHeroBackdropPath,
              workPosterFallbackPath:
                  b.work.posterPath ?? b.work.bangumiPosterPath,
              workPosterOwnerId: b.effectiveHeroBackdropOwnerId,
              onDarkBackdrop: widget.onDarkBackdrop,
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
    final showRawFileName = widget.displayPreferences.showRawVideoFilename;
    final cardWidth = widget.compact ? 132.0 : 148.0;
    final cardHeight = cardWidth + (showRawFileName ? 84.0 : 62.0);
    final subdirHints = DetailSupplementaryHelper.buildCdSubdirHints(cds);

    return Listener(
      onPointerSignal: _handleTrackPointerSignal,
      child: SizedBox(
        height: cardHeight,
        child: ListView.separated(
          controller: _trackScrollCtrl,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
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
              showRawFileName: showRawFileName,
              onDarkBackdrop: widget.onDarkBackdrop,
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
            color: widget.onDarkBackdrop
                ? KonataTheme.overlayWhiteTextDim
                : p.textMuted,
            fontSize: KonataTheme.fontSizeBodySm,
          ),
        ),
      ),
    );
  }
}
