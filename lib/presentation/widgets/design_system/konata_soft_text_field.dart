import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';
import 'konata_glass_dialog.dart';

/// 无外框圆角 `10px` 柔光填充输入框（彻底消除生硬矩形 `OutlineInputBorder`）。
class KonataSoftTextField extends StatefulWidget {
  /// 创建无框柔光输入框。
  const KonataSoftTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.label,
    this.hintText,
    this.obscureText = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffix,
    this.onChanged,
    this.onSubmitted,
    this.dense = false,
    this.maxLines = 1,
    this.height,
    this.borderRadius,
  });

  /// 文本控制器。
  final TextEditingController? controller;

  /// 焦点节点。
  final FocusNode? focusNode;

  /// 可选顶部标签说明。
  final String? label;

  /// 占位提示文本。
  final String? hintText;

  /// 是否密码掩码显示。
  final bool obscureText;

  /// 键盘输入类型。
  final TextInputType? keyboardType;

  /// 可选前置图标。
  final IconData? prefixIcon;

  /// 可选尾部组件。
  final Widget? suffix;

  /// 文本变更回调。
  final ValueChanged<String>? onChanged;

  /// 回车提交回调。
  final ValueChanged<String>? onSubmitted;

  /// 是否紧凑高度。
  final bool dense;

  /// 最大展示行数（默认为单行 `1`）。
  final int maxLines;

  /// 可选固定高度（用于与同排操作按钮严格等高对齐）。
  final double? height;

  /// 可选圆角覆盖（默认 `BorderRadius.circular(10)`）。
  final BorderRadiusGeometry? borderRadius;

  @override
  State<KonataSoftTextField> createState() => _KonataSoftTextFieldState();
}

class _KonataSoftTextFieldState extends State<KonataSoftTextField> {
  FocusNode? _internalFocusNode;
  bool _focused = false;

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _effectiveFocusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant KonataSoftTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _internalFocusNode)?.removeListener(
        _onFocusChange,
      );
      _effectiveFocusNode.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    _effectiveFocusNode.removeListener(_onFocusChange);
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (mounted) {
      setState(() => _focused = _effectiveFocusNode.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final compactIme = KonataGlassDialog.isLandscapeCompactInputActive(context);
    final effectiveDense = widget.dense || compactIme;
    final effectiveHint = widget.hintText ?? (compactIme ? widget.label : null);
    final field = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      height: widget.height,
      alignment: widget.height != null ? Alignment.center : null,
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: widget.height != null ? 0 : (effectiveDense ? 7 : 10),
      ),
      decoration: BoxDecoration(
        color: p.softFill,
        borderRadius: widget.borderRadius ?? BorderRadius.circular(10),
        border: Border.all(
          color: _focused ? p.hoverBorder : Colors.transparent,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (widget.prefixIcon != null) ...[
            Icon(widget.prefixIcon, size: 16, color: p.textSecondary),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _effectiveFocusNode,
              obscureText: widget.obscureText,
              maxLines: widget.maxLines,
              keyboardType: widget.keyboardType,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              style: TextStyle(color: p.textPrimary, fontSize: 13.5),
              decoration: InputDecoration(
                hintText: effectiveHint,
                hintStyle: TextStyle(color: p.textMuted, fontSize: 13),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (widget.suffix != null) ...[
            const SizedBox(width: 6),
            widget.suffix!,
          ],
        ],
      ),
    );

    if (widget.label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Offstage(
          offstage: compactIme,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label!,
                style: TextStyle(
                  color: p.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
        field,
      ],
    );
  }
}
