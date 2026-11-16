import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';

/// 全站统一悬浮毛玻璃弹窗呼出入口（默认加深外部遮罩以突出前景弹窗并抑制底层穿透）。
Future<T?> showKonataGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.black.withValues(alpha: isDark ? 0.45 : 0.35),
    builder: builder,
  );
}

/// 全站统一悬浮毛玻璃弹窗容器（36px 高斯模糊 + 通透半透明玻璃叠色 + 1px 微光描边）。
class KonataGlassDialog extends StatelessWidget {
  /// 创建毛玻璃弹窗。
  const KonataGlassDialog({
    super.key,
    required this.title,
    required this.child,
    this.width = 520,
    this.height,
    this.maxHeight,
    this.headerTrailing,
    this.actions,
    this.onClose,
  });

  /// 弹窗标题。
  final String title;

  /// 主体内容（若外部未提供高度限制且内容较多，建议内部自行滚动或配合 [maxHeight]）。
  final Widget child;

  /// 弹窗固定宽度。
  final double width;

  /// 可选固定高度。
  final double? height;

  /// 可选最大高度约束。
  final double? maxHeight;

  /// 可选标题栏右侧扩展控件（紧邻关闭按钮左侧）。
  final Widget? headerTrailing;

  /// 可选底部操作按钮区（右对齐排列）。
  final List<Widget>? actions;

  /// 点击右上角关闭按钮回调（默认为 `Navigator.of(context).maybePop()`）。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glassBg = p.isDark
        ? const Color(0xFF1F232D).withValues(alpha: 0.90)
        : const Color(0xFFFDFDFE).withValues(alpha: 0.94);
    final glassBorder = p.isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.95);
    final shadowColor = Colors.black.withValues(alpha: p.isDark ? 0.38 : 0.14);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: 36,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 44, sigmaY: 44),
            child: Container(
              width: width,
              height: height,
              constraints: maxHeight != null
                  ? BoxConstraints(maxHeight: maxHeight!)
                  : null,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: glassBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: glassBorder, width: 1),
              ),
              child: Column(
                mainAxisSize:
                    height != null ? MainAxisSize.max : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (headerTrailing != null) ...[
                        headerTrailing!,
                        const SizedBox(width: 8),
                      ],
                      KonataGlassCloseButton(
                        onPressed:
                            onClose ?? () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (height != null || maxHeight != null)
                    Flexible(child: child)
                  else
                    child,
                  if (actions != null && actions!.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (int i = 0; i < actions!.length; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          actions![i],
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆形半透明微光关闭按钮（供毛玻璃侧栏与弹窗头部复用）。
class KonataGlassCloseButton extends StatefulWidget {
  /// 创建圆形微光关闭按钮。
  const KonataGlassCloseButton({
    super.key,
    required this.onPressed,
    this.tooltip = '关闭',
  });

  /// 点击回调。
  final VoidCallback? onPressed;

  /// 悬停提示。
  final String tooltip;

  @override
  State<KonataGlassCloseButton> createState() => _KonataGlassCloseButtonState();
}

class _KonataGlassCloseButtonState extends State<KonataGlassCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = widget.onPressed != null;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hovered && enabled ? p.surfaceHover : p.surface,
              border: Border.all(
                color: _hovered && enabled ? p.hoverBorder : p.hairline,
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.close_rounded,
              size: 16,
              color: enabled ? p.textSecondary : p.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
