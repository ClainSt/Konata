import 'dart:ui';

import 'package:flutter/material.dart';

import '../../domain/models/series_group.dart';
import '../../domain/models/work.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';

/// 详情页底部左侧的紧凑毛玻璃系列成员下拉切换胶囊。
class SeriesSwitcherDropdown extends StatefulWidget {
  /// 创建系列成员下拉切换器。
  const SeriesSwitcherDropdown({
    super.key,
    required this.activeWork,
    required this.seriesMembers,
    this.seriesGroup,
    required this.onSelectWork,
  });

  /// 当前正在详情页展示的作品。
  final Work activeWork;

  /// 同系列按顺序排布的全部成员作品。
  final List<Work> seriesMembers;

  /// 所属系列编组元信息。
  final SeriesGroup? seriesGroup;

  /// 选定同系列其它成员后的原地切换回调。
  final ValueChanged<String> onSelectWork;

  @override
  State<SeriesSwitcherDropdown> createState() => _SeriesSwitcherDropdownState();
}

class _SeriesSwitcherDropdownState extends State<SeriesSwitcherDropdown> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _menuEntry;

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
      builder: (ctx) => _SeriesMenuOverlay(
        link: _link,
        seriesGroup: widget.seriesGroup,
        activeWorkId: widget.activeWork.id,
        seriesMembers: orderedMembers,
        labelBuilder: _memberDisplayLabel,
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

    return CompositedTransformTarget(
      link: _link,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Material(
            color: isOpen
                ? KonataPlaybackTokens.activePillBg(p)
                : KonataPlaybackTokens.glassSurface(p),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
              side: BorderSide(
                color: isOpen
                    ? KonataPlaybackTokens.activeGlassBorder(p)
                    : KonataPlaybackTokens.glassBorder(p),
                width: 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              hoverColor: KonataPlaybackTokens.hoverFill(p),
              onTap: _toggleMenu,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 8.5,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.layers_rounded,
                      size: 14.5,
                      color: p.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 168),
                      child: Text(
                        currentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: KonataTheme.detailTextStyle(
                          palette: p,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: isOpen ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 17,
                        color: p.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SeriesMenuOverlay extends StatefulWidget {
  const _SeriesMenuOverlay({
    required this.link,
    required this.seriesGroup,
    required this.activeWorkId,
    required this.seriesMembers,
    required this.labelBuilder,
    required this.onDismiss,
    required this.onPick,
  });

  final LayerLink link;
  final SeriesGroup? seriesGroup;
  final String activeWorkId;
  final List<Work> seriesMembers;
  final String Function(Work member, int index) labelBuilder;
  final VoidCallback onDismiss;
  final ValueChanged<String> onPick;

  @override
  State<_SeriesMenuOverlay> createState() => _SeriesMenuOverlayState();
}

class _SeriesMenuOverlayState extends State<_SeriesMenuOverlay> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(0, -10),
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Container(
                  width: 280,
                  constraints: const BoxConstraints(maxHeight: 340),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: KonataPlaybackTokens.popoverSurface(p),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: KonataPlaybackTokens.glassBorder(p),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: KonataPlaybackTokens.shadowColor(p),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.seriesGroup != null &&
                          widget.seriesGroup!.title.trim().isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                          child: Text(
                            '${widget.seriesGroup!.title} · ${widget.seriesMembers.length} 部',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Divider(height: 6, color: p.hairline),
                      ],
                      Flexible(
                        child: MouseRegion(
                          onExit: (_) {
                            if (_hoveredIndex != null) {
                              setState(() => _hoveredIndex = null);
                            }
                          },
                          child: KonataDraggableScrollbar(
                            builder: (_, ctrl) => ListView.builder(
                              controller: ctrl,
                              shrinkWrap: true,
                              padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
                              itemCount: widget.seriesMembers.length,
                              itemBuilder: (_, index) {
                                final member = widget.seriesMembers[index];
                                final selected =
                                    member.id == widget.activeWorkId;
                                final hovered =
                                    !selected && _hoveredIndex == index;
                                final label = widget.labelBuilder(
                                  member,
                                  index,
                                );
                                final showTitleSubtitle =
                                    member.title.trim() != label &&
                                    !label.contains(member.title.trim());
                                final subtitleText = showTitleSubtitle
                                    ? (member.year != null
                                          ? '${member.title} (${member.year})'
                                          : member.title)
                                    : (member.year != null
                                          ? '${member.year}'
                                          : null);
                                return MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  onEnter: (_) {
                                    final next = selected ? null : index;
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
                                    borderRadius: BorderRadius.circular(9),
                                    onTap: () => widget.onPick(member.id),
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(
                                        vertical: 1.5,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? p.accent.withValues(alpha: 0.16)
                                            : (hovered
                                                  ? p.softFill
                                                  : Colors.transparent),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: selected
                                                        ? p.accent
                                                        : p.textPrimary,
                                                    fontSize: 13,
                                                    fontWeight: selected
                                                        ? FontWeight.w700
                                                        : FontWeight.w500,
                                                  ),
                                                ),
                                                if (subtitleText != null)
                                                  Text(
                                                    subtitleText,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: p.textMuted,
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          if (selected) ...[
                                            const SizedBox(width: 8),
                                            Icon(
                                              Icons.check_rounded,
                                              size: 16,
                                              color: p.accent,
                                            ),
                                          ],
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
