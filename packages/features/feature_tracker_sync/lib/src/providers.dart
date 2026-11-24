import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/bangumi_sync_client.dart';
import 'data/bangumi_sync_config_store.dart';
import 'data/bangumi_tracker_provider.dart';
import 'state/tracker_sync_coordinator.dart';

/// 追番进度同步模块的运行时依赖集合（由宿主应用在根作用域注入）。
final class FeatureTrackerSyncDependencies {
  /// 创建追番进度同步模块依赖容器。
  const FeatureTrackerSyncDependencies({
    required this.databases,
    required this.secureStorage,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.diagnosticLog,
    required this.httpClient,
    required this.urlOpener,
    required this.platform,
    this.rawHttpClientOverride,
    this.additionalProviders = const <ProgressTrackerProvider>[],
    this.subjectResolver,
    this.autoFlushOnEvent = true,
    this.autoFlushInterval,
  });

  /// 本地三库持久化集合。
  final KonataDatabaseBundle databases;

  /// 系统安全凭据存储端口（PAT 仅存此处）。
  final SecureStoragePort secureStorage;

  /// 作用域偏好配置仓库。
  final ScopedPrefsStore scopedPrefs;

  /// 领域事件总线。
  final DomainEventBus domainEventBus;

  /// 脱敏诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 统一 HTTP 客户端端口。
  final KonataHttpClientPort httpClient;

  /// 外部链接打开端口。
  final UrlOpenerPort urlOpener;

  /// 当前运行平台分类。
  final KonataPlatform platform;

  /// 测试场景可注入的底层 `http.Client`。
  final http.Client? rawHttpClientOverride;

  /// 额外扩展挂载的追番同步提供者列表。
  final List<ProgressTrackerProvider> additionalProviders;

  /// 可选的多平台外部条目编号映射解析器。
  final TrackerSubjectResolver? subjectResolver;

  /// 收到完播事件后是否立即尝试推送。
  final bool autoFlushOnEvent;

  /// 可选后台定时补推轮询周期。
  final Duration? autoFlushInterval;
}

/// 追番同步模块宿主依赖注入入口；必须在根 `ProviderScope` 覆盖。
final featureTrackerSyncDependenciesProvider =
    Provider<FeatureTrackerSyncDependencies>((ref) {
      throw UnimplementedError(
        '必须在宿主根 ProviderScope 覆盖 featureTrackerSyncDependenciesProvider',
      );
    });

/// 供模块静态清单使用的 Bangumi 延迟代理提供者单例。
final DelegatingBangumiTrackerProvider manifestBangumiTrackerProvider =
    DelegatingBangumiTrackerProvider();

/// Bangumi 配置与 PAT 安全仓库提供者。
final bangumiSyncConfigStoreProvider = Provider<BangumiSyncConfigStore>((ref) {
  final deps = ref.watch(featureTrackerSyncDependenciesProvider);
  return BangumiSyncConfigStore(
    scopedPrefs: deps.scopedPrefs,
    secureStorage: deps.secureStorage,
    syncMetaDao: deps.databases.userState.syncMeta,
  );
});

/// Bangumi 官方直连客户端提供者。
final bangumiSyncClientProvider = Provider<BangumiSyncClient>((ref) {
  final deps = ref.watch(featureTrackerSyncDependenciesProvider);
  final client = BangumiSyncClient(
    httpClientPort: deps.rawHttpClientOverride == null ? deps.httpClient : null,
    httpClient: deps.rawHttpClientOverride,
    diagnosticLog: deps.diagnosticLog,
  );
  ref.onDispose(client.close);
  return client;
});

/// Bangumi 追番提供者适配器提供者。
final bangumiTrackerProvider = Provider<BangumiTrackerProvider>((ref) {
  final configStore = ref.watch(bangumiSyncConfigStoreProvider);
  final client = ref.watch(bangumiSyncClientProvider);
  final provider = BangumiTrackerProvider(
    configStore: configStore,
    client: client,
  );
  manifestBangumiTrackerProvider.bind(provider);
  ref.onDispose(() => manifestBangumiTrackerProvider.unbind(provider));
  return provider;
});

/// 多平台追番同步协调器提供者。
final trackerSyncCoordinatorProvider = Provider<TrackerSyncCoordinator>((ref) {
  final deps = ref.watch(featureTrackerSyncDependenciesProvider);
  final configStore = ref.watch(bangumiSyncConfigStoreProvider);
  final client = ref.watch(bangumiSyncClientProvider);
  final primary = ref.watch(bangumiTrackerProvider);

  final coordinator = TrackerSyncCoordinator(
    databases: deps.databases,
    domainEventBus: deps.domainEventBus,
    diagnosticLog: deps.diagnosticLog,
    configStore: configStore,
    client: client,
    bangumiProvider: primary,
    additionalProviders: deps.additionalProviders,
    subjectResolver: deps.subjectResolver,
    autoFlushOnEvent: deps.autoFlushOnEvent,
    autoFlushInterval: deps.autoFlushInterval,
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
