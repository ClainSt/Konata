import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/media_source.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/work.dart';
import '../../infrastructure/cache/artwork_cache.dart';
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/network_config_repository.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_http_client.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import '../scraping/scrape_orchestrator.dart';
import '../scraping/scrape_progress.dart';
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

/// 海报与剧照本地磁盘缓存异步 Provider（直连统一 `photos/` 目录，零系统用户缓存写入）。
final artworkCacheProvider = FutureProvider<ArtworkCache>((ref) async {
  final photos = ref.watch(photosStorageProvider);
  final cache = ArtworkCache.photos(photos);
  ref.onDispose(cache.close);
  return cache;
});

/// 刮削进度状态管理器。
class ScrapeController extends StateNotifier<ScrapeProgress> {
  /// 创建刮削控制器。
  ScrapeController(this._ref) : super(const ScrapeProgress());

  final Ref _ref;
  bool _cancelRequested = false;

  Future<ScrapeOrchestrator> _buildOrchestrator() async {
    final config = await _ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final cache = await _ref.read(artworkCacheProvider.future);
    final repository = _ref.read(libraryRepositoryProvider);
    final httpClient = TmdbHttpClient(config: config, scheduler: scheduler);
    final tmdbService = TmdbService(
      httpClient: httpClient,
      artworkCache: cache,
    );
    final bangumiService = BangumiService(httpClient: httpClient);
    const gatewayFactory = MediaSourceGatewayFactory();
    return ScrapeOrchestrator(
      repository: repository,
      tmdbService: tmdbService,
      bangumiService: bangumiService,
      gatewayBuilder: gatewayFactory.create,
      photosStorage: _ref.read(photosStorageProvider),
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
      final orchestrator = await _buildOrchestrator();
      await orchestrator.scanAndScrapeSource(
        source,
        scanRootsOverride: scanRootsOverride,
        isCancelled: () => _cancelRequested,
        onProgress: (progress) {
          state = progress;
        },
      );
    } catch (error) {
      if (state.phase != ScrapePhase.failed) {
        state = state.copyWith(
          phase: ScrapePhase.failed,
          errorMessage: '$error',
        );
      }
      rethrow;
    } finally {
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
}

/// 刮削进度与操作控制器 Provider。
final scrapeControllerProvider =
    StateNotifierProvider<ScrapeController, ScrapeProgress>((ref) {
      return ScrapeController(ref);
    });
