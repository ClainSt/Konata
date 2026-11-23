import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/logging/diagnostic_event.dart';
import '../../domain/sync/konata_sync_models.dart';
import '../../infrastructure/database/drift_library_repository.dart';
import '../../infrastructure/sync/konata_sync_store.dart';
import '../../infrastructure/sync/webdav_sync_config_repository.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/library_providers.dart';
import '../providers/playback_providers.dart';
import '../sync/konata_backup_service.dart';
import '../sync/webdav_sync_coordinator.dart';

/// 同步元信息与墓碑仓储 Provider（自动复用 `libraryRepositoryProvider` 底层数据库连接，100% 兼容内存测试库）。
final konataSyncStoreProvider = Provider<KonataSyncStore>((ref) {
  final repo = ref.watch(libraryRepositoryProvider);
  if (repo is DriftLibraryRepository) {
    return KonataSyncStore(repo.database);
  }
  final db = ref.watch(konataDatabaseProvider);
  return KonataSyncStore(db);
});

/// WebDAV 多设备同步配置持久化仓储 Provider。
final webDavSyncConfigRepositoryProvider = Provider<WebDavSyncConfigRepository>(
  (ref) => const WebDavSyncConfigRepository(),
);

/// 本地 `.konata` 备份恢复与快照服务 Provider。
final konataBackupServiceProvider = Provider<KonataBackupService>((ref) {
  final repo = ref.watch(libraryRepositoryProvider);
  final store = ref.watch(konataSyncStoreProvider);
  final logStore = ref.watch(diagnosticsLogStoreProvider);
  return KonataBackupService(
    repository: repo,
    syncStore: store,
    logStore: logStore,
  );
});

/// WebDAV 多设备分片同步协调器 Provider。
final webDavSyncCoordinatorProvider = Provider<WebDavSyncCoordinator>((ref) {
  final backupService = ref.watch(konataBackupServiceProvider);
  final syncStore = ref.watch(konataSyncStoreProvider);
  final pool = ref.watch(webDavConnectionPoolProvider);
  final logStore = ref.watch(diagnosticsLogStoreProvider);
  return WebDavSyncCoordinator(
    backupService: backupService,
    syncStore: syncStore,
    connectionPool: pool,
    logStore: logStore,
  );
});

/// 备份与 WebDAV 多设备同步界面响应状态。
class WebDavSyncUiState {
  /// 创建同步界面状态。
  const WebDavSyncUiState({
    this.config = const WebDavSyncConfig(),
    this.loaded = false,
    this.isBusy = false,
    this.isTesting = false,
    this.lastSyncAt,
    this.lastSummary,
    this.lastError,
  });

  final WebDavSyncConfig config;
  final bool loaded;
  final bool isBusy;
  final bool isTesting;
  final DateTime? lastSyncAt;
  final String? lastSummary;
  final String? lastError;

  WebDavSyncUiState copyWith({
    WebDavSyncConfig? config,
    bool? loaded,
    bool? isBusy,
    bool? isTesting,
    DateTime? lastSyncAt,
    String? lastSummary,
    String? lastError,
    bool clearError = false,
  }) {
    return WebDavSyncUiState(
      config: config ?? this.config,
      loaded: loaded ?? this.loaded,
      isBusy: isBusy ?? this.isBusy,
      isTesting: isTesting ?? this.isTesting,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSummary: lastSummary ?? this.lastSummary,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

/// WebDAV 定时同步基础时间单位 Provider（默认 1 分钟，可在单元测试中缩短周期）。
final webDavSyncIntervalUnitProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 1),
);

/// WebDAV 同步配置读写、连通性校验、定时自动同步与本地备份恢复状态控制器。
class WebDavSyncController extends Notifier<WebDavSyncUiState> {
  void Function()? _disposeDiagContributor;
  Timer? _playbackStopSyncTimer;
  Timer? _periodicSyncTimer;
  int _activePeriodicMinutes = 0;
  bool _startupSyncTriggered = false;

  @override
  WebDavSyncUiState build() {
    final logStore = ref.watch(diagnosticsLogStoreProvider);
    _disposeDiagContributor?.call();
    _disposeDiagContributor = logStore.registerSnapshotContributor(
      'webdav_sync',
      () => DiagnosticSnapshotSection(
        id: 'webdav_sync',
        title: 'WebDAV 多设备同步状态',
        entries: <String, String>{
          'enabled': state.config.enabled.toString(),
          'hasServerUrl': state.config.hasValidServerUrl.toString(),
          'remoteDir': state.config.normalizedRemoteDir,
          'syncScope': state.config.syncScope.describeLabel(),
          'autoStartup': state.config.autoSyncOnStartup.toString(),
          'autoStop': state.config.autoSyncOnPlaybackStop.toString(),
          'intervalMinutes': state.config.autoSyncIntervalMinutes.toString(),
          'isBusy': state.isBusy.toString(),
          if (state.lastSyncAt != null)
            'lastSyncAt': state.lastSyncAt!.toIso8601String(),
          if (state.lastSummary != null) 'lastSummary': state.lastSummary!,
          if (state.lastError != null) 'lastError': state.lastError!,
        },
      ),
    );
    ref.onDispose(() {
      _playbackStopSyncTimer?.cancel();
      _playbackStopSyncTimer = null;
      _periodicSyncTimer?.cancel();
      _periodicSyncTimer = null;
      _activePeriodicMinutes = 0;
      _disposeDiagContributor?.call();
      _disposeDiagContributor = null;
    });
    unawaited(_restore());
    return const WebDavSyncUiState();
  }

  /// 按当前同步配置启停后台定时轮询计时器（关闭同步、地址无效、未勾选同步内容或间隔为 0 时立即停钟）。
  void _reconcilePeriodicTimer(WebDavSyncConfig config) {
    final minutes = WebDavSyncConfig.normalizeIntervalMinutes(
      config.autoSyncIntervalMinutes,
    );
    final shouldRun =
        config.enabled &&
        config.hasValidServerUrl &&
        config.syncScope.hasAnySelected &&
        minutes > 0;
    if (!shouldRun) {
      _periodicSyncTimer?.cancel();
      _periodicSyncTimer = null;
      _activePeriodicMinutes = 0;
      return;
    }
    if (_periodicSyncTimer != null && _activePeriodicMinutes == minutes) {
      return;
    }
    _periodicSyncTimer?.cancel();
    _activePeriodicMinutes = minutes;
    final unit = ref.read(webDavSyncIntervalUnitProvider);
    final period = Duration(microseconds: unit.inMicroseconds * minutes);
    _periodicSyncTimer = Timer.periodic(period, (_) {
      if (!ref.mounted) {
        _periodicSyncTimer?.cancel();
        _periodicSyncTimer = null;
        return;
      }
      final current = state;
      if (current.isBusy ||
          current.isTesting ||
          !current.config.enabled ||
          !current.config.hasValidServerUrl ||
          !current.config.syncScope.hasAnySelected) {
        return;
      }
      unawaited(_syncSilently());
    });
  }

  Future<void> _restore() async {
    try {
      final configRepo = ref.read(webDavSyncConfigRepositoryProvider);
      final syncStore = ref.read(konataSyncStoreProvider);
      final config = await configRepo.load();
      final lastMsRaw = await syncStore.readMeta(
        KonataSyncStore.metaKeyWebDavLastSyncMs,
      );
      final lastSummary = await syncStore.readMeta(
        KonataSyncStore.metaKeyWebDavLastSummary,
      );
      if (!ref.mounted) return;
      final lastMs = int.tryParse(lastMsRaw ?? '');
      state = state.copyWith(
        config: config,
        loaded: true,
        lastSyncAt: lastMs != null && lastMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(lastMs)
            : null,
        lastSummary: lastSummary,
      );
      _reconcilePeriodicTimer(config);
      if (!_startupSyncTriggered &&
          config.enabled &&
          config.autoSyncOnStartup &&
          config.hasValidServerUrl &&
          config.syncScope.hasAnySelected) {
        _startupSyncTriggered = true;
        unawaited(_syncSilently());
      }
    } catch (error) {
      developer.log(
        '恢复 WebDAV 同步配置失败',
        name: 'konata.sync_providers',
        error: error,
      );
      if (ref.mounted) {
        state = state.copyWith(loaded: true);
      }
    }
  }

  /// 停播后按需防抖触发后台静默同步（仅在开启「停播后静默上传进度」且勾选「观看进度与播放历史」时生效）。
  void notifyPlaybackStopped() {
    final cfg = state.config;
    if (!cfg.enabled ||
        !cfg.autoSyncOnPlaybackStop ||
        !cfg.hasValidServerUrl ||
        !cfg.syncScope.includePlaybacks) {
      return;
    }
    _playbackStopSyncTimer?.cancel();
    _playbackStopSyncTimer = Timer(const Duration(seconds: 2), () {
      _playbackStopSyncTimer = null;
      if (ref.mounted) {
        unawaited(_syncSilently());
      }
    });
  }

  Future<void> _syncSilently() async {
    try {
      await syncNow();
    } catch (error) {
      developer.log(
        '后台自动 WebDAV 同步失败（已写入诊断日志）',
        name: 'konata.sync_providers',
        error: error,
      );
    }
  }

  /// 保存并持久化 WebDAV 同步配置，并即时重建或关闭定时同步计时器。
  Future<void> saveConfig(WebDavSyncConfig next) async {
    state = state.copyWith(config: next, clearError: true);
    _reconcilePeriodicTimer(next);
    await ref.read(webDavSyncConfigRepositoryProvider).save(next);
  }

  /// 测试目标 WebDAV 同步服务器连通性（返回 `null` 表示成功，否则返回中文错误原因）。
  Future<String?> testConnection(WebDavSyncConfig config) async {
    state = state.copyWith(isTesting: true, clearError: true);
    try {
      return await ref.read(webDavSyncCoordinatorProvider).testConnection(config);
    } finally {
      if (ref.mounted) {
        state = state.copyWith(isTesting: false);
      }
    }
  }

  /// 立即执行 WebDAV 多设备分片同步并刷新媒体库与播放历史视图。
  Future<KonataSyncOutcome> syncNow({WebDavSyncConfig? configOverride}) async {
    final effective = configOverride ?? state.config;
    if (configOverride != null) {
      await saveConfig(configOverride);
    }
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      final outcome = await ref
          .read(webDavSyncCoordinatorProvider)
          .syncNow(effective);
      _invalidateLibraryAfterSync();
      if (ref.mounted) {
        state = state.copyWith(
          isBusy: false,
          lastSyncAt: DateTime.now(),
          lastSummary: outcome.toSummaryMessage(),
          clearError: true,
        );
      }
      return outcome;
    } catch (error) {
      final msg = NetworkErrorSanitizer.toUserMessage(
        error,
        prefix: 'WebDAV 同步失败',
      );
      if (ref.mounted) {
        state = state.copyWith(isBusy: false, lastError: msg);
      }
      rethrow;
    }
  }

  /// 执行本地 `.konata` 备份按范围选择性恢复并刷新全部相关媒体库与历史视图。
  Future<KonataSyncOutcome> restoreLocalBackup(
    Uint8List bytes, {
    required KonataBackupRestoreMode mode,
    KonataSyncDataScope scope = KonataSyncDataScope.all,
  }) async {
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      final outcome = await ref
          .read(konataBackupServiceProvider)
          .restoreFromKonataArchiveBytes(bytes, mode: mode, scope: scope);
      _invalidateLibraryAfterSync();
      if (ref.mounted) {
        state = state.copyWith(isBusy: false, clearError: true);
      }
      return outcome;
    } catch (error) {
      if (ref.mounted) {
        state = state.copyWith(
          isBusy: false,
          lastError: NetworkErrorSanitizer.toUserMessage(
            error,
            prefix: '备份恢复失败',
          ),
        );
      }
      rethrow;
    }
  }

  void _invalidateLibraryAfterSync() {
    if (!ref.mounted) return;
    ref.invalidate(libraryItemsProvider);
    ref.invalidate(worksCountProvider);
    ref.invalidate(hiddenWorksProvider);
    ref.invalidate(playbackHistoryProvider);
    ref.invalidate(seriesGroupsProvider);
  }
}

/// WebDAV 多设备同步与本地备份控制器 Provider。
final webDavSyncControllerProvider =
    NotifierProvider<WebDavSyncController, WebDavSyncUiState>(
      WebDavSyncController.new,
    );
