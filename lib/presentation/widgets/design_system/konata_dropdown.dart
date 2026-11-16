import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';
import 'konata_draggable_scrollbar.dart';

/// 统一下拉菜单选项数据模型。
@immutable
class KonataDropdownOption<T> {
  /// 创建一个下拉选项。
  const KonataDropdownOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.searchText,
  });

  /// 选项关联值。
  final T value;

  /// 主展示文本。
  final String label;

  /// 可选次级说明文本。
  final String? subtitle;

  /// 额外用于可搜索下拉框匹配的关键词（如原始标题、ID 等）。
  final String? searchText;

  bool matchesQuery(String lowerQuery) {
    if (lowerQuery.isEmpty) return true;
    if (label.toLowerCase().contains(lowerQuery)) return true;
    if (subtitle != null && subtitle!.toLowerCase().contains(lowerQuery)) {
      return true;
    }
    if (searchText != null && searchText!.toLowerCase().contains(lowerQuery)) {
      return true;
    }
    return false;
  }
}

/// 统一圆角毛玻璃下拉选择组件（替代原生直角灰白 `DropdownButton`）。
class KonataDropdown<T> extends StatefulWidget {
  /// 创建统一圆角毛玻璃下拉组件。
  const KonataDropdown({
    super.key,
    required this.options,
    required this.onChanged,
    this.value,
    this.hintText = '请选择...',
    this.enabled = true,
    this.dense = false,
    this.menuWidth,
    this.maxMenuHeight = 280,
    this.leadingIcon,
  });

  /// 当前选中的值。
  final T? value;

  /// 选项列表。
  final List<KonataDropdownOption<T>> options;

  /// 值变更回调。
  final ValueChanged<T>? onChanged;

  /// 未选中值时的占位提示文本。
  final String hintText;

  /// 是否可用。
  final bool enabled;

  /// 紧凑模式（用于表格行或弹窗工具栏）。
  final bool dense;

  /// 下拉面板自定义宽度（为空时自动与触发器同宽且保证最小可视宽度）。
  final double? menuWidth;

  /// 下拉面板最大高度。
  final double maxMenuHeight;

  /// 可选触发器前缀图标。
  final IconData? leadingIcon;

  @override
  State<KonataDropdown<T>> createState() => _KonataDropdownState<T>();
}

class _KonataDropdownState<T> extends State<KonataDropdown<T>> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  bool _hovered = false;

  @override
  void dispose() {
    _closeMenu(notify: false);
    super.dispose();
  }

  void _closeMenu({bool notify = true}) {
    _entry?.remove();
    _entry = null;
    if (notify && mounted) {
      setState(() {});
    }
  }

  void _toggleMenu() {
    if (!widget.enabled || widget.options.isEmpty) return;
    if (_entry != null) {
      _closeMenu();
      return;
    }
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final triggerSize = renderBox.size;
    final triggerOffset = renderBox.localToGlobal(Offset.zero);
    final screenSize = MediaQuery.sizeOf(context);
    final overlay = Overlay.of(context, rootOverlay: true);

    final effectiveWidth = math.max(
      widget.menuWidth ?? triggerSize.width,
      math.min(200.0, screenSize.width - 24),
    );
    final spaceBelow =
        screenSize.height - (triggerOffset.dy + triggerSize.height) - 16;
    final spaceAbove = triggerOffset.dy - 16;
    final openUpward = spaceBelow < 180 && spaceAbove > spaceBelow;
    final availableHeight = math.max(
      140.0,
      math.min(widget.maxMenuHeight, openUpward ? spaceAbove : spaceBelow),
    );
    final overflowRight =
        triggerOffset.dx + effectiveWidth > screenSize.width - 12;
    final horizontalShift = overflowRight
        ? (screenSize.width - 12 - effectiveWidth - triggerOffset.dx)
        : 0.0;

    _entry = OverlayEntry(
      builder: (_) => _FrostedDropdownOverlay<T>(
        link: _link,
        width: effectiveWidth,
        maxHeight: availableHeight,
        openUpward: openUpward,
        horizontalShift: horizontalShift,
        triggerHeight: triggerSize.height,
        options: widget.options,
        selectedValue: widget.value,
        searchable: false,
        searchHint: '',
        emptyText: '暂无选项',
        onDismiss: _closeMenu,
        onSelect: (val) {
          _closeMenu();
          widget.onChanged?.call(val);
        },
      ),
    );
    overlay.insert(_entry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isOpen = _entry != null;
    final activeOption = widget.options
        .where((opt) => opt.value == widget.value)
        .firstOrNull;
    final height = widget.dense ? 32.0 : 38.0;

    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? _toggleMenu : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: height,
            padding: EdgeInsets.symmetric(
              horizontal: widget.dense ? 10 : 12,
            ),
            decoration: BoxDecoration(
              color: !widget.enabled
                  ? p.softFill.withValues(alpha: 0.55)
                  : (isOpen || _hovered ? p.surfaceHover : p.softFill),
              borderRadius: BorderRadius.circular(widget.dense ? 9 : 11),
              border: Border.all(
                color: isOpen
                    ? p.accent.withValues(alpha: 0.65)
                    : (_hovered ? p.hoverBorder : p.hairline),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                if (widget.leadingIcon != null) ...[
                  Icon(
                    widget.leadingIcon,
                    size: widget.dense ? 14 : 16,
                    color: p.textSecondary,
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    activeOption?.label ?? widget.hintText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: activeOption != null
                          ? (widget.enabled ? p.textPrimary : p.textMuted)
                          : p.textMuted,
                      fontSize: widget.dense ? 12 : 12.5,
                      fontWeight: activeOption != null
                          ? FontWeight.w500
                          : FontWeight.w400,
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
                    size: widget.dense ? 17 : 18,
                    color: widget.enabled ? p.textSecondary : p.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 支持实时输入关键词过滤的统一圆角毛玻璃下拉选择框。
class KonataSearchableSelect<T> extends StatefulWidget {
  /// 创建带实时搜索筛选功能的圆角毛玻璃下拉选择框。
  const KonataSearchableSelect({
    super.key,
    required this.options,
    required this.onChanged,
    this.value,
    this.hintText = '搜索并选择...',
    this.searchHint = '输入关键词筛选...',
    this.emptyText = '未找到匹配项',
    this.enabled = true,
    this.dense = false,
    this.menuWidth,
    this.maxMenuHeight = 320,
    this.leadingIcon,
  });

  final T? value;
  final List<KonataDropdownOption<T>> options;
  final ValueChanged<T>? onChanged;
  final String hintText;
  final String searchHint;
  final String emptyText;
  final bool enabled;
  final bool dense;
  final double? menuWidth;
  final double maxMenuHeight;
  final IconData? leadingIcon;

  @override
  State<KonataSearchableSelect<T>> createState() =>
      _KonataSearchableSelectState<T>();
}

class _KonataSearchableSelectState<T> extends State<KonataSearchableSelect<T>> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  bool _hovered = false;

  @override
  void dispose() {
    _closeMenu(notify: false);
    super.dispose();
  }

  void _closeMenu({bool notify = true}) {
    _entry?.remove();
    _entry = null;
    if (notify && mounted) {
      setState(() {});
    }
  }

  void _toggleMenu() {
    if (!widget.enabled) return;
    if (_entry != null) {
      _closeMenu();
      return;
    }
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final triggerSize = renderBox.size;
    final triggerOffset = renderBox.localToGlobal(Offset.zero);
    final screenSize = MediaQuery.sizeOf(context);
    final overlay = Overlay.of(context, rootOverlay: true);

    final effectiveWidth = math.max(
      widget.menuWidth ?? triggerSize.width,
      math.min(260.0, screenSize.width - 24),
    );
    final spaceBelow =
        screenSize.height - (triggerOffset.dy + triggerSize.height) - 16;
    final spaceAbove = triggerOffset.dy - 16;
    final openUpward = spaceBelow < 220 && spaceAbove > spaceBelow;
    final availableHeight = math.max(
      180.0,
      math.min(widget.maxMenuHeight, openUpward ? spaceAbove : spaceBelow),
    );
    final overflowRight =
        triggerOffset.dx + effectiveWidth > screenSize.width - 12;
    final horizontalShift = overflowRight
        ? (screenSize.width - 12 - effectiveWidth - triggerOffset.dx)
        : 0.0;

    _entry = OverlayEntry(
      builder: (_) => _FrostedDropdownOverlay<T>(
        link: _link,
        width: effectiveWidth,
        maxHeight: availableHeight,
        openUpward: openUpward,
        horizontalShift: horizontalShift,
        triggerHeight: triggerSize.height,
        options: widget.options,
        selectedValue: widget.value,
        searchable: true,
        searchHint: widget.searchHint,
        emptyText: widget.emptyText,
        onDismiss: _closeMenu,
        onSelect: (val) {
          _closeMenu();
          widget.onChanged?.call(val);
        },
      ),
    );
    overlay.insert(_entry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isOpen = _entry != null;
    final activeOption = widget.options
        .where((opt) => opt.value == widget.value)
        .firstOrNull;
    final height = widget.dense ? 34.0 : 38.0;

    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? _toggleMenu : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: !widget.enabled
                  ? p.softFill.withValues(alpha: 0.55)
                  : (isOpen || _hovered ? p.surfaceHover : p.softFill),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: isOpen
                    ? p.accent.withValues(alpha: 0.65)
                    : (_hovered ? p.hoverBorder : p.hairline),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  widget.leadingIcon ?? Icons.search_rounded,
                  size: 15,
                  color: activeOption != null ? p.accent : p.textMuted,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    activeOption?.label ?? widget.hintText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: activeOption != null ? p.textPrimary : p.textMuted,
                      fontSize: 12.5,
                      fontWeight: activeOption != null
                          ? FontWeight.w500
                          : FontWeight.w400,
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
                    size: 18,
                    color: widget.enabled ? p.textSecondary : p.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
    required this.searchable,
    required this.searchHint,
    required this.emptyText,
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
  final bool searchable;
  final String searchHint;
  final String emptyText;
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
      duration: const Duration(milliseconds: 180),
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
    final panelBg = p.isDark
        ? const Color(0xFF171B24).withValues(alpha: 0.94)
        : const Color(0xFFF8FAFC).withValues(alpha: 0.96);
    final panelBorder = p.isDark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.10);

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
          targetAnchor:
              widget.openUpward ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor:
              widget.openUpward ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(widget.horizontalShift, widget.openUpward ? -6 : 6),
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
                  borderRadius: BorderRadius.circular(14),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: Container(
                      width: widget.width,
                      constraints: BoxConstraints(maxHeight: widget.maxHeight),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: panelBg,
                        borderRadius: BorderRadius.circular(14),
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
                              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                              child: TextField(
                                controller: _searchCtrl,
                                focusNode: _searchFocus,
                                style: TextStyle(
                                  color: p.textPrimary,
                                  fontSize: 12.5,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: widget.searchHint,
                                  hintStyle: TextStyle(
                                    color: p.textMuted,
                                    fontSize: 12,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.search_rounded,
                                    size: 16,
                                    color: p.textMuted,
                                  ),
                                  prefixIconConstraints: const BoxConstraints(
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
                                              const BoxConstraints.tightFor(
                                                width: 28,
                                                height: 28,
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
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: p.hairline),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: p.hairline),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: p.accent.withValues(alpha: 0.65),
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
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                            )
                          else
                            Flexible(
                              child: MouseRegion(
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
                                    padding: const EdgeInsets.fromLTRB(
                                      6,
                                      4,
                                      14,
                                      4,
                                    ),
                                    itemCount: filtered.length,
                                    itemBuilder: (_, index) {
                                      final item = filtered[index];
                                      final selected =
                                          item.value == widget.selectedValue;
                                      return _DropdownOptionTile(
                                        label: item.label,
                                        subtitle: item.subtitle,
                                        selected: selected,
                                        hovered:
                                            !selected && _hoveredIndex == index,
                                        onHoverEnter: () {
                                          final next = selected ? null : index;
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
                              ),
                            ),
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
    );
  }
}

class _DropdownOptionTile extends StatelessWidget {
  const _DropdownOptionTile({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.hovered,
    required this.onHoverEnter,
    required this.onHoverExit,
    required this.onTap,
  });

  final String label;
  final String? subtitle;
  final bool selected;
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
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          margin: const EdgeInsets.symmetric(vertical: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
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
                        fontSize: 12.5,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (selected) ...[
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
