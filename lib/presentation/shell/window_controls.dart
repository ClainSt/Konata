import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';

/// 极简无框窗口控制按钮组（最小化 / 最大化还原状态实时同步 / 关闭）。
class WindowControls extends StatefulWidget {
  /// 创建窗口控制按钮组。
  ///
  /// [forceLightIcons] 用于深色原画详情页顶栏，确保图标始终清晰可读。
  const WindowControls({super.key, this.forceLightIcons = false});

  /// 是否强制使用浅色图标。
  final bool forceLightIcons;

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> with WindowListener {
  bool _isMaximized = false;

  bool get _canControlWindow =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (_canControlWindow) {
      windowManager.addListener(this);
      _syncMaximizedState();
    }
  }

  @override
  void dispose() {
    if (_canControlWindow) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _syncMaximizedState() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (mounted && maximized != _isMaximized) {
        setState(() => _isMaximized = maximized);
      }
    } catch (_) {
      // 测试环境无 window_manager 宿主通道时安全忽略
    }
  }

  Future<void> _ensureNativeControlsHidden() async {
    if (!_canControlWindow) return;
    try {
      await Window.hideWindowControls();
    } catch (_) {
      // 测试环境无原生窗口上下文时安全忽略
    }
  }

  @override
  void onWindowMaximize() {
    unawaited(_ensureNativeControlsHidden());
    if (mounted) {
      setState(() => _isMaximized = true);
    }
  }

  @override
  void onWindowUnmaximize() {
    unawaited(_ensureNativeControlsHidden());
    if (mounted) {
      setState(() => _isMaximized = false);
    }
  }

  @override
  void onWindowRestore() {
    unawaited(_ensureNativeControlsHidden());
    if (mounted) {
      setState(() => _isMaximized = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final iconColor = widget.forceLightIcons ? Colors.white : p.textSecondary;
    final hoverBg = widget.forceLightIcons
        ? Colors.white.withValues(alpha: 0.14)
        : p.secondaryButtonBg;

    final controlsRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowControlButton(
          tooltip: '最小化',
          icon: Icons.remove_rounded,
          iconColor: iconColor,
          hoverBg: hoverBg,
          onPressed: () {
            if (_canControlWindow) {
              windowManager.minimize();
            }
          },
        ),
        _WindowControlButton(
          tooltip: _isMaximized ? '向下还原' : '最大化',
          icon: _isMaximized
              ? Icons.filter_none_rounded
              : Icons.crop_square_rounded,
          iconSize: _isMaximized ? 13.5 : 15,
          iconColor: iconColor,
          hoverBg: hoverBg,
          onPressed: () async {
            if (!_canControlWindow) return;
            if (_isMaximized) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
            await _ensureNativeControlsHidden();
          },
        ),
        _WindowControlButton(
          tooltip: '关闭',
          icon: Icons.close_rounded,
          iconColor: iconColor,
          hoverBg: hoverBg,
          isClose: true,
          onPressed: () {
            if (_canControlWindow) {
              windowManager.close();
            }
          },
        ),
      ],
    );

    if (!widget.forceLightIcons) return controlsRow;

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.22),
            ),
          ),
          child: controlsRow,
        ),
      ),
    );
  }
}

class _WindowControlButton extends StatefulWidget {
  const _WindowControlButton({
    required this.tooltip,
    required this.icon,
    required this.iconColor,
    required this.hoverBg,
    required this.onPressed,
    this.iconSize = 17,
    this.isClose = false,
  });

  final String tooltip;
  final IconData icon;
  final Color iconColor;
  final Color hoverBg;
  final double iconSize;
  final bool isClose;
  final VoidCallback onPressed;

  @override
  State<_WindowControlButton> createState() => _WindowControlButtonState();
}

class _WindowControlButtonState extends State<_WindowControlButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = _hovered
        ? (widget.isClose ? KonataTheme.windowCloseHoverRed : widget.hoverBg)
        : Colors.transparent;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox(
            width: 36,
            height: 32,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: _hovered && widget.isClose
                      ? Colors.white
                      : widget.iconColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
