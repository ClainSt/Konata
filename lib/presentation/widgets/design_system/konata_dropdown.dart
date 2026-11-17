import 'dart:math' as math;
import '../../theme/konata_adaptive_tokens.dart';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
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
    final height = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : widget.dense
        ? 32.0
        : 38.0;

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
            padding: EdgeInsets.symmetric(horizontal: widget.dense ? 10 : 12),
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
    final height = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : widget.dense
        ? 34.0
        : 38.0;

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

/// 全站统一悬浮毛玻璃多选下拉组件（点击条目即时切换勾选，点击外部或按 Esc 键收起）。
class KonataMultiSelectDropdown<T> extends StatefulWidget {
  /// 创建统一圆角毛玻璃多选下拉组件。
  const KonataMultiSelectDropdown({
    super.key,
    required this.options,
    required this.selectedValues,
    required this.onToggle,
    required this.displayText,
    this.hintText = '请选择...',
    this.enabled = true,
    this.dense = false,
    this.menuWidth,
    this.maxMenuHeight = 280,
    this.leadingIcon,
    this.centerAligned = false,
  });

  /// 当前已勾选值集合。
  final Set<T> selectedValues;

  /// 选项列表。
  final List<KonataDropdownOption<T>> options;

  /// 点击某一项的切换回调。
  final ValueChanged<T>? onToggle;

  /// 触发器当前展示文案（如 `"文字标题"` / `"文字标题 · 标题徽标"` / `"不显示"`）。
  final String displayText;

  /// 展示文案为空时的占位提示。
  final String hintText;

  /// 是否可用。
  final bool enabled;

  /// 紧凑模式。
  final bool dense;

  /// 自定义菜单宽度。
  final double? menuWidth;

  /// 菜单最大高度。
  final double maxMenuHeight;

  /// 可选前缀图标。
  final IconData? leadingIcon;

  /// 是否使用胶囊居中对齐样式（触发器与浮层水平正中心对齐，内部勾选项对称居中排布）。
  final bool centerAligned;

  @override
  State<KonataMultiSelectDropdown<T>> createState() =>
      _KonataMultiSelectDropdownState<T>();
}

class _KonataMultiSelectDropdownState<T>
    extends State<KonataMultiSelectDropdown<T>> {
  final LayerLink _link = LayerLink();
  late final ValueNotifier<Set<T>> _selectedNotifier;
  OverlayEntry? _entry;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _selectedNotifier = ValueNotifier<Set<T>>(
      Set<T>.from(widget.selectedValues),
    );
  }

  @override
  void didUpdateWidget(covariant KonataMultiSelectDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(oldWidget.selectedValues, widget.selectedValues)) {
      final snapshot = Set<T>.from(widget.selectedValues);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _selectedNotifier.value = snapshot;
        }
      });
    }
  }

  @override
  void dispose() {
    _closeMenu(notify: false);
    _selectedNotifier.dispose();
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

    final effectiveWidth = widget.menuWidth != null
        ? math.min(widget.menuWidth!, screenSize.width - 24)
        : math.max(triggerSize.width, math.min(200.0, screenSize.width - 24));
    final spaceBelow =
        screenSize.height - (triggerOffset.dy + triggerSize.height) - 16;
    final spaceAbove = triggerOffset.dy - 16;
    final openUpward = spaceBelow < 180 && spaceAbove > spaceBelow;
    final availableHeight = math.max(
      140.0,
      math.min(widget.maxMenuHeight, openUpward ? spaceAbove : spaceBelow),
    );
    final double horizontalShift;
    if (widget.centerAligned) {
      final centeredLeft =
          triggerOffset.dx + (triggerSize.width - effectiveWidth) / 2;
      final clampedLeft = centeredLeft.clamp(
        12.0,
        math.max(12.0, screenSize.width - 12 - effectiveWidth),
      );
      horizontalShift = clampedLeft - centeredLeft;
    } else {
      final overflowRight =
          triggerOffset.dx + effectiveWidth > screenSize.width - 12;
      horizontalShift = overflowRight
          ? (screenSize.width - 12 - effectiveWidth - triggerOffset.dx)
          : 0.0;
    }

    _entry = OverlayEntry(
      builder: (_) => _FrostedDropdownOverlay<T>(
        link: _link,
        width: effectiveWidth,
        maxHeight: availableHeight,
        openUpward: openUpward,
        horizontalShift: horizontalShift,
        triggerHeight: triggerSize.height,
        options: widget.options,
        selectedValue: null,
        multiSelect: true,
        selectedValuesListenable: _selectedNotifier,
        searchable: false,
        searchHint: '',
        emptyText: '暂无选项',
        centerAligned: widget.centerAligned,
        onDismiss: _closeMenu,
        onSelect: (val) => widget.onToggle?.call(val),
      ),
    );
    overlay.insert(_entry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isOpen = _entry != null;
    final height = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : widget.centerAligned
        ? 36.0
        : (widget.dense ? 32.0 : 38.0);
    final label = widget.displayText.trim().isNotEmpty
        ? widget.displayText
        : widget.hintText;
    final borderRadius = widget.centerAligned
        ? BorderRadius.circular(999)
        : BorderRadius.circular(widget.dense ? 9 : 11);

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
            padding: EdgeInsets.symmetric(horizontal: widget.dense ? 10 : 12),
            decoration: BoxDecoration(
              color: !widget.enabled
                  ? p.softFill.withValues(alpha: 0.55)
                  : (isOpen || _hovered ? p.surfaceHover : p.softFill),
              borderRadius: borderRadius,
              border: Border.all(
                color: isOpen
                    ? p.accent.withValues(alpha: 0.65)
                    : (_hovered ? p.hoverBorder : p.hairline),
                width: isOpen && widget.centerAligned ? 1.5 : 1,
              ),
            ),
            child: widget.centerAligned
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.enabled ? p.textPrimary : p.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        child: AnimatedRotation(
                          turns: isOpen ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 17,
                            color: widget.enabled
                                ? p.textSecondary
                                : p.textMuted,
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
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
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.enabled ? p.textPrimary : p.textMuted,
                            fontSize: widget.dense ? 12 : 12.5,
                            fontWeight: FontWeight.w500,
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
                      borderRadius: BorderRadius.circular(14),
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
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide(
                                          color: p.hairline,
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide(
                                          color: p.hairline,
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
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
                                        fontSize: 12.5,
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
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          constraints: KonataAdaptiveTokens.isAndroid
              ? const BoxConstraints(
                  minHeight: KonataAdaptiveTokens.touchTarget,
                )
              : null,
          margin: const EdgeInsets.symmetric(vertical: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(9),
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
                          fontSize: 12.5,
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
                              fontSize: 12.5,
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
                                  fontSize: 11,
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
