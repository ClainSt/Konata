import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:window_manager/window_manager.dart' as wm;

import 'window_host_port.dart';

/// Windows 原生窗口缩放事件通道名称（与 `windows/runner/flutter_window.cpp` 对齐）。
const String konataWindowResizeChannelName = 'konata/window_resize';

/// Windows 11 原生 DWM 窗口材质控制器。
///
/// 负责将应用的亮/暗主题模式与用户所选材质（Acrylic / Mica / Tabbed）
/// 实时同步至 Win32 DWM 合成层，实现透明桌面壁纸穿透光影。
final class WindowMaterialController {
  /// 暗色模式下的亚克力半透明叠色（深曜石底色，透出桌面光影）。
  static const Color darkAcrylicTint = Color(0xB80E1015);

  /// 亮色模式下的亚克力半透明叠色（柔和画册白，透出桌面光影）。
  static const Color lightAcrylicTint = Color(0xC4F4F5F8);

  /// 判断当前实际生效的是否为暗色模式。
  static bool resolveIsDark(ThemeMode mode, Brightness platformBrightness) {
    return switch (mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformBrightness == Brightness.dark,
    };
  }

  bool? _lastIsDark;
  KonataWindowMaterial? _lastMaterial;
  final audioMiniActive = ValueNotifier<bool>(false);

  /// 音频异形窗口期间暂停矩形系统材质，恢复后按最新偏好重新应用。
  Future<void> setAudioMini(bool enabled) async {
    if (audioMiniActive.value == enabled) return;
    audioMiniActive.value = enabled;
    if (enabled) {
      try {
        await Window.setEffect(
          effect: WindowEffect.transparent,
          color: Colors.transparent,
        );
      } catch (_) {
        audioMiniActive.value = false;
        rethrow;
      }
      return;
    }
    final material = _lastMaterial;
    final dark = _lastIsDark;
    if (material != null && dark != null) {
      await apply(
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        platformBrightness: dark ? Brightness.dark : Brightness.light,
        material: material,
        force: true,
      );
    }
  }

  /// 应用 Windows DWM 窗口材质与明暗效果。
  Future<void> apply({
    required ThemeMode themeMode,
    required Brightness platformBrightness,
    required KonataWindowMaterial material,
    bool force = false,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    final isDark = resolveIsDark(themeMode, platformBrightness);
    if (!force && _lastIsDark == isDark && _lastMaterial == material) {
      return;
    }
    _lastIsDark = isDark;
    _lastMaterial = material;
    if (audioMiniActive.value) return;
    try {
      switch (material) {
        case KonataWindowMaterial.acrylic:
          await Window.setEffect(
            effect: WindowEffect.acrylic,
            color: isDark ? darkAcrylicTint : lightAcrylicTint,
            dark: isDark,
          );
        case KonataWindowMaterial.mica:
          await Window.setEffect(effect: WindowEffect.mica, dark: isDark);
        case KonataWindowMaterial.tabbed:
          await Window.setEffect(effect: WindowEffect.tabbed, dark: isDark);
      }
      // 每次应用或切换 DWM 材质后重新隐藏 Win32 原生标题栏控制按钮，防止与 Flutter 控制键重叠。
      await Window.hideWindowControls();
    } catch (error) {
      developer.log(
        '应用 Windows DWM 窗口材质忽略',
        name: 'konata.windows_window_host',
        error: error,
      );
    }
  }
}

/// Windows 桌面无框窗口宿主实现（统一收口 DWM 材质、缩放节流监听、顶栏拖拽与三键控制）。
final class WindowsWindowHost implements KonataDesktopWindowHostPort {
  /// 创建 Windows 无框窗口宿主。
  WindowsWindowHost({WindowMaterialController? materialController})
    : _materialController = materialController ?? WindowMaterialController();

  final WindowMaterialController _materialController;

  @override
  Future<void> applyMaterial({
    required ThemeMode themeMode,
    required Brightness platformBrightness,
    required KonataWindowMaterial material,
    bool force = false,
  }) {
    return _materialController.apply(
      themeMode: themeMode,
      platformBrightness: platformBrightness,
      material: material,
      force: force,
    );
  }

  @override
  Future<void> hideWindowControls() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await Window.hideWindowControls();
    } catch (error) {
      developer.log(
        '隐藏原生窗口控制按钮忽略',
        name: 'konata.windows_window_host',
        error: error,
      );
    }
  }

  @override
  void Function() bindLiveResizeChannel(
    ValueNotifier<bool> resizingNotifier, {
    required VoidCallback onMinimized,
  }) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return () {};
    }
    const resizeChannel = MethodChannel(konataWindowResizeChannelName);
    Timer? guardTimer;
    var disposed = false;
    resizeChannel.setMethodCallHandler((call) async {
      if (disposed) return null;
      if (call.method == 'windowMinimized') {
        onMinimized();
        return null;
      }
      if (call.method != 'resizeStateChanged') return null;
      final resizing = call.arguments == true;
      guardTimer?.cancel();
      guardTimer = null;
      if (resizingNotifier.value != resizing) {
        resizingNotifier.value = resizing;
      }
      if (resizing) {
        guardTimer = Timer(KonataPlaybackTokens.windowResizeGuardTimeout, () {
          guardTimer = null;
          if (!disposed && resizingNotifier.value) {
            resizingNotifier.value = false;
          }
        });
      }
      return null;
    });
    return () {
      disposed = true;
      guardTimer?.cancel();
      guardTimer = null;
      resizeChannel.setMethodCallHandler(null);
    };
  }

  @override
  Widget buildWindowControls({
    bool forceLightIcons = false,
    bool showGlassPill = false,
  }) {
    return WindowControls(
      forceLightIcons: forceLightIcons,
      showGlassPill: showGlassPill,
    );
  }

  @override
  Widget buildDragToMoveArea({required Widget child}) {
    return ValueListenableBuilder<bool>(
      valueListenable: _materialController.audioMiniActive,
      child: child,
      builder: (context, audioMini, child) {
        if (!audioMini) return wm.DragToMoveArea(child: child!);
        // 音频小窗不进入系统窗口移动循环，避免触发分屏贴靠。
        const channel = MethodChannel('konata/desktop_mini');
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) =>
              unawaited(channel.invokeMethod<void>('beginAudioDrag')),
          onPanUpdate: (_) =>
              unawaited(channel.invokeMethod<void>('updateAudioDrag')),
          onPanEnd: (_) =>
              unawaited(channel.invokeMethod<void>('endAudioDrag')),
          onPanCancel: () =>
              unawaited(channel.invokeMethod<void>('endAudioDrag')),
          child: child,
        );
      },
    );
  }
}

/// 极简无框窗口控制按钮组（最小化 / 最大化还原状态实时同步 / 关闭）。
class WindowControls extends StatefulWidget {
  /// 创建窗口控制按钮组。
  ///
  /// [forceLightIcons] 用于深色原画与音视频舞台顶栏强制亮白图标；
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

  bool get _canControlWindow =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  wm.Window? _resolveNativeWindow() {
    if (!_canControlWindow) {
      return null;
    }
    try {
      return _boundWindow ??= wm.WindowManager.instance.getCurrent();
    } catch (error) {
      developer.log(
        '获取原生窗口句柄失败，测试或无窗口环境已降级',
        name: 'konata.window_controls',
        error: error,
      );
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
            '注册原生窗口事件监听忽略',
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
        developer.log(
          '移除原生窗口事件监听忽略',
          name: 'konata.window_controls',
          error: error,
        );
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
      developer.log('读取最大化状态忽略', name: 'konata.window_controls', error: error);
    }
  }

  Future<void> _ensureNativeControlsHidden() async {
    if (!_canControlWindow) {
      return;
    }
    try {
      await Window.hideWindowControls();
    } catch (error) {
      developer.log(
        '重申隐藏原生标题栏按钮忽略',
        name: 'konata.window_controls',
        error: error,
      );
    }
  }

  /// 处理来自 `window_manager` 的窗口生命周期事件并同步最大化状态图标。
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
    final showPill = widget.showGlassPill;
    final iconColor = widget.forceLightIcons
        ? KonataTheme.pureWhite
        : (showPill ? p.textPrimary : p.textSecondary);
    final hoverBg = widget.forceLightIcons
        ? KonataTheme.overlayWhiteDim
        : (showPill ? p.secondaryButtonHoverBg : p.secondaryButtonBg);

    final controlsRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
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
          tooltip: _isMaximized ? '还原' : '最大化',
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
        boxShadow: <BoxShadow>[
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
        child: KonataAdaptiveBackdropBlur(
          filter: KonataTheme.blurFilterMedium,
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

    return KonataTooltip(
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
