import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/library_providers.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_dialog.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/managed_image.dart';
import 'detail_bottom_drawer.dart';
import 'detail_gear_menu.dart';
import 'detail_secondary_filter_bar.dart';
import 'episode_drawer_card.dart';
import 'supplementary_asset_cards.dart';

/// 作品详情页高透毛玻璃「完整列表」弹窗：支持关键字检索、一级分类切换、二级筛选与可拖拽网格浏览。
class DetailFullListDialog extends ConsumerStatefulWidget {
  /// 创建完整列表弹窗。
  const DetailFullListDialog({
    super.key,
    required this.bundle,
    required this.imageLoader,
    required this.initialTab,
    this.initialSecondaryFilterKey,
    this.showRawVideoFilename = true,
    this.showCdTab = true,
    this.showScanTab = true,
    required this.onEpisodeTap,
    required this.onEpisodeAdjustSlot,
    this.onEpisodePlayBuiltin,
    this.onEpisodePlayExternal,
    this.onEpisodeMarkCompleted,
    this.onCdTap,
    this.onCdPlayImmersive,
    this.onCdPlayExternal,
    this.onScanTap,
  });

  /// 作品详情数据包。
  final WorkDetailBundle bundle;

  /// 图片加载器。
  final ManagedImageLoader imageLoader;

  /// 打开时的默认一级分类页签。
  final DetailDrawerTab initialTab;

  /// 打开时的默认二级筛选键。
  final String? initialSecondaryFilterKey;

  /// 是否显示视频原始文件名。
  final bool showRawVideoFilename;

  /// 是否允许展示 CD 页签。
  final bool showCdTab;

  /// 是否允许展示 Scan 页签。
  final bool showScanTab;

  /// 点击剧集/特典播放回调。
  final ValueChanged<Episode> onEpisodeTap;

  /// 右键指定内置播放器播放回调。
  final ValueChanged<Episode>? onEpisodePlayBuiltin;

  /// 右键指定外部播放器播放回调。
  final ValueChanged<Episode>? onEpisodePlayExternal;

  /// 右键微调剧集编号回调。
  final ValueChanged<Episode> onEpisodeAdjustSlot;

  /// 右键标为已看回调。
  final ValueChanged<Episode>? onEpisodeMarkCompleted;

  /// 点击 CD 音轨回调。
  final ValueChanged<MediaVariant>? onCdTap;

  /// 右键使用内置全屏流光页播放 CD 回调。
  final ValueChanged<MediaVariant>? onCdPlayImmersive;

  /// 右键使用外部播放器播放 CD 回调。
  final ValueChanged<MediaVariant>? onCdPlayExternal;

  /// 点击 Scan 扫图回调。
  final ValueChanged<MediaVariant>? onScanTap;

  /// 以高透毛玻璃遮罩形式弹出完整资源列表弹窗。
  static Future<void> show(
    BuildContext context, {
    required WorkDetailBundle bundle,
    required ManagedImageLoader imageLoader,
    required DetailDrawerTab initialTab,
    String? initialSecondaryFilterKey,
    bool showRawVideoFilename = true,
    bool showCdTab = true,
    bool showScanTab = true,
    required ValueChanged<Episode> onEpisodeTap,
    required ValueChanged<Episode> onEpisodeAdjustSlot,
    ValueChanged<Episode>? onEpisodePlayBuiltin,
    ValueChanged<Episode>? onEpisodePlayExternal,
    ValueChanged<Episode>? onEpisodeMarkCompleted,
    ValueChanged<MediaVariant>? onCdTap,
    ValueChanged<MediaVariant>? onCdPlayImmersive,
    ValueChanged<MediaVariant>? onCdPlayExternal,
    ValueChanged<MediaVariant>? onScanTap,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (ctx) => DetailFullListDialog(
        bundle: bundle,
        imageLoader: imageLoader,
        initialTab: initialTab,
        initialSecondaryFilterKey: initialSecondaryFilterKey,
        showRawVideoFilename: showRawVideoFilename,
        showCdTab: showCdTab,
        showScanTab: showScanTab,
        onEpisodeTap: (ep) {
          Navigator.of(ctx).pop();
          onEpisodeTap(ep);
        },
        onEpisodePlayBuiltin: onEpisodePlayBuiltin == null
            ? null
            : (ep) {
                Navigator.of(ctx).pop();
                onEpisodePlayBuiltin(ep);
              },
        onEpisodePlayExternal: onEpisodePlayExternal == null
            ? null
            : (ep) {
                Navigator.of(ctx).pop();
                onEpisodePlayExternal(ep);
              },
        onEpisodeAdjustSlot: onEpisodeAdjustSlot,
        onEpisodeMarkCompleted: onEpisodeMarkCompleted,
        onCdTap: onCdTap,
        onCdPlayImmersive: onCdPlayImmersive == null
            ? null
            : (v) {
                Navigator.of(ctx).pop();
                onCdPlayImmersive(v);
              },
        onCdPlayExternal: onCdPlayExternal,
        onScanTap: onScanTap,
      ),
    );
  }

  @override
  ConsumerState<DetailFullListDialog> createState() =>
      _DetailFullListDialogState();
}

class _DetailFullListDialogState extends ConsumerState<DetailFullListDialog> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _gridScrollController = ScrollController();
  late final ScanThumbnailScheduler _scanScheduler;

  late DetailDrawerTab _activeTab;
  String? _selectedSecondaryKey;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _scanScheduler = ref.read(scanThumbnailSchedulerProvider);
    _activeTab = _resolveAvailableTab(widget.initialTab);
    _selectedSecondaryKey = widget.initialSecondaryFilterKey;
  }

  @override
  void dispose() {
    _scanScheduler.cancelAll();
    _searchController.dispose();
    _gridScrollController.dispose();
    super.dispose();
  }

  DetailDrawerTab _resolveAvailableTab(DetailDrawerTab candidate) {
    final cdAllowed = widget.showCdTab && widget.bundle.cdVariants.isNotEmpty;
    final scanAllowed =
        widget.showScanTab && widget.bundle.scanVariants.isNotEmpty;
    if (candidate == DetailDrawerTab.cd && !cdAllowed) {
      return DetailDrawerTab.main;
    }
    if (candidate == DetailDrawerTab.scan && !scanAllowed) {
      return DetailDrawerTab.main;
    }
    return candidate;
  }

  void _selectTab(DetailDrawerTab tab) {
    if (_activeTab == tab) return;
    if (_activeTab == DetailDrawerTab.scan && tab != DetailDrawerTab.scan) {
      _scanScheduler.cancelAll();
    }
    setState(() {
      _activeTab = tab;
      _selectedSecondaryKey = null;
    });
    _jumpToTop();
  }

  void _selectSecondary(String? key) {
    if (_selectedSecondaryKey == key) return;
    if (_activeTab == DetailDrawerTab.scan) {
      _scanScheduler.cancelAll();
    }
    setState(() => _selectedSecondaryKey = key);
    _jumpToTop();
  }

  void _jumpToTop() {
    if (_gridScrollController.hasClients) {
      _gridScrollController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = (screenSize.width * 0.84).clamp(620.0, 1180.0);
    final dialogHeight = (screenSize.height * 0.82).clamp(480.0, 820.0);

    final mainEps = widget.bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .toList(growable: false);
    final extraEps = widget.bundle.episodes
        .where((e) => e.category == EpisodeCategory.extra)
        .toList(growable: false);
    final cdList =
        widget.showCdTab ? widget.bundle.cdVariants : const <MediaVariant>[];
    final scanList = widget.showScanTab
        ? widget.bundle.scanVariants
        : const <MediaVariant>[];
    final showSharedBadge = widget.bundle.seriesMembers.length >= 2;
    final normQuery = _query.trim().toLowerCase();

    // 预计算特典二级分类与展示标题
    final extraKindByEpId = <String, ExtraKind>{};
    final extraCountByKind = <ExtraKind, int>{};
    final extraDisplayTitleByEpId = <String, String>{};
    for (final ep in extraEps) {
      final variants = widget.bundle.variantsForEpisode(ep.id);
      final firstVar = variants.isNotEmpty ? variants.first : null;
      final kind = firstVar != null
          ? SupplementarySubclassifier.classifyExtraVideo(
              fileName: firstVar.fileName,
              relativePath: firstVar.relativePath,
              fallbackExtraType: ep.extraType,
            )
          : (ep.extraType ?? ExtraKind.sp);
      extraKindByEpId[ep.id] = kind;
      extraCountByKind[kind] = (extraCountByKind[kind] ?? 0) + 1;
      final defaultTitle = EpisodeTitleFormatter.formatCardTitle(
        episode: ep,
        workTitle: widget.bundle.work.title,
        workMediaType: widget.bundle.work.tmdbMediaType,
        mainEpisodeCount: mainEps.length,
      );
      extraDisplayTitleByEpId[ep.id] =
          SupplementarySubclassifier.formatExtraDisplayTitle(
            episode: ep,
            episodeVariants: variants,
            allWorkVariants: widget.bundle.variants,
            defaultFormattedTitle: defaultTitle,
          );
    }

    final cdSummary = SupplementarySubclassifier.groupCdVariants(cdList);
    final scanSummary = SupplementarySubclassifier.groupScanVariants(scanList);

    // 构造当前一级页签对应的二级筛选项
    final secondaryItems = switch (_activeTab) {
      DetailDrawerTab.extra => SupplementarySubclassifier.extraKindDisplayOrder
          .where((k) => (extraCountByKind[k] ?? 0) > 0)
          .map(
            (k) => DetailSecondaryFilterItem(
              key: k.name,
              label: SupplementarySubclassifier.extraKindLabel(k),
              count: extraCountByKind[k] ?? 0,
            ),
          )
          .toList(growable: false),
      DetailDrawerTab.cd => cdSummary.chips
          .map(
            (c) => DetailSecondaryFilterItem(
              key: c.key,
              label: c.label,
              count: c.count,
            ),
          )
          .toList(growable: false),
      DetailDrawerTab.scan => scanSummary.chips
          .map(
            (c) => DetailSecondaryFilterItem(
              key: c.key,
              label: c.label,
              count: c.count,
            ),
          )
          .toList(growable: false),
      DetailDrawerTab.main => const <DetailSecondaryFilterItem>[],
    };

    final activeTotalCount = switch (_activeTab) {
      DetailDrawerTab.main => mainEps.length,
      DetailDrawerTab.extra => extraEps.length,
      DetailDrawerTab.cd => cdList.length,
      DetailDrawerTab.scan => scanList.length,
    };

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: KonataDraggableDialog(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Container(
              width: dialogWidth,
              height: dialogHeight,
              decoration: BoxDecoration(
                color: KonataPlaybackTokens.popoverSurface(p),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: KonataPlaybackTokens.glassBorder(p),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: KonataDialogDragHandle(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              '${widget.bundle.work.title} · 完整列表',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: KonataTheme.detailTextStyle(
                                palette: p,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 240,
                        height: 34,
                        child: _FrostedSearchField(
                          controller: _searchController,
                          onChanged: (v) {
                            setState(() => _query = v);
                            _jumpToTop();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: '关闭 (Esc)',
                        onPressed: () => Navigator.of(context).pop(),
                        style: IconButton.styleFrom(
                          backgroundColor: KonataPlaybackTokens.softFill(p),
                          side: BorderSide(
                            color: KonataPlaybackTokens.glassBorder(p),
                            width: 0.8,
                          ),
                        ),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: p.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 一级分类胶囊条
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        DetailDrawerTabChip(
                          label: '正片 (${mainEps.length})',
                          active: _activeTab == DetailDrawerTab.main,
                          onTap: () => _selectTab(DetailDrawerTab.main),
                        ),
                        const SizedBox(width: 6),
                        DetailDrawerTabChip(
                          label: '特典 (${extraEps.length})',
                          active: _activeTab == DetailDrawerTab.extra,
                          onTap: () => _selectTab(DetailDrawerTab.extra),
                        ),
                        if (cdList.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          DetailDrawerTabChip(
                            label: 'CD (${cdList.length})',
                            active: _activeTab == DetailDrawerTab.cd,
                            onTap: () => _selectTab(DetailDrawerTab.cd),
                          ),
                        ],
                        if (scanList.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          DetailDrawerTabChip(
                            label: 'Scan (${scanList.length})',
                            active: _activeTab == DetailDrawerTab.scan,
                            onTap: () => _selectTab(DetailDrawerTab.scan),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (secondaryItems.length >= 2) ...[
                    const SizedBox(height: 10),
                    DetailSecondaryFilterBar(
                      items: secondaryItems,
                      totalCount: activeTotalCount,
                      selectedKey: _selectedSecondaryKey,
                      onSelected: _selectSecondary,
                      horizontalPadding: 0,
                      compact: true,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: _buildFilteredGrid(
                      mainEps: mainEps,
                      extraEps: extraEps,
                      cdList: cdList,
                      scanList: scanList,
                      extraKindByEpId: extraKindByEpId,
                      extraDisplayTitleByEpId: extraDisplayTitleByEpId,
                      cdSummary: cdSummary,
                      scanSummary: scanSummary,
                      showSharedBadge: showSharedBadge,
                      normQuery: normQuery,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilteredGrid({
    required List<Episode> mainEps,
    required List<Episode> extraEps,
    required List<MediaVariant> cdList,
    required List<MediaVariant> scanList,
    required Map<String, ExtraKind> extraKindByEpId,
    required Map<String, String> extraDisplayTitleByEpId,
    required CdAlbumGroupSummary cdSummary,
    required ScanVolumeGroupSummary scanSummary,
    required bool showSharedBadge,
    required String normQuery,
  }) {
    if (_activeTab == DetailDrawerTab.main ||
        _activeTab == DetailDrawerTab.extra) {
      var list = _activeTab == DetailDrawerTab.main ? mainEps : extraEps;
      if (_activeTab == DetailDrawerTab.extra &&
          _selectedSecondaryKey != null) {
        list = list
            .where((e) => extraKindByEpId[e.id]?.name == _selectedSecondaryKey)
            .toList(growable: false);
      }
      if (normQuery.isNotEmpty) {
        list = list.where((e) {
          final vars = widget.bundle.variantsForEpisode(e.id);
          final title = extraDisplayTitleByEpId[e.id] ?? e.title ?? '';
          if (title.toLowerCase().contains(normQuery)) return true;
          if ('${e.episodeNumber}'.contains(normQuery)) return true;
          return vars.any(
            (v) =>
                v.fileName.toLowerCase().contains(normQuery) ||
                v.relativePath.toLowerCase().contains(normQuery),
          );
        }).toList(growable: false);
      }
      if (list.isEmpty) {
        return _buildEmptyMatch();
      }
      return KonataDraggableScrollbar(
        controller: _gridScrollController,
        builder: (_, ctrl) => GridView.builder(
          controller: ctrl,
          padding: const EdgeInsets.only(right: 16, bottom: 6),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 256,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            mainAxisExtent: 214,
          ),
          itemCount: list.length,
          itemBuilder: (_, index) {
            final ep = list[index];
            final variants = widget.bundle.variantsForEpisode(ep.id);
            final playback = widget.bundle.playbackByEpisodeId[ep.id];
            final markHandler = widget.onEpisodeMarkCompleted;
            return EpisodeDrawerCard(
              episode: ep,
              variants: variants,
              fallbackBackdropPath:
                  widget.bundle.work.backdropPath ??
                  widget.bundle.work.posterPath,
              imageLoader: widget.imageLoader,
              workTitle: widget.bundle.work.title,
              workMediaType: widget.bundle.work.tmdbMediaType,
              mainEpisodeCount: mainEps.length,
              displayTitleOverride: _activeTab == DetailDrawerTab.extra
                  ? extraDisplayTitleByEpId[ep.id]
                  : null,
              showRawFileName: widget.showRawVideoFilename,
              onTap: () => widget.onEpisodeTap(ep),
              onPlayBuiltin: widget.onEpisodePlayBuiltin == null
                  ? null
                  : () => widget.onEpisodePlayBuiltin!(ep),
              onPlayExternal: widget.onEpisodePlayExternal == null
                  ? null
                  : () => widget.onEpisodePlayExternal!(ep),
              onAdjustSlot: () => widget.onEpisodeAdjustSlot(ep),
              playback: playback,
              onMarkCompleted: markHandler == null
                  ? null
                  : () => markHandler(ep),
            );
          },
        ),
      );
    }

    if (_activeTab == DetailDrawerTab.cd) {
      var list = cdList;
      if (_selectedSecondaryKey != null) {
        list = list
            .where(
              (v) => cdSummary.byVariantId[v.id]?.albumKey ==
                  _selectedSecondaryKey,
            )
            .toList(growable: false);
      }
      if (normQuery.isNotEmpty) {
        list = list.where((v) {
          final group = cdSummary.byVariantId[v.id];
          return v.fileName.toLowerCase().contains(normQuery) ||
              (group?.chipLabel.toLowerCase().contains(normQuery) ?? false) ||
              (group?.directSubdirShort?.toLowerCase().contains(normQuery) ??
                  false);
        }).toList(growable: false);
      }
      if (list.isEmpty) return _buildEmptyMatch();

      final showDirectSubdir =
          _selectedSecondaryKey == null && cdSummary.hasMultipleSubdirs;
      return KonataDraggableScrollbar(
        controller: _gridScrollController,
        builder: (_, ctrl) => GridView.builder(
          controller: ctrl,
          padding: const EdgeInsets.only(right: 16, bottom: 6),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 204,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            mainAxisExtent: 196,
          ),
          itemCount: list.length,
          itemBuilder: (_, index) {
            final v = list[index];
            final group = cdSummary.byVariantId[v.id];
            return CdDrawerCard(
              variant: v,
              showSeriesSharedBadge: showSharedBadge,
              directSubdirLabel:
                  showDirectSubdir ? group?.directSubdirShort : null,
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
      );
    }

    var list = scanList;
    if (_selectedSecondaryKey != null) {
      list = list
          .where(
            (v) =>
                scanSummary.byVariantId[v.id]?.volumeKey ==
                _selectedSecondaryKey,
          )
          .toList(growable: false);
    }
    if (normQuery.isNotEmpty) {
      list = list.where((v) {
        final group = scanSummary.byVariantId[v.id];
        return v.fileName.toLowerCase().contains(normQuery) ||
            (group?.chipLabel?.toLowerCase().contains(normQuery) ?? false) ||
            (group?.directSubdirShort?.toLowerCase().contains(normQuery) ??
                false);
      }).toList(growable: false);
    }
    if (list.isEmpty) return _buildEmptyMatch();

    final showDirectSubdir =
        _selectedSecondaryKey == null && scanSummary.hasMultipleSubdirs;
    return KonataDraggableScrollbar(
      controller: _gridScrollController,
      builder: (_, ctrl) => GridView.builder(
        controller: ctrl,
        padding: const EdgeInsets.only(right: 16, bottom: 6),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 204,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          mainAxisExtent: 196,
        ),
        itemCount: list.length,
        itemBuilder: (_, index) {
          final v = list[index];
          final group = scanSummary.byVariantId[v.id];
          return ScanDrawerCard(
            variant: v,
            source: widget.bundle.sourcesById[v.sourceId],
            workId: widget.bundle.work.id,
            workTitle: widget.bundle.work.title,
            showSeriesSharedBadge: showSharedBadge,
            directSubdirLabel:
                showDirectSubdir ? group?.directSubdirShort : null,
            onTap: () => widget.onScanTap?.call(v),
          );
        },
      ),
    );
  }

  Widget _buildEmptyMatch() {
    return Center(
      child: Text(
        '没有符合当前筛选条件的文件',
        style: KonataTheme.detailTextStyle(
          color: Colors.white.withValues(alpha: 0.68),
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _FrostedSearchField extends StatelessWidget {
  const _FrostedSearchField({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: KonataPlaybackTokens.softFill(p),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: KonataPlaybackTokens.glassBorder(p),
          width: 0.9,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 16,
            color: p.textSecondary,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: KonataTheme.detailTextStyle(
                palette: p,
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
              ),
              cursorColor: p.textPrimary,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '搜索文件名或分组...',
                hintStyle: KonataTheme.detailTextStyle(
                  palette: p,
                  color: p.textMuted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w400,
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                controller.clear();
                onChanged('');
              },
              child: Icon(
                Icons.close_rounded,
                size: 15,
                color: p.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}
