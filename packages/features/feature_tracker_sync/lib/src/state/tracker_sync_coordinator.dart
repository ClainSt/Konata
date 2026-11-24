import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/bangumi_sync_client.dart';
import '../data/bangumi_sync_config_store.dart';
import '../data/bangumi_sync_models.dart';
import '../data/bangumi_tracker_provider.dart';

/// 多追番平台外部条目编号解析回调。
typedef TrackerSubjectResolver =
    String? Function(String trackerId, WorkRecord work);

/// 多平台追番进度同步协调器（状态层严格保持零 Riverpod）。
///
/// 职责包括：
/// 1. 监听 [DomainEventBus] 的 [EpisodeCompletionChangedEvent] 并自动写入持久化队列；
/// 2. 管理多个 [ProgressTrackerProvider] 的分发与指数退避重试；
/// 3. 检测 401/403 鉴权失效并立即暂停重试，提示用户重新绑定 PAT；
/// 4. 编排单作品与全库双向对齐同步。
final class TrackerSyncCoordinator extends ChangeNotifier {
  /// 创建追番同步协调器。
  TrackerSyncCoordinator({
    required this._databases,
    required this._domainEventBus,
    required this._diagnosticLog,
    required this._configStore,
    required this._client,
    BangumiTrackerProvider? bangumiProvider,
    List<ProgressTrackerProvider> additionalProviders =
        const <ProgressTrackerProvider>[],
    TrackerSubjectResolver? subjectResolver,
    this._autoFlushOnEvent = true,
    Duration? autoFlushInterval,
    DateTime Function()? clock,
  }) : _subjectResolver = subjectResolver ?? defaultSubjectResolver,
       _clock = clock ?? DateTime.now {
    final primary =
        bangumiProvider ??
        BangumiTrackerProvider(configStore: _configStore, client: _client);
    _providers[primary.trackerId] = primary;
    for (final provider in additionalProviders) {
      _providers[provider.trackerId] = provider;
    }

    _config = _configStore.readConfig();
    final persistedAuth = _configStore.readAuthState();
    if (persistedAuth.authInvalid) {
      _authInvalidByTracker[BangumiTrackerProvider.trackerKey] = true;
      _authMessageByTracker[BangumiTrackerProvider.trackerKey] =
          persistedAuth.authError ?? 'Bangumi PAT 已失效，请重新绑定';
    }

    _pendingBangumiItems = _databases.userState.trackerSyncQueue
        .listDueForTracker(
          BangumiTrackerProvider.trackerKey,
          nowMs: nonRetryableNextRetryAtMs,
          limit: 500,
        );

    _eventSub = _domainEventBus
        .on<EpisodeCompletionChangedEvent>()
        .listen(_onEpisodeCompletionEvent);
    _configSub = _configStore.watchConfig().listen(_onConfigUpdated);
    _queueSub = _databases.userState.trackerSyncQueue
        .watchForTracker(BangumiTrackerProvider.trackerKey)
        .listen(_onBangumiQueueUpdated);

    unawaited(_refreshTokenPresence());

    if (autoFlushInterval != null) {
      _autoFlushTimer = Timer.periodic(
        autoFlushInterval,
        (_) => unawaited(flushDueQueue()),
      );
    }
  }

  /// 指数退避间隔（秒）：30 秒、2 分钟、10 分钟、30 分钟。
  static const List<int> backoffDelaySeconds = <int>[30, 120, 600, 1800];

  /// 单个队列项的最大自动重试次数。
  static const int maxRetryAttempts = 6;

  /// 不可自动重试项（例如 401/403 或超出上限）使用的远期哨兵时间戳。
  static const int nonRetryableNextRetryAtMs = 0x3FFFFFFFFFFFFFFF;

  /// 默认外部条目编号解析规则。
  static String? defaultSubjectResolver(String trackerId, WorkRecord work) {
    if (trackerId == BangumiTrackerProvider.trackerKey) {
      return work.bangumiId != null && work.bangumiId! > 0
          ? work.bangumiId.toString()
          : null;
    }
    return null;
  }

  final KonataDatabaseBundle _databases;
  final DomainEventBus _domainEventBus;
  final DiagnosticLogPort _diagnosticLog;
  final BangumiSyncConfigStore _configStore;
  final BangumiSyncClient _client;
  final TrackerSubjectResolver _subjectResolver;
  final bool _autoFlushOnEvent;
  final DateTime Function() _clock;

  final Map<String, ProgressTrackerProvider> _providers =
      <String, ProgressTrackerProvider>{};
  final Map<String, bool> _authInvalidByTracker = <String, bool>{};
  final Map<String, String> _authMessageByTracker = <String, String>{};

  StreamSubscription<EpisodeCompletionChangedEvent>? _eventSub;
  StreamSubscription<BangumiSyncConfig>? _configSub;
  StreamSubscription<List<TrackerSyncQueueItem>>? _queueSub;
  Timer? _autoFlushTimer;
  Future<void> _serialChain = Future<void>.value();

  late BangumiSyncConfig _config;
  bool _hasToken = false;
  bool _isBusy = false;
  bool _disposed = false;
  List<TrackerSyncQueueItem> _pendingBangumiItems =
      const <TrackerSyncQueueItem>[];
  String? _statusMessage;
  BangumiLibrarySyncReport? _lastReport;

  /// 当前 Bangumi 同步配置快照。
  BangumiSyncConfig get config => _config;

  /// 安全存储中是否已配置 PAT。
  bool get hasToken => _hasToken;

  /// 当前是否有网络验证、队列冲刷或全库同步正在执行。
  bool get isBusy => _isBusy;

  /// Bangumi 是否处于鉴权失效待重绑状态。
  bool get authInvalid =>
      _authInvalidByTracker[BangumiTrackerProvider.trackerKey] ?? false;

  /// Bangumi 鉴权失效提示文案。
  String? get authErrorMessage =>
      _authMessageByTracker[BangumiTrackerProvider.trackerKey];

  /// 界面展示的最近操作反馈文案。
  String? get statusMessage => _statusMessage;

  /// 最近一次全库同步执行报告。
  BangumiLibrarySyncReport? get lastReport => _lastReport;

  /// 当前 Bangumi 待同步或暂停队列快照。
  List<TrackerSyncQueueItem> get pendingBangumiItems => _pendingBangumiItems;

  /// 当前 Bangumi 队列总条目数。
  int get pendingCount => _pendingBangumiItems.length;

  /// 可继续重试的 Bangumi 队列条目数。
  int get retryablePendingCount => _pendingBangumiItems
      .where((item) => item.nextRetryAtMs < nonRetryableNextRetryAtMs)
      .length;

  /// 因 401/403 或永久错误暂停的队列条目数。
  int get pausedPendingCount => _pendingBangumiItems
      .where((item) => item.nextRetryAtMs >= nonRetryableNextRetryAtMs)
      .length;

  /// 已注册的追番同步提供者只读映射。
  Map<String, ProgressTrackerProvider> get providers =>
      Map<String, ProgressTrackerProvider>.unmodifiable(_providers);

  /// 指定追番平台是否处于鉴权失效暂停状态。
  bool isTrackerAuthInvalid(String trackerId) =>
      _authInvalidByTracker[trackerId] ?? false;

  /// 动态注册额外第三方追番平台提供者。
  void registerProvider(ProgressTrackerProvider provider) {
    _providers[provider.trackerId] = provider;
    _safeNotify();
  }

  /// 等待当前串行事件与队列任务执行完毕（主要供测试同步观测）。
  Future<void> waitForIdle() async {
    Future<void> last;
    do {
      await Future<void>.delayed(Duration.zero);
      last = _serialChain;
      await last;
    } while (!identical(last, _serialChain));
  }

  /// 刷新并加载最新配置与凭据状态。
  Future<void> reload() async {
    _config = _configStore.readConfig();
    await _refreshTokenPresence();
    _pendingBangumiItems = _databases.userState.trackerSyncQueue
        .listDueForTracker(
          BangumiTrackerProvider.trackerKey,
          nowMs: nonRetryableNextRetryAtMs,
          limit: 500,
        );
    _safeNotify();
  }

  /// 更新 Bangumi 非敏感同步开关或模式。
  Future<void> updateConfig(BangumiSyncConfig next) async {
    _config = next;
    await _configStore.saveConfig(next);
    _safeNotify();
  }

  /// 绑定并验证新的 Bangumi PAT；验证成功后重置因鉴权暂停的队列条目。
  Future<BangumiUserProfile> bindAndVerifyToken(String rawToken) async {
    final token = rawToken.trim();
    if (token.isEmpty) {
      throw const BangumiAuthException(
        statusCode: 401,
        message: '请输入 Bangumi PAT',
      );
    }

    _setBusy(true);
    try {
      final profile = await _client.verifyToken(token);
      await _configStore.saveToken(token);
      _hasToken = true;
      _config = _config.copyWith(enabled: true, verifiedProfile: profile);
      await _configStore.saveConfig(_config);

      final nowMs = _clock().toUtc().millisecondsSinceEpoch;
      _authInvalidByTracker[BangumiTrackerProvider.trackerKey] = false;
      _authMessageByTracker.remove(BangumiTrackerProvider.trackerKey);
      _configStore.writeAuthState(authInvalid: false, updatedAtMs: nowMs);

      _rearmPausedBangumiItems();
      _statusMessage = '已验证并绑定账号 ${profile.nickname}';
      _diagnosticLog.logEvent(
        subsystem: DiagnosticSubsystem.tracker,
        code: 'TRACKER_TOKEN_VERIFIED',
        message: 'Bangumi PAT 验证通过并完成绑定',
        source: 'TrackerSyncCoordinator',
      );
      return profile;
    } on BangumiAuthException catch (error) {
      final nowMs = _clock().toUtc().millisecondsSinceEpoch;
      final safeMsg = _sanitizeError(error.message, extraSecret: token);
      _authInvalidByTracker[BangumiTrackerProvider.trackerKey] = true;
      _authMessageByTracker[BangumiTrackerProvider.trackerKey] = safeMsg;
      _configStore.writeAuthState(
        authInvalid: true,
        authError: safeMsg,
        updatedAtMs: nowMs,
      );
      _statusMessage = safeMsg;
      rethrow;
    } on BangumiApiException catch (error) {
      _statusMessage = _sanitizeError(error.message, extraSecret: token);
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  /// 解绑当前 Bangumi PAT 并清理账号展示信息。
  Future<void> unbindToken() async {
    _setBusy(true);
    try {
      await _configStore.deleteToken();
      _hasToken = false;
      _config = _config.copyWith(clearVerifiedProfile: true);
      await _configStore.saveConfig(_config);

      final nowMs = _clock().toUtc().millisecondsSinceEpoch;
      _authInvalidByTracker.remove(BangumiTrackerProvider.trackerKey);
      _authMessageByTracker.remove(BangumiTrackerProvider.trackerKey);
      _configStore.writeAuthState(authInvalid: false, updatedAtMs: nowMs);
      _statusMessage = '已解绑 Bangumi PAT';
    } finally {
      _setBusy(false);
    }
  }

  /// 冲刷已到重试窗口的追番队列。
  ///
  /// 当 [includeBackoffScheduled] 为 `true`（如用户点击手动一键补推）时，
  /// 会立刻重发处于退避等待中的条目，但绝不会跳过 401/403 暂停标记。
  Future<int> flushDueQueue({
    String? trackerId,
    bool includeBackoffScheduled = false,
    DateTime? nowOverride,
  }) {
    return _enqueueSerial(
      () => _flushDueQueueInternal(
        trackerId: trackerId,
        includeBackoffScheduled: includeBackoffScheduled,
        nowOverride: nowOverride,
      ),
    );
  }

  /// 手动立即同步单部作品的观看进度（支持本地向远端推送与按模式回补本地完播状态）。
  Future<BangumiWorkSyncResult> syncWork(WorkId workId) {
    return _enqueueSerial(() => _syncWorkInternal(workId));
  }

  /// 手动执行全库作品 Bangumi 双向追番对齐。
  Future<BangumiLibrarySyncReport> syncAllLibraryWorks({
    bool ignoreManualGuard = false,
  }) {
    return _enqueueSerial(
      () => _syncAllInternal(ignoreManualGuard: ignoreManualGuard),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _eventSub?.cancel();
    _configSub?.cancel();
    _queueSub?.cancel();
    _autoFlushTimer?.cancel();
    super.dispose();
  }

  Future<T> _enqueueSerial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serialChain = _serialChain.then((_) async {
      if (_disposed) {
        completer.completeError(StateError('TrackerSyncCoordinator 已释放'));
        return;
      }
      try {
        final result = await action();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  void _onEpisodeCompletionEvent(EpisodeCompletionChangedEvent event) {
    if (_disposed) {
      return;
    }
    unawaited(
      _enqueueSerial(() => _handleCompletionEventInternal(event)).catchError(
        (_) {},
      ),
    );
  }

  void _onConfigUpdated(BangumiSyncConfig next) {
    _config = next;
    _safeNotify();
  }

  void _onBangumiQueueUpdated(List<TrackerSyncQueueItem> items) {
    _pendingBangumiItems = items;
    _safeNotify();
  }

  Future<void> _refreshTokenPresence() async {
    _hasToken = await _configStore.hasToken();
    _safeNotify();
  }

  Future<void> _handleCompletionEventInternal(
    EpisodeCompletionChangedEvent event,
  ) async {
    _config = _configStore.readConfig();
    if (!_config.enabled || !_config.autoSyncOnEpisodeComplete) {
      return;
    }

    final work = _databases.library.works.findById(event.workId);
    final episode = _databases.library.episodes.findById(event.episodeId);
    if (work == null || work.isDeleted || episode == null || episode.isDeleted) {
      return;
    }

    final resolvedEpisodeNum = BangumiEpisodeAligner.resolveMainEpisodeNumberForPush(
      work: work,
      episode: episode,
    );
    if (resolvedEpisodeNum == null) {
      return;
    }

    final workEpisodes = _databases.library.episodes
        .listByWork(work.id)
        .where(
          (ep) =>
              !ep.isDeleted &&
              ep.category == EpisodeCategory.main &&
              ep.seasonNumber > 0,
        )
        .toList();
    var completedCount = 0;
    for (final ep in workEpisodes) {
      final isEpDone = ep.id == event.episodeId
          ? event.completed
          : (_databases.userState.playbackRecords
                    .findLatestByEpisode(ep.id)
                    ?.isCompleted ??
                false);
      if (isEpDone) {
        completedCount++;
      }
    }

    var enqueuedAny = false;
    final nowMs = _clock().toUtc().millisecondsSinceEpoch;
    for (final provider in _providers.values) {
      final subjectId = _subjectResolver(provider.trackerId, work);
      if (subjectId == null || subjectId.isEmpty) {
        continue;
      }
      final configured = await provider.isConfigured();
      if (!configured) {
        continue;
      }

      final queueKey =
          '${provider.trackerId}:$subjectId:s${episode.seasonNumber}:e$resolvedEpisodeNum';
      final isPausedByAuth = isTrackerAuthInvalid(provider.trackerId);
      final payloadJson = jsonEncode(<String, Object?>{
        'workId': work.id.value,
        'workTitle': work.title,
        'episodeId': episode.id.value,
        'completed': event.completed,
        'autoMarkCollectionCompleted': _config.autoMarkCollectionCompleted,
        'localMainEpisodeCount': workEpisodes.length,
        'localCompletedCount': completedCount,
      });

      _databases.userState.trackerSyncQueue.enqueue(
        TrackerSyncQueueItem(
          queueKey: queueKey,
          trackerId: provider.trackerId,
          externalSubjectId: subjectId,
          seasonNumber: episode.seasonNumber,
          episodeNumber: resolvedEpisodeNum,
          targetStatus: event.completed
              ? BangumiEpisodeWatchStatus.watched.apiValue
              : BangumiEpisodeWatchStatus.unwatched.apiValue,
          payloadJson: payloadJson,
          enqueuedAtMs: nowMs,
          nextRetryAtMs: isPausedByAuth ? nonRetryableNextRetryAtMs : 0,
          lastError: isPausedByAuth
              ? _authMessageByTracker[provider.trackerId]
              : null,
        ),
      );
      enqueuedAny = true;
    }

    _pendingBangumiItems = _databases.userState.trackerSyncQueue
        .listDueForTracker(
          BangumiTrackerProvider.trackerKey,
          nowMs: nonRetryableNextRetryAtMs,
          limit: 500,
        );
    _safeNotify();

    if (enqueuedAny && _autoFlushOnEvent) {
      await _flushDueQueueInternal(nowOverride: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true));
    }
  }

  Future<int> _flushDueQueueInternal({
    String? trackerId,
    bool includeBackoffScheduled = false,
    DateTime? nowOverride,
  }) async {
    final nowMs = (nowOverride ?? _clock()).toUtc().millisecondsSinceEpoch;
    final targetTrackers = trackerId != null
        ? <String>[trackerId]
        : _providers.keys.toList();

    var succeededCount = 0;
    for (final id in targetTrackers) {
      final provider = _providers[id];
      if (provider == null) {
        continue;
      }

      if (isTrackerAuthInvalid(id)) {
        if (id == BangumiTrackerProvider.trackerKey) {
          _statusMessage =
              _authMessageByTracker[id] ?? 'Bangumi PAT 已失效，请先重新绑定后再补推';
          _safeNotify();
        }
        continue;
      }

      if (!await provider.isConfigured()) {
        continue;
      }

      final candidates = includeBackoffScheduled
          ? _databases.userState.trackerSyncQueue
                .listDueForTracker(
                  id,
                  nowMs: nonRetryableNextRetryAtMs - 1,
                  limit: 200,
                )
          : _databases.userState.trackerSyncQueue.listDueForTracker(
              id,
              nowMs: nowMs,
              limit: 200,
            );

      for (final item in candidates) {
        if (item.nextRetryAtMs >= nonRetryableNextRetryAtMs) {
          continue;
        }

        final meta = _decodePayloadMap(item.payloadJson);
        final completed = meta['completed'] is bool
            ? meta['completed'] as bool
            : item.targetStatus == BangumiEpisodeWatchStatus.watched.apiValue;

        final result = await provider.pushProgress(
          TrackerProgressPayload(
            trackerId: item.trackerId,
            externalSubjectId: item.externalSubjectId,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            completed: completed,
            extraMetadata: meta,
          ),
        );

        if (result.success) {
          _databases.userState.trackerSyncQueue.remove(item.queueKey);
          succeededCount++;
          continue;
        }

        final safeError = _sanitizeError(result.errorMessage ?? '推送追番进度失败');
        final nextRetryCount = item.retryCount + 1;

        if (!result.retryable && _looksLikeAuthFailure(safeError)) {
          _authInvalidByTracker[id] = true;
          _authMessageByTracker[id] = safeError;
          if (id == BangumiTrackerProvider.trackerKey) {
            _configStore.writeAuthState(
              authInvalid: true,
              authError: safeError,
              updatedAtMs: nowMs,
            );
          }
          _databases.userState.trackerSyncQueue.markRetryFailed(
            item.queueKey,
            retryCount: nextRetryCount,
            nextRetryAtMs: nonRetryableNextRetryAtMs,
            lastError: safeError,
          );
          _statusMessage = safeError;
          _diagnosticLog.logEvent(
            subsystem: DiagnosticSubsystem.tracker,
            code: 'TRACKER_QUEUE_PAUSED_AUTH',
            message: '检测到鉴权失效，已暂停追番队列自动重试',
            severity: DiagnosticSeverity.warn,
            source: 'TrackerSyncCoordinator',
            context: <String, Object?>{
              'trackerId': id,
              'queueKey': item.queueKey,
            },
          );
          break;
        }

        if (!result.retryable || nextRetryCount >= maxRetryAttempts) {
          _databases.userState.trackerSyncQueue.markRetryFailed(
            item.queueKey,
            retryCount: nextRetryCount,
            nextRetryAtMs: nonRetryableNextRetryAtMs,
            lastError: safeError,
          );
          _statusMessage = safeError;
          continue;
        }

        final delayIndex = math.min(
          item.retryCount,
          backoffDelaySeconds.length - 1,
        );
        final nextRetryAt = nowMs + backoffDelaySeconds[delayIndex] * 1000;
        _databases.userState.trackerSyncQueue.markRetryFailed(
          item.queueKey,
          retryCount: nextRetryCount,
          nextRetryAtMs: nextRetryAt,
          lastError: safeError,
        );
        _statusMessage = safeError;
      }
    }

    _pendingBangumiItems = _databases.userState.trackerSyncQueue
        .listDueForTracker(
          BangumiTrackerProvider.trackerKey,
          nowMs: nonRetryableNextRetryAtMs,
          limit: 500,
        );
    if (succeededCount > 0 && _authInvalidByTracker[BangumiTrackerProvider.trackerKey] != true) {
      _statusMessage = '已成功补推 $succeededCount 条追番进度';
    }
    _safeNotify();
    return succeededCount;
  }

  Future<BangumiWorkSyncResult> _syncWorkInternal(WorkId workId) async {
    final work = _databases.library.works.findById(workId);
    if (work == null || work.isDeleted) {
      return BangumiWorkSyncResult(
        workId: workId,
        workTitle: workId.value,
        skippedReason: '作品不存在或已删除',
      );
    }

    final subjectId = work.bangumiId;
    if (subjectId == null || subjectId <= 0) {
      return BangumiWorkSyncResult(
        workId: work.id,
        workTitle: work.title,
        skippedReason: '未绑定 Bangumi 条目编号',
      );
    }

    if (authInvalid) {
      return BangumiWorkSyncResult(
        workId: work.id,
        workTitle: work.title,
        subjectId: subjectId,
        authInvalid: true,
        errorMessage: authErrorMessage ?? 'Bangumi PAT 已失效，请重新绑定',
      );
    }

    final token = await _configStore.readToken();
    if (token == null || token.isEmpty) {
      return BangumiWorkSyncResult(
        workId: work.id,
        workTitle: work.title,
        subjectId: subjectId,
        skippedReason: '尚未绑定 Bangumi PAT',
      );
    }

    final episodes = _databases.library.episodes.listByWork(work.id);
    final completedIds = <EpisodeId>{};
    for (final ep in episodes) {
      final latest = _databases.userState.playbackRecords.findLatestByEpisode(
        ep.id,
      );
      if (latest != null && latest.isCompleted) {
        completedIds.add(ep.id);
      }
    }

    try {
      final remoteEpisodes = await _client.fetchSubjectEpisodes(
        token: token,
        subjectId: subjectId,
        type: 0,
      );
      final plan = BangumiEpisodeAligner.buildPlan(
        work: work,
        localEpisodes: episodes,
        completedLocalEpisodeIds: completedIds,
        remoteEpisodes: remoteEpisodes,
        syncMode: _config.syncMode,
      );
      if (plan.matchedLocalEpisodes.isEmpty) {
        return BangumiWorkSyncResult(
          workId: work.id,
          workTitle: work.title,
          subjectId: subjectId,
          skippedReason: '未找到可对齐的正片剧集',
        );
      }

      if (plan.episodeIdsToPushWatched.isNotEmpty) {
        await _client.patchSubjectEpisodes(
          token: token,
          subjectId: subjectId,
          episodeIds: plan.episodeIdsToPushWatched,
          status: BangumiEpisodeWatchStatus.watched,
        );
      }

      if (plan.localEpisodeIdsToPullWatched.isNotEmpty) {
        _applyPulledEpisodeCompletions(
          work: work,
          episodes: episodes,
          pulledEpisodeIds: plan.localEpisodeIdsToPullWatched,
        );
      }

      var collectionUpdated = false;
      final existingCollection = await _client.fetchUserSubjectCollection(
        token: token,
        subjectId: subjectId,
      );
      final hasAnyCompleted =
          completedIds.isNotEmpty || plan.localEpisodeIdsToPullWatched.isNotEmpty;
      final shouldMarkCollect =
          _config.autoMarkCollectionCompleted &&
          _config.syncMode == BangumiSyncMode.autoCompleteAndPush &&
          plan.allLocalCompletedAfterPull &&
          plan.allRemoteCompletedAfterPush;

      if (shouldMarkCollect &&
          existingCollection != BangumiCollectionType.collect) {
        await _client.upsertUserSubjectCollection(
          token: token,
          subjectId: subjectId,
          type: BangumiCollectionType.collect,
        );
        collectionUpdated = true;
      } else if (hasAnyCompleted &&
          (existingCollection == null ||
              existingCollection == BangumiCollectionType.wish)) {
        await _client.upsertUserSubjectCollection(
          token: token,
          subjectId: subjectId,
          type: BangumiCollectionType.doing,
        );
        collectionUpdated = true;
      }

      final localCompletedAfter =
          completedIds.length + plan.localEpisodeIdsToPullWatched.length;
      return BangumiWorkSyncResult(
        workId: work.id,
        workTitle: work.title,
        subjectId: subjectId,
        matchedLocalEpisodeCount: plan.matchedLocalEpisodes.length,
        localCompletedEpisodeCount: localCompletedAfter,
        pushedEpisodes: plan.episodeIdsToPushWatched.length,
        pulledEpisodes: plan.localEpisodeIdsToPullWatched.length,
        collectionUpdated: collectionUpdated,
      );
    } on BangumiAuthException catch (error) {
      final nowMs = _clock().toUtc().millisecondsSinceEpoch;
      final safeMsg = _sanitizeError(error.message, extraSecret: token);
      _authInvalidByTracker[BangumiTrackerProvider.trackerKey] = true;
      _authMessageByTracker[BangumiTrackerProvider.trackerKey] = safeMsg;
      _configStore.writeAuthState(
        authInvalid: true,
        authError: safeMsg,
        updatedAtMs: nowMs,
      );
      _statusMessage = safeMsg;
      _safeNotify();
      return BangumiWorkSyncResult(
        workId: work.id,
        workTitle: work.title,
        subjectId: subjectId,
        authInvalid: true,
        errorMessage: safeMsg,
      );
    } on BangumiApiException catch (error) {
      return BangumiWorkSyncResult(
        workId: work.id,
        workTitle: work.title,
        subjectId: subjectId,
        errorMessage: _sanitizeError(error.message, extraSecret: token),
      );
    } catch (error) {
      return BangumiWorkSyncResult(
        workId: work.id,
        workTitle: work.title,
        subjectId: subjectId,
        errorMessage: _sanitizeError(error.toString(), extraSecret: token),
      );
    }
  }

  Future<BangumiLibrarySyncReport> _syncAllInternal({
    bool ignoreManualGuard = false,
  }) async {
    _setBusy(true);
    final startedAt = _clock();
    try {
      _config = _configStore.readConfig();
      if (!ignoreManualGuard && !_config.enabled) {
        final report = BangumiLibrarySyncReport(
          startedAt: startedAt,
          finishedAt: _clock(),
          errorMessages: const <String>['Bangumi 追番同步已关闭'],
        );
        _lastReport = report;
        _statusMessage = 'Bangumi 追番同步已关闭';
        return report;
      }

      if (authInvalid) {
        final msg = authErrorMessage ?? 'Bangumi PAT 已失效，请重新绑定后再试';
        final report = BangumiLibrarySyncReport(
          startedAt: startedAt,
          finishedAt: _clock(),
          authInvalid: true,
          errorMessages: <String>[msg],
        );
        _lastReport = report;
        _statusMessage = msg;
        return report;
      }

      await _flushDueQueueInternal(
        trackerId: BangumiTrackerProvider.trackerKey,
        includeBackoffScheduled: true,
        nowOverride: startedAt,
      );
      if (authInvalid) {
        final msg = authErrorMessage ?? 'Bangumi PAT 已失效，请重新绑定后再试';
        final report = BangumiLibrarySyncReport(
          startedAt: startedAt,
          finishedAt: _clock(),
          authInvalid: true,
          errorMessages: <String>[msg],
        );
        _lastReport = report;
        _statusMessage = msg;
        return report;
      }

      final works = _databases.library.works.listVisible();
      var syncedWorks = 0;
      var skippedWorks = 0;
      var pushedEpisodes = 0;
      var pulledEpisodes = 0;
      var updatedCollections = 0;
      var failedWorks = 0;
      var hitAuthInvalid = false;
      final errors = <String>[];

      for (final work in works) {
        if (work.bangumiId == null || work.bangumiId! <= 0) {
          skippedWorks++;
          continue;
        }
        final res = await _syncWorkInternal(work.id);
        if (res.authInvalid) {
          failedWorks++;
          hitAuthInvalid = true;
          if (res.errorMessage != null) {
            errors.add(res.errorMessage!);
          }
          break;
        }
        if (res.hasError) {
          failedWorks++;
          errors.add('${res.workTitle}: ${res.errorMessage}');
          continue;
        }
        if (res.skippedReason != null) {
          skippedWorks++;
          continue;
        }
        syncedWorks++;
        pushedEpisodes += res.pushedEpisodes;
        pulledEpisodes += res.pulledEpisodes;
        if (res.collectionUpdated) {
          updatedCollections++;
        }
      }

      final finishedAt = _clock();
      if (!hitAuthInvalid) {
        _config = _config.copyWith(
          lastFullSyncAtMs: finishedAt.toUtc().millisecondsSinceEpoch,
        );
        await _configStore.saveConfig(_config);
      }

      final report = BangumiLibrarySyncReport(
        startedAt: startedAt,
        finishedAt: finishedAt,
        syncedWorks: syncedWorks,
        skippedWorks: skippedWorks,
        pushedEpisodes: pushedEpisodes,
        pulledEpisodes: pulledEpisodes,
        updatedCollections: updatedCollections,
        failedWorks: failedWorks,
        authInvalid: hitAuthInvalid,
        errorMessages: errors,
      );
      _lastReport = report;
      _statusMessage = hitAuthInvalid
          ? (errors.isNotEmpty ? errors.first : 'Bangumi PAT 已失效，请重新绑定')
          : '全库同步完成：同步 $syncedWorks 部，推送 $pushedEpisodes 集，回写 $pulledEpisodes 集';
      return report;
    } finally {
      _setBusy(false);
    }
  }

  void _applyPulledEpisodeCompletions({
    required WorkRecord work,
    required List<EpisodeRecord> episodes,
    required List<EpisodeId> pulledEpisodeIds,
  }) {
    final variants = _databases.library.mediaVariants.listByWork(work.id);
    final epById = <EpisodeId, EpisodeRecord>{
      for (final ep in episodes) ep.id: ep,
    };
    final nowMs = _clock().toUtc().millisecondsSinceEpoch;

    for (final epId in pulledEpisodeIds) {
      final ep = epById[epId];
      if (ep == null) {
        continue;
      }
      final existing = _databases.userState.playbackRecords.findLatestByEpisode(
        epId,
      );
      final variantId =
          existing?.variantId ??
          variants
              .where((v) => v.episodeId == epId && !v.isDeleted)
              .map((v) => v.id)
              .firstOrNull ??
          variants.map((v) => v.id).firstOrNull ??
          VariantId.trusted('tracker_sync_${work.id.value}');

      // 从远端回写本地完成状态时直接更新播放记录表，避免再次触发出站推送循环。
      _databases.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: existing?.id ?? 'tracker_pull_${work.id.value}_${epId.value}',
          canonicalKey: existing?.canonicalKey ?? ep.canonicalKey,
          workId: work.id,
          episodeId: epId,
          variantId: variantId,
          seasonNumber: ep.seasonNumber,
          episodeNumber: ep.episodeNumber,
          episodeTitle: ep.title ?? '',
          sourceKind: existing?.sourceKind ?? MediaSourceKind.local,
          playedAtMs: existing?.playedAtMs ?? nowMs,
          positionSeconds: existing?.positionSeconds ?? 0,
          durationSeconds: existing?.durationSeconds ?? 0,
          isCompleted: true,
          updatedAtMs: nowMs,
          sourceDeviceId: 'bangumi_tracker',
        ),
      );
    }
  }

  void _rearmPausedBangumiItems() {
    final existing = _databases.userState.trackerSyncQueue.listDueForTracker(
      BangumiTrackerProvider.trackerKey,
      nowMs: nonRetryableNextRetryAtMs,
      limit: 500,
    );
    for (final item in existing) {
      if (item.nextRetryAtMs < nonRetryableNextRetryAtMs) {
        continue;
      }
      _databases.userState.trackerSyncQueue.enqueue(
        TrackerSyncQueueItem(
          queueKey: item.queueKey,
          trackerId: item.trackerId,
          externalSubjectId: item.externalSubjectId,
          seasonNumber: item.seasonNumber,
          episodeNumber: item.episodeNumber,
          targetStatus: item.targetStatus,
          payloadJson: item.payloadJson,
          enqueuedAtMs: item.enqueuedAtMs,
          retryCount: 0,
          nextRetryAtMs: 0,
          lastError: null,
        ),
      );
    }
    _pendingBangumiItems = _databases.userState.trackerSyncQueue
        .listDueForTracker(
          BangumiTrackerProvider.trackerKey,
          nowMs: nonRetryableNextRetryAtMs,
          limit: 500,
        );
  }

  static Map<String, Object?> _decodePayloadMap(String raw) {
    if (raw.trim().isEmpty) {
      return const <String, Object?>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // 忽略损坏附加载荷并按基础字段执行推送。
    }
    return const <String, Object?>{};
  }

  static bool _looksLikeAuthFailure(String msg) {
    return msg.contains('鉴权失效') ||
        msg.contains('401') ||
        msg.contains('403') ||
        msg.contains('PAT');
  }

  String _sanitizeError(String raw, {String? extraSecret}) {
    var result = raw.trim();
    if (extraSecret != null && extraSecret.isNotEmpty) {
      result = result.replaceAll(extraSecret, '[REDACTED]');
    }
    result = NetworkErrorSanitizer.redactSecrets(result);
    return DiagnosticTextSanitizer.redactSecrets(result);
  }

  void _setBusy(bool value) {
    _isBusy = value;
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
