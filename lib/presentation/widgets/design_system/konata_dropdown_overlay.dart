part of 'konata_dropdown.dart';

class _FrostedDropdownOverlay<T> extends StatefulWidget {
  const _FrostedDropdownOverlay({
    required this.link,
    required this.width,
    required this.maxHeight,
    required this.openUpward,
    required this.horizontalShift,
    required this.triggerHeight,
    required this.options,
    required this.selectedValue,
    this.multiSelect = false,
    this.selectedValuesListenable,
    required this.searchable,
    required this.searchHint,
    required this.emptyText,
    this.centerAligned = false,
    required this.onDismiss,
    required this.onSelect,
  });

  final LayerLink link;
  final double width;
  final double maxHeight;
  final bool openUpward;
  final double horizontalShift;
  final double triggerHeight;
  final List<KonataDropdownOption<T>> options;
  final T? selectedValue;
  final bool multiSelect;
  final ValueListenable<Set<T>>? selectedValuesListenable;
  final bool searchable;
  final String searchHint;
  final String emptyText;
  final bool centerAligned;
  final VoidCallback onDismiss;
  final ValueChanged<T> onSelect;

  @override
  State<_FrostedDropdownOverlay<T>> createState() =>
      _FrostedDropdownOverlayState<T>();
}

class _FrostedDropdownOverlayState<T> extends State<_FrostedDropdownOverlay<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollCtrl = ScrollController();
  String _query = '';
  int? _hoveredIndex;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: KonataTheme.motionMedium,
    );
    final curve = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOutCubic,
    );
    _fadeAnim = curve;
    _scaleAnim = Tween<double>(begin: 0.96, end: 1.0).animate(curve);
    _animCtrl.forward();
    if (widget.searchable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lowerQ = _query.trim().toLowerCase();
    final filtered = lowerQ.isEmpty
        ? widget.options
        : widget.options
              .where((o) => o.matchesQuery(lowerQ))
              .toList(growable: false);

    // 高不透明防文字穿透毛玻璃背景，确保列表与底层文字永不互相叠加干扰
    final panelBg = KonataPlaybackTokens.popoverSurface(p);
    final panelBorder = KonataPlaybackTokens.glassBorder(p);

    Widget buildOptionsList(Set<T>? selectedSet) {
      return MouseRegion(
        onExit: (_) {
          if (_hoveredIndex != null) {
            setState(() => _hoveredIndex = null);
          }
        },
        child: KonataDraggableScrollbar(
          controller: _scrollCtrl,
          builder: (_, ctrl) => ListView.builder(
            controller: ctrl,
            shrinkWrap: true,
            padding: widget.centerAligned
                ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
                : const EdgeInsets.fromLTRB(6, 4, 14, 4),
            itemCount: filtered.length,
            itemBuilder: (_, index) {
              final item = filtered[index];
              final selected = selectedSet != null
                  ? selectedSet.contains(item.value)
                  : item.value == widget.selectedValue;
              return _DropdownOptionTile(
                label: item.label,
                subtitle: item.subtitle,
                selected: selected,
                multiSelect: widget.multiSelect,
                centerAligned: widget.centerAligned,
                hovered: !selected && _hoveredIndex == index,
                onHoverEnter: () {
                  final next = selected && !widget.multiSelect ? null : index;
                  if (_hoveredIndex != next) {
                    setState(() => _hoveredIndex = next);
                  }
                },
                onHoverExit: () {
                  if (_hoveredIndex == index) {
                    setState(() => _hoveredIndex = null);
                  }
                },
                onTap: () => widget.onSelect(item.value),
              );
            },
          ),
        ),
      );
    }

    final listContent =
        widget.multiSelect && widget.selectedValuesListenable != null
        ? ValueListenableBuilder<Set<T>>(
            valueListenable: widget.selectedValuesListenable!,
            builder: (_, selectedSet, _) => buildOptionsList(selectedSet),
          )
        : buildOptionsList(null);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
      },
      child: Focus(
        autofocus: !widget.searchable,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: widget.onDismiss,
              ),
            ),
            CompositedTransformFollower(
              link: widget.link,
              targetAnchor: widget.centerAligned
                  ? (widget.openUpward
                        ? Alignment.topCenter
                        : Alignment.bottomCenter)
                  : (widget.openUpward
                        ? Alignment.topLeft
                        : Alignment.bottomLeft),
              followerAnchor: widget.centerAligned
                  ? (widget.openUpward
                        ? Alignment.bottomCenter
                        : Alignment.topCenter)
                  : (widget.openUpward
                        ? Alignment.bottomLeft
                        : Alignment.topLeft),
              offset: Offset(
                widget.horizontalShift,
                widget.openUpward ? -6 : 6,
              ),
              child: Material(
                color: Colors.transparent,
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: ScaleTransition(
                    scale: _scaleAnim,
                    alignment: widget.openUpward
                        ? Alignment.bottomCenter
                        : Alignment.topCenter,
                    child: ClipRRect(
                      borderRadius: KonataTheme.borderRadiusPanel,
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                        child: Container(
                          width: widget.width,
                          constraints: BoxConstraints(
                            maxHeight: widget.maxHeight,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: panelBg,
                            borderRadius: KonataTheme.borderRadiusPanel,
                            border: Border.all(color: panelBorder, width: 1),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: p.isDark ? 0.42 : 0.14,
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
                              if (widget.searchable) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    2,
                                    8,
                                    6,
                                  ),
                                  child: TextField(
                                    controller: _searchCtrl,
                                    focusNode: _searchFocus,
                                    style: TextStyle(
                                      color: p.textPrimary,
                                      fontSize: KonataTheme.fontSizeBodyXs,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      prefixIcon: Icon(
                                        Icons.search_rounded,
                                        size: 16,
                                        color: p.textMuted,
                                      ),
                                      prefixIconConstraints:
                                          const BoxConstraints(
                                            minWidth: 32,
                                            minHeight: 30,
                                          ),
                                      suffixIcon: _query.isNotEmpty
                                          ? IconButton(
                                              icon: const Icon(
                                                Icons.close_rounded,
                                                size: 14,
                                              ),
                                              color: p.textSecondary,
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  BoxConstraints.tightFor(
                                                    width:
                                                        defaultTargetPlatform ==
                                                            TargetPlatform
                                                                .android
                                                        ? KonataAdaptiveTokens
                                                              .touchTarget
                                                        : 28,
                                                    height:
                                                        defaultTargetPlatform ==
                                                            TargetPlatform
                                                                .android
                                                        ? KonataAdaptiveTokens
                                                              .touchTarget
                                                        : 28,
                                                  ),
                                              onPressed: () {
                                                _searchCtrl.clear();
                                                setState(() {
                                                  _query = '';
                                                  _hoveredIndex = null;
                                                });
                                                if (_scrollCtrl.hasClients) {
                                                  _scrollCtrl.jumpTo(0);
                                                }
                                              },
                                            )
                                          : null,
                                      filled: true,
                                      fillColor: p.softFill,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                      border: OutlineInputBorder(
                                        borderRadius: KonataTheme.borderRadiusControl,
                                        borderSide: BorderSide(
                                          color: p.hairline,
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: KonataTheme.borderRadiusControl,
                                        borderSide: BorderSide(
                                          color: p.hairline,
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: KonataTheme.borderRadiusControl,
                                        borderSide: BorderSide(
                                          color: p.accent.withValues(
                                            alpha: 0.65,
                                          ),
                                        ),
                                      ),
                                    ),
                                    onChanged: (v) {
                                      setState(() {
                                        _query = v;
                                        _hoveredIndex = null;
                                      });
                                      if (_scrollCtrl.hasClients) {
                                        _scrollCtrl.jumpTo(0);
                                      }
                                    },
                                  ),
                                ),
                                Divider(height: 1, color: p.hairline),
                              ],
                              if (filtered.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 18,
                                  ),
                                  child: Center(
                                    child: Text(
                                      widget.emptyText,
                                      style: TextStyle(
                                        color: p.textMuted,
                                        fontSize: KonataTheme.fontSizeBodyXs,
                                      ),
                                    ),
                                  ),
                                )
                              else
                                Flexible(child: listContent),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DropdownOptionTile extends StatelessWidget {
  const _DropdownOptionTile({
    required this.label,
    required this.subtitle,
    required this.selected,
    this.multiSelect = false,
    this.centerAligned = false,
    required this.hovered,
    required this.onHoverEnter,
    required this.onHoverExit,
    required this.onTap,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final bool multiSelect;
  final bool centerAligned;
  final bool hovered;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bgColor = selected
        ? p.accent.withValues(alpha: 0.16)
        : (hovered ? p.softFill : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHoverEnter(),
      onExit: (_) => onHoverExit(),
      child: InkWell(
        autofocus: false,
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        borderRadius: KonataTheme.borderRadiusThumb,
        onTap: onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          constraints: KonataAdaptiveTokens.isAndroid
              ? const BoxConstraints(
                  minHeight: KonataAdaptiveTokens.touchTarget,
                )
              : null,
          margin: const EdgeInsets.symmetric(vertical: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: KonataTheme.borderRadiusThumb,
          ),
          child: centerAligned
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (multiSelect) ...[
                      Icon(
                        selected
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 16,
                        color: selected ? p.accent : p.textMuted,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? p.accent : p.textPrimary,
                          fontSize: KonataTheme.fontSizeBodyXs,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    if (multiSelect) ...[
                      Icon(
                        selected
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 16,
                        color: selected ? p.accent : p.textMuted,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected ? p.accent : p.textPrimary,
                              fontSize: KonataTheme.fontSizeBodyXs,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          if (subtitle != null && subtitle!.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 1.5),
                              child: Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.textMuted,
                                  fontSize: KonataTheme.fontSizeCaptionXs,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!multiSelect && selected) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.check_rounded, size: 15, color: p.accent),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
