import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 详情页底部左侧的紧凑毛玻璃系列成员下拉切换胶囊（严禁引入 `material_ui`）。
class SeriesSwitcherDropdown extends StatefulWidget {
  /// 创建系列成员下拉切换器。
  const SeriesSwitcherDropdown({
    super.key,
    required this.activeWork,
    required this.seriesMembers,
    this.seriesGroup,
    required this.onSelectWork,
    this.compact = false,
    this.openDownward = false,
  });

  /// 当前正在详情页展示的作品。
  final Work activeWork;

  /// 同系列按顺序排布的全部成员作品。
  final List<Work> seriesMembers;

  /// 所属系列编组元信息。
  final SeriesGroup? seriesGroup;

  /// 选定同系列其它成员后的就地切换回调。
  final ValueChanged<String> onSelectWork;

  /// 是否使用紧凑视觉尺寸。
  final bool compact;

  /// 浮层是否向下弹出（防止置于顶部栏时被顶部裁切）。
  final bool openDownward;

  @override
  State<SeriesSwitcherDropdown> createState() => _SeriesSwitcherDropdownState();
}

class _SeriesSwitcherDropdownState extends State<SeriesSwitcherDropdown> {
  final LayerLink _link = LayerLink();
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _menuEntry;

  @override
  void didUpdateWidget(covariant SeriesSwitcherDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeWork.id != widget.activeWork.id ||
        oldWidget.seriesMembers.length != widget.seriesMembers.length) {
      _closeMenu();
    }
  }

  @override
  void dispose() {
    _closeMenu();
    super.dispose();
  }

  void _closeMenu() {
    _menuEntry?.remove();
    _menuEntry = null;
  }

  String _memberDisplayLabel(Work member, int index) {
    return SeriesSeasonFormatter.formatMemberLabel(
      member,
      widget.seriesMembers,
      seriesGroup: widget.seriesGroup,
      fallbackOrder: index + 1,
    );
  }

  ({String title, String? meta}) _memberMenuParts(Work member, int index) {
    return SeriesSeasonFormatter.formatMemberMenuParts(
      member,
      widget.seriesMembers,
      seriesGroup: widget.seriesGroup,
      fallbackOrder: index + 1,
    );
  }

  void _toggleMenu() {
    if (_menuEntry != null) {
      _closeMenu();
      setState(() {});
      return;
    }
    final orderedMembers = SeriesSeasonFormatter.sortSeriesMembers(
      widget.seriesMembers,
    );
    final overlay = Overlay.of(context, rootOverlay: true);
    _menuEntry = OverlayEntry(
      builder: (_) => _SeriesMenuOverlay(
        link: _link,
        anchorKey: _anchorKey,
        seriesGroup: widget.seriesGroup,
        activeWorkId: widget.activeWork.id,
        seriesMembers: orderedMembers,
        partsBuilder: _memberMenuParts,
        openDownward: widget.openDownward,
        onDismiss: () {
          _closeMenu();
          if (mounted) setState(() {});
        },
        onPick: (workId) {
          _closeMenu();
          if (mounted) setState(() {});
          if (workId != widget.activeWork.id) {
            widget.onSelectWork(workId);
          }
        },
      ),
    );
    overlay.insert(_menuEntry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.seriesMembers.length < 2) {
      return const SizedBox.shrink();
    }
    final orderedMembers = SeriesSeasonFormatter.sortSeriesMembers(
      widget.seriesMembers,
    );
    final activeIdx = orderedMembers.indexWhere(
      (m) => m.id == widget.activeWork.id,
    );
    final currentLabel = _memberDisplayLabel(
      widget.activeWork,
      activeIdx >= 0 ? activeIdx : 0,
    );
    final p = context.palette;
    final isOpen = _menuEntry != null;
    final viewportSize = MediaQuery.sizeOf(context);

    final effectiveCompact =
        widget.compact ||
        (KonataAdaptiveTokens.isAndroid &&
            viewportSize.shortestSide < KonataAdaptiveTokens.tabletBreakpoint);
    final pillTextMaxWidth = effectiveCompact
        ? 136.0
        : (viewportSize.width >= 1100.0 ? 240.0 : 176.0);
    final capsuleHeight = KonataPlaybackTokens.detailActionCapsuleHeight(
      isTouch: KonataAdaptiveTokens.isAndroid,
    );
    const radius = KonataPlaybackTokens.detailActionCapsuleRadius;

    final pill = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: KonataAdaptiveBackdropBlur(
        filter: KonataTheme.blurFilterMedium,
        child: Material(
          color: isOpen
              ? KonataPlaybackTokens.activePillBg(p)
              : KonataPlaybackTokens.glassSurface(p),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(
              color: isOpen
                  ? KonataPlaybackTokens.activeGlassBorder(p)
                  : KonataPlaybackTokens.glassBorder(p),
              width: KonataPlaybackTokens.detailActionCapsuleBorderWidth,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(radius),
            hoverColor: KonataPlaybackTokens.hoverFill(p),
            onTap: _toggleMenu,
            child: SizedBox(
              height: capsuleHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: effectiveCompact ? 12 : 15,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.layers_rounded,
                      size: effectiveCompact ? 14.5 : 15.5,
                      color: p.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: pillTextMaxWidth),
                      child: Text(
                        currentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: effectiveCompact
                              ? KonataTheme.fontSizeCaption
                              : KonataTheme.fontSizeBodySm,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${orderedMembers.length}',
                      style: TextStyle(
                        color: p.textMuted,
                        fontSize: KonataTheme.fontSizeBadge,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      isOpen
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      size: 16,
                      color: p.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return KeyedSubtree(
      key: _anchorKey,
      child: CompositedTransformTarget(link: _link, child: pill),
    );
  }
}

class _SeriesMenuOverlay extends StatefulWidget {
  const _SeriesMenuOverlay({
    required this.link,
    required this.anchorKey,
    required this.seriesGroup,
    required this.activeWorkId,
    required this.seriesMembers,
    required this.partsBuilder,
    required this.openDownward,
    required this.onDismiss,
    required this.onPick,
  });

  final LayerLink link;
  final GlobalKey anchorKey;
  final SeriesGroup? seriesGroup;
  final String activeWorkId;
  final List<Work> seriesMembers;
  final ({String title, String? meta}) Function(Work, int) partsBuilder;
  final bool openDownward;
  final VoidCallback onDismiss;
  final ValueChanged<String> onPick;

  @override
  State<_SeriesMenuOverlay> createState() => _SeriesMenuOverlayState();
}

class _SeriesMenuOverlayState extends State<_SeriesMenuOverlay> {
  final ScrollController _scrollCtrl = ScrollController();
  int? _hoveredIndex;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final renderBox =
        widget.anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final anchorTopLeft = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final anchorSize = renderBox?.size ?? Size.zero;
    final media = MediaQuery.of(context);
    final viewport = media.size;
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    const edgeMargin = 12.0;

    final maxAvailW = math.max(180.0, viewport.width - edgeMargin * 2);
    final menuWidth = isAndroid
        ? math.min(280.0, maxAvailW)
        : math.min(340.0, maxAvailW);
    final availableSpace = widget.openDownward
        ? math.max(
            180.0,
            viewport.height -
                anchorTopLeft.dy -
                anchorSize.height -
                media.padding.bottom -
                edgeMargin,
          )
        : math.max(180.0, anchorTopLeft.dy - media.padding.top - edgeMargin);
    final capHeight = isAndroid ? 320.0 : 380.0;
    final maxH = math.min(capHeight, availableSpace);

    var horizontalOffset = 0.0;
    if (anchorTopLeft.dx + menuWidth > viewport.width - edgeMargin) {
      horizontalOffset =
          (viewport.width - edgeMargin - menuWidth) - anchorTopLeft.dx;
    }
    if (anchorTopLeft.dx + horizontalOffset < edgeMargin) {
      horizontalOffset = edgeMargin - anchorTopLeft.dx;
    }

    final seriesTitle = widget.seriesGroup?.title.trim();
    final headerText = (seriesTitle != null && seriesTitle.isNotEmpty)
        ? seriesTitle
        : '同系列作品';

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
          targetAnchor: widget.openDownward
              ? Alignment.bottomLeft
              : Alignment.topLeft,
          followerAnchor: widget.openDownward
              ? Alignment.topLeft
              : Alignment.bottomLeft,
          offset: Offset(horizontalOffset, widget.openDownward ? 8 : -8),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: menuWidth, maxHeight: maxH),
            child: ClipRRect(
              borderRadius: KonataTheme.borderRadiusCard,
              child: KonataAdaptiveBackdropBlur(
                filter: KonataTheme.blurFilterCapsule,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: KonataPlaybackTokens.popoverSurface(p),
                    borderRadius: KonataTheme.borderRadiusCard,
                    border: Border.all(
                      color: KonataPlaybackTokens.glassBorder(p),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.collections_bookmark_outlined,
                              size: 14,
                              color: p.accent,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                headerText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.textSecondary,
                                  fontSize: KonataTheme.fontSizeBadge,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              '${widget.seriesMembers.length} 部',
                              style: TextStyle(
                                color: p.textMuted,
                                fontSize: KonataTheme.fontSizeMicro,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(height: 1, color: p.hairline),
                      Flexible(
                        child: KonataDraggableScrollbar(
                          controller: _scrollCtrl,
                          builder: (_, ctrl) => ListView.builder(
                            controller: ctrl,
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            shrinkWrap: true,
                            itemCount: widget.seriesMembers.length,
                            itemBuilder: (_, index) {
                              final m = widget.seriesMembers[index];
                              final active = m.id == widget.activeWorkId;
                              final parts = widget.partsBuilder(m, index);
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                child: KonataPopoverOptionTile(
                                  hovered: _hoveredIndex == index,
                                  selected: active,
                                  minHeight: isAndroid
                                      ? KonataAdaptiveTokens.touchTarget
                                      : 40,
                                  onHoverEnter: () =>
                                      setState(() => _hoveredIndex = index),
                                  onHoverExit: () {
                                    if (_hoveredIndex == index) {
                                      setState(() => _hoveredIndex = null);
                                    }
                                  },
                                  onTap: () => widget.onPick(m.id),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              parts.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: active
                                                    ? p.accent
                                                    : p.textPrimary,
                                                fontSize:
                                                    KonataTheme.fontSizeBodyXs,
                                                fontWeight: active
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                              ),
                                            ),
                                            if (parts.meta != null &&
                                                parts.meta!.isNotEmpty)
                                              Text(
                                                parts.meta!,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: p.textMuted,
                                                  fontSize: KonataTheme
                                                      .fontSizeCaptionXs,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (active)
                                        Icon(
                                          Icons.check_rounded,
                                          size: 14,
                                          color: p.accent,
                                        ),
                                    ],
                                  ),
                                ),
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
        ),
      ],
    );
  }
}
