import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../application/providers/playback_providers.dart';
import '../application/providers/theme_providers.dart';
import '../domain/config/konata_lane_config.dart';
import '../infrastructure/players/d3d11_video_bridge.dart';
import '../infrastructure/players/real_external_player_launcher.dart';
import '../infrastructure/players/windows_code_page_decoder.dart';
import '../infrastructure/storage/storage_root_provider.dart';
import '../presentation/app/konata_app.dart';
import '../presentation/settings/settings_external_tools_panel.dart';
import '../presentation/shell/top_nav_bar.dart';
import '../presentation/shell/window_controls.dart';
import '../presentation/theme/window_material_controller.dart';
import 'platform_composition.dart';

/// Windows 桌面窗口宿主实现（收口 `flutter_acrylic` 与 `window_manager` 全部调用）。
class WindowsKonataWindowHost implements KonataWindowHost {
  /// 创建 Windows 窗口宿主。
  const WindowsKonataWindowHost();

  @override
  Future<void> applyMaterial({
    required ThemeMode themeMode,
    required Brightness platformBrightness,
    required KonataWindowMaterial material,
    bool force = false,
  }) {
    return WindowMaterialController.apply(
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
    } catch (_) {}
  }

  @override
  Future<bool> isFullScreen() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return false;
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setFullScreen(bool fullScreen) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await windowManager.setFullScreen(fullScreen);
      await Window.hideWindowControls();
    } catch (_) {}
  }

  @override
  Future<void> startDragging() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await windowManager.startDragging();
    } catch (_) {}
  }

  @override
  Future<void> toggleMaximize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
      await Window.hideWindowControls();
    } catch (_) {}
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
    return DragToMoveArea(child: child);
  }
}

/// Windows 专属应用组装根（同时保持对 `integration_test` 跨端默认入口的 100% 兼容）。
class WindowsCompositionRoot {
  const WindowsCompositionRoot._();

  /// 返回 Windows 桌面端所需的全部 Riverpod 能力覆写集合。
  static List<Override> providerOverrides({StorageRootService? storageRoot}) {
    return <Override>[
      if (storageRoot != null) storageRootProvider.overrideWithValue(storageRoot),
      konataWindowHostProvider.overrideWithValue(
        const WindowsKonataWindowHost(),
      ),
      konataVideoBridgeFactoryProvider.overrideWithValue(
        () => D3D11VideoBridge(),
      ),
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
      externalPlayerLauncherProvider.overrideWith((ref) {
        final bridge = ref.watch(localStreamBridgeProvider);
        final factory = ref.watch(mediaSourceGatewayFactoryProvider);
        return RealExternalPlayerLauncher(
          streamBridge: bridge,
          gatewayFactory: factory,
        );
      }),
      legacyCodePageDecoderProvider.overrideWithValue(
        WindowsCodePageDecoder.decode,
      ),
    ];
  }

  /// 初始化 Windows 透明无框窗口并启动 Konata 根应用。
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    final appWindowTitle = KonataLaneConfig.resolveDesktopWindowTitle();

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await Window.initialize();
      await Window.hideWindowControls();
      await windowManager.ensureInitialized();
      await windowManager.setBackgroundColor(Colors.transparent);
      final options = WindowOptions(
        size: const Size(1360, 820),
        minimumSize: const Size(960, 620),
        center: true,
        title: appWindowTitle,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
        backgroundColor: Colors.transparent,
      );
      await windowManager.waitUntilReadyToShow(options, () async {
        await WindowMaterialController.apply(
          themeMode: ThemeMode.dark,
          platformBrightness:
              WidgetsBinding.instance.platformDispatcher.platformBrightness,
          material: KonataWindowMaterial.acrylic,
        );
        await windowManager.setTitle(appWindowTitle);
        await Window.hideWindowControls();
        await windowManager.show();
        await windowManager.focus();
      });
    }

    runApp(
      ProviderScope(
        overrides: providerOverrides(),
        child: const KonataApp(),
      ),
    );
  }
}
