import 'package:flutter/material.dart';

import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
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
  }) : initialCategory = category,
       initialSeasonNumber = seasonNumber,
       initialEpisodeNumber = episodeNumber,
       initialExtraType = extraType;

  /// 物理视频变体。
  final MediaVariant variant;

  /// 初始剧集分类。
  final EpisodeCategory initialCategory;

  /// 初始季号。
  final int initialSeasonNumber;

  /// 初始集号。
  final int initialEpisodeNumber;

  /// 初始特典子类。
  final ExtraKind initialExtraType;

  /// 当前分类。
  EpisodeCategory category;

  /// 当前季号。
  int seasonNumber;

  /// 当前集号。
  int episodeNumber;

  /// 当前特典子类。
  ExtraKind extraType;

  /// 相对于初始状态是否发生变更。
  bool get isModified =>
      category != initialCategory ||
      seasonNumber != initialSeasonNumber ||
      episodeNumber != initialEpisodeNumber ||
      extraType != initialExtraType;
}

/// 可视化选集浮层中的单个目标剧集/特典槽位项。
class _SlotOption {
  const _SlotOption({
    required this.category,
    required this.seasonNumber,
    required this.episodeNumber,
    this.extraType,
    required this.code,
    required this.label,
  });

  final EpisodeCategory category;
  final int seasonNumber;
  final int episodeNumber;
  final ExtraKind? extraType;
  final String code;
  final String label;
}

/// 点击单行季/集胶囊弹出的高透毛玻璃可视化选集浮层控件。
class EpisodeSlotPickerButton extends StatefulWidget {
  /// 创建可视化选集胶囊按钮。
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
    final specialByKey = <String, Episode>{};
    var maxMainEp = 0;

    for (final ep in widget.referenceEpisodes) {
      final num = ep.episodeNumber ?? 0;
      if (ep.category == EpisodeCategory.main && num > 0) {
        mainByKey.putIfAbsent(num, () => ep);
        if (num > maxMainEp) maxMainEp = num;
      } else if (ep.category == EpisodeCategory.extra && num > 0) {
        final key = '${ep.extraType?.name ?? 'sp'}:$num';
        specialByKey.putIfAbsent(key, () => ep);
      }
    }

    final season = widget.defaultMainSeason <= 0 ? 1 : widget.defaultMainSeason;
    final mainLimit = maxMainEp > 12 ? maxMainEp : 12;
    final options = <_SlotOption>[];

    for (var i = 1; i <= mainLimit; i++) {
      final ep = mainByKey[i];
      final eStr = EpisodeTitleFormatter.formatEpisodeNumberLabel(
        i,
        ep?.episodeNumberEnd,
      );
      final title = (ep?.title?.trim().isNotEmpty ?? false)
          ? ep!.title!.trim()
          : '第 $eStr 话';
      options.add(
        _SlotOption(
          category: EpisodeCategory.main,
          seasonNumber: ep?.seasonNumber ?? season,
          episodeNumber: i,
          code: 'E$eStr',
          label: 'E$eStr · $title',
        ),
      );
    }

    final specials = specialByKey.values.toList()
      ..sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
    if (specials.isNotEmpty) {
      for (final sp in specials) {
        final num = sp.episodeNumber ?? 1;
        final kind = sp.extraType ?? ExtraKind.sp;
        final code = 'S00E${num.toString().padLeft(2, '0')}';
        final title = (sp.title?.trim().isNotEmpty ?? false)
            ? sp.title!.trim()
            : '${kind.name.toUpperCase()} $num';
        options.add(
          _SlotOption(
            category: EpisodeCategory.extra,
            seasonNumber: 0,
            episodeNumber: num,
            extraType: kind,
            code: code,
            label: '$code · $title',
          ),
        );
      }
    } else {
      for (var i = 1; i <= 4; i++) {
        final code = 'S00E${i.toString().padLeft(2, '0')}';
        options.add(
          _SlotOption(
            category: EpisodeCategory.extra,
            seasonNumber: 0,
            episodeNumber: i,
            extraType: ExtraKind.sp,
            code: code,
            label: '$code · 特典映像 $i',
          ),
        );
      }
    }
    return options;
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
        pos.dy + box.size.height + 286 > screen.height - 16 && pos.dy > 260;

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
    final code = isMain
        ? 'S${r.seasonNumber.toString().padLeft(2, '0')}E${r.episodeNumber.toString().padLeft(2, '0')}'
        : 'S00E${r.episodeNumber.toString().padLeft(2, '0')}·${r.extraType.name.toUpperCase()}';

    return CompositedTransformTarget(
      link: _link,
      child: Tooltip(
        message: '点击从当前作品分集列表中可视选择槽位',
        child: InkWell(
          borderRadius: KonataTheme.borderRadiusBadge,
          onTap: widget.enabled ? _toggle : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: isMain
                  ? p.accent.withValues(alpha: 0.14)
                  : p.warning.withValues(alpha: 0.14),
              borderRadius: KonataTheme.borderRadiusBadge,
              border: Border.all(
                color: isMain
                    ? p.accent.withValues(alpha: 0.40)
                    : p.warning.withValues(alpha: 0.42),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  code,
                  style: TextStyle(
                    color: isMain ? p.accent : p.warning,
                    fontSize: KonataTheme.fontSizeCaptionXs,
                    fontFamily: 'Consolas',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.unfold_more_rounded,
                  size: 13,
                  color: isMain ? p.accent : p.warning,
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
                  width: 296,
                  constraints: const BoxConstraints(maxHeight: 280),
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
                          '快速点击指定目标剧集槽位',
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
                                final isCurrent =
                                    opt.category ==
                                        widget.currentRow.category &&
                                    opt.episodeNumber ==
                                        widget.currentRow.episodeNumber &&
                                    (opt.category == EpisodeCategory.extra ||
                                        opt.seasonNumber ==
                                            widget.currentRow.seasonNumber);
                                final isHovered =
                                    !isCurrent && _hoveredIndex == index;
                                return MouseRegion(
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
                                    borderRadius: KonataTheme.borderRadiusSm,
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
                                            ? p.accent.withValues(alpha: 0.16)
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
                                                fontSize:
                                                    KonataTheme.fontSizeCaption,
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

/// 支持键盘直输与 `+/-` 按钮快速步进的紧凑数字输入框。
class InlineNumberStepperBox extends StatefulWidget {
  /// 创建可键盘输入与步进微调的紧凑数字盒。
  const InlineNumberStepperBox({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  /// 字段前标（如 `季`、`集`）。
  final String label;

  /// 当前数值。
  final int value;

  /// 是否启用交互。
  final bool enabled;

  /// 数值变更回调。
  final ValueChanged<int> onChanged;

  @override
  State<InlineNumberStepperBox> createState() => _InlineNumberStepperBoxState();
}

class _InlineNumberStepperBoxState extends State<InlineNumberStepperBox> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(covariant InlineNumberStepperBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        int.tryParse(_ctrl.text.trim()) != widget.value) {
      _ctrl.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Opacity(
      opacity: widget.enabled ? 1 : 0.45,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: p.softFill,
          borderRadius: KonataTheme.borderRadiusSm,
          border: Border.all(color: p.hairline),
        ),
        child: Row(
          children: [
            Text(
              widget.label,
              style: TextStyle(
                color: p.textMuted,
                fontSize: KonataTheme.fontSizeBadge,
              ),
            ),
            InkWell(
              borderRadius: KonataTheme.borderRadiusXs,
              onTap: widget.enabled && widget.value > 0
                  ? () => widget.onChanged(widget.value - 1)
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.remove_rounded,
                  size: 12,
                  color: p.textSecondary,
                ),
              ),
            ),
            Expanded(
              child: TextField(
                enabled: widget.enabled,
                controller: _ctrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: KonataTheme.fontSizeCaption,
                  fontWeight: FontWeight.w600,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 2),
                  border: InputBorder.none,
                ),
                onChanged: (v) {
                  final parsed = int.tryParse(v.trim());
                  if (parsed != null && parsed >= 0) {
                    widget.onChanged(parsed);
                  }
                },
              ),
            ),
            InkWell(
              borderRadius: KonataTheme.borderRadiusXs,
              onTap: widget.enabled
                  ? () => widget.onChanged(widget.value + 1)
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.add_rounded,
                  size: 12,
                  color: p.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
