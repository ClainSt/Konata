import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_dialog.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/managed_image.dart';
import 'detail_bottom_drawer.dart';
import 'detail_gear_menu.dart';
import 'detail_secondary_filter_bar.dart';
import 'episode_drawer_card.dart';
import 'supplementary_asset_cards.dart';

/// 作品详情页高透毛玻璃「完整列表」弹窗：支持关键字实时检索、一级分类切换、二级筛选与可拖拽网格浏览。
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

  final WorkDetailBundle bundle;
  final ManagedImageLoader imageLoader;
  final DetailDrawerTab initialTab;
  final String? initialSecondaryFilterKey;
  final bool showRawVideoFilename;
  final bool showCdTab;
  final bool showScanTab;
  final ValueChanged<Episode> onEpisodeTap;
  final ValueChanged<Episode>? onEpisodePlayBuiltin;
  final ValueChanged<Episode>? onEpisodePlayExternal;
  final ValueChanged<Episode> onEpisodeAdjustSlot;
  final ValueChanged<Episode>? onEpisodeMarkCompleted;
  final ValueChanged<MediaVariant>? onCdTap;
  final ValueChanged<MediaVariant>? onCdPlayImmersive;
  final ValueChanged<MediaVariant>? onCdPlayExternal;
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
      barrierColor: KonataTheme.scrimBlackStrong,
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
  static final RegExp _kTechBracketNoise = RegExp(
    r'\[[^\]]*(?:1080p|720p|2160p|4k|x264|x265|hevc|avc|av1|ma10p|hi10p|hi444pp|8bit|10bit|flac|aac|ac3|dts|bdrip|web-?dl|webrip|\d{3,4}x\d{3,4})[^\]]*\]',
    caseSensitive: false,
  );
  static final RegExp _kDigitsOnly = RegExp(r'^\d+$');

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
    _searchController.addListener(_syncQueryFromController);
  }

  @override
  void dispose() {
    _searchController.removeListener(_syncQueryFromController);
    _scanScheduler.cancelAll();
    _searchController.dispose();
    _gridScrollController.dispose();
    super.dispose();
  }

  void _syncQueryFromController() {
    final next = _searchController.text;
    if (_query == next) return;
    setState(() => _query = next);
    _jumpToTop();
  }

  DetailDrawerTab _resolveAvailableTab(DetailDrawerTab candidate) {
    final cdAllowed =
        widget.showCdTab &&
        widget.bundle.cdVariants.any(
          (v) => !CueVariantResolver.isCueSheetFile(v.fileName),
        );
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

  /// 剥离文件名中固定的压制技术参数（如 `[Ma10p_1080p][x265_flac]`）与作品标题数字（如 `86`），防止搜集号 `2`/`5` 全量误命中。
  String _stripFileNameNoiseForNumericSearch(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    var cleaned = stem.replaceAll(_kTechBracketNoise, ' ');
    final workTitle = widget.bundle.work.title.trim();
    if (workTitle.isNotEmpty) {
      cleaned = cleaned.replaceAll(
        RegExp(RegExp.escape(workTitle), caseSensitive: false),
        ' ',
      );
    }
    return cleaned.toLowerCase();
  }

  String _directSubdirName(String relativePath) {
    final norm = relativePath.replaceAll('\\', '/');
    final slash = norm.lastIndexOf('/');
    if (slash <= 0) return '';
    final parent = norm.substring(0, slash);
    final prevSlash = parent.lastIndexOf('/');
    return prevSlash >= 0 ? parent.substring(prevSlash + 1) : parent;
  }

  bool _matchesEpisodeQuery({
    required Episode ep,
    required String cardTitle,
    required String extraKindLabel,
    required List<MediaVariant> variants,
    required List<String> tokens,
  }) {
    final cardTitleLower = cardTitle.toLowerCase();
    final epTitleLower = (ep.title ?? '').toLowerCase();
    final kindLower = extraKindLabel.toLowerCase();
    final epNum = ep.episodeNumber;
    final paddedEpNum = epNum != null ? epNum.toString().padLeft(2, '0') : '';

    for (final tok in tokens) {
      if (_kDigitsOnly.hasMatch(tok)) {
        final parsedNum = int.tryParse(tok);
        final hitEpNum =
            (parsedNum != null &&
                epNum != null &&
                epNum > 0 &&
                epNum == parsedNum) ||
            (epNum != null && epNum > 0 && paddedEpNum.contains(tok)) ||
            cardTitleLower.contains(tok);
        if (hitEpNum) continue;
        final hitCleanFile = variants.any(
          (v) => _stripFileNameNoiseForNumericSearch(v.fileName).contains(tok),
        );
        if (!hitCleanFile) return false;
      } else {
        final hitMeta =
            cardTitleLower.contains(tok) ||
            epTitleLower.contains(tok) ||
            kindLower.contains(tok);
        if (hitMeta) continue;
        final hitFile = variants.any(
          (v) =>
              v.fileName.toLowerCase().contains(tok) ||
              _directSubdirName(v.relativePath).toLowerCase().contains(tok),
        );
        if (!hitFile) return false;
      }
    }
    return true;
  }

  bool _matchesAssetVariantQuery({
    required MediaVariant variant,
    required String? chipLabel,
    required String? subdirShort,
    required List<String> tokens,
  }) {
    final chipLower = (chipLabel ?? '').toLowerCase();
    final subLower = (subdirShort ?? _directSubdirName(variant.relativePath))
        .toLowerCase();
    final fileLower = variant.fileName.toLowerCase();

    for (final tok in tokens) {
      if (_kDigitsOnly.hasMatch(tok)) {
        final hit =
            _stripFileNameNoiseForNumericSearch(
              variant.fileName,
            ).contains(tok) ||
            chipLower.contains(tok) ||
            subLower.contains(tok);
        if (!hit) return false;
      } else {
        final hit =
            fileLower.contains(tok) ||
            chipLower.contains(tok) ||
            subLower.contains(tok);
        if (!hit) return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screenSize = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final compact =
        screenSize.width < KonataAdaptiveTokens.tabletBreakpoint ||
        screenSize.height < KonataAdaptiveTokens.shortViewportHeight;
    final dialogWidth = (compact
        ? math.max(240.0, screenSize.width - safe.horizontal - 24.0)
        : (screenSize.width * 0.84).clamp(
            math.min(620.0, screenSize.width - 24.0),
            1180.0,
          )).toDouble();
    final dialogHeight = (compact
        ? math.max(200.0, screenSize.height - safe.vertical - 24.0)
        : (screenSize.height * 0.82).clamp(
            math.min(480.0, screenSize.height - 24.0),
            820.0,
          )).toDouble();

    final mainEps = widget.bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .toList(growable: false);
    final extraEps = widget.bundle.episodes
        .where((e) => e.category == EpisodeCategory.extra)
        .toList(growable: false);
    final cdList = widget.showCdTab
        ? widget.bundle.cdVariants
              .where((v) => !CueVariantResolver.isCueSheetFile(v.fileName))
              .toList(growable: false)
        : const <MediaVariant>[];
    final scanList = widget.showScanTab
        ? widget.bundle.scanVariants
        : const <MediaVariant>[];
    final showSharedBadge = widget.bundle.seriesMembers.length >= 2;
    final queryTokens = _query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

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

    final secondaryItems = switch (_activeTab) {
      DetailDrawerTab.extra =>
        SupplementarySubclassifier.extraKindDisplayOrder
            .where((k) => (extraCountByKind[k] ?? 0) > 0)
            .map(
              (k) => DetailSecondaryFilterItem(
                key: k.name,
                label: SupplementarySubclassifier.extraKindLabel(k),
                count: extraCountByKind[k] ?? 0,
              ),
            )
            .toList(growable: false),
      DetailDrawerTab.cd =>
        cdSummary.chips
            .map(
              (c) => DetailSecondaryFilterItem(
                key: c.key,
                label: c.label,
                count: c.count,
              ),
            )
            .toList(growable: false),
      DetailDrawerTab.scan =>
        scanSummary.chips
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
          borderRadius: KonataTheme.borderRadiusCapsule,
          child: BackdropFilter(
            filter: KonataTheme.blurFilterCapsule,
            child: Container(
              width: dialogWidth,
              height: dialogHeight,
              decoration: BoxDecoration(
                color: KonataPlaybackTokens.popoverSurface(p),
                borderRadius: KonataTheme.borderRadiusCapsule,
                border: Border.all(
                  color: KonataPlaybackTokens.glassBorder(p),
                  width: 1,
                ),
              ),
              padding: EdgeInsets.fromLTRB(
                compact ? 14.0 : 22.0,
                compact ? 12.0 : 18.0,
                compact ? 14.0 : 22.0,
                compact ? 12.0 : 18.0,
              ),
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
                                fontSize: compact ? 15.5 : 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 248,
                          height: KonataAdaptiveTokens.isAndroid
                              ? KonataAdaptiveTokens.touchTarget
                              : 34,
                          child: KonataSearchField(
                            controller: _searchController,
                            borderRadius: KonataTheme.borderRadiusCard,
                            onChanged: (v) {
                              if (_query == v) return;
                              setState(() => _query = v);
                              _jumpToTop();
                            },
                          ),
                        ),
                      ],
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: '关闭 (Esc)',
                        constraints: KonataAdaptiveTokens.isAndroid
                            ? const BoxConstraints(
                                minWidth: KonataAdaptiveTokens.touchTarget,
                                minHeight: KonataAdaptiveTokens.touchTarget,
                              )
                            : null,
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
                  if (compact) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: KonataAdaptiveTokens.isAndroid
                          ? KonataAdaptiveTokens.touchTarget
                          : 36,
                      child: KonataSearchField(
                        controller: _searchController,
                        borderRadius: KonataTheme.borderRadiusCard,
                        onChanged: (v) {
                          if (_query == v) return;
                          setState(() => _query = v);
                          _jumpToTop();
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: KonataTheme.subtleOutlineBorder(p),
                        borderRadius: KonataTheme.borderRadiusPill,
                        border: Border.all(
                          color: KonataTheme.subtleControlBorder(p),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DetailDrawerTabChip(
                            label: '正片 (${mainEps.length})',
                            active: _activeTab == DetailDrawerTab.main,
                            onTap: () => _selectTab(DetailDrawerTab.main),
                          ),
                          const SizedBox(width: 4),
                          DetailDrawerTabChip(
                            label: '特典 (${extraEps.length})',
                            active: _activeTab == DetailDrawerTab.extra,
                            onTap: () => _selectTab(DetailDrawerTab.extra),
                          ),
                          if (cdList.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            DetailDrawerTabChip(
                              label: 'CD (${cdList.length})',
                              active: _activeTab == DetailDrawerTab.cd,
                              onTap: () => _selectTab(DetailDrawerTab.cd),
                            ),
                          ],
                          if (scanList.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            DetailDrawerTabChip(
                              label: 'Scan (${scanList.length})',
                              active: _activeTab == DetailDrawerTab.scan,
                              onTap: () => _selectTab(DetailDrawerTab.scan),
                            ),
                          ],
                        ],
                      ),
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
                      queryTokens: queryTokens,
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
    required List<String> queryTokens,
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
      if (queryTokens.isNotEmpty) {
        list = list
            .where((e) {
              final vars = widget.bundle.variantsForEpisode(e.id);
              final cardTitle = _activeTab == DetailDrawerTab.extra
                  ? (extraDisplayTitleByEpId[e.id] ?? '')
                  : EpisodeTitleFormatter.formatCardTitle(
                      episode: e,
                      workTitle: widget.bundle.work.title,
                      workMediaType: widget.bundle.work.tmdbMediaType,
                      mainEpisodeCount: mainEps.length,
                    );
              final kindLabel = _activeTab == DetailDrawerTab.extra
                  ? SupplementarySubclassifier.extraKindLabel(
                      extraKindByEpId[e.id] ?? ExtraKind.sp,
                    )
                  : '正片';
              return _matchesEpisodeQuery(
                ep: e,
                cardTitle: cardTitle,
                extraKindLabel: kindLabel,
                variants: vars,
                tokens: queryTokens,
              );
            })
            .toList(growable: false);
      }
      if (list.isEmpty) {
        return _buildEmptyMatch();
      }
      return _buildCompactCardRows<Episode>(
        items: list,
        itemBuilder: (ep) {
          final variants = widget.bundle.variantsForEpisode(ep.id);
          final playback = widget.bundle.playbackByEpisodeId[ep.id];
          final markHandler = widget.onEpisodeMarkCompleted;
          return EpisodeDrawerCard(
            key: ValueKey('full_list_ep_${ep.id}'),
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
            compactMeta: true,
            onDarkBackdrop: false,
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
      );
    }

    if (_activeTab == DetailDrawerTab.cd) {
      var list = cdList;
      if (_selectedSecondaryKey != null) {
        list = list
            .where(
              (v) =>
                  cdSummary.byVariantId[v.id]?.albumKey ==
                  _selectedSecondaryKey,
            )
            .toList(growable: false);
      }
      if (queryTokens.isNotEmpty) {
        list = list
            .where((v) {
              final group = cdSummary.byVariantId[v.id];
              return _matchesAssetVariantQuery(
                variant: v,
                chipLabel: group?.chipLabel,
                subdirShort: group?.directSubdirShort,
                tokens: queryTokens,
              );
            })
            .toList(growable: false);
      }
      if (list.isEmpty) return _buildEmptyMatch();

      final showDirectSubdir =
          _selectedSecondaryKey == null && cdSummary.hasMultipleSubdirs;
      return _buildCompactCardRows<MediaVariant>(
        items: list,
        itemBuilder: (v) {
          final group = cdSummary.byVariantId[v.id];
          final dot = v.fileName.lastIndexOf('.');
          final stem = dot > 0 ? v.fileName.substring(0, dot) : v.fileName;
          final titleOverride =
              (CueVariantResolver.isGenericDiscImageStem(stem) &&
                  group != null &&
                  group.chipLabel.isNotEmpty &&
                  group.chipLabel != 'CD')
              ? group.chipLabel
              : null;
          return CdDrawerCard(
            key: ValueKey('full_list_cd_${v.id}'),
            variant: v,
            showSeriesSharedBadge: showSharedBadge,
            displayTitleOverride: titleOverride,
            showRawFileName: widget.showRawVideoFilename,
            directSubdirLabel: showDirectSubdir
                ? group?.directSubdirShort
                : null,
            onDarkBackdrop: false,
            onTap: () => widget.onCdTap?.call(v),
            onPlayImmersive: widget.onCdPlayImmersive == null
                ? null
                : () => widget.onCdPlayImmersive!(v),
            onPlayExternal: widget.onCdPlayExternal == null
                ? null
                : () => widget.onCdPlayExternal!(v),
          );
        },
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
    if (queryTokens.isNotEmpty) {
      list = list
          .where((v) {
            final group = scanSummary.byVariantId[v.id];
            return _matchesAssetVariantQuery(
              variant: v,
              chipLabel: group?.chipLabel,
              subdirShort: group?.directSubdirShort,
              tokens: queryTokens,
            );
          })
          .toList(growable: false);
    }
    if (list.isEmpty) return _buildEmptyMatch();

    final showDirectSubdir =
        _selectedSecondaryKey == null && scanSummary.hasMultipleSubdirs;
    return _buildCompactCardRows<MediaVariant>(
      items: list,
      itemBuilder: (v) {
        final group = scanSummary.byVariantId[v.id];
        return ScanDrawerCard(
          key: ValueKey('full_list_scan_${v.id}'),
          variant: v,
          source: widget.bundle.sourcesById[v.sourceId],
          workId: widget.bundle.work.id,
          workTitle: widget.bundle.work.title,
          showSeriesSharedBadge: showSharedBadge,
          directSubdirLabel: showDirectSubdir ? group?.directSubdirShort : null,
          onDarkBackdrop: false,
          onTap: () => widget.onScanTap?.call(v),
        );
      },
    );
  }

  /// 按卡片「16:9 缩略图 + 底部实际文字」真实自然高度紧凑分行排布，消除固定网格行高造成的垂直空隙。
  Widget _buildCompactCardRows<T>({
    required List<T> items,
    required Widget Function(T item) itemBuilder,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const rightPad = 16.0;
        const crossSpacing = 12.0;
        const maxExtent = 256.0;
        final usableWidth = math.max(120.0, constraints.maxWidth - rightPad);
        final columns = math.max(
          1,
          ((usableWidth + crossSpacing) / (maxExtent + crossSpacing)).ceil(),
        );
        final rowCount = (items.length + columns - 1) ~/ columns;

        return KonataDraggableScrollbar(
          controller: _gridScrollController,
          builder: (_, ctrl) => ListView.separated(
            controller: ctrl,
            padding: const EdgeInsets.only(right: rightPad, bottom: 6),
            itemCount: rowCount,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, rowIdx) {
              final start = rowIdx * columns;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var col = 0; col < columns; col++) ...[
                    if (col > 0) const SizedBox(width: crossSpacing),
                    Expanded(
                      child: start + col < items.length
                          ? itemBuilder(items[start + col])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildEmptyMatch() {
    final p = context.palette;
    final trimmed = _query.trim();
    return Center(
      child: Text(
        trimmed.isEmpty ? '没有符合当前筛选条件的文件' : '当前分类下未找到匹配 “$trimmed” 的条目',
        style: KonataTheme.detailTextStyle(
          palette: p,
          color: p.textSecondary,
          fontSize: KonataTheme.fontSizeBody,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
