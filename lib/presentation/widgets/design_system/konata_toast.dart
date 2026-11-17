import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/konata_palette.dart';

OverlayEntry? _activeToastEntry;

/// 弹出全站统一悬浮毛玻璃胶囊提示（取代丑陋的黑底 SnackBar，不抢占导航点击）。
void showKonataToast(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = const Duration(milliseconds: 2400),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _activeToastEntry?.remove();
  _activeToastEntry = null;

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _KonataGlassToastOverlay(
      message: message,
      isError: isError,
      duration: duration,
      onDismissed: () {
        if (entry.mounted) {
          entry.remove();
        }
        if (identical(_activeToastEntry, entry)) {
          _activeToastEntry = null;
        }
      },
    ),
  );
  _activeToastEntry = entry;
  overlay.insert(entry);
}

class _KonataGlassToastOverlay extends StatefulWidget {
  const _KonataGlassToastOverlay({
    required this.message,
    required this.isError,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final bool isError;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_KonataGlassToastOverlay> createState() =>
      _KonataGlassToastOverlayState();
}

class _KonataGlassToastOverlayState extends State<_KonataGlassToastOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.16),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    _dismissTimer = Timer(widget.duration, _beginClose);
  }

  Future<void> _beginClose() async {
    if (!mounted) return;
    await _controller.reverse();
    if (mounted) {
      widget.onDismissed();
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final accentColor = widget.isError ? p.danger : p.accent;
    final bgColor = p.isDark
        ? const Color(0xFF2A2E39).withValues(alpha: 0.62)
        : Colors.white.withValues(alpha: 0.78);
    final borderColor = widget.isError
        ? p.danger.withValues(alpha: 0.45)
        : (p.isDark
            ? Colors.white.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.92));

    // 在窗口安全区正中心悬浮展示轻提示，避免遮挡底部操作胶囊或详情页工具栏。
    return Positioned.fill(
      child: IgnorePointer(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Center(
            child: FadeTransition(
            opacity: _opacity,
            child: SlideTransition(
              position: _slide,
              child: Material(
                type: MaterialType.transparency,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 520),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: borderColor, width: 1),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: p.isDark ? 0.30 : 0.10,
                            ),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.isError
                                ? Icons.error_outline_rounded
                                : Icons.check_circle_outline_rounded,
                            size: 17,
                            color: accentColor,
                          ),
                          const SizedBox(width: 9),
                          Flexible(
                            child: Text(
                              widget.message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
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
        ),
        ),
      ),
    );
  }
}
