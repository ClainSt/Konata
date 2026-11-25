import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart'
    show EpisodeTitleFormatter;
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_edit_models.dart';

class _SlotOption {
  const _SlotOption({
    required this.category,
    required this.seasonNumber,
    required this.episodeNumber,
    this.extraType,
    required this.isTmdbSpecial,
    required this.groupHeader,
    required this.label,
  });

  final EpisodeCategory category;
  final int seasonNumber;
  final int episodeNumber;
  final ExtraKind? extraType;
  final bool isTmdbSpecial;
  final String groupHeader;
  final String label;

  bool matches(EditableFileMappingRow row) {
    if (category != row.category) return false;
    if (category == EpisodeCategory.main) {
      return seasonNumber == row.seasonNumber &&
          episodeNumber == row.episodeNumber;
    }
    if (isTmdbSpecial != row.isTmdbSpecial) return false;
    if (isTmdbSpecial) {
      return episodeNumber == row.episodeNumber;
    }
    return true;
  }
}

/// 单行文件映射槽位选择器按钮（一键选定正片分集、保持原识别特典或 `TMDB Season 0` 特别篇）。
class EpisodeSlotPickerButton extends StatefulWidget {
  /// 创建文件映射槽位选择器按钮。
  const EpisodeSlotPickerButton({
    super.key,
    required this.row,
    required this.referenceEpisodes,
    required this.defaultMainSeason,
    required this.enabled,
    required this.onPicked,
  });

  /// 当前文件映射行状态。
  final EditableFileMappingRow row;

  /// 参考正片与特别篇剧集目录。
  final List<Episode> referenceEpisodes;

  /// 默认正片季号。
  final int defaultMainSeason;

  /// 是否允许修改。
  final bool enabled;

  /// 用户点选槽位后的回调。
  final void Function(
    EpisodeCategory category,
    int seasonNumber,
    int episodeNumber,
    ExtraKind? extraType,
    bool isTmdbSpecial,
  )
  onPicked;

  @override
  State<EpisodeSlotPickerButton> createState() =>
      _EpisodeSlotPickerButtonState();
}

class _EpisodeSlotPickerButtonState extends State<EpisodeSlotPickerButton> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _dismiss();
    super.dispose();
  }

  void _dismiss() {
    _entry?.remove();
    _entry = null;
  }

  List<_SlotOption> _buildOptions() {
    final mainByKey = <int, Episode>{};
    final tmdbSpecialByNum = <int, Episode>{};
    var maxMainEp = 0;

    for (final ep in widget.referenceEpisodes) {
      final num = ep.episodeNumber ?? 0;
      if (ep.category == EpisodeCategory.main && num > 0) {
        mainByKey.putIfAbsent(num, () => ep);
        if (num > maxMainEp) maxMainEp = num;
      } else if (ep.category == EpisodeCategory.extra &&
          num > 0 &&
          (ep.extraType == null || ep.extraType == ExtraKind.sp)) {
        tmdbSpecialByNum.putIfAbsent(num, () => ep);
      }
    }

    final season = widget.defaultMainSeason <= 0 ? 1 : widget.defaultMainSeason;
    final mainLimit = maxMainEp > 12 ? maxMainEp : 12;
    final options = <_SlotOption>[];

    final keepExtraLabel = widget.row.displayRecognizedExtra;
    options.add(
      _SlotOption(
        category: EpisodeCategory.extra,
        seasonNumber: 0,
        episodeNumber: widget.row.initialCategory == EpisodeCategory.extra
            ? widget.row.initialEpisodeNumber
            : 0,
        extraType: widget.row.initialCategory == EpisodeCategory.extra
            ? widget.row.initialExtraType
            : ExtraKind.sp,
        isTmdbSpecial: false,
        groupHeader: '特典（按原识别保留）',
        label: '特典 · $keepExtraLabel',
      ),
    );

    for (var i = 1; i <= mainLimit; i++) {
      final ep = mainByKey[i];
      final eStr = EpisodeTitleFormatter.formatEpisodeNumberLabel(
        i,
        ep?.episodeNumberEnd,
      );
      final rawTitle = ep?.title?.trim() ?? '';
      final suffix = rawTitle.isNotEmpty ? ' · $rawTitle' : '';
      options.add(
        _SlotOption(
          category: EpisodeCategory.main,
          seasonNumber: ep?.seasonNumber ?? season,
          episodeNumber: i,
          isTmdbSpecial: false,
          groupHeader: 'TMDB 正片分集',
          label: '正片 · 第 $eStr 集$suffix',
        ),
      );
    }

    final specials = tmdbSpecialByNum.values.toList()
      ..sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
    if (specials.isNotEmpty) {
      for (final sp in specials) {
        final num = sp.episodeNumber ?? 1;
        final eStr = num.toString().padLeft(2, '0');
        final rawTitle = sp.title?.trim() ?? '';
        final suffix = rawTitle.isNotEmpty ? ' · $rawTitle' : '';
        options.add(
          _SlotOption(
            category: EpisodeCategory.extra,
            seasonNumber: 0,
            episodeNumber: num,
            extraType: ExtraKind.sp,
            isTmdbSpecial: true,
            groupHeader: 'TMDB 特别篇 (Season 0)',
            label: '特别篇 · 第 $eStr 集$suffix',
          ),
        );
      }
    } else {
      for (var i = 1; i <= 4; i++) {
        final eStr = i.toString().padLeft(2, '0');
        options.add(
          _SlotOption(
            category: EpisodeCategory.extra,
            seasonNumber: 0,
            episodeNumber: i,
            extraType: ExtraKind.sp,
            isTmdbSpecial: true,
            groupHeader: 'TMDB 特别篇 (Season 0)',
            label: '特别篇 · 第 $eStr 集',
          ),
        );
      }
    }
    return options;
  }

  String _formatClosedLabel(EditableFileMappingRow r) {
    if (r.category == EpisodeCategory.main) {
      final epNum = r.episodeNumber > 0 ? r.episodeNumber : 1;
      int? epEnd;
      for (final ep in widget.referenceEpisodes) {
        if (ep.category == EpisodeCategory.main &&
            ep.seasonNumber == r.seasonNumber &&
            ep.episodeNumber == epNum) {
          epEnd = ep.episodeNumberEnd;
          break;
        }
      }
      final eStr = EpisodeTitleFormatter.formatEpisodeNumberLabel(epNum, epEnd);
      if (r.seasonNumber > 1) {
        final sStr = r.seasonNumber.toString().padLeft(2, '0');
        return '正片 · S${sStr}E$eStr';
      }
      return '正片 · 第 $eStr 集';
    }
    if (r.isTmdbSpecial && r.episodeNumber > 0) {
      final eStr = r.episodeNumber.toString().padLeft(2, '0');
      return '特别篇 · 第 $eStr 集';
    }
    return r.displayRecognizedExtra;
  }

  void _toggle() {
    if (!widget.enabled) return;
    if (_entry != null) {
      _dismiss();
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final pos = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    final openUpward =
        pos.dy + box.size.height + 300 > screen.height - 16 && pos.dy > 260;

    final options = _buildOptions();
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (_) => _SlotPopoverOverlay(
        link: _link,
        openUpward: openUpward,
        options: options,
        currentRow: widget.row,
        onDismiss: _dismiss,
        onPick: (opt) {
          _dismiss();
          widget.onPicked(
            opt.category,
            opt.seasonNumber,
            opt.episodeNumber,
            opt.extraType,
            opt.isTmdbSpecial,
          );
        },
      ),
    );
    overlay.insert(_entry!);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = _formatClosedLabel(widget.row);
    final isMain = widget.row.category == EpisodeCategory.main;

    return CompositedTransformTarget(
      link: _link,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? _toggle : null,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: p.softFill,
            borderRadius: KonataTheme.borderRadiusSm,
            border: Border.all(
              color: widget.row.isModified ? p.accent : p.hairline,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isMain ? p.accent : p.warning,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeCaption,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: p.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlotPopoverOverlay extends StatefulWidget {
  const _SlotPopoverOverlay({
    required this.link,
    required this.openUpward,
    required this.options,
    required this.currentRow,
    required this.onDismiss,
    required this.onPick,
  });

  final LayerLink link;
  final bool openUpward;
  final List<_SlotOption> options;
  final EditableFileMappingRow currentRow;
  final VoidCallback onDismiss;
  final ValueChanged<_SlotOption> onPick;

  @override
  State<_SlotPopoverOverlay> createState() => _SlotPopoverOverlayState();
}

class _SlotPopoverOverlayState extends State<_SlotPopoverOverlay> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  String _query = '';
  int? _hoveredIndex;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lowerQuery = _query.trim().toLowerCase();
    final filtered = widget.options
        .where(
          (o) =>
              lowerQuery.isEmpty ||
              o.label.toLowerCase().contains(lowerQuery) ||
              o.groupHeader.toLowerCase().contains(lowerQuery),
        )
        .toList(growable: false);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          targetAnchor: widget.openUpward
              ? Alignment.topLeft
              : Alignment.bottomLeft,
          followerAnchor: widget.openUpward
              ? Alignment.bottomLeft
              : Alignment.topLeft,
          offset: Offset(0, widget.openUpward ? -4 : 4),
          child: ClipRRect(
            borderRadius: KonataTheme.borderRadiusCard,
            child: BackdropFilter(
              filter: KonataTheme.blurFilterOverlay,
              child: Container(
                width: 300,
                constraints: BoxConstraints(
                  maxHeight: math.min(
                    320,
                    MediaQuery.sizeOf(context).height * 0.52,
                  ),
                ),
                decoration: BoxDecoration(
                  color: KonataTheme.glassDialogSurface(p),
                  borderRadius: KonataTheme.borderRadiusCard,
                  border: Border.all(
                    color: KonataTheme.glassDialogBorder(p),
                    width: 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                      child: KonataSoftTextField(
                        controller: _searchCtrl,
                        dense: true,
                        prefixIcon: Icons.search_rounded,
                        hintText: '搜索集数、标题或特典...',
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    Flexible(
                      child: KonataDraggableScrollbar(
                        controller: _scrollCtrl,
                        builder: (_, ctrl) => ListView.builder(
                          controller: ctrl,
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(6, 0, 10, 6),
                          itemCount: filtered.length,
                          itemBuilder: (_, index) {
                            final opt = filtered[index];
                            final selected = opt.matches(widget.currentRow);
                            final showHeader =
                                index == 0 ||
                                filtered[index - 1].groupHeader !=
                                    opt.groupHeader;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (showHeader)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      8,
                                      8,
                                      4,
                                    ),
                                    child: Text(
                                      opt.groupHeader,
                                      style: TextStyle(
                                        color: p.textMuted,
                                        fontSize: KonataTheme.fontSizeCaptionXs,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                KonataPopoverOptionTile(
                                  hovered: _hoveredIndex == index,
                                  selected: selected,
                                  onHoverEnter: () =>
                                      setState(() => _hoveredIndex = index),
                                  onHoverExit: () {
                                    if (_hoveredIndex == index) {
                                      setState(() => _hoveredIndex = null);
                                    }
                                  },
                                  onTap: () => widget.onPick(opt),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          opt.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: selected
                                                ? p.accent
                                                : p.textPrimary,
                                            fontSize:
                                                KonataTheme.fontSizeCaption,
                                            fontWeight: selected
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      if (selected)
                                        Icon(
                                          Icons.check_rounded,
                                          size: 14,
                                          color: p.accent,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
