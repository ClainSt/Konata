import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/theme_providers.dart';
import '../../composition/platform_composition.dart';
import '../../domain/config/konata_lane_config.dart';
import '../audio/mini_audio_bar.dart';
import '../shell/adaptive_capsule_layout.dart';
import '../shell/android_scroll_capture_bridge.dart';
import '../shell/desktop_shell.dart';
import '../theme/konata_theme.dart';

/// Konata 全局多端滚动行为：支持多指针拖拽并禁用隐式默认滚动条，
/// 确保全站滚动视图统一由显式绑定独立 `ScrollController` 的 `KonataDraggableScrollbar` 托管。
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

/// Konata 跨端共享根应用组件（通过组装根注入窗口宿主，确保 Android 零桌面依赖）。
class KonataApp extends ConsumerWidget {
  /// 创建根应用组件。
  const KonataApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final windowHost = ref.watch(konataWindowHostProvider);
    if (windowHost is! NoopKonataWindowHost) {
      final windowMaterial = ref.watch(windowMaterialProvider);
      final platformBrightness = MediaQuery.platformBrightnessOf(context);
      // 仅在桌面宿主启用时联动同步亮/暗主题与窗口材质，Android 零额外监听与帧回调开销。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        windowHost.applyMaterial(
          themeMode: themeMode,
          platformBrightness: platformBrightness,
          material: windowMaterial,
        );
      });
    }

    final navKey = ref.watch(rootNavigatorKeyProvider);
    final routeObserver = ref.watch(rootRouteObserverProvider);
    final appTitle = KonataLaneConfig.resolveDesktopWindowTitle();

    return MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [routeObserver],
      title: appTitle,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const KonataScrollBehavior(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: themeMode,
      theme: ref.watch(konataLightThemeProvider),
      darkTheme: ref.watch(konataDarkThemeProvider),
      builder: (context, child) => AndroidScrollCaptureScope(
        navigatorKey: navKey,
        child: MiniAudioOverlayHost(child: child ?? const SizedBox.shrink()),
      ),
      home: const DesktopShell(),
    );
  }
}
