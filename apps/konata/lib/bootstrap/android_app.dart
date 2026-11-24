import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'app_bootstrap.dart';
import 'host_storage_adapters.dart';

/// 启动 Konata v3 Android 专用极薄组装壳（严禁引入任何桌面端插件与 Win32 依赖）。
///
/// 根据当前屏幕最短边自动识别手机（`< 600dp`）或平板（`>= 600dp`）形态，
/// 并将 `ApplicationSupportDirectory` 注入纯 Dart 存储底座。
Future<void> runAndroidKonataApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  final platform = _detectAndroidFormFactor();
  final storageRoot = await createAndroidStorageRoot();
  final bootstrap = await KonataBootstrapContext.initialize(
    platform: platform,
    storageRoot: storageRoot,
    secureStorage: const FlutterSecureStorageAdapter(),
  );

  runApp(
    KonataBootstrapApp(
      bootstrap: bootstrap,
      platformLabel: platform == KonataPlatform.androidTablet
          ? 'Android 平板'
          : 'Android 手机',
    ),
  );
}

KonataPlatform _detectAndroidFormFactor() {
  final views = ui.PlatformDispatcher.instance.views;
  if (views.isEmpty) {
    return KonataPlatform.androidPhone;
  }
  final view = views.first;
  final dpr = view.devicePixelRatio;
  if (dpr <= 0) {
    return KonataPlatform.androidPhone;
  }
  final logicalSize = view.physicalSize / dpr;
  return logicalSize.shortestSide >= 600
      ? KonataPlatform.androidTablet
      : KonataPlatform.androidPhone;
}
