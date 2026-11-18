import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import 'konata_glass_dialog.dart';

/// 悬浮内嵌圆角毛玻璃侧栏（桌面距顶 56px 避开窗口控制键，触屏自适应安全区与矮屏高度）。
class KonataGlassSideSheet extends StatefulWidget {
  /// 创建悬浮毛玻璃侧栏。
  const KonataGlassSideSheet({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
    this.width = 420,
    this.bottomInset = 16.0,
  });

  /// 顶部主标题（纯文字 20px Bold，无左侧图标与下方硬分割线）。
  final String title;

  /// 关闭回调（收起动画完成后触发）。
  final VoidCallback onClose;

  /// 主体内容区域。
  final Widget child;

  /// 侧栏基准宽度（默认 420px）。
  final double width;

  /// 距容器底部的安全避让间距。
  final double bottomInset;

  @override
  State<KonataGlassSideSheet> createState() => _KonataGlassSideSheetState();
}

class _KonataGlassSideSheetState extends State<KonataGlassSideSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  final ValueNotifier<double> _dragDx = ValueNotifier<double>(0.0);
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(1.06, 0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _dragDx.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleClose() async {
    if (_closing) return;
    _closing = true;
    await _controller.reverse();
    if (mounted) {
      widget.onClose();
    }
  }

  void _onHeaderHorizontalDragUpdate(DragUpdateDetails details) {
    if (_closing) return;
    _dragDx.value = (_dragDx.value + details.delta.dx).clamp(0.0, 500.0);
  }

  void _onHeaderHorizontalDragEnd(DragEndDetails details) {
    if (_closing) return;
    final velocity = details.primaryVelocity ?? 0.0;
    if (_dragDx.value > 56.0 || velocity > 380.0) {
      _handleClose();
      return;
    }
    _dragDx.value = 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final isShort = screen.height < KonataAdaptiveTokens.shortViewportHeight;

    final rightInset = math.max(12.0, safe.right + 12.0);
    final effectiveWidth = math.min(
      widget.width,
      math.max(240.0, screen.width - safe.left - rightInset - 12.0),
    );
    final topInset = isAndroid
        ? (isShort
              ? math.max(8.0, safe.top + 8.0)
              : math.max(KonataAdaptiveTokens.tabletTopSafeMin, safe.top + 12.0))
        : 56.0;
    final bottomInset = isAndroid && isShort
        ? math.max(8.0, safe.bottom + 8.0)
        : math.max(safe.bottom + 12.0, widget.bottomInset);

    final barrierColor = p.isDark
        ? Colors.black.withValues(alpha: 0.44)
        : Colors.black.withValues(alpha: 0.35);
    final panelColor = p.isDark
        ? const Color(0xFF1F232D).withValues(alpha: 0.90)
        : const Color(0xFFFDFDFE).withValues(alpha: 0.94);
    final borderColor = p.isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.95);

    final sheetStack = Stack(
      children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: GestureDetector(
              onTap: _handleClose,
              child: Container(color: barrierColor),
            ),
          ),
        ),
        Positioned(
          top: topInset,
          right: isAndroid ? rightInset : 16,
          bottom: bottomInset,
          width: effectiveWidth,
          child: ValueListenableBuilder<double>(
            valueListenable: _dragDx,
            builder: (context, dx, child) => Transform.translate(
              offset: Offset(dx, 0),
              child: child,
            ),
            child: SlideTransition(
              position: _slideAnimation,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: p.isDark ? 0.38 : 0.14,
                      ),
                      blurRadius: 32,
                      offset: const Offset(-4, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 44, sigmaY: 44),
                    child: Container(
                      decoration: BoxDecoration(
                        color: panelColor,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: borderColor, width: 1),
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onHorizontalDragUpdate:
                                  _onHeaderHorizontalDragUpdate,
                              onHorizontalDragEnd: _onHeaderHorizontalDragEnd,
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  isShort ? 16 : 22,
                                  isShort ? 10 : 16,
                                  isShort ? 10 : 14,
                                  isShort ? 6 : 10,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        widget.title,
                                        style: TextStyle(
                                          color: p.textPrimary,
                                          fontSize: isShort ? 17 : 20,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                    ),
                                    KonataGlassCloseButton(
                                      onPressed: _handleClose,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(child: widget.child),
                          ],
                        ),
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

    if (Navigator.maybeOf(context) != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _handleClose();
          }
        },
        child: sheetStack,
      );
    }
    return sheetStack;
  }
}
