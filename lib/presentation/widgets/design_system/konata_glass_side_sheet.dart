import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';
import 'konata_glass_dialog.dart';

/// 悬浮内嵌圆角毛玻璃侧栏（距顶 56px 避开窗口控制键，右/底各留 16px 外边距）。
class KonataGlassSideSheet extends StatefulWidget {
  /// 创建悬浮毛玻璃侧栏。
  const KonataGlassSideSheet({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
    this.width = 420,
  });

  /// 顶部主标题（纯文字 20px Bold，无左侧图标与下方硬分割线）。
  final String title;

  /// 关闭回调（收起动画完成后触发）。
  final VoidCallback onClose;

  /// 主体内容区域。
  final Widget child;

  /// 侧栏宽度（默认 420px）。
  final double width;

  @override
  State<KonataGlassSideSheet> createState() => _KonataGlassSideSheetState();
}

class _KonataGlassSideSheetState extends State<KonataGlassSideSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
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
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _controller.forward();
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final barrierColor = p.isDark
        ? Colors.black.withValues(alpha: 0.44)
        : Colors.black.withValues(alpha: 0.35);
    final panelColor = p.isDark
        ? const Color(0xFF1F232D).withValues(alpha: 0.90)
        : const Color(0xFFFDFDFE).withValues(alpha: 0.94);
    final borderColor = p.isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.95);

    return Stack(
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
          top: 56,
          right: 16,
          bottom: 16,
          width: widget.width,
          child: SlideTransition(
            position: _slideAnimation,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: p.isDark ? 0.38 : 0.14),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(22, 20, 18, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.title,
                                  style: TextStyle(
                                    color: p.textPrimary,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                              KonataGlassCloseButton(onPressed: _handleClose),
                            ],
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
      ],
    );
  }
}
