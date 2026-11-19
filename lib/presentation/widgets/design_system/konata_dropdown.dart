import 'dart:math' as math;
import '../../theme/konata_adaptive_tokens.dart';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import 'konata_draggable_scrollbar.dart';
import '../../theme/konata_theme.dart';

part 'konata_dropdown_overlay.dart';

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
            duration: KonataTheme.motionFast,
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
                  duration: KonataTheme.motionMedium,
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
            duration: KonataTheme.motionFast,
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: !widget.enabled
                  ? p.softFill.withValues(alpha: 0.55)
                  : (isOpen || _hovered ? p.surfaceHover : p.softFill),
              borderRadius: KonataTheme.borderRadiusTile,
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
                      fontSize: KonataTheme.fontSizeBodyXs,
                      fontWeight: activeOption != null
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: isOpen ? 0.5 : 0.0,
                  duration: KonataTheme.motionMedium,
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
        ? KonataTheme.borderRadiusPill
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
            duration: KonataTheme.motionFast,
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
                            fontSize: KonataTheme.fontSizeCaption,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        child: AnimatedRotation(
                          turns: isOpen ? 0.5 : 0.0,
                          duration: KonataTheme.motionMedium,
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
                        duration: KonataTheme.motionMedium,
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

