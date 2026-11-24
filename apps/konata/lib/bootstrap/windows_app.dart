import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:window_manager/window_manager.dart' as wm;

import 'app_bootstrap.dart';
import 'feature_registry.dart';
import 'host_storage_adapters.dart';
import 'windows_platform_bridges.dart';
import 'windows_window_host.dart';

/// 启动 Konata v3 Windows 桌面端极薄组装壳。
///
/// 严格执行 Windows 纯绿色便携目录规则（零写 C 盘系统用户目录）、无框 DWM 亚克力/云母透光窗口初始化、
/// 桌面原生渲染与外部播放器接力桥接以及编译期车道标题隔离。
Future<void> runWindowsKonataApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端合理收紧首帧内存图片缓存配额，兼顾大海报墙丝滑滚屏与内存占用控制。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 2000;

  final storageRoot = createWindowsStorageRoot();
  const filePicker = HostFilePickerAdapter();
  final bootstrap = await KonataBootstrapContext.initialize(
    platform: KonataPlatform.windows,
    storageRoot: storageRoot,
    secureStorage: const FlutterSecureStorageAdapter(),
    filePicker: filePicker,
    backupFilePort: filePicker,
    hostWindow: WindowsPlaybackWindowAdapter(),
    desktopSurfaceBridge: WindowsD3d11VideoBridge(),
    externalPlayerStoreBuilder: createWindowsExternalPlayerStore,
    desktopRelayGatewayBuilder: createWindowsDesktopRelayGateway,
    desktopProfileDelegate: createWindowsMpvProfileDelegate(),
    legacyCodePageDecoder: windowsLegacyCodePageDecoder,
    pickExecutableFile: filePicker.pickExecutableFile,
    pickShaderFiles: filePicker.pickShaderFiles,
  );

  final windowHost = WindowsWindowHost();
  final initialAppearance = readInitialAppearancePrefs(bootstrap.scopedPrefs);

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    final title = KonataLaneConfig.resolveDesktopWindowTitle();
    try {
      await Window.initialize();
      await Window.hideWindowControls();
      wm.Window? nativeWin;
      try {
        nativeWin = wm.WindowManager.instance.getCurrent();
      } catch (error, stackTrace) {
        bootstrap.diagnosticLog.logError(
          subsystem: DiagnosticSubsystem.window,
          code: 'WIN_HANDLE_RESOLVE_FAILED',
          message: '获取原生桌面窗口句柄失败，已跳过无框窗口属性设置',
          error: error,
          stackTrace: stackTrace,
          severity: DiagnosticSeverity.warn,
          source: 'apps/konata/lib/bootstrap/windows_app.dart:runWindowsKonataApp',
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
          KonataPlaybackTokens.desktopNormalWindowMinSize,
        ).toNative();
        nativeWin.center();
        nativeWin.title = title;
      }

      await windowHost.applyMaterial(
        themeMode: initialAppearance.themeMode,
        platformBrightness:
            WidgetsBinding.instance.platformDispatcher.platformBrightness,
        material: initialAppearance.windowMaterial,
        force: true,
      );
      if (nativeWin != null) {
        nativeWin.title = title;
      }
      await Window.hideWindowControls();
      nativeWin?.show();
      nativeWin?.focus();
    } catch (error, stackTrace) {
      bootstrap.diagnosticLog.logError(
        subsystem: DiagnosticSubsystem.window,
        code: 'WIN_CHROME_INIT_SKIPPED',
        message: '初始化桌面无框 DWM 窗口壳层失败，已降级默认窗口呈现',
        error: error,
        stackTrace: stackTrace,
        severity: DiagnosticSeverity.warn,
        source: 'apps/konata/lib/bootstrap/windows_app.dart:runWindowsKonataApp',
      );
    }
  }

  runApp(
    KonataBootstrapApp(
      bootstrap: bootstrap,
      platformLabel: 'Windows',
      windowHost: windowHost,
    ),
  );
}
