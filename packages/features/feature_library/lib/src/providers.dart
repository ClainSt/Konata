import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'state/library_controller.dart';
import 'state/work_management_controller.dart';

/// 图像按需字节加载回调类型（供 `ManagedImage` 统一接入缓存与网络）。
typedef LibraryArtworkLoader = ArtworkByteLoader;

/// `feature_library` 对宿主及集成测试暴露的显式依赖集合。
final class FeatureLibraryDependencies {
  /// 构造媒体库业务包依赖容器。
  const FeatureLibraryDependencies({
    required this.databases,
    required this.storageRoot,
    required this.diagnosticLog,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.navigator,
    required this.httpClient,
    required this.photosStorage,
    required this.artworkCache,
    required this.platform,
    this.artworkLoader,
  });

  /// 三库合一持久化门面。
  final KonataDatabaseBundle databases;

  /// 应用便携根路径服务。
  final StorageRootPort storageRoot;

  /// 结构化诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 分作用域配置存储（保存排序及筛选项）。
  final ScopedPrefsStore scopedPrefs;

  /// 跨模块低频领域事件总线。
  final DomainEventBus domainEventBus;

  /// 全局导航动作抽象接口。
  final AppNavigator navigator;

  /// 受控 HTTP 客户端端口（供网络海报/剧照及手动纠偏检索使用）。
  final KonataHttpClientPort httpClient;

  /// 本机 `photos/` 艺术图存储服务。
  final PhotosStorage photosStorage;

  /// 统一图像磁盘缓存服务。
  final ArtworkCacheStore artworkCache;

  /// 当前宿主运行平台形态。
  final KonataPlatform platform;

  /// 宿主共享的图片加载能力。
  final ArtworkByteLoader? artworkLoader;
}

/// 媒体库依赖注入根 `Provider`（必须由宿主 `ProviderScope` 覆盖提供）。
final featureLibraryDependenciesProvider = Provider<FeatureLibraryDependencies>(
  (ref) {
    throw UnimplementedError(
      'featureLibraryDependenciesProvider 必须由宿主 ProviderScope 注入覆盖',
    );
  },
);

/// 由宿主连接至详情模块的作品管理弹窗端口。
final workManageDialogPortProvider = Provider<WorkManageDialogPort?>(
  (ref) => null,
);

/// 媒体库主海报墙与待复核队列状态控制器 `Provider`。
final libraryControllerProvider = Provider<LibraryController>((ref) {
  final deps = ref.watch(featureLibraryDependenciesProvider);
  final controller = LibraryController(
    databases: deps.databases,
    scopedPrefs: deps.scopedPrefs,
    eventBus: deps.domainEventBus,
    diagnosticLog: deps.diagnosticLog,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// 作品隐藏、软删除、合并与手工匹配纠偏控制器 `Provider`。
final workManagementControllerProvider = Provider<WorkManagementController>((
  ref,
) {
  final deps = ref.watch(featureLibraryDependenciesProvider);
  return WorkManagementController(
    databases: deps.databases,
    storageRoot: deps.storageRoot,
    scopedPrefs: deps.scopedPrefs,
    eventBus: deps.domainEventBus,
    httpClient: deps.httpClient,
    photosStorage: deps.photosStorage,
    diagnosticLog: deps.diagnosticLog,
  );
});

/// 供 `ManagedImage` 使用的封面/剧照字节异步加载器 `Provider`。
///
/// 优先命中 `ArtworkCacheStore` 或本机 `photos/` 缓存目录，未命中时回落受控 `TmdbService` 拉取并回写。
final libraryArtworkLoaderProvider = Provider<LibraryArtworkLoader>((ref) {
  final deps = ref.watch(featureLibraryDependenciesProvider);
  return deps.artworkLoader ??
      createArtworkByteLoader(
        httpClient: deps.httpClient,
        artworkCache: deps.artworkCache,
      );
});
