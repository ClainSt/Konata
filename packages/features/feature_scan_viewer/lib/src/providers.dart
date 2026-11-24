import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/scan_lightbox_loader.dart';
import 'data/scan_thumbnail_scheduler.dart';

/// 可选桌面窗口全屏控制端口（由应用壳按需注入，避免业务切片依赖桌面原生插件）。
abstract interface class ScanWindowFullscreenPort {
  /// 查询当前应用窗口是否已处于全屏态。
  Future<bool> isFullScreen();

  /// 切换应用窗口全屏态。
  Future<void> setFullScreen(bool enable);
}

/// `feature_scan_viewer` 纵向业务包唯一外部依赖契约容器（由应用壳在顶层 `ProviderScope` 覆盖注入）。
final class FeatureScanViewerDependencies {
  /// 创建扫图画廊依赖容器。
  const FeatureScanViewerDependencies({
    required this.databases,
    required this.storageRoot,
    required this.diagnosticLog,
    required this.scopedPrefs,
    required this.gatewayFactory,
    required this.photosStorage,
    required this.platform,
    this.customStreamOpener,
    this.urlOpener = const NoopUrlOpenerPort(),
    this.windowFullscreen,
  });

  /// 三库物理分治生命周期总管（用于只读查询作品、扫图变体与媒体源配置）。
  final KonataDatabaseBundle databases;

  /// 跨端存储根目录解析端口。
  final StorageRootPort storageRoot;

  /// 脱敏结构化诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 分命名空间自治配置存储器（持久化画廊模式与视图密度）。
  final ScopedPrefsStore scopedPrefs;

  /// 只读媒体源网关工厂。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 作品图片与扫图微缩图存储管理器（仅写入 `photos/<作品>/scans/*.webp`）。
  final PhotosStorage photosStorage;

  /// 当前宿主运行平台形态。
  final KonataPlatform platform;

  /// 可选自定义扫图原图流读取回调（主要供离线测试或宿主代理复用）。
  final ScanSourceStreamOpener? customStreamOpener;

  /// 跨平台外部看图打开端口。
  final UrlOpenerPort urlOpener;

  /// 可选桌面窗口全屏控制端口。
  final ScanWindowFullscreenPort? windowFullscreen;
}

/// 扫图画廊业务包核心依赖注入 Provider（必须由宿主壳在顶层 `ProviderScope` 中覆写）。
final featureScanViewerDependenciesProvider =
    Provider<FeatureScanViewerDependencies>((ref) {
      throw UnimplementedError(
        'featureScanViewerDependenciesProvider 必须由宿主启动壳覆盖注入',
      );
    });

/// 扫图三级按源并发微缩图调度器 Provider（随容器释放自动中止在途流）。
final scanThumbnailSchedulerProvider = Provider<ScanThumbnailScheduler>((ref) {
  final deps = ref.watch(featureScanViewerDependenciesProvider);
  final scheduler = ScanThumbnailScheduler(
    photosStorage: deps.photosStorage,
    gatewayFactory: deps.gatewayFactory,
    streamOpener: deps.customStreamOpener,
    diagnosticLog: deps.diagnosticLog,
  );
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

/// 扫图高清原图只读流式加载器 Provider（严格零原图落盘）。
final scanLightboxLoaderProvider = Provider<ScanLightboxLoader>((ref) {
  final deps = ref.watch(featureScanViewerDependenciesProvider);
  return ScanLightboxLoader(
    gatewayFactory: deps.gatewayFactory,
    diagnosticLog: deps.diagnosticLog,
    streamOpener: deps.customStreamOpener,
  );
});
