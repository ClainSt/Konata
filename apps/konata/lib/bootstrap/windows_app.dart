import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:window_manager/window_manager.dart' as wm;

import 'app_bootstrap.dart';
import 'host_storage_adapters.dart';
import 'windows_platform_bridges.dart';

/// 启动 Konata v3 Windows 桌面端极薄组装壳。
///
/// 严格执行 Windows 纯绿色便携目录规则（零写 C 盘系统用户目录）、桌面原生渲染桥接与编译期车道标题隔离。
Future<void> runWindowsKonataApp() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  );

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    final title = KonataLaneConfig.resolveDesktopWindowTitle();
    try {
      final nativeWin = wm.WindowManager.instance.getCurrent();
      if (nativeWin != null) {
        nativeWin.title = title;
      }
    } catch (error, stackTrace) {
      bootstrap.diagnosticLog.logError(
        subsystem: DiagnosticSubsystem.window,
        code: 'WIN_TITLE_INIT_SKIPPED',
        message: '设置桌面窗口初始标题失败，已回退默认标题',
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
    ),
  );
}
