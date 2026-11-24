import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'state/source_scrape_controller.dart';
import 'state/sources_controller.dart';

/// `feature_sources` 对宿主及集成测试暴露的显式依赖集合。
final class FeatureSourcesDependencies {
  /// 构造媒体源业务包依赖对象。
  const FeatureSourcesDependencies({
    required this.databases,
    required this.storageRoot,
    required this.secureStorage,
    required this.diagnosticLog,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.navigator,
    required this.filePicker,
    required this.httpClient,
    required this.gatewayFactory,
    required this.photosStorage,
    required this.platform,
  });

  /// 三库合一持久化门面（主媒体库 + 用户态 + 缓存）。
  final KonataDatabaseBundle databases;

  /// 应用便携根路径服务。
  final StorageRootPort storageRoot;

  /// 受保护的系统级凭据存储。
  final SecureStoragePort secureStorage;

  /// 结构化诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 分作用域配置存储。
  final ScopedPrefsStore scopedPrefs;

  /// 低频跨模块领域事件总线。
  final DomainEventBus domainEventBus;

  /// 全局导航动作抽象接口。
  final AppNavigator navigator;

  /// 跨端系统文件与目录选择器端口。
  final FilePickerPort filePicker;

  /// 受控 HTTP 客户端端口（含网络凭据与代理配置）。
  final KonataHttpClientPort httpClient;

  /// 跨协议只读媒体源网关工厂。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 本机艺术图管理存储。
  final PhotosStorage photosStorage;

  /// 当前运行平台类型（桌面 / 手机 / 平板）。
  final KonataPlatform platform;
}

/// 媒体源业务包依赖注入根 `Provider`（必须由宿主 `ProviderScope` 覆盖提供）。
final featureSourcesDependenciesProvider =
    Provider<FeatureSourcesDependencies>((ref) {
      throw UnimplementedError(
        'featureSourcesDependenciesProvider 必须由宿主 ProviderScope 注入覆盖',
      );
    });

/// 媒体源受保护凭据仓储 `Provider`。
final sourceCredentialStoreProvider = Provider<SourceCredentialStore>((ref) {
  final deps = ref.watch(featureSourcesDependenciesProvider);
  return SourceCredentialStore(storage: deps.secureStorage);
});

/// 媒体源管理核心控制器 `Provider`。
final sourcesControllerProvider = Provider<SourcesController>((ref) {
  final deps = ref.watch(featureSourcesDependenciesProvider);
  final credentials = ref.watch(sourceCredentialStoreProvider);
  final controller = SourcesController(
    databases: deps.databases,
    credentialStore: credentials,
    gatewayFactory: deps.gatewayFactory,
    eventBus: deps.domainEventBus,
    scopedPrefs: deps.scopedPrefs,
    diagnosticLog: deps.diagnosticLog,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// 扫库与刮削任务编排控制器 `Provider`。
final sourceScrapeControllerProvider = Provider<SourceScrapeController>((ref) {
  final deps = ref.watch(featureSourcesDependenciesProvider);
  final controller = SourceScrapeController(
    databases: deps.databases,
    storageRoot: deps.storageRoot,
    scopedPrefs: deps.scopedPrefs,
    eventBus: deps.domainEventBus,
    httpClient: deps.httpClient,
    gatewayFactory: deps.gatewayFactory,
    photosStorage: deps.photosStorage,
    diagnosticLog: deps.diagnosticLog,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// 实时订阅全部未删除媒体源列表的响应式流 `Provider`。
final mediaSourcesStreamProvider = StreamProvider<List<MediaSource>>((ref) {
  final controller = ref.watch(sourcesControllerProvider);
  return controller.watchSources();
});

/// 查询指定媒体源下全部忽略目录列表的响应式流 `Provider`。
final ignoredFoldersStreamProvider =
    StreamProvider.family<List<String>, String>((ref, sourceId) {
      final controller = ref.watch(sourcesControllerProvider);
      return controller.watchIgnoredFolders(sourceId);
    });
