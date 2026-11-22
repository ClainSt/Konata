import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers/konata_value_notifier.dart';
import '../application/providers/memory_coordinator.dart';
import '../infrastructure/network/android_system_proxy_flutter.dart';
import '../infrastructure/storage/storage_root_provider.dart';
import '../presentation/app/konata_app.dart';
import 'platform_composition.dart';

/// Android 专属应用组装根（零桌面插件、零 Win32、零外部播放器与 D3D11 静态依赖）。
class AndroidCompositionRoot {
  const AndroidCompositionRoot._();

  /// 启动 Android 端根应用并注入应用专属存储根路径与 Android 系统代理通道。
  static Future<void> run() async {
    WidgetsFlutterBinding.ensureInitialized();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.maximumSizeBytes =
        KonataMemoryCoordinator.androidImageCacheMaxBytes;
    imageCache.maximumSize =
        KonataMemoryCoordinator.androidImageCacheMaxEntries;
    final storageRoot = await StorageRootService.createForCurrentPlatform();
    runApp(
      ProviderScope(
        retry: konataNoProviderRetry,
        overrides: [
          storageRootProvider.overrideWithValue(storageRoot),
          systemProxyResolverProvider.overrideWithValue(
            queryPlatformAndroidSystemProxy,
          ),
          konataUiImageCacheTrimmerProvider.overrideWithValue(
            () => PaintingBinding.instance.imageCache.clear(),
          ),
        ],
        child: const KonataApp(),
      ),
    );
  }
}
