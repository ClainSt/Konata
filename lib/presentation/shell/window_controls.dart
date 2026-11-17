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
  /// [forceLightIcons] 用于深色原画顶栏强制亮白图标；
  /// [showGlassPill] 用于全屏原画详情页（无论浅色或深色模式均包裹高对比度磨砂胶囊底座）。
  const WindowControls({
    super.key,
    this.forceLightIcons = false,
    this.showGlassPill = false,
  });

  /// 是否强制使用浅色图标与暗色胶囊底座。
  final bool forceLightIcons;

  /// 是否包裹毛玻璃胶囊底座（解决浅色模式下原画顶栏裸露图标看不清的问题）。
  final bool showGlassPill;

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls>
    with WindowListener, WidgetsBindingObserver {
  bool _isMaximized = false;
  Timer? _metricsSyncTimer;

  bool get _canControlWindow =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_canControlWindow) {
      windowManager.addListener(this);
      unawaited(_syncMaximizedState());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_syncMaximizedState());
        }
      });
    }
  }

  @override
  void dispose() {
    _metricsSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_canControlWindow) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!_canControlWindow) {
      return;
    }
    unawaited(_syncMaximizedState());
    _metricsSyncTimer?.cancel();
    _metricsSyncTimer = Timer(const Duration(milliseconds: 90), () {
      if (mounted) {
        unawaited(_syncMaximizedState());
      }
    });
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
    if (!_canControlWindow) {
      return;
    }
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
    if (_canControlWindow) {
      unawaited(_syncMaximizedState());
    }
  }

  @override
  void onWindowResize() {
    if (_canControlWindow) {
      unawaited(_syncMaximizedState());
    }
  }

  @override
  void onWindowResized() {
    if (_canControlWindow) {
      unawaited(_syncMaximizedState());
    }
  }

  @override
  void onWindowMoved() {
    if (_canControlWindow) {
      unawaited(_syncMaximizedState());
    }
  }

  @override
  void onWindowFocus() {
    if (_canControlWindow) {
      unawaited(_syncMaximizedState());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final showPill = widget.forceLightIcons || widget.showGlassPill;
    final iconColor = widget.forceLightIcons
        ? Colors.white
        : (showPill ? p.textPrimary : p.textSecondary);
    final hoverBg = widget.forceLightIcons
        ? Colors.white.withValues(alpha: 0.14)
        : (showPill ? p.secondaryButtonHoverBg : p.secondaryButtonBg);

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
          onHoverEnter: _canControlWindow
              ? () => unawaited(_syncMaximizedState())
              : null,
          onPressed: () async {
            if (!_canControlWindow) {
              return;
            }
            if (_isMaximized) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
            await _ensureNativeControlsHidden();
            await _syncMaximizedState();
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

    if (!showPill) {
      return controlsRow;
    }

    final pillBg = widget.forceLightIcons
        ? Colors.black.withValues(alpha: 0.30)
        : p.surface;
    final pillBorder = widget.forceLightIcons
        ? Colors.white.withValues(alpha: 0.22)
        : p.hairline;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: widget.forceLightIcons ? 0.22 : 0.12,
            ),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: pillBorder),
            ),
            child: controlsRow,
          ),
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
    this.onHoverEnter,
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
  final VoidCallback? onHoverEnter;

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
        onEnter: (_) {
          widget.onHoverEnter?.call();
          setState(() => _hovered = true);
        },
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
                borderRadius: BorderRadius.circular(999),
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
