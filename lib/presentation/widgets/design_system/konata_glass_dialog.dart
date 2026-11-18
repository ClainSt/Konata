import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import 'konata_draggable_dialog.dart';

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

/// 全站统一毛玻璃底部抽屉呼出入口（供窄屏折叠动作、筛选排序面板共用，严格同源玻璃材质与圆角）。
Future<T?> showKonataGlassBottomSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  List<Widget>? actions,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: isDark ? 0.48 : 0.34),
    builder: (sheetCtx) {
      final p = sheetCtx.palette;
      final glassBg = p.isDark
          ? const Color(0xFF1F232D).withValues(alpha: 0.92)
          : const Color(0xFFFDFDFE).withValues(alpha: 0.95);
      final glassBorder = p.isDark
          ? Colors.white.withValues(alpha: 0.18)
          : Colors.white.withValues(alpha: 0.95);
      final maxH = MediaQuery.sizeOf(sheetCtx).height * 0.78;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 44, sigmaY: 44),
            child: Container(
              decoration: BoxDecoration(
                color: glassBg,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
                border: Border(
                  top: BorderSide(color: glassBorder, width: 1),
                  left: BorderSide(color: glassBorder, width: 1),
                  right: BorderSide(color: glassBorder, width: 1),
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 14, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            KonataGlassCloseButton(
                              onPressed: () => Navigator.of(sheetCtx).maybePop(),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, thickness: 1, color: p.hairline),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                          child: builder(sheetCtx),
                        ),
                      ),
                      if (actions != null && actions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 10,
                            runSpacing: 8,
                            children: actions,
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
    },
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

  /// 弹窗基准宽度（窄视口自动收敛防溢出）。
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
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final compact =
        screen.width < KonataAdaptiveTokens.tabletBreakpoint ||
        screen.height < KonataAdaptiveTokens.shortViewportHeight;
    final availableW = math.max(220.0, screen.width - safe.horizontal - 24.0);
    final availableH = math.max(
      180.0,
      screen.height -
          safe.vertical -
          MediaQuery.viewInsetsOf(context).vertical -
          24.0,
    );
    final effectiveWidth = math.min(width, availableW);
    final effectiveHeight = height != null
        ? math.min(height!, availableH)
        : null;
    final effectiveMaxHeight = maxHeight != null
        ? math.min(maxHeight!, availableH)
        : (KonataAdaptiveTokens.isAndroid ? availableH : null);

    final glassBg = p.isDark
        ? const Color(0xFF1F232D).withValues(alpha: 0.90)
        : const Color(0xFFFDFDFE).withValues(alpha: 0.94);
    final glassBorder = p.isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.95);
    final shadowColor = Colors.black.withValues(alpha: p.isDark ? 0.38 : 0.14);

    Widget body = child;
    if (effectiveHeight == null &&
        effectiveMaxHeight != null &&
        maxHeight == null) {
      body = SingleChildScrollView(child: child);
    }

    return KonataDraggableDialog(
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
              width: effectiveWidth,
              height: effectiveHeight,
              constraints: effectiveMaxHeight != null
                  ? BoxConstraints(maxHeight: effectiveMaxHeight)
                  : null,
              padding: EdgeInsets.all(compact ? 16 : 22),
              decoration: BoxDecoration(
                color: glassBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: glassBorder, width: 1),
              ),
              child: Column(
                mainAxisSize: effectiveHeight != null
                    ? MainAxisSize.max
                    : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: KonataDialogDragHandle(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.textPrimary,
                                fontSize: compact ? 16.5 : 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (headerTrailing != null && !compact) ...[
                        const SizedBox(width: 8),
                        headerTrailing!,
                      ],
                      const SizedBox(width: 8),
                      KonataGlassCloseButton(
                        onPressed:
                            onClose ?? () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                  if (headerTrailing != null && compact) ...[
                    const SizedBox(height: 8),
                    headerTrailing!,
                  ],
                  SizedBox(height: compact ? 12 : 16),
                  if (effectiveHeight != null || effectiveMaxHeight != null)
                    Flexible(child: body)
                  else
                    body,
                  if (actions != null && actions!.isNotEmpty) ...[
                    SizedBox(height: compact ? 12 : 18),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 10,
                        runSpacing: 8,
                        children: actions!,
                      ),
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

/// 圆形半透明微光关闭按钮（供毛玻璃侧栏与弹窗头部复用，Android 保证 48dp 热区）。
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
    final touchSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 30.0;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox(
            width: touchSize,
            height: touchSize,
            child: Center(
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
        ),
      ),
    );
  }
}
