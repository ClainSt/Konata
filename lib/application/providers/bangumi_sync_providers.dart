import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/logging/diagnostic_event.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/work.dart';
import '../../domain/sync/bangumi_sync_models.dart';
import '../../infrastructure/network/bangumi_sync_client.dart';
import '../../infrastructure/sync/bangumi_sync_config_repository.dart';
import '../../infrastructure/sync/konata_sync_store.dart';
import '../sync/bangumi_progress_sync_service.dart';
import 'diagnostics_providers.dart';
import 'library_providers.dart';
import 'scraping_providers.dart';
import 'sync_providers.dart';

/// Bangumi PAT 同步配置仓储 Provider。
final bangumiSyncConfigRepositoryProvider =
    Provider<BangumiSyncConfigRepository>(
      (ref) => const BangumiSyncConfigRepository(),
    );

/// Bangumi 同步客户端 Provider（复用共享 HTTP 调度器与代理配置）。
final bangumiSyncClientProvider = Provider<BangumiSyncClient>((ref) {
  final configAsync = ref.watch(tmdbNetworkConfigProvider);
  final netConfig = configAsync.value ?? const TmdbNetworkConfig();
  final httpClient = createAppTmdbHttpClient(ref, netConfig);
  ref.onDispose(httpClient.close);
  return BangumiSyncClient(
    httpClient: httpClient,
    logStore: ref.watch(diagnosticsLogStoreProvider),
  );
});

/// Bangumi 观看进度同步服务 Provider。
final bangumiProgressSyncServiceProvider = Provider<BangumiProgressSyncService>(
  (ref) => BangumiProgressSyncService(
    repository: ref.watch(libraryRepositoryProvider),
    syncStore: ref.watch(konataSyncStoreProvider),
    client: ref.watch(bangumiSyncClientProvider),
    logStore: ref.watch(diagnosticsLogStoreProvider),
  ),
);

/// Bangumi 进度同步界面响应式状态。
class BangumiSyncUiState {
  /// 创建 Bangumi 同步状态。
  const BangumiSyncUiState({
    this.config = const BangumiSyncConfig(),
    this.loaded = false,
    this.isVerifying = false,
    this.isSyncing = false,
    this.profile,
    this.pendingQueueCount = 0,
    this.lastSyncAt,
    this.lastSummary,
    this.lastError,
  });

  final BangumiSyncConfig config;
  final bool loaded;
  final bool isVerifying;
  final bool isSyncing;
  final BangumiUserProfile? profile;
  final int pendingQueueCount;
  final DateTime? lastSyncAt;
  final String? lastSummary;
  final String? lastError;

  /// 当前是否已启用且填写了 PAT 令牌。
  bool get isReadyForSync => config.enabled && config.hasToken;

  BangumiSyncUiState copyWith({
    BangumiSyncConfig? config,
    bool? loaded,
    bool? isVerifying,
    bool? isSyncing,
    BangumiUserProfile? profile,
    bool clearProfile = false,
    int? pendingQueueCount,
    DateTime? lastSyncAt,
    String? lastSummary,
    String? lastError,
    bool clearError = false,
  }) {
    return BangumiSyncUiState(
      config: config ?? this.config,
      loaded: loaded ?? this.loaded,
      isVerifying: isVerifying ?? this.isVerifying,
      isSyncing: isSyncing ?? this.isSyncing,
      profile: clearProfile ? null : (profile ?? this.profile),
      pendingQueueCount: pendingQueueCount ?? this.pendingQueueCount,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSummary: lastSummary ?? this.lastSummary,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

/// Bangumi PAT 配置、验证、自动上报与全库双向同步状态控制器。
class BangumiSyncController extends Notifier<BangumiSyncUiState> {
  void Function()? _disposeDiagContributor;

  @override
  BangumiSyncUiState build() {
    final logStore = ref.watch(diagnosticsLogStoreProvider);
    _disposeDiagContributor?.call();
    _disposeDiagContributor = logStore.registerSnapshotContributor(
      'bangumi_sync',
      () => DiagnosticSnapshotSection(
        id: 'bangumi_sync',
        title: 'Bangumi PAT 观看进度同步状态',
        entries: <String, String>{
          'enabled': state.config.enabled.toString(),
          'hasToken': state.config.hasToken.toString(),
          'syncMode': state.config.syncMode.name,
          'autoPushOnComplete': state.config.autoPushOnComplete.toString(),
          'pendingQueueCount': state.pendingQueueCount.toString(),
          if (state.profile != null) 'account': state.profile!.username,
          if (state.lastSyncAt != null)
            'lastSyncAt': state.lastSyncAt!.toIso8601String(),
          if (state.lastSummary != null) 'lastSummary': state.lastSummary!,
          if (state.lastError != null) 'lastError': state.lastError!,
        },
      ),
    );
    ref.onDispose(() {
      _disposeDiagContributor?.call();
      _disposeDiagContributor = null;
    });
    unawaited(_restore());
    return const BangumiSyncUiState();
  }

  Future<void> _restore() async {
    try {
      final configRepo = ref.read(bangumiSyncConfigRepositoryProvider);
      final syncStore = ref.read(konataSyncStoreProvider);
      final service = ref.read(bangumiProgressSyncServiceProvider);
      final config = await configRepo.load();
      final profile = config.hasToken ? await service.readCachedProfile() : null;
      final queue = await syncStore.readBangumiSyncQueue();
      final lastMsRaw = await syncStore.readMeta(
        KonataSyncStore.metaKeyBangumiLastSyncMs,
      );
      final lastSummary = await syncStore.readMeta(
        KonataSyncStore.metaKeyBangumiLastSummary,
      );
      if (!ref.mounted) return;
      final lastMs = int.tryParse(lastMsRaw ?? '');
      state = state.copyWith(
        config: config,
        loaded: true,
        profile: profile,
        clearProfile: profile == null,
        pendingQueueCount: queue.length,
        lastSyncAt: lastMs != null && lastMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(lastMs)
            : null,
        lastSummary: lastSummary,
      );
    } catch (error) {
      developer.log(
        '恢复 Bangumi 同步配置失败',
        name: 'konata.bangumi_sync_providers',
        error: error,
      );
      if (ref.mounted) {
        state = state.copyWith(loaded: true);
      }
    }
  }

  /// 保存并持久化 Bangumi 同步配置。
  Future<void> saveConfig(BangumiSyncConfig next) async {
    final tokenCleared = !next.hasToken;
    state = state.copyWith(
      config: next,
      clearProfile: tokenCleared,
      clearError: true,
    );
    await ref.read(bangumiSyncConfigRepositoryProvider).save(next);
    if (tokenCleared) {
      await ref
          .read(konataSyncStoreProvider)
          .deleteMeta(KonataSyncStore.metaKeyBangumiProfileJson);
    }
  }

  /// 验证 PAT 令牌并缓存公开账号资料。
  Future<BangumiUserProfile> verifyToken(BangumiSyncConfig draft) async {
    await saveConfig(draft);
    state = state.copyWith(isVerifying: true, clearError: true);
    try {
      final profile = await ref
          .read(bangumiProgressSyncServiceProvider)
          .verifyAndCacheProfile(draft.personalAccessToken);
      if (ref.mounted) {
        state = state.copyWith(
          isVerifying: false,
          profile: profile,
          clearError: true,
        );
      }
      return profile;
    } catch (error) {
      final msg = NetworkErrorSanitizer.toUserMessage(error);
      if (ref.mounted) {
        state = state.copyWith(
          isVerifying: false,
          clearProfile: true,
          lastError: msg,
        );
      }
      rethrow;
    }
  }

  /// 单集完播或手动标记已看时静默入队并后台冲刷（绝不阻塞播控或抛出未捕获异常）。
  Future<void> notifyEpisodeCompleted({
    required Work work,
    required Episode episode,
    bool watched = true,
  }) async {
    final cfg = state.config;
    if (!cfg.enabled ||
        !cfg.autoPushOnComplete ||
        !cfg.hasToken ||
        work.bangumiId == null) {
      return;
    }
    try {
      await ref
          .read(bangumiProgressSyncServiceProvider)
          .enqueueEpisodeWatched(
            config: cfg,
            work: work,
            episode: episode,
            watched: watched,
          );
    } catch (error) {
      developer.log(
        '后台自动上报 Bangumi 单集进度失败（已留在离线队列）',
        name: 'konata.bangumi_sync_providers',
        error: error,
      );
    } finally {
      await refreshPendingQueueCount();
    }
  }

  /// 立即同步单部作品（供详情页齿轮菜单触发）。
  Future<BangumiWorkSyncResult> syncWork(String workId) async {
    state = state.copyWith(isSyncing: true, clearError: true);
    try {
      final res = await ref
          .read(bangumiProgressSyncServiceProvider)
          .syncWork(config: state.config, workId: workId);
      if (res.pulledWatchedCount > 0 && ref.mounted) {
        ref.invalidate(workDetailBundleProvider(workId));
        ref.invalidate(playbackHistoryProvider);
      }
      await refreshPendingQueueCount();
      if (ref.mounted) {
        state = state.copyWith(
          isSyncing: false,
          lastSyncAt: DateTime.now(),
          lastSummary: res.toSummaryMessage(),
          clearError: true,
        );
      }
      return res;
    } catch (error) {
      final msg = NetworkErrorSanitizer.toUserMessage(
        error,
        prefix: 'Bangumi 同步失败',
      );
      if (ref.mounted) {
        state = state.copyWith(isSyncing: false, lastError: msg);
      }
      rethrow;
    }
  }

  /// 立即执行全库 Bangumi 双向进度同步。
  Future<BangumiLibrarySyncReport> syncAllLibrary({
    BangumiSyncConfig? configOverride,
  }) async {
    final effective = configOverride ?? state.config;
    if (configOverride != null) {
      await saveConfig(configOverride);
    }
    state = state.copyWith(isSyncing: true, clearError: true);
    try {
      final report = await ref
          .read(bangumiProgressSyncServiceProvider)
          .syncAllLibraryWorks(effective);
      if (report.totalPulled > 0 && ref.mounted) {
        ref.invalidate(libraryItemsProvider);
        ref.invalidate(playbackHistoryProvider);
      }
      if (ref.mounted) {
        state = state.copyWith(
          isSyncing: false,
          pendingQueueCount: report.remainingQueued,
          lastSyncAt: DateTime.now(),
          lastSummary: report.toSummaryMessage(),
          clearError: report.firstError == null,
          lastError: report.firstError,
        );
      }
      return report;
    } catch (error) {
      final msg = NetworkErrorSanitizer.toUserMessage(
        error,
        prefix: 'Bangumi 同步失败',
      );
      if (ref.mounted) {
        state = state.copyWith(isSyncing: false, lastError: msg);
      }
      rethrow;
    }
  }

  /// 手动立即重试待上报离线队列。
  Future<int> flushQueueNow() async {
    state = state.copyWith(isSyncing: true, clearError: true);
    try {
      final flushed = await ref
          .read(bangumiProgressSyncServiceProvider)
          .flushPendingQueue(state.config, ignoreBackoff: true);
      await refreshPendingQueueCount();
      if (ref.mounted) {
        state = state.copyWith(isSyncing: false, clearError: true);
      }
      return flushed;
    } catch (error) {
      final msg = NetworkErrorSanitizer.toUserMessage(error);
      if (ref.mounted) {
        state = state.copyWith(isSyncing: false, lastError: msg);
      }
      rethrow;
    }
  }

  /// 刷新当前 SQLite 中待重试队列条目数。
  Future<void> refreshPendingQueueCount() async {
    try {
      final items = await ref
          .read(konataSyncStoreProvider)
          .readBangumiSyncQueue();
      if (ref.mounted) {
        state = state.copyWith(pendingQueueCount: items.length);
      }
    } catch (error) {
      developer.log(
        '读取 Bangumi 待重试队列计数失败',
        name: 'konata.bangumi_sync_providers',
        error: error,
      );
    }
  }
}

/// Bangumi PAT 同步控制器 Provider。
final bangumiSyncControllerProvider =
    NotifierProvider<BangumiSyncController, BangumiSyncUiState>(
      BangumiSyncController.new,
    );
