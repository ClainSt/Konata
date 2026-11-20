import 'package:flutter/material.dart';

import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';

/// 手动编辑「文件映射修正」单行可变状态模型。
class EditableFileMappingRow {
  /// 创建单行文件映射编辑状态。
  EditableFileMappingRow({
    required this.variant,
    required this.category,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.extraType,
    this.recognizedExtraLabel = '',
    this.isTmdbSpecial = false,
  }) : initialCategory = category,
       initialSeasonNumber = seasonNumber,
       initialEpisodeNumber = episodeNumber,
       initialExtraType = extraType,
       initialIsTmdbSpecial = isTmdbSpecial;

  /// 物理视频变体。
  final MediaVariant variant;

  /// 初始剧集分类。
  final EpisodeCategory initialCategory;

  /// 初始季号。
  final int initialSeasonNumber;

  /// 初始集号（未编号普通特典可为 0）。
  final int initialEpisodeNumber;

  /// 初始特典子类。
  final ExtraKind initialExtraType;

  /// 初始是否已对齐至 TMDB Season 0 特别篇。
  final bool initialIsTmdbSpecial;

  /// 自动识别出的特典可读标签（如 `PV01`、`NCOP1`、`CM02`），普通特典默认原样展示。
  final String recognizedExtraLabel;

  /// 当前分类。
  EpisodeCategory category;

  /// 当前季号。
  int seasonNumber;

  /// 当前集号。
  int episodeNumber;

  /// 当前特典子类。
  ExtraKind extraType;

  /// 当前是否显式对齐为 TMDB 特别篇（Season 0）。
  bool isTmdbSpecial;

  /// 面向非特别篇特典的简洁识别展示文案（优先使用真实识别标题，如 `PV01`、`NCOP1`）。
  String get displayRecognizedExtra {
    final trimmed = recognizedExtraLabel.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final kindUpper = extraType.name.toUpperCase();
    if (episodeNumber > 0) {
      return '$kindUpper${episodeNumber.toString().padLeft(2, '0')}';
    }
    return kindUpper;
  }

  /// 相对于初始状态是否发生变更。
  bool get isModified =>
      category != initialCategory ||
      seasonNumber != initialSeasonNumber ||
      episodeNumber != initialEpisodeNumber ||
      extraType != initialExtraType ||
      isTmdbSpecial != initialIsTmdbSpecial;
}

/// 可视化选集下拉浮层中的单个目标槽位项。
class _SlotOption {
  const _SlotOption({
    required this.category,
    required this.seasonNumber,
    required this.episodeNumber,
    this.extraType,
    required this.isTmdbSpecial,
    required this.label,
    required this.groupHeader,
  });

  final EpisodeCategory category;
  final int seasonNumber;
  final int episodeNumber;
  final ExtraKind? extraType;
  final bool isTmdbSpecial;
  final String label;
  final String groupHeader;
}

/// 点击单行归属下拉框弹出的高透毛玻璃可视化选集浮层控件。
///
/// 仅提供三类清晰归属：TMDB 对应正片第几集、TMDB 对应特别篇第几集，以及保持原识别特典（如 `PV01`）。
class EpisodeSlotPickerButton extends StatefulWidget {
  /// 创建可视化选集下拉按钮。
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

  /// 当前作品关联的正片与特别篇剧集目录（供一键点选）。
  final List<Episode> referenceEpisodes;

  /// 默认正片季号。
  final int defaultMainSeason;

  /// 是否允许编辑。
  final bool enabled;

  /// 用户点选某一槽位后的回调。
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

    // 1. 保持识别特典（原样 PV01 / NCOP1 等，不强行编入 S00E01）
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

    // 2. TMDB 正片分集（兼容多集合并文件区间如 01-02）
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

    // 3. TMDB 特别篇（Season 0）
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
      builder: (ctx) => _SlotPopoverOverlay(
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
    final r = widget.row;
    final isMain = r.category == EpisodeCategory.main;
    final isSpecial = !isMain && r.isTmdbSpecial;
    final label = _formatClosedLabel(r);
    final tintColor = isMain
        ? p.accent
        : (isSpecial ? p.warning : p.textSecondary);
    final bgColor = isMain
        ? p.accent.withValues(alpha: 0.14)
        : (isSpecial ? p.warning.withValues(alpha: 0.14) : p.softFill);
    final borderColor = isMain
        ? p.accent.withValues(alpha: 0.38)
        : (isSpecial ? p.warning.withValues(alpha: 0.40) : p.hairline);
    final minHeight = KonataAdaptiveTokens.isAndroid ? 36.0 : 30.0;

    return CompositedTransformTarget(
      link: _link,
      child: Tooltip(
        message: '下拉选择对应 TMDB 正片/特别篇集数，或保持当前特典识别结果',
        child: InkWell(
          borderRadius: KonataTheme.borderRadiusControl,
          onTap: widget.enabled ? _toggle : null,
          child: Container(
            constraints: BoxConstraints(
              minWidth: 124,
              maxWidth: 168,
              minHeight: minHeight,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: KonataTheme.borderRadiusControl,
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tintColor,
                      fontSize: KonataTheme.fontSizeCaption,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: tintColor,
                ),
              ],
            ),
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
  final ScrollController _ctrl = ScrollController();
  int? _hoveredIndex;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool _isCurrentOption(_SlotOption opt) {
    final r = widget.currentRow;
    if (opt.category != r.category) return false;
    if (opt.category == EpisodeCategory.main) {
      return opt.seasonNumber == r.seasonNumber &&
          opt.episodeNumber == r.episodeNumber;
    }
    if (opt.isTmdbSpecial != r.isTmdbSpecial) return false;
    if (!opt.isTmdbSpecial) return true;
    return opt.episodeNumber == r.episodeNumber;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bgColor = Color.alphaBlend(
      p.elevatedSurface.withValues(alpha: 0.94),
      p.isDark
          ? KonataTheme.darkPopoverSurface
          : KonataTheme.lightPopoverSurface,
    );

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
              ? Alignment.topRight
              : Alignment.bottomRight,
          followerAnchor: widget.openUpward
              ? Alignment.bottomRight
              : Alignment.topRight,
          offset: Offset(0, widget.openUpward ? -6 : 6),
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: KonataTheme.borderRadiusPanel,
              child: BackdropFilter(
                filter: KonataTheme.blurFilterCapsule,
                child: Container(
                  width: 304,
                  constraints: const BoxConstraints(maxHeight: 296),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: KonataTheme.borderRadiusPanel,
                    border: Border.all(
                      color: KonataTheme.pureWhite.withValues(
                        alpha: p.isDark ? 0.18 : 0.72,
                      ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: KonataTheme.pureBlack.withValues(
                          alpha: p.isDark ? 0.42 : 0.16,
                        ),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                        child: Text(
                          '指定对应 TMDB 正片 / 特别篇，或保留原识别特典',
                          style: TextStyle(
                            color: p.textMuted,
                            fontSize: KonataTheme.fontSizeCaptionXs,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Flexible(
                        child: MouseRegion(
                          onExit: (_) {
                            if (_hoveredIndex != null) {
                              setState(() => _hoveredIndex = null);
                            }
                          },
                          child: KonataDraggableScrollbar(
                            controller: _ctrl,
                            builder: (_, ctrl) => ListView.builder(
                              controller: ctrl,
                              padding: const EdgeInsets.fromLTRB(6, 0, 14, 0),
                              shrinkWrap: true,
                              itemCount: widget.options.length,
                              itemBuilder: (_, index) {
                                final opt = widget.options[index];
                                final showGroupHeader =
                                    index == 0 ||
                                    widget.options[index - 1].groupHeader !=
                                        opt.groupHeader;
                                final isCurrent = _isCurrentOption(opt);
                                final isHovered =
                                    !isCurrent && _hoveredIndex == index;
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (showGroupHeader)
                                      Padding(
                                        padding: EdgeInsets.fromLTRB(
                                          10,
                                          index == 0 ? 2 : 8,
                                          10,
                                          3,
                                        ),
                                        child: Text(
                                          opt.groupHeader,
                                          style: TextStyle(
                                            color: p.textMuted,
                                            fontSize:
                                                KonataTheme.fontSizeCaptionXs,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      onEnter: (_) {
                                        final next = isCurrent ? null : index;
                                        if (_hoveredIndex != next) {
                                          setState(() => _hoveredIndex = next);
                                        }
                                      },
                                      onExit: (_) {
                                        if (_hoveredIndex == index) {
                                          setState(() => _hoveredIndex = null);
                                        }
                                      },
                                      child: InkWell(
                                        autofocus: false,
                                        canRequestFocus: false,
                                        focusColor: Colors.transparent,
                                        hoverColor: Colors.transparent,
                                        highlightColor: Colors.transparent,
                                        splashColor: Colors.transparent,
                                        borderRadius:
                                            KonataTheme.borderRadiusSm,
                                        onTap: () => widget.onPick(opt),
                                        child: Container(
                                          margin: const EdgeInsets.symmetric(
                                            vertical: 1.5,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isCurrent
                                                ? p.accent.withValues(
                                                    alpha: 0.16,
                                                  )
                                                : (isHovered
                                                      ? p.softFill
                                                      : Colors.transparent),
                                            borderRadius:
                                                KonataTheme.borderRadiusSm,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: EllipsisTextWithTooltip(
                                                  text: opt.label,
                                                  maxLines: 1,
                                                  style: TextStyle(
                                                    color: isCurrent
                                                        ? p.accent
                                                        : p.textPrimary,
                                                    fontSize: KonataTheme
                                                        .fontSizeCaption,
                                                    fontWeight: isCurrent
                                                        ? FontWeight.w600
                                                        : FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                              if (isCurrent)
                                                Icon(
                                                  Icons.check_rounded,
                                                  size: 15,
                                                  color: p.accent,
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
