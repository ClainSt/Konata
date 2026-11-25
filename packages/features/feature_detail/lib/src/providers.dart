import 'dart:async';
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/detail_cd_artwork.dart';
import 'data/detail_display_preferences.dart';
import 'data/detail_work_actions.dart';
import 'data/main_episode_frame_backfill_service.dart';
import 'data/main_episode_frame_extractor.dart';
import 'data/work_artwork_options.dart';
import 'state/work_detail_controller.dart';

/// `feature_detail` 业务包运行所需的全部跨包显式依赖（由应用组装根覆写注入）。
final class FeatureDetailDependencies {
  /// 构造作品详情业务包依赖集合。
  const FeatureDetailDependencies({
    required this.databases,
    required this.storageRoot,
    required this.diagnosticLog,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.navigator,
    required this.filePicker,
    required this.urlOpener,
    required this.httpClient,
    required this.gatewayFactory,
    required this.streamBridge,
    required this.warmupService,
    required this.photosStorage,
    required this.artworkCache,
    required this.platform,
    this.detailTabs = const <DetailTabContribution>[],
    this.detailActions = const <DetailActionContribution>[],
    this.libMpvClientFactory,
    this.mappingIndexProvider,
    this.sourceDeviceId = '',
    this.autoStartWarmupAndBackfill = true,
  });

  /// 三库物理分治数据库总管。
  final KonataDatabaseBundle databases;

  /// 跨端存储根目录解析端口。
  final StorageRootPort storageRoot;

  /// 统一脱敏结构化诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 分命名空间自治配置存储器。
  final ScopedPrefsStore scopedPrefs;

  /// 低频跨包领域事件总线。
  final DomainEventBus domainEventBus;

  /// 跨 Feature 唯一导航路由端口。
  final AppNavigator navigator;

  /// 系统文件与图片选择器端口。
  final FilePickerPort filePicker;

  /// 系统外部链接打开端口。
  final UrlOpenerPort urlOpener;

  /// 优先级受控网络客户端端口。
  final KonataHttpClientPort httpClient;

  /// 只读媒体源网关工厂端口。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 本地流式网桥端口。
  final LocalStreamBridgePort streamBridge;

  /// 详情页同级字幕与目录静默预热服务。
  final WorkDetailWarmupService warmupService;

  /// 统一 `photos/` 分作品目录图片管理器。
  final PhotosStorage photosStorage;

  /// 图片读写缓存端口。
  final ArtworkCacheStore artworkCache;

  /// 当前运行宿主平台类型。
  final KonataPlatform platform;

  /// 动态注入的详情页扩展标签页贡献清单（如扫图画廊）。
  final List<DetailTabContribution> detailTabs;

  /// 动态注入的详情页扩展动作贡献清单。
  final List<DetailActionContribution> detailActions;

  /// 可选抽帧用原生 `libmpv` 客户端工厂。
  final LibMpvClient Function()? libMpvClientFactory;

  /// 可选离线映射索引提供器。
  final Future<BangumiTmdbIndex?> Function()? mappingIndexProvider;

  /// 可选本机同步设备标识。
  final String sourceDeviceId;

  /// 是否在进入详情页后自动执行静默预热与缺失剧照抽帧补图。
  final bool autoStartWarmupAndBackfill;
}

/// 作品详情页业务包依赖容器 Provider（必须由宿主 `ProviderScope` 覆盖注入）。
final featureDetailDependenciesProvider = Provider<FeatureDetailDependencies>((
  ref,
) {
  throw UnimplementedError('featureDetailDependenciesProvider 必须由应用组装根覆写注入');
});

/// 详情页内聚领域仓储实例 Provider。
final detailLibraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  return StorageScrapeRepository(
    deps.databases,
    sourceDeviceId: deps.sourceDeviceId,
  );
});

/// 详情页受管 `TMDB` 服务实例 Provider（绑定统一网络端口与作品级磁盘缓存）。
final detailTmdbServiceProvider = Provider<TmdbService>((ref) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  return TmdbService(
    httpClient: deps.httpClient,
    artworkCache: deps.artworkCache,
  );
});

/// 详情页 `Bangumi` 在线服务实例 Provider。
final detailBangumiServiceProvider = Provider<BangumiService>((ref) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  return BangumiService(httpClient: deps.httpClient);
});

/// 详情页 `Fanart.tv` 整包缓存与熔断协调器 Provider。
final detailFanartCacheProvider = Provider<FanartArtworkCache>((ref) {
  final cache = FanartArtworkCache();
  ref.onDispose(cache.clear);
  return cache;
});

/// 详情页 `Fanart.tv` 熔断器 Provider。
final detailFanartCircuitBreakerProvider = Provider<FanartCircuitBreaker>((
  ref,
) {
  return FanartCircuitBreaker();
});

/// 详情页 `Fanart.tv` 服务实例 Provider。
final detailFanartServiceProvider = Provider<FanartService>((ref) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  return FanartService(
    httpClient: deps.httpClient,
    circuitBreaker: ref.watch(detailFanartCircuitBreakerProvider),
    artworkCache: ref.watch(detailFanartCacheProvider),
  );
});

/// 详情页透明标题徽标在途去重协调器 Provider。
final detailClearLogoResolverProvider = Provider<ClearLogoResolver>((ref) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  return ClearLogoResolver(
    tmdbService: ref.watch(detailTmdbServiceProvider),
    fanartService: ref.watch(detailFanartServiceProvider),
    networkConfig: deps.httpClient.config,
  );
});

/// 详情页内置单作重刮流水线 Provider。
final detailScrapePipelineProvider = Provider<ScrapePipeline>((ref) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  final repo = ref.watch(detailLibraryRepositoryProvider);
  final tmdb = ref.watch(detailTmdbServiceProvider);
  final bgm = ref.watch(detailBangumiServiceProvider);
  final fanart = ref.watch(detailFanartServiceProvider);
  final clearLogo = ref.watch(detailClearLogoResolverProvider);
  return ScrapePipeline(
    repository: repo,
    tmdbService: tmdb,
    bangumiService: bgm,
    fanartService: fanart,
    clearLogoResolver: clearLogo,
    gatewayBuilder: (source) =>
        deps.gatewayFactory.create(projectMediaSourceView(source)),
    photosStorage: PhotosStorageArtworkPortAdapter(deps.photosStorage),
    diagnosticLog: deps.diagnosticLog,
    eventBus: deps.domainEventBus,
  );
});

/// 详情页展示偏好存储访问器 Provider。
final detailDisplayPreferencesStoreProvider =
    Provider<DetailDisplayPreferencesStore>((ref) {
      final deps = ref.watch(featureDetailDependenciesProvider);
      return DetailDisplayPreferencesStore(deps.scopedPrefs);
    });

/// 详情页展示偏好响应式流 Provider。
final detailDisplayPreferencesProvider =
    StreamProvider.autoDispose<DetailDisplayPreferences>((ref) {
      final store = ref.watch(detailDisplayPreferencesStoreProvider);
      return store.watch();
    });

/// 全局正片无头流式抽帧服务 Provider（单并发串行）。
final mainEpisodeFrameExtractorProvider = Provider<MainEpisodeFrameExtractor>((
  ref,
) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  final isFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
  return MainEpisodeFrameExtractor(
    streamBridge: deps.streamBridge,
    gatewayFactory: deps.gatewayFactory,
    logStore: deps.diagnosticLog,
    clientFactory:
        deps.libMpvClientFactory ??
        (isFlutterTest ? null : FfiLibMpvClient.create),
  );
});

/// 详情页多源候选艺术图聚合服务 Provider。
final workArtworkOptionsServiceProvider = Provider<WorkArtworkOptionsService>((
  ref,
) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  return WorkArtworkOptionsService(
    httpClient: deps.httpClient,
    tmdbService: ref.watch(detailTmdbServiceProvider),
    bangumiService: ref.watch(detailBangumiServiceProvider),
    fanartService: ref.watch(detailFanartServiceProvider),
    circuitBreaker: ref.watch(detailFanartCircuitBreakerProvider),
    mappingIndexProvider: deps.mappingIndexProvider,
  );
});

/// 详情页写操作业务执行器 Provider。
final detailWorkActionsServiceProvider = Provider<DetailWorkActionsService>((
  ref,
) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  return DetailWorkActionsService(
    repository: ref.watch(detailLibraryRepositoryProvider),
    databases: deps.databases,
    photosStorage: deps.photosStorage,
    domainEventBus: deps.domainEventBus,
    tmdbService: ref.watch(detailTmdbServiceProvider),
    bangumiService: ref.watch(detailBangumiServiceProvider),
    scrapePipeline: ref.watch(detailScrapePipelineProvider),
    mappingIndexProvider: deps.mappingIndexProvider,
    sourceDeviceId: deps.sourceDeviceId,
  );
});

/// 详情页受管图片按需解码加载器 Provider（将图片类别映射至受管磁盘分目录）。
final detailManagedImageLoaderProvider = Provider<ManagedImageLoader>((ref) {
  final tmdb = ref.watch(detailTmdbServiceProvider);
  return bindManagedArtworkLoader((
    url, {
    targetWidth,
    imageSize,
    ownerWorkId,
    artwork,
  }) {
    final subfolder = switch (artwork) {
      ManagedArtwork.poster => PhotoSubfolder.posters,
      ManagedArtwork.still => PhotoSubfolder.thumbnails,
      ManagedArtwork.backdrop => PhotoSubfolder.backdrops,
      ManagedArtwork.logo => PhotoSubfolder.logos,
      null => PhotoSubfolder.posters,
    };
    return tmdb.fetchImageBytes(
      url,
      size: imageSize,
      targetWidth: targetWidth,
      ownerWorkId: ownerWorkId,
      subfolder: subfolder,
      priority: RequestPriority.interactive,
    );
  });
});

/// 按作品主键创建的详情状态控制器族 Provider（页面销毁时自动释放订阅与定时任务）。
final workDetailControllerProvider = Provider.autoDispose
    .family<WorkDetailController, WorkId>((ref, workId) {
      final deps = ref.watch(featureDetailDependenciesProvider);
      final repo = ref.watch(detailLibraryRepositoryProvider);
      final actionsService = ref.watch(detailWorkActionsServiceProvider);
      final backfillService = MainEpisodeFrameBackfillService(
        repository: repo,
        photosStorage: deps.photosStorage,
        extractor: ref.watch(mainEpisodeFrameExtractorProvider),
        onWorkUpdated: (updatedId) {
          deps.domainEventBus.publish(
            LibraryWorkChangedEvent(
              workId: WorkId.trusted(updatedId),
              reason: 'edited',
              occurredAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        },
      );
      final controller = WorkDetailController(
        workId: workId,
        databases: deps.databases,
        repository: repo,
        photosStorage: deps.photosStorage,
        domainEventBus: deps.domainEventBus,
        navigator: deps.navigator,
        filePicker: deps.filePicker,
        urlOpener: deps.urlOpener,
        warmupService: deps.warmupService,
        platform: deps.platform,
        detailTabs: deps.detailTabs,
        detailActions: deps.detailActions,
        displayPreferencesStore: ref.watch(
          detailDisplayPreferencesStoreProvider,
        ),
        frameBackfillService: backfillService,
        artworkOptionsService: ref.watch(workArtworkOptionsServiceProvider),
        actionsService: actionsService,
        scrapePipeline: ref.watch(detailScrapePipelineProvider),
        tmdbService: ref.watch(detailTmdbServiceProvider),
        bangumiService: ref.watch(detailBangumiServiceProvider),
        autoStartWarmupAndBackfill: deps.autoStartWarmupAndBackfill,
      );
      ref.onDispose(controller.dispose);
      unawaited(controller.load());
      return controller;
    });

/// 同一宿主共享的限流 CD 封面加载器。
final detailCdCoverLoaderProvider = Provider<DetailCdCoverLoader>((ref) {
  final deps = ref.watch(featureDetailDependenciesProvider);
  return DetailCdArtworkService(
    databases: deps.databases,
    photosStorage: deps.photosStorage,
    gatewayFactory: deps.gatewayFactory,
  ).load;
});
