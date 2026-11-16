import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'application/playback/playback_preferences_provider.dart';
import 'application/providers/theme_providers.dart';
import 'presentation/audio/mini_audio_bar.dart';
import 'presentation/shell/desktop_shell.dart';
import 'presentation/theme/konata_theme.dart';
import 'presentation/theme/window_material_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    await Window.initialize();
    await Window.hideWindowControls();
    await windowManager.ensureInitialized();
    await windowManager.setBackgroundColor(Colors.transparent);
    const options = WindowOptions(
      size: Size(1360, 820),
      minimumSize: Size(960, 620),
      center: true,
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
      await Window.hideWindowControls();
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: KonataApp()));
}

/// Konata 全局桌面滚动行为：支持多指针拖拽并禁用框架隐式自动套壳的不可控默认滚动条，
/// 确保所有列表与网格由显式绑定独立 `ScrollController` 的 `KonataDraggableScrollbar` 统一管理。
class KonataScrollBehavior extends MaterialScrollBehavior {
  /// 创建 Konata 全局滚动行为。
  const KonataScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

/// Konata 根应用组件（Windows 11 DWM 原生材质穿透 + 亮/暗双主题）。
class KonataApp extends ConsumerWidget {
  /// 创建根应用组件。
  const KonataApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final windowMaterial = ref.watch(windowMaterialProvider);
    final platformBrightness = MediaQuery.platformBrightnessOf(context);

    // 联动同步亮/暗主题与窗口材质至系统 DWM 合成层
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WindowMaterialController.apply(
        themeMode: themeMode,
        platformBrightness: platformBrightness,
        material: windowMaterial,
      );
    });

    return MaterialApp(
      navigatorKey: ref.watch(rootNavigatorKeyProvider),
      title: 'Konata',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const KonataScrollBehavior(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: themeMode,
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      builder: (context, child) =>
          MiniAudioOverlayHost(child: child ?? const SizedBox.shrink()),
      home: const DesktopShell(),
    );
  }
}
