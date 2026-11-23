import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:window_manager/window_manager.dart' as wm;

import '../application/providers/desktop_external_tools_providers.dart';
import '../application/providers/konata_value_notifier.dart';
import '../application/providers/memory_coordinator.dart';
import '../application/providers/playback_providers.dart';
import '../application/providers/theme_providers.dart';
import '../domain/config/konata_lane_config.dart';
import '../infrastructure/players/d3d11_video_bridge.dart';
import '../infrastructure/players/real_external_player_launcher.dart';
import '../infrastructure/players/windows_code_page_decoder.dart';
import '../infrastructure/players/windows_desktop_relay_gateway.dart';
import '../infrastructure/players/windows_mpv_profile_adapter.dart';
import '../infrastructure/storage/storage_root_provider.dart';
import '../presentation/app/konata_app.dart';
import '../presentation/settings/settings_external_tools_panel.dart';
import '../presentation/shell/top_nav_bar.dart';
import '../presentation/shell/window_controls.dart';
import '../presentation/theme/konata_playback_tokens.dart';
import '../presentation/theme/window_material_controller.dart';
import 'platform_composition.dart';

/// Windows 桌面窗口宿主实现（收口 `flutter_acrylic` 与 `window_manager` 全部调用）。
class WindowsKonataWindowHost implements KonataWindowHost {
  /// 创建 Windows 窗口宿主。
  WindowsKonataWindowHost({WindowMaterialController? materialController})
    : _materialController = materialController ?? WindowMaterialController();

  final WindowMaterialController _materialController;
  bool _inAlwaysOnTopMiniWindow = false;
  Rect? _savedNormalBounds;
  bool _savedNormalMaximized = false;
  bool _savedNormalFullScreen = false;
  Offset? _lastMiniWindowOrigin;

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
      developer.log('可恢复异常已记录', name: 'konata.windows_composition_root', error: error);
    }
  }

  wm.Window? _currentNativeWindow() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return null;
    try {
      return wm.WindowManager.instance.getCurrent();
    } catch (error) {
      developer.log(
        '可恢复异常已记录',
        name: 'konata.windows_composition_root',
        error: error,
      );
      return null;
    }
  }

  @override
  Future<bool> isFullScreen() async {
    return _currentNativeWindow()?.isFullScreen ?? false;
  }

  @override
  Future<void> setFullScreen(bool fullScreen) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      final win = _currentNativeWindow();
      if (win != null) {
        win.isFullScreen = fullScreen;
      }
      await Window.hideWindowControls();
    } catch (error) {
      developer.log(
        '可恢复异常已记录',
        name: 'konata.windows_composition_root',
        error: error,
      );
    }
  }

  @override
  Future<void> startDragging() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      _currentNativeWindow()?.startDragging();
    } catch (error) {
      developer.log(
        '可恢复异常已记录',
        name: 'konata.windows_composition_root',
        error: error,
      );
    }
  }

  @override
  Future<void> toggleMaximize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      final win = _currentNativeWindow();
      if (win != null) {
        if (win.isMaximized) {
          win.unmaximize();
        } else {
          win.maximize();
        }
      }
      await Window.hideWindowControls();
    } catch (error) {
      developer.log(
        '可恢复异常已记录',
        name: 'konata.windows_composition_root',
        error: error,
      );
    }
  }

  @override
  bool get supportsAlwaysOnTopMiniWindow =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  Future<void> enterAlwaysOnTopMiniWindow({
    required Size targetSize,
    required Size minimumSize,
  }) async {
    if (!supportsAlwaysOnTopMiniWindow) return;
    try {
      final win = _currentNativeWindow();
      if (win == null) return;
      if (!_inAlwaysOnTopMiniWindow) {
        _savedNormalFullScreen = win.isFullScreen;
        _savedNormalMaximized = win.isMaximized;
        if (win.isFullScreen) {
          win.isFullScreen = false;
        }
        if (win.isMaximized) {
          win.unmaximize();
        }
        final currentBounds = win.bounds.toRect();
        _savedNormalBounds =
            (currentBounds.width >= 600 && currentBounds.height >= 400)
            ? currentBounds
            : KonataPlaybackTokens.desktopNormalWindowFallbackBounds;
        _inAlwaysOnTopMiniWindow = true;
      }

      win.minimumSize = wm.SizeToNative(minimumSize).toNative();
      win.setSize(wm.SizeToNative(targetSize).toNative(), false);
      final saved =
          _savedNormalBounds ??
          KonataPlaybackTokens.desktopNormalWindowFallbackBounds;
      final desiredOrigin =
          _lastMiniWindowOrigin ??
          Offset(
            (saved.right -
                    targetSize.width -
                    KonataPlaybackTokens.desktopAlwaysOnTopMiniEdgeOffset)
                .clamp(0.0, double.infinity),
            (saved.bottom -
                    targetSize.height -
                    KonataPlaybackTokens.desktopAlwaysOnTopMiniEdgeOffset)
                .clamp(0.0, double.infinity),
          );
      win.position = wm.OffsetToNative(desiredOrigin).toNative();
      win.isAlwaysOnTop = true;
      await Window.hideWindowControls();
    } catch (error) {
      developer.log(
        '进入桌面置顶迷你窗失败，已忽略并保持当前窗口态',
        name: 'konata.windows_composition_root',
        error: error,
      );
    }
  }

  @override
  Future<void> exitAlwaysOnTopMiniWindow() async {
    if (!supportsAlwaysOnTopMiniWindow || !_inAlwaysOnTopMiniWindow) return;
    try {
      final win = _currentNativeWindow();
      if (win != null) {
        _lastMiniWindowOrigin = win.position.toOffset();
        win.isAlwaysOnTop = false;
        win.minimumSize = wm.SizeToNative(
          KonataPlaybackTokens.desktopNormalWindowMinSize,
        ).toNative();
        final restoreBounds =
            _savedNormalBounds ??
            KonataPlaybackTokens.desktopNormalWindowFallbackBounds;
        win.bounds = wm.RectToNative(restoreBounds).toNative();
        if (_savedNormalMaximized) {
          win.maximize();
        }
        if (_savedNormalFullScreen) {
          win.isFullScreen = true;
        }
      }
      await Window.hideWindowControls();
    } catch (error) {
      developer.log(
        '还原桌面主窗口边界失败，已尝试恢复置顶态',
        name: 'konata.windows_composition_root',
        error: error,
      );
    } finally {
      _inAlwaysOnTopMiniWindow = false;
      _savedNormalMaximized = false;
      _savedNormalFullScreen = false;
    }
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
    return wm.DragToMoveArea(child: child);
  }
}

/// Windows 专属应用组装根（同时保持对 `integration_test` 跨端默认入口的 100% 兼容）。
class WindowsCompositionRoot {
  const WindowsCompositionRoot._();

  /// 返回 Windows 桌面端所需的全部 Riverpod 能力覆写集合。
  static List<Override> providerOverrides({
    StorageRootService? storageRoot,
    WindowMaterialController? materialController,
  }) {
    return <Override>[
      if (storageRoot != null) storageRootProvider.overrideWithValue(storageRoot),
      if (materialController != null)
        windowMaterialControllerProvider.overrideWithValue(materialController),
      konataWindowHostProvider.overrideWith(
        (ref) => WindowsKonataWindowHost(
          materialController: ref.watch(windowMaterialControllerProvider),
        ),
      ),
      konataVideoBridgeFactoryProvider.overrideWithValue(
        () => D3D11VideoBridge(),
      ),
      mpvPlatformProfileDelegateProvider.overrideWithValue(
        const WindowsMpvProfileDelegate(),
      ),
      desktopRelayGatewayProvider.overrideWith((ref) {
        final store = ref.watch(desktopExternalPlayerStoreProvider);
        final bridge = ref.watch(localStreamBridgeProvider);
        final factory = ref.watch(mediaSourceGatewayFactoryProvider);
        final launcher = RealExternalPlayerLauncher(
          streamBridge: bridge,
          gatewayFactory: factory,
        );
        return WindowsDesktopRelayGateway(store: store, launcher: launcher);
      }),
      platformHwdecSubtitleProvider.overrideWithValue(
        '自动启用 D3D11VA 硬件加速，遇异常源自动软解兜底',
      ),
      platformExclusiveAudioTitleProvider.overrideWithValue(
        'WASAPI 音频独占模式',
      ),
      platformExclusiveAudioSheetTitleProvider.overrideWithValue(
        'WASAPI 独占直通',
      ),
      platformBitstreamTitleProvider.overrideWithValue('HDMI / S/PDIF 源码透传'),
      desktopExternalToolsPanelBuilderProvider.overrideWithValue(
        (_) => const SettingsExternalToolsPanel(),
      ),
      desktopTopNavBarBuilderProvider.overrideWithValue(
        ({
          required activeSection,
          required onSectionChanged,
          required searchQuery,
          required onSearchChanged,
          required searchFocusNode,
          required searchExpanded,
          required onSearchExpandedChanged,
          required onToggleTheme,
        }) => TopNavBar(
          activeSection: activeSection,
          onSectionChanged: onSectionChanged,
          searchQuery: searchQuery,
          onSearchChanged: onSearchChanged,
          searchFocusNode: searchFocusNode,
          searchExpanded: searchExpanded,
          onSearchExpandedChanged: onSearchExpandedChanged,
          onToggleTheme: onToggleTheme,
        ),
      ),
      legacyCodePageDecoderProvider.overrideWithValue(
        WindowsCodePageDecoder.decode,
      ),
      konataUiImageCacheTrimmerProvider.overrideWithValue(
        () => PaintingBinding.instance.imageCache.clear(),
      ),
      konataNativeMemoryTrimmerProvider.overrideWithValue(
        D3D11VideoBridge.trimSystemMemory,
      ),
    ];
  }

  /// 初始化 Windows 透明无框窗口并启动 Konata 根应用。
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.maximumSizeBytes =
        KonataMemoryCoordinator.desktopImageCacheMaxBytes;
    imageCache.maximumSize =
        KonataMemoryCoordinator.desktopImageCacheMaxEntries;
    final appWindowTitle = KonataLaneConfig.resolveDesktopWindowTitle();

    final materialController = WindowMaterialController();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await Window.initialize();
      await Window.hideWindowControls();
      wm.Window? nativeWin;
      try {
        nativeWin = wm.WindowManager.instance.getCurrent();
      } catch (error) {
        developer.log(
          '可恢复异常已记录',
          name: 'konata.windows_composition_root',
          error: error,
        );
      }
      if (nativeWin != null) {
        nativeWin.titleBarStyle = wm.TitleBarStyle.hidden;
        nativeWin.isWindowControlButtonsVisible = false;
        nativeWin.backgroundColor = wm.ColorToNative(
          Colors.transparent,
        ).toNative();
        if (nativeWin.isFullScreen) {
          nativeWin.isFullScreen = false;
        }
        if (nativeWin.isMaximized) {
          nativeWin.unmaximize();
        }
        if (nativeWin.isMinimized) {
          nativeWin.restore();
        }
        nativeWin.setSize(
          wm.SizeToNative(const Size(1360, 820)).toNative(),
          false,
        );
        nativeWin.minimumSize = wm.SizeToNative(
          const Size(960, 620),
        ).toNative();
        nativeWin.center();
        nativeWin.title = appWindowTitle;
      }
      await materialController.apply(
        themeMode: ThemeMode.dark,
        platformBrightness:
            WidgetsBinding.instance.platformDispatcher.platformBrightness,
        material: KonataWindowMaterial.acrylic,
      );
      if (nativeWin != null) {
        nativeWin.title = appWindowTitle;
      }
      await Window.hideWindowControls();
      nativeWin?.show();
      nativeWin?.focus();
    }

    runApp(
      ProviderScope(
        retry: konataNoProviderRetry,
        overrides: providerOverrides(materialController: materialController),
        child: const KonataApp(),
      ),
    );
  }
}
