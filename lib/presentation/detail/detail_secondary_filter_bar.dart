
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers/library_providers.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';

/// 详情页底部抽屉与完整列表共用的剧集、特典、CD 与 Scan 二级分组聚合数据。
class DetailSupplementaryViewData {
  const DetailSupplementaryViewData._({
    required this.mainEpisodes,
    required this.extraEpisodes,
    required this.cdList,
    required this.scanList,
    required this.extraKindByEpId,
    required this.extraDisplayTitleByEpId,
    required this.cdSummary,
    required this.scanSummary,
    required this.extraSecondaryItems,
    required this.cdSecondaryItems,
    required this.scanSecondaryItems,
  });

  /// 从作品详情聚合包统一计算正片、特典、CD、Scan 列表与二级筛选选项。
  factory DetailSupplementaryViewData.fromBundle({
    required WorkDetailBundle bundle,
    required bool showCdTab,
    required bool showScanTab,
  }) {
    final mainEps = bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .toList(growable: false);
    final extraEps = bundle.episodes
        .where((e) => e.category == EpisodeCategory.extra)
        .toList(growable: false);
    final cdList = showCdTab
        ? bundle.cdVariants
              .where((v) => !CueVariantResolver.isCueSheetFile(v.fileName))
              .toList(growable: false)
        : const <MediaVariant>[];
    final scanList = showScanTab
        ? bundle.scanVariants
        : const <MediaVariant>[];

    final extraKindByEpId = <String, ExtraKind>{};
    final extraCountByKind = <ExtraKind, int>{};
    final extraDisplayTitleByEpId = <String, String>{};
    for (final ep in extraEps) {
      final variants = bundle.variantsForEpisode(ep.id);
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
      extraDisplayTitleByEpId[ep.id] =
          SupplementarySubclassifier.formatExtraDisplayTitle(
            episode: ep,
            episodeVariants: variants,
            allWorkVariants: bundle.variants,
            defaultFormattedTitle: EpisodeTitleFormatter.formatCardTitle(
              episode: ep,
              workTitle: bundle.work.title,
              workMediaType: bundle.work.tmdbMediaType,
              mainEpisodeCount: mainEps.length,
            ),
          );
    }

    final cdSummary = SupplementarySubclassifier.groupCdVariants(cdList);
    final scanSummary = SupplementarySubclassifier.groupScanVariants(scanList);

    List<DetailSecondaryFilterItem> toItems(
      Iterable<({String key, String label, int count})> chips,
    ) => [
      for (final c in chips)
        DetailSecondaryFilterItem(key: c.key, label: c.label, count: c.count),
    ];

    return DetailSupplementaryViewData._(
      mainEpisodes: mainEps,
      extraEpisodes: extraEps,
      cdList: cdList,
      scanList: scanList,
      extraKindByEpId: extraKindByEpId,
      extraDisplayTitleByEpId: extraDisplayTitleByEpId,
      cdSummary: cdSummary,
      scanSummary: scanSummary,
      extraSecondaryItems: [
        for (final k in SupplementarySubclassifier.extraKindDisplayOrder)
          if ((extraCountByKind[k] ?? 0) > 0)
            DetailSecondaryFilterItem(
              key: k.name,
              label: SupplementarySubclassifier.extraKindLabel(k),
              count: extraCountByKind[k]!,
            ),
      ],
      cdSecondaryItems: toItems(cdSummary.chips),
      scanSecondaryItems: toItems(scanSummary.chips),
    );
  }

  final List<Episode> mainEpisodes;
  final List<Episode> extraEpisodes;
  final List<MediaVariant> cdList;
  final List<MediaVariant> scanList;
  final Map<String, ExtraKind> extraKindByEpId;
  final Map<String, String> extraDisplayTitleByEpId;
  final CdAlbumGroupSummary cdSummary;
  final ScanVolumeGroupSummary scanSummary;
  final List<DetailSecondaryFilterItem> extraSecondaryItems;
  final List<DetailSecondaryFilterItem> cdSecondaryItems;
  final List<DetailSecondaryFilterItem> scanSecondaryItems;

  /// 当整轨光盘镜像使用通用占位名时，回退使用专辑分组标签作为展示标题。
  String? cdTitleOverrideFor(MediaVariant variant) {
    final group = cdSummary.byVariantId[variant.id];
    final dot = variant.fileName.lastIndexOf('.');
    final stem = dot > 0
        ? variant.fileName.substring(0, dot)
        : variant.fileName;
    return (CueVariantResolver.isGenericDiscImageStem(stem) &&
            group != null &&
            group.chipLabel.isNotEmpty &&
            group.chipLabel != 'CD')
        ? group.chipLabel
        : null;
  }
}

/// 详情页二级分类筛选条上的单条筛选项数据。
class DetailSecondaryFilterItem {
  /// 创建二级筛选项。
  const DetailSecondaryFilterItem({
    required this.key,
    required this.label,
    required this.count,
  });

  /// 筛选项唯一键（例如特典类型名、专辑 key、分卷 key）。
  final String key;

  /// 展示标签文本。
  final String label;

  /// 当前分组包含的条目数量。
  final int count;
}

/// 作品详情页底部抽屉/完整列表共用的高透二级筛选条。
class DetailSecondaryFilterBar extends StatefulWidget {
  /// 创建二级筛选条。
  const DetailSecondaryFilterBar({
    super.key,
    required this.items,
    required this.totalCount,
    required this.selectedKey,
    required this.onSelected,
    this.horizontalPadding = 36,
    this.compact = false,
  });

  /// 具体二级分类选项列表。
  final List<DetailSecondaryFilterItem> items;

  /// 全部分类条目总数。
  final int totalCount;

  /// 当前选中的二级键，`null` 代表「全部」。
  final String? selectedKey;

  /// 选中或切换二级选项时的回调。
  final ValueChanged<String?> onSelected;

  /// 左右内边距（详情页底部轨道默认为 36，完整列表弹窗可调小）。
  final double horizontalPadding;

  /// 是否使用紧凑尺寸（用于弹窗内部）。
  final bool compact;

  @override
  State<DetailSecondaryFilterBar> createState() =>
      _DetailSecondaryFilterBarState();
}

class _DetailSecondaryFilterBarState extends State<DetailSecondaryFilterBar> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final isPhone =
        KonataAdaptiveTokens.isAndroid &&
        screenSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint;
    final effectiveCompact = widget.compact || isPhone;
    final barHeight = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : (effectiveCompact ? 30.0 : 32.0);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
        child: SizedBox(
          height: barHeight,
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent && _scrollController.hasClients) {
                final delta = event.scrollDelta.dy != 0
                    ? event.scrollDelta.dy
                    : event.scrollDelta.dx;
                final pos = _scrollController.position;
                final target = (_scrollController.offset + delta).clamp(
                  pos.minScrollExtent,
                  pos.maxScrollExtent,
                );
                _scrollController.jumpTo(target);
              }
            },
            child: ListView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              // 显式归零内边距，防止横屏刘海安全区在外部已避让后被 ListView 二次重复注入导致左侧错位。
              padding: EdgeInsets.zero,
              children: [
                _SecondaryFilterChip(
                  label: '全部',
                  selected: widget.selectedKey == null,
                  compact: effectiveCompact,
                  onTap: () => widget.onSelected(null),
                ),
                for (final item in widget.items) ...[
                  SizedBox(width: isPhone ? 6 : 8),
                  _SecondaryFilterChip(
                    label: item.label,
                    selected: widget.selectedKey == item.key,
                    compact: effectiveCompact,
                    onTap: () => widget.onSelected(item.key),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryFilterChip extends StatefulWidget {
  const _SecondaryFilterChip({
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_SecondaryFilterChip> createState() => _SecondaryFilterChipState();
}

class _SecondaryFilterChipState extends State<_SecondaryFilterChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bgColor = KonataPlaybackTokens.secondaryFilterPillBg(
      p,
      selected: widget.selected,
      hovered: _hovered,
    );
    final borderColor = KonataPlaybackTokens.secondaryFilterPillBorder(
      p,
      selected: widget.selected,
    );
    final textColor = KonataPlaybackTokens.secondaryFilterPillText(
      p,
      selected: widget.selected,
      hovered: _hovered,
    );

    final pill = ClipRRect(
      borderRadius: KonataTheme.borderRadiusPill,
      child: BackdropFilter(
        filter: KonataTheme.blurFilterSubtle,
        child: AnimatedContainer(
          duration: KonataTheme.motionStandard,
          curve: Curves.easeOutCubic,
          constraints: BoxConstraints(
            minWidth: KonataAdaptiveTokens.isAndroid
                ? KonataAdaptiveTokens.touchTarget
                : 0,
            maxWidth: widget.compact ? 210 : 280,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 11 : 13,
            vertical: widget.compact ? 5.5 : 6,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(
              color: borderColor,
              width: widget.selected ? 1.0 : 0.85,
            ),
          ),
          child: Center(
            widthFactor: 1.0,
            heightFactor: 1.0,
            child: EllipsisTextWithTooltip(
              text: widget.label,
              maxLines: 1,
              style: KonataTheme.detailTextStyle(
                palette: p,
                color: textColor,
                fontSize: widget.compact ? 11.5 : 12,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: KonataAdaptiveTokens.isAndroid
            ? ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: KonataAdaptiveTokens.touchTarget,
                  minHeight: KonataAdaptiveTokens.touchTarget,
                ),
                child: Center(widthFactor: 1.0, heightFactor: 1.0, child: pill),
              )
            : pill,
      ),
    );
  }
}
