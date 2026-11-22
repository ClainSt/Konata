import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../composition/platform_composition.dart';
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
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
import '../scraping/ongoing_work_auto_sync.dart';
import '../scraping/scrape_orchestrator.dart';
import '../scraping/scrape_progress.dart';
import '../scraping/scrape_progress_tracker.dart';
import '../scraping/work_directory_sync_service.dart';
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
final fanartRelayHealthProvider = StateProvider<FanartRelayHealthSnapshot>(
  (ref) => FanartRelayHealthSnapshot.ok,
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
class ScrapeController extends StateNotifier<ScrapeProgress> {
  /// 创建刮削控制器。
  ScrapeController(this._ref) : super(const ScrapeProgress());

  final Ref _ref;
  bool _cancelRequested = false;
  final Set<String> _autoBackfillInFlight = <String>{};
  final Set<String> _workSyncInFlight = <String>{};
  final Map<String, DateTime> _lastWorkSyncAt = <String, DateTime>{};
  DateTime? _lastOngoingAutoSyncAt;
  bool _ongoingAutoSyncRunning = false;

  Future<BangumiTmdbIndex> _resolveActiveMappingIndex({
    bool checkUpdateIfDue = false,
  }) async {
    final updater = _ref.read(bangumiTmdbMapUpdaterProvider);
    if (checkUpdateIfDue) {
      try {
        final config = await _ref.read(tmdbNetworkConfigProvider.future);
        final res = await updater.checkAndUpdateIfDue(
          force: false,
          networkConfig: config,
        );
        if (res.state == BangumiTmdbUpdateState.updated ||
            res.state == BangumiTmdbUpdateState.upToDate) {
          _ref.invalidate(bangumiTmdbSnapshotProvider);
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
      final snap = await _ref.read(bangumiTmdbSnapshotProvider.future);
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
    final config = await _ref.read(tmdbNetworkConfigProvider.future);
    final cache = await _ref.read(artworkCacheProvider.future);
    final repository = _ref.read(libraryRepositoryProvider);
    final activeIndex = mappingIndex ?? await _resolveActiveMappingIndex();
    final httpClient = createAppTmdbHttpClient(_ref, config);
    final tmdbService = TmdbService(
      httpClient: httpClient,
      artworkCache: cache,
    );
    final bangumiService = BangumiService(httpClient: httpClient);
    final fanartService = FanartService(
      httpClient: httpClient,
      circuitBreaker: _ref.read(fanartCircuitBreakerProvider),
      artworkCache: _ref.read(fanartArtworkCacheProvider),
    );
    final clearLogoResolver = ClearLogoResolver(
      tmdbService: tmdbService,
      fanartService: fanartService,
      networkConfig: config,
      mappingIndex: activeIndex,
      inFlightRegistry: _ref.read(clearLogoInFlightRegistryProvider),
    );
    const gatewayFactory = MediaSourceGatewayFactory();
    return ScrapeOrchestrator(
      repository: repository,
      tmdbService: tmdbService,
      bangumiService: bangumiService,
      fanartService: fanartService,
      clearLogoResolver: clearLogoResolver,
      gatewayBuilder: gatewayFactory.create,
      photosStorage: _ref.read(photosStorageProvider),
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

    // 实时流式上墙刷新器：首批匹配成功作品立即刷新媒体库展示，后续按 800ms / 8 部节流刷新，
    // 让用户在长扫描期间实时看到海报墙持续增长而不拖慢数据库与 UI。
    final liveRefresher = ScrapeLibraryRefreshThrottler(
      onRefresh: () {
        _ref.invalidate(libraryItemsProvider);
        _ref.invalidate(worksCountProvider);
        _ref.invalidate(seriesGroupsProvider);
      },
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
          state = progress;
        },
        onWorkPersisted: (workId, status, displayTitle) {
          if (status == ScrapeStatus.matched) {
            liveRefresher.notifyMatched();
          }
        },
      );
    } catch (error) {
      if (state.phase != ScrapePhase.failed) {
        state = state.copyWith(
          phase: ScrapePhase.failed,
          errorMessage: NetworkErrorSanitizer.toUserMessage(error),
        );
      }
      rethrow;
    } finally {
      liveRefresher.dispose();
      _cancelRequested = false;
      _ref.invalidate(libraryItemsProvider);
      _ref.invalidate(worksCountProvider);
      _ref.invalidate(seriesGroupsProvider);
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
      _ref,
      sourceWorkId: workId,
      bangumiId: updated.bangumiId,
      tmdbId: updated.tmdbId ?? tmdbId,
      tmdbMediaType: updated.tmdbMediaType ?? mediaType,
      matchedSeason: updated.matchedSeason,
    );
    if (autoMerged != null) {
      await _ref
          .read(photosStorageProvider)
          .renameWorkFolderIfNeeded(autoMerged.id, autoMerged.title);
      return autoMerged;
    }
    await _ref
        .read(photosStorageProvider)
        .renameWorkFolderIfNeeded(updated.id, updated.title);
    _ref.invalidate(libraryItemsProvider);
    _ref.invalidate(worksCountProvider);
    _ref.invalidate(seriesGroupsProvider);
    _ref.invalidate(workDetailBundleProvider(workId));
    _ref.invalidate(workScrapeCandidatesProvider(workId));
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
      final config = await _ref.read(tmdbNetworkConfigProvider.future);
      if (!interactive &&
          config.credentialKind == TmdbCredentialKind.none &&
          !config.isFanartAvailable) {
        return null;
      }
      final before = await _ref
          .read(libraryRepositoryProvider)
          .findWorkById(workId);
      if (before == null) return null;

      final orchestrator = await _buildOrchestrator();
      final updated = await orchestrator.autoBindOrBackfillWorkTmdb(
        workId,
        interactive: interactive,
      );
      _ref.read(fanartRelayHealthProvider.notifier).state = _ref
          .read(fanartCircuitBreakerProvider)
          .snapshot();
      if (updated == null) return null;

      if (updated.tmdbId != null && updated.tmdbMediaType != null) {
        final autoMerged = await tryAutoMergeSupplementaryWork(
          _ref,
          sourceWorkId: workId,
          bangumiId: updated.bangumiId,
          tmdbId: updated.tmdbId!,
          tmdbMediaType: updated.tmdbMediaType!,
          matchedSeason: updated.matchedSeason,
        );
        if (autoMerged != null) {
          await _ref
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
      if (changed) {
        await _ref
            .read(photosStorageProvider)
            .renameWorkFolderIfNeeded(updated.id, updated.title);
        _ref.invalidate(libraryItemsProvider);
        _ref.invalidate(worksCountProvider);
        _ref.invalidate(seriesGroupsProvider);
        _ref.invalidate(workDetailBundleProvider(workId));
        _ref.invalidate(workScrapeCandidatesProvider(workId));
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

  /// 详情页打开或起播发现文件缺失时，对单个作品目录执行轻量静默同步（自动追加新集与清理删集）。
  Future<SingleWorkSyncResult> syncWorkDirectorySilently(
    String workId, {
    bool force = false,
  }) async {
    if (state.isRunning) return SingleWorkSyncResult.unchanged;
    final now = DateTime.now();
    final lastAt = _lastWorkSyncAt[workId];
    if (!force &&
        lastAt != null &&
        now.difference(lastAt) <
            OngoingWorkAutoSyncConfig.perWorkDetailSyncCooldown) {
      return SingleWorkSyncResult.unchanged;
    }
    if (!_workSyncInFlight.add(workId)) {
      return SingleWorkSyncResult.unchanged;
    }
    try {
      final orchestrator = await _buildOrchestrator();
      final result = await orchestrator.syncSingleWorkDirectory(workId);
      _lastWorkSyncAt[workId] = DateTime.now();
      if (result.changed) {
        _ref.invalidate(workDetailBundleProvider(workId));
        _ref.invalidate(libraryItemsProvider);
        _ref.invalidate(worksCountProvider);
        _ref.invalidate(seriesGroupsProvider);
        _ref.invalidate(playbackHistoryProvider);
      }
      return result;
    } catch (error) {
      developer.log(
        '详情页静默同步作品目录失败，已忽略不影响浏览（workId=$workId）',
        name: 'konata.scraping_providers',
        error: error,
      );
      return SingleWorkSyncResult.errorSkipped;
    } finally {
      _workSyncInFlight.remove(workId);
    }
  }

  /// 应用启动与切回前台时对近期追番/活跃作品执行受控后台自动巡检（最多 12 部、10 分钟冷却，防网盘风控）。
  Future<int> runOngoingWorksAutoSyncIfDue({bool force = false}) async {
    if (state.isRunning || _ongoingAutoSyncRunning) return 0;
    final now = DateTime.now();
    if (!force &&
        _lastOngoingAutoSyncAt != null &&
        now.difference(_lastOngoingAutoSyncAt!) <
            OngoingWorkAutoSyncConfig.minAutoSyncInterval) {
      return 0;
    }
    _ongoingAutoSyncRunning = true;
    var changedWorks = 0;
    try {
      final repository = _ref.read(libraryRepositoryProvider);
      final sources = await repository.getMediaSources();
      if (sources.isEmpty) return 0;
      final works = await repository.getAllWorks();
      if (works.isEmpty) return 0;
      final recentPlaybacks = await repository.getPlaybackHistory(limit: 40);
      final allVariants = await repository.getAllVariants();
      final episodeSetByWork = <String, Set<String>>{};
      for (final v in allVariants) {
        if (v.assetKind != AssetKind.video) continue;
        final epId = v.episodeId;
        if (epId == null || epId.isEmpty) continue;
        episodeSetByWork.putIfAbsent(v.workId, () => <String>{}).add(epId);
      }
      final mainCountByWork = <String, int>{
        for (final e in episodeSetByWork.entries) e.key: e.value.length,
      };
      final targetIds = OngoingWorkAutoSyncPlanner.selectCandidateWorkIds(
        works: works,
        recentPlaybacks: recentPlaybacks,
        mainEpisodeCountByWorkId: mainCountByWork,
        now: now,
      );
      if (targetIds.isEmpty) return 0;

      final orchestrator = await _buildOrchestrator();
      for (var i = 0; i < targetIds.length; i++) {
        if (state.isRunning) break;
        final workId = targetIds[i];
        if (!_workSyncInFlight.add(workId)) continue;
        try {
          final res = await orchestrator.syncSingleWorkDirectory(
            workId,
            isCancelled: () => state.isRunning,
          );
          _lastWorkSyncAt[workId] = DateTime.now();
          if (res.changed) {
            changedWorks++;
            _ref.invalidate(workDetailBundleProvider(workId));
          }
        } catch (error) {
          developer.log(
            '后台追番自动巡检单作品失败，跳过继续（workId=$workId）',
            name: 'konata.scraping_providers',
            error: error,
          );
        } finally {
          _workSyncInFlight.remove(workId);
        }
        if (i + 1 < targetIds.length && !state.isRunning) {
          await Future<void>.delayed(
            OngoingWorkAutoSyncConfig.betweenWorksPacing,
          );
        }
      }

      if (changedWorks > 0) {
        _ref.invalidate(libraryItemsProvider);
        _ref.invalidate(worksCountProvider);
        _ref.invalidate(seriesGroupsProvider);
        _ref.invalidate(playbackHistoryProvider);
      }
      return changedWorks;
    } catch (error) {
      developer.log(
        '后台追番自动巡检异常，等待下一周期重试',
        name: 'konata.scraping_providers',
        error: error,
      );
      return changedWorks;
    } finally {
      _lastOngoingAutoSyncAt = DateTime.now();
      _ongoingAutoSyncRunning = false;
    }
  }
}

/// 刮削进度与操作控制器 Provider。
final scrapeControllerProvider =
    StateNotifierProvider<ScrapeController, ScrapeProgress>((ref) {
      return ScrapeController(ref);
    });
