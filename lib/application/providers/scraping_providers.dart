import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../composition/platform_composition.dart';
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/bangumi_tmdb_index.dart';
import '../../infrastructure/cache/artwork_cache.dart';
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/fanart_service.dart';
import '../../infrastructure/network/network_config_repository.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_http_client.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../../infrastructure/scraping/bangumi_tmdb_map_updater.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../scraping/clear_logo_resolver.dart';
import '../scraping/scrape_orchestrator.dart';
import '../scraping/scrape_progress.dart';
import 'konata_value_notifier.dart';
import 'library_providers.dart';
import 'work_merge_actions.dart';

/// 网络配置仓储 Provider。
final networkConfigRepositoryProvider = Provider<NetworkConfigRepository>((
  ref,
) {
  return const NetworkConfigRepository();
});

/// 当前 TMDB 网络配置异步读取 Provider。
final tmdbNetworkConfigProvider = FutureProvider<TmdbNetworkConfig>((ref) {
  return ref.watch(networkConfigRepositoryProvider).load();
});

/// 双通道 HTTP 优先级调度器 Provider。
final priorityHttpSchedulerProvider = Provider<PriorityHttpScheduler>((ref) {
  return PriorityHttpScheduler();
});

/// 全应用共享的不可达官方域名冷却注册表 Provider（10 分钟冷却窗口，由 Riverpod 托管生命周期）。
final domainCooldownRegistryProvider = Provider<DomainCooldownRegistry>(
  (ref) => DomainCooldownRegistry(),
);

/// 统一构建绑定共享调度器、域名冷却与平台系统代理通道的 [TmdbHttpClient]。
TmdbHttpClient createAppTmdbHttpClient(Ref ref, TmdbNetworkConfig config) {
  return TmdbHttpClient(
    config: config,
    scheduler: ref.read(priorityHttpSchedulerProvider),
    cooldownRegistry: ref.read(domainCooldownRegistryProvider),
    systemProxyResolver: ref.read(systemProxyResolverProvider),
  );
}

/// 全应用复用的持久化 [TmdbHttpClient] Provider（复用 TCP/TLS Keep-Alive 连接池与 DoH 缓存，配置变更自动释放重建）。
final appTmdbHttpClientProvider = FutureProvider<TmdbHttpClient>((ref) async {
  final config = await ref.watch(tmdbNetworkConfigProvider.future);
  final client = createAppTmdbHttpClient(ref, config);
  ref.onDispose(client.close);
  return client;
});

/// 全应用共享的 Fanart.tv 内置无状态中继熔断器 Provider（区分 429 频率限流与日额度耗尽）。
final fanartCircuitBreakerProvider = Provider<FanartCircuitBreaker>((ref) {
  final breaker = FanartCircuitBreaker();
  ref.onDispose(breaker.reset);
  return breaker;
});

/// 全应用共享的 Fanart.tv 整包艺术图（徽标 + 封面 + 无字背景）有界内存缓存 Provider。
final fanartArtworkCacheProvider = Provider<FanartArtworkCache>((ref) {
  final cache = FanartArtworkCache();
  ref.onDispose(cache.clear);
  return cache;
});

/// 全应用共享的透明徽标在途去重注册表 Provider（防止详情页重建或同系列多季并发重复探测）。
final clearLogoInFlightRegistryProvider = Provider<ClearLogoInFlightRegistry>((
  ref,
) {
  final registry = ClearLogoInFlightRegistry();
  ref.onDispose(registry.clear);
  return registry;
});

/// Fanart.tv 内置中继健康与熔断 UI 状态 Provider（供设置页与「编辑标题徽标」弹窗实时展示引导）。
final fanartRelayHealthProvider =
    NotifierProvider<
      KonataValueNotifier<FanartRelayHealthSnapshot>,
      FanartRelayHealthSnapshot
    >(
      () => KonataValueNotifier<FanartRelayHealthSnapshot>.value(
        FanartRelayHealthSnapshot.ok,
      ),
    );

/// 海报与剧照本地磁盘缓存异步 Provider（直连统一 `photos/` 目录，零系统用户缓存写入）。
final artworkCacheProvider = FutureProvider<ArtworkCache>((ref) async {
  final photos = ref.watch(photosStorageProvider);
  final cache = ArtworkCache.photos(photos);
  ref.onDispose(cache.close);
  return cache;
});

/// Bangumi ↔ TMDB 离线映射表加载与 24 小时静默热更新服务 Provider。
final bangumiTmdbMapUpdaterProvider = Provider<BangumiTmdbMapUpdater>((ref) {
  return BangumiTmdbMapUpdater(storageRoot: ref.watch(storageRootProvider));
});

/// 当前生效的 Bangumi ↔ TMDB 离线映射表只读快照 Provider。
final bangumiTmdbSnapshotProvider = FutureProvider<BangumiTmdbSnapshot>((ref) {
  return ref.watch(bangumiTmdbMapUpdaterProvider).loadActiveSnapshot();
});

/// 刮削进度状态管理器。
class ScrapeController extends Notifier<ScrapeProgress> {
  /// 创建刮削进度状态管理器。
  ScrapeController({this.initialState});

  /// 可选初始状态（供单元测试直接注入预置进度）。
  final ScrapeProgress? initialState;

  bool _cancelRequested = false;
  final Set<String> _autoBackfillInFlight = <String>{};

  @override
  ScrapeProgress build() => initialState ?? const ScrapeProgress();

  Future<BangumiTmdbIndex> _resolveActiveMappingIndex({
    bool checkUpdateIfDue = false,
  }) async {
    final updater = ref.read(bangumiTmdbMapUpdaterProvider);
    if (checkUpdateIfDue) {
      try {
        final config = await ref.read(tmdbNetworkConfigProvider.future);
        final res = await updater.checkAndUpdateIfDue(
          force: false,
          networkConfig: config,
        );
        if (res.state == BangumiTmdbUpdateState.updated ||
            res.state == BangumiTmdbUpdateState.upToDate) {
          ref.invalidate(bangumiTmdbSnapshotProvider);
        }
        return res.snapshot.index;
      } catch (error) {
        developer.log(
          '扫描前静默检查映射表更新失败，沿用现有离线映射表',
          name: 'konata.scraping_providers',
          error: error,
        );
      }
    }
    try {
      final snap = await ref.read(bangumiTmdbSnapshotProvider.future);
      return snap.index;
    } catch (error) {
      developer.log(
        '读取离线映射表快照失败，自动回退静态表',
        name: 'konata.scraping_providers',
        error: error,
      );
      return BangumiTmdbIndex.empty();
    }
  }

  Future<ScrapeOrchestrator> _buildOrchestrator({
    BangumiTmdbIndex? mappingIndex,
  }) async {
    final config = await ref.read(tmdbNetworkConfigProvider.future);
    final cache = await ref.read(artworkCacheProvider.future);
    final repository = ref.read(libraryRepositoryProvider);
    final activeIndex = mappingIndex ?? await _resolveActiveMappingIndex();
    final httpClient = createAppTmdbHttpClient(ref, config);
    final tmdbService = TmdbService(
      httpClient: httpClient,
      artworkCache: cache,
    );
    final bangumiService = BangumiService(httpClient: httpClient);
    final fanartService = FanartService(
      httpClient: httpClient,
      circuitBreaker: ref.read(fanartCircuitBreakerProvider),
      artworkCache: ref.read(fanartArtworkCacheProvider),
    );
    final clearLogoResolver = ClearLogoResolver(
      tmdbService: tmdbService,
      fanartService: fanartService,
      networkConfig: config,
      mappingIndex: activeIndex,
      inFlightRegistry: ref.read(clearLogoInFlightRegistryProvider),
    );
    const gatewayFactory = MediaSourceGatewayFactory();
    return ScrapeOrchestrator(
      repository: repository,
      tmdbService: tmdbService,
      bangumiService: bangumiService,
      fanartService: fanartService,
      clearLogoResolver: clearLogoResolver,
      gatewayBuilder: gatewayFactory.create,
      photosStorage: ref.read(photosStorageProvider),
      mappingIndex: activeIndex,
    );
  }

  /// 请求中止当前正在执行的扫描与刮削任务。
  void requestCancel() {
    if (!state.isRunning) return;
    _cancelRequested = true;
    state = state.copyWith(cancelRequested: true);
  }

  /// 触发对指定媒体源的扫描与四段漏斗刮削。
  ///
  /// 当提供非空 [scanRootsOverride] 时，本次仅扫描指定的相对子目录集合。
  Future<void> scanSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
  }) async {
    if (state.isRunning) return;
    _cancelRequested = false;

    final effectiveRoots = scanRootsOverride ?? const <String>[];
    state = ScrapeProgress(
      phase: ScrapePhase.scanning,
      sourceId: source.id,
      sourceLabel: source.label,
      currentItemName: source.label,
      selectedRoots: List.unmodifiable(effectiveRoots),
    );

    try {
      final activeIndex = await _resolveActiveMappingIndex(
        checkUpdateIfDue: true,
      );
      final orchestrator = await _buildOrchestrator(mappingIndex: activeIndex);
      await orchestrator.scanAndScrapeSource(
        source,
        scanRootsOverride: scanRootsOverride,
        isCancelled: () => _cancelRequested,
        onProgress: (progress) {
          if (ref.mounted) {
            state = progress;
          }
        },
      );
    } catch (error) {
      if (ref.mounted && state.phase != ScrapePhase.failed) {
        state = state.copyWith(
          phase: ScrapePhase.failed,
          errorMessage: NetworkErrorSanitizer.toUserMessage(error),
        );
      }
      rethrow;
    } finally {
      _cancelRequested = false;
      if (ref.mounted) {
        ref.invalidate(libraryItemsProvider);
        ref.invalidate(worksCountProvider);
        ref.invalidate(seriesGroupsProvider);
      }
    }
  }

  /// 人工纠错绑定或元数据刷新（`resetManualLocks: true` 可重置既有锁定与文件映射）。
  Future<Work> rebindWork({
    required String workId,
    required int tmdbId,
    required TmdbMediaType mediaType,
    bool writeIdToFolderName = false,
    bool resetManualLocks = false,
  }) async {
    final orchestrator = await _buildOrchestrator();
    final updated = await orchestrator.rebindWorkToTmdb(
      workId,
      tmdbId,
      mediaType,
      writeIdToFolderName: writeIdToFolderName,
      resetManualLocks: resetManualLocks,
    );
    // 防空壳守卫：若当前条目无任何正片且同 TMDB(季)/Bangumi 主作品已在库，则直接自动并入
    final autoMerged = await tryAutoMergeSupplementaryWork(
      ref,
      sourceWorkId: workId,
      bangumiId: updated.bangumiId,
      tmdbId: updated.tmdbId ?? tmdbId,
      tmdbMediaType: updated.tmdbMediaType ?? mediaType,
      matchedSeason: updated.matchedSeason,
    );
    if (autoMerged != null) {
      await ref
          .read(photosStorageProvider)
          .renameWorkFolderIfNeeded(autoMerged.id, autoMerged.title);
      return autoMerged;
    }
    await ref
        .read(photosStorageProvider)
        .renameWorkFolderIfNeeded(updated.id, updated.title);
    ref.invalidate(libraryItemsProvider);
    ref.invalidate(worksCountProvider);
    ref.invalidate(seriesGroupsProvider);
    ref.invalidate(workDetailBundleProvider(workId));
    ref.invalidate(workScrapeCandidatesProvider(workId));
    return updated;
  }

  /// 详情页进入自动补全或手动点击重新抓取：自动补绑缺失的 `tmdbId` 并回填透明标题与无字横版背景。
  Future<Work?> ensureOrRescrapeWork({
    required String workId,
    bool interactive = false,
  }) async {
    if (!interactive && !_autoBackfillInFlight.add(workId)) {
      return null;
    }
    try {
      final config = await ref.read(tmdbNetworkConfigProvider.future);
      if (!interactive &&
          config.credentialKind == TmdbCredentialKind.none &&
          !config.isFanartAvailable) {
        return null;
      }
      final before = await ref
          .read(libraryRepositoryProvider)
          .findWorkById(workId);
      if (before == null) return null;

      final orchestrator = await _buildOrchestrator();
      final updated = await orchestrator.autoBindOrBackfillWorkTmdb(
        workId,
        interactive: interactive,
      );
      if (ref.mounted) {
        ref.read(fanartRelayHealthProvider.notifier).state = ref
            .read(fanartCircuitBreakerProvider)
            .snapshot();
      }
      if (updated == null) return null;

      if (updated.tmdbId != null && updated.tmdbMediaType != null) {
        final autoMerged = await tryAutoMergeSupplementaryWork(
          ref,
          sourceWorkId: workId,
          bangumiId: updated.bangumiId,
          tmdbId: updated.tmdbId!,
          tmdbMediaType: updated.tmdbMediaType!,
          matchedSeason: updated.matchedSeason,
        );
        if (autoMerged != null) {
          await ref
              .read(photosStorageProvider)
              .renameWorkFolderIfNeeded(autoMerged.id, autoMerged.title);
          return autoMerged;
        }
      }

      final changed =
          updated.tmdbId != before.tmdbId ||
          updated.tvdbId != before.tvdbId ||
          updated.posterPath != before.posterPath ||
          updated.logoPath != before.logoPath ||
          updated.backdropPath != before.backdropPath ||
          updated.title != before.title ||
          updated.overview != before.overview ||
          updated.bangumiScore != before.bangumiScore ||
          interactive;
      if (changed && ref.mounted) {
        await ref
            .read(photosStorageProvider)
            .renameWorkFolderIfNeeded(updated.id, updated.title);
        ref.invalidate(libraryItemsProvider);
        ref.invalidate(worksCountProvider);
        ref.invalidate(seriesGroupsProvider);
        ref.invalidate(workDetailBundleProvider(workId));
        ref.invalidate(workScrapeCandidatesProvider(workId));
      }
      return updated;
    } catch (_) {
      if (!interactive) return null;
      rethrow;
    } finally {
      if (!interactive) {
        _autoBackfillInFlight.remove(workId);
      }
    }
  }
}

/// 刮削进度与操作控制器 Provider。
final scrapeControllerProvider =
    NotifierProvider<ScrapeController, ScrapeProgress>(ScrapeController.new);
