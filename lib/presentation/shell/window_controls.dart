import 'dart:async';
import 'dart:developer' as developer;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:window_manager/window_manager.dart' as wm;

import '../../application/providers/platform_capability.dart';
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
  State<WindowControls> createState() => WindowControlsState();
}

/// 窗口控制按钮组状态（负责订阅原生窗口事件并同步最大化/还原图标与标题栏按钮隐藏）。
class WindowControlsState extends State<WindowControls>
    with WidgetsBindingObserver {
  bool _isMaximized = false;
  Timer? _metricsSyncTimer;
  wm.Window? _boundWindow;
  wm.ListenerId? _windowListenerId;

  bool get _canControlWindow => KonataPlatform.isWindows;

  wm.Window? _resolveNativeWindow() {
    if (!_canControlWindow) {
      return null;
    }
    try {
      return _boundWindow ??= wm.WindowManager.instance.getCurrent();
    } catch (error) {
      // 测试环境无原生窗口宿主动态库时安全降级
      developer.log('可恢复异常已记录', name: 'konata.window_controls', error: error);
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_canControlWindow) {
      final win = _resolveNativeWindow();
      if (win != null) {
        try {
          _windowListenerId = win.addListener(handleWindowEvent);
        } catch (error) {
          developer.log(
            '可恢复异常已记录',
            name: 'konata.window_controls',
            error: error,
          );
        }
      }
      _syncMaximizedState();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _syncMaximizedState();
        }
      });
    }
  }

  @override
  void dispose() {
    _metricsSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final win = _boundWindow;
    final listenerId = _windowListenerId;
    _boundWindow = null;
    _windowListenerId = null;
    if (win != null && listenerId != null) {
      try {
        win.removeListener(listenerId);
      } catch (error) {
        developer.log('可恢复异常已记录', name: 'konata.window_controls', error: error);
      }
    }
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!_canControlWindow) {
      return;
    }
    _syncMaximizedState();
    _metricsSyncTimer?.cancel();
    _metricsSyncTimer = Timer(KonataTheme.windowMetricsDebounce, () {
      if (mounted) {
        _syncMaximizedState();
      }
    });
  }

  void _syncMaximizedState() {
    final win = _resolveNativeWindow();
    if (win == null) {
      return;
    }
    try {
      final maximized = win.isMaximized;
      if (mounted && maximized != _isMaximized) {
        setState(() => _isMaximized = maximized);
      }
    } catch (error) {
      // 测试环境无原生窗口宿主时安全忽略
      developer.log('可恢复异常已记录', name: 'konata.window_controls', error: error);
    }
  }

  Future<void> _ensureNativeControlsHidden() async {
    if (!_canControlWindow) {
      return;
    }
    try {
      await Window.hideWindowControls();
    } catch (error) {
      // 测试环境无原生窗口上下文时安全忽略
      developer.log('可恢复异常已记录', name: 'konata.window_controls', error: error);
    }
  }

  /// 处理来自 `nativeapi` 的窗口生命周期事件并同步最大化状态图标。
  void handleWindowEvent(wm.WindowEvent event) {
    switch (event) {
      case wm.WindowMaximizedEvent():
        unawaited(_ensureNativeControlsHidden());
        if (mounted) {
          setState(() => _isMaximized = true);
        }
      case wm.WindowRestoredEvent():
        unawaited(_ensureNativeControlsHidden());
        if (mounted) {
          setState(() => _isMaximized = false);
        }
        _syncMaximizedState();
      case wm.WindowResizedEvent():
      case wm.WindowMovedEvent():
      case wm.WindowFocusedEvent():
      case wm.WindowExitedFullScreenEvent():
        _syncMaximizedState();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canControlWindow) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final showPill = widget.forceLightIcons || widget.showGlassPill;
    final iconColor = widget.forceLightIcons
        ? KonataTheme.pureWhite
        : (showPill ? p.textPrimary : p.textSecondary);
    final hoverBg = widget.forceLightIcons
        ? KonataTheme.overlayWhiteDim
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
            _resolveNativeWindow()?.minimize();
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
          onHoverEnter: _canControlWindow ? _syncMaximizedState : null,
          onPressed: () async {
            final win = _resolveNativeWindow();
            if (win == null) {
              return;
            }
            if (_isMaximized) {
              win.unmaximize();
            } else {
              win.maximize();
            }
            await _ensureNativeControlsHidden();
            _syncMaximizedState();
          },
        ),
        _WindowControlButton(
          tooltip: '关闭',
          icon: Icons.close_rounded,
          iconColor: iconColor,
          hoverBg: hoverBg,
          isClose: true,
          onPressed: () {
            _resolveNativeWindow()?.close();
          },
        ),
      ],
    );

    if (!showPill) {
      return controlsRow;
    }

    final pillBg = widget.forceLightIcons
        ? KonataTheme.scrimBlackSubtle
        : p.surface;
    final pillBorder = widget.forceLightIcons
        ? KonataTheme.overlayWhiteBorderStrong
        : p.hairline;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: KonataTheme.borderRadiusPill,
        boxShadow: [
          BoxShadow(
            color: KonataTheme.pureBlack.withValues(
              alpha: widget.forceLightIcons ? 0.22 : 0.12,
            ),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: KonataTheme.borderRadiusPill,
        child: BackdropFilter(
          filter: KonataTheme.blurFilterControl,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: KonataTheme.borderRadiusPill,
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
                borderRadius: KonataTheme.borderRadiusPill,
              ),
              child: Center(
                child: Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: _hovered && widget.isClose
                      ? KonataTheme.pureWhite
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
