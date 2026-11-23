import 'dart:async';
import 'dart:convert';

import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/logging/diagnostic_event.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/sync/bangumi_sync_models.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/network/bangumi_sync_client.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/sync/konata_sync_store.dart';

/// Bangumi PAT 观看进度双向同步与离线重试队列编排服务。
class BangumiProgressSyncService {
  /// 创建 Bangumi 进度同步服务。
  BangumiProgressSyncService({
    required LibraryRepository repository,
    required this._syncStore,
    required this._client,
    this._logStore,
    DateTime Function()? clock,
  }) : _repo = repository,
       _clock = clock ?? DateTime.now;

  static const int _maxRetryAttempts = 6;

  final LibraryRepository _repo;
  final KonataSyncStore _syncStore;
  final BangumiSyncClient _client;
  final DiagnosticsLogStore? _logStore;
  final DateTime Function() _clock;

  Future<int>? _inFlightFlush;

  /// 验证 PAT 并缓存公开账号资料至 `SyncKvMeta`。
  Future<BangumiUserProfile> verifyAndCacheProfile(String pat) async {
    final profile = await _client.verifyToken(pat);
    await _syncStore.writeMeta(
      KonataSyncStore.metaKeyBangumiProfileJson,
      jsonEncode(profile.toJson()),
    );
    _logStore?.logEvent(
      subsystem: DiagnosticSubsystem.bangumi,
      code: 'BGM_PROFILE_VERIFIED',
      message: '已验证 Bangumi 账号：${profile.displayLabel}',
      source:
          'lib/application/sync/bangumi_progress_sync_service.dart:verifyAndCacheProfile',
      context: <String, Object?>{'userId': profile.id},
    );
    return profile;
  }

  /// 读取本地缓存的 Bangumi 公开账号资料。
  Future<BangumiUserProfile?> readCachedProfile() async {
    final raw = await _syncStore.readMeta(
      KonataSyncStore.metaKeyBangumiProfileJson,
    );
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return BangumiUserProfile.fromJson(
          decoded.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// 当单集本地完播或手动标记已看时，先持久化入队再立即异步冲刷上报（离线绝不丢进度）。
  Future<void> enqueueEpisodeWatched({
    required BangumiSyncConfig config,
    required Work work,
    required Episode episode,
    bool watched = true,
  }) async {
    final subjectId = work.bangumiId;
    if (!config.enabled ||
        !config.autoPushOnComplete ||
        !config.hasToken ||
        subjectId == null ||
        subjectId <= 0) {
      return;
    }
    // 非主正片且非 Season 0 特别篇的零散特典（如 CM/NCOP/Menu）不向 Bangumi 章节上报。
    if (episode.category != EpisodeCategory.main && episode.seasonNumber != 0) {
      return;
    }
    final epPart = episode.episodeNumber == null
        ? 'feature'
        : 'e${episode.episodeNumber}';
    final queueKey = 'ep::$subjectId::s${episode.seasonNumber}::$epPart';
    await _syncStore.enqueueBangumiSyncItem(
      queueKey: queueKey,
      subjectId: subjectId,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      targetStatus: watched
          ? BangumiEpisodeWatchStatus.watched
          : BangumiEpisodeWatchStatus.unwatched,
      nowMs: _clock().millisecondsSinceEpoch,
    );
    await flushPendingQueue(config);
  }

  /// 冲刷本地 SQLite 中待重试的 Bangumi 上报队列（按 `subjectId` 分组批量 `PATCH`）。
  Future<int> flushPendingQueue(
    BangumiSyncConfig config, {
    bool ignoreBackoff = false,
  }) {
    final active = _inFlightFlush;
    if (active != null) return active;
    final run = _flushPendingQueueInternal(
      config,
      ignoreBackoff: ignoreBackoff,
    );
    _inFlightFlush = run;
    return run.whenComplete(() {
      if (identical(_inFlightFlush, run)) {
        _inFlightFlush = null;
      }
    });
  }

  Future<int> _flushPendingQueueInternal(
    BangumiSyncConfig config, {
    required bool ignoreBackoff,
  }) async {
    if (!config.enabled || !config.hasToken) return 0;
    final nowMs = _clock().millisecondsSinceEpoch;
    final items = await _syncStore.readBangumiSyncQueue(
      dueBeforeMs: ignoreBackoff ? null : nowMs,
    );
    if (items.isEmpty) return 0;

    final bySubject = <int, List<BangumiSyncQueueItem>>{};
    for (final item in items) {
      bySubject.putIfAbsent(item.subjectId, () => <BangumiSyncQueueItem>[]).add(
        item,
      );
    }

    var flushed = 0;
    for (final entry in bySubject.entries) {
      final subjectId = entry.key;
      final group = entry.value;
      try {
        var collection = await _client.fetchSubjectEpisodes(
          subjectId: subjectId,
          personalAccessToken: config.personalAccessToken,
        );
        if (!collection.isCollected) {
          await _client.upsertSubjectCollection(
            subjectId: subjectId,
            collectionType: BangumiCollectionType.doing,
            personalAccessToken: config.personalAccessToken,
          );
          collection = await _client.fetchSubjectEpisodes(
            subjectId: subjectId,
            personalAccessToken: config.personalAccessToken,
          );
        }

        final idsByStatus = <int, List<int>>{};
        final matchedKeys = <String>[];
        final unmatchableKeys = <String>[];

        for (final item in group) {
          final remoteEp = BangumiEpisodeAligner.matchRemoteEpisode(
            remoteEpisodes: collection.episodes,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            isSpecial: item.seasonNumber == 0,
          );
          if (remoteEp == null) {
            unmatchableKeys.add(item.queueKey);
            continue;
          }
          if (remoteEp.watchStatus != item.targetStatus) {
            idsByStatus
                .putIfAbsent(item.targetStatus, () => <int>[])
                .add(remoteEp.episodeId);
          }
          matchedKeys.add(item.queueKey);
        }

        for (final statusEntry in idsByStatus.entries) {
          await _client.patchEpisodesStatus(
            subjectId: subjectId,
            episodeIds: statusEntry.value,
            watchStatus: statusEntry.key,
            personalAccessToken: config.personalAccessToken,
          );
        }

        // 若全部本篇章节均已看完，自动将条目标记为「看过」。
        if (config.autoMarkSubjectCompleted &&
            idsByStatus.containsKey(BangumiEpisodeWatchStatus.watched)) {
          final newlyWatchedIds = idsByStatus[BangumiEpisodeWatchStatus.watched]!
              .toSet();
          final mainEps = collection.episodes
              .where((e) => e.isMainEpisode)
              .toList(growable: false);
          if (mainEps.isNotEmpty &&
              mainEps.every(
                (e) => e.isWatched || newlyWatchedIds.contains(e.episodeId),
              )) {
            await _client.upsertSubjectCollection(
              subjectId: subjectId,
              collectionType: BangumiCollectionType.collect,
              personalAccessToken: config.personalAccessToken,
            );
          }
        }

        await _syncStore.removeBangumiQueueKeys(<String>[
          ...matchedKeys,
          ...unmatchableKeys,
        ]);
        flushed += matchedKeys.length;
      } on BangumiAuthException catch (authErr) {
        _logStore?.logError(
          subsystem: DiagnosticSubsystem.bangumi,
          code: 'BGM_QUEUE_AUTH_STOPPED',
          message: authErr.message,
          error: authErr,
          source:
              'lib/application/sync/bangumi_progress_sync_service.dart:_flushPendingQueueInternal',
          context: <String, Object?>{'subjectId': subjectId},
        );
        // 鉴权失败后立刻终止整轮冲刷，避免对失效 PAT 持续重试。
        rethrow;
      } catch (error, stackTrace) {
        final friendly = NetworkErrorSanitizer.toUserMessage(error);
        for (final item in group) {
          final nextCount = item.retryCount + 1;
          if (nextCount >= _maxRetryAttempts) {
            await _syncStore.removeBangumiQueueKeys(<String>[item.queueKey]);
          } else {
            final delaySeconds = _backoffSeconds(nextCount);
            await _syncStore.markBangumiQueueRetryFailed(
              queueKey: item.queueKey,
              retryCount: nextCount,
              errorMessage: friendly,
              nextRetryAtMs: nowMs + delaySeconds * 1000,
            );
          }
        }
        _logStore?.logError(
          subsystem: DiagnosticSubsystem.bangumi,
          severity: DiagnosticSeverity.warn,
          code: 'BGM_QUEUE_RETRY_SCHEDULED',
          message: 'Bangumi 条目 #$subjectId 上报暂时失败，已写入重试队列：$friendly',
          error: error,
          stackTrace: stackTrace,
          source:
              'lib/application/sync/bangumi_progress_sync_service.dart:_flushPendingQueueInternal',
          context: <String, Object?>{
            'subjectId': subjectId,
            'groupSize': group.length,
          },
        );
      }
    }
    return flushed;
  }

  /// 对单部已绑定 `bangumiId` 的作品执行完整的双向（或仅上报）进度同步。
  Future<BangumiWorkSyncResult> syncWork({
    required BangumiSyncConfig config,
    required String workId,
    RequestPriority priority = RequestPriority.interactive,
  }) async {
    if (!config.hasToken) {
      throw const BangumiAuthException('请先在「设置 -> 备份与同步」填写 Bangumi 个人访问令牌');
    }
    final work = await _repo.findWorkById(workId);
    if (work == null) {
      return BangumiWorkSyncResult(
        workId: workId,
        subjectId: 0,
        error: '作品不存在',
      );
    }
    final subjectId = work.bangumiId;
    if (subjectId == null || subjectId <= 0) {
      return BangumiWorkSyncResult(
        workId: workId,
        subjectId: 0,
        error: '该作品尚未绑定 Bangumi 条目 ID',
      );
    }

    final episodes = await _repo.getEpisodesByWork(work.id);
    final variants = await _repo.getVariantsByWork(work.id);
    final playbacks = await _repo.getPlaybacksByWork(work.id);
    final playbackByEpId = <String, PlaybackRecord>{
      for (final r in playbacks) r.episodeId: r,
    };
    final variantByEpId = <String, String>{};
    for (final v in variants) {
      final epId = v.episodeId;
      if (epId != null && epId.isNotEmpty) {
        variantByEpId.putIfAbsent(epId, () => v.id);
      }
    }

    var collection = await _client.fetchSubjectEpisodes(
      subjectId: subjectId,
      personalAccessToken: config.personalAccessToken,
      priority: priority,
    );

    final localCompletedEps = <Episode>[
      for (final ep in episodes)
        if (playbackByEpId[ep.id]?.isCompleted == true &&
            (ep.category == EpisodeCategory.main || ep.seasonNumber == 0))
          ep,
    ];

    int? promotedTo;
    if (!collection.isCollected && localCompletedEps.isNotEmpty) {
      await _client.upsertSubjectCollection(
        subjectId: subjectId,
        collectionType: BangumiCollectionType.doing,
        personalAccessToken: config.personalAccessToken,
        priority: priority,
      );
      promotedTo = BangumiCollectionType.doing;
      collection = await _client.fetchSubjectEpisodes(
        subjectId: subjectId,
        personalAccessToken: config.personalAccessToken,
        priority: priority,
      );
    }

    var pulledCount = 0;
    if (config.syncMode == BangumiSyncMode.bidirectional &&
        collection.isCollected) {
      final now = _clock();
      for (final remoteEp in collection.episodes) {
        if (!remoteEp.isWatched) continue;
        final localEp = BangumiEpisodeAligner.matchLocalEpisode(
          localEpisodes: episodes,
          remoteEpisode: remoteEp,
        );
        if (localEp == null) continue;
        final existing = playbackByEpId[localEp.id];
        if (existing != null && existing.isCompleted) continue;

        final dur = (existing != null && existing.durationSeconds > 0)
            ? existing.durationSeconds
            : ((existing != null && existing.positionSeconds > 0)
                  ? existing.positionSeconds
                  : 1);
        final updated = PlaybackRecord(
          id: existing?.id ?? '${work.id}::${localEp.id}',
          workId: work.id,
          episodeId: localEp.id,
          variantId: existing?.variantId ?? variantByEpId[localEp.id] ?? '',
          seasonNumber: localEp.seasonNumber,
          episodeNumber: localEp.episodeNumber,
          episodeTitle:
              existing?.episodeTitle ??
              localEp.title ??
              (localEp.episodeNumber != null
                  ? '第 ${localEp.episodeNumber} 话'
                  : work.title),
          sourceType: existing?.sourceType ?? MediaSourceKind.local,
          playedAt: existing?.playedAt ?? now,
          positionSeconds: dur,
          durationSeconds: dur,
          isCompleted: true,
        );
        await _repo.recordPlayback(updated);
        playbackByEpId[localEp.id] = updated;
        pulledCount++;
      }
    }

    final toPushIds = <int>[];
    final seenPushIds = <int>{};
    for (final ep in localCompletedEps) {
      final remoteEp = BangumiEpisodeAligner.matchRemoteEpisode(
        remoteEpisodes: collection.episodes,
        seasonNumber: ep.seasonNumber,
        episodeNumber: ep.episodeNumber,
        isSpecial: ep.seasonNumber == 0,
      );
      if (remoteEp == null || remoteEp.isWatched) continue;
      if (seenPushIds.add(remoteEp.episodeId)) {
        toPushIds.add(remoteEp.episodeId);
      }
    }

    if (toPushIds.isNotEmpty) {
      await _client.patchEpisodesStatus(
        subjectId: subjectId,
        episodeIds: toPushIds,
        watchStatus: BangumiEpisodeWatchStatus.watched,
        personalAccessToken: config.personalAccessToken,
        priority: priority,
      );
    }

    if (config.autoMarkSubjectCompleted && collection.isCollected) {
      final mainRemote = collection.episodes
          .where((e) => e.isMainEpisode)
          .toList(growable: false);
      final allMainWatched =
          mainRemote.isNotEmpty &&
          mainRemote.every(
            (e) => e.isWatched || seenPushIds.contains(e.episodeId),
          );
      if (allMainWatched && toPushIds.isNotEmpty) {
        await _client.upsertSubjectCollection(
          subjectId: subjectId,
          collectionType: BangumiCollectionType.collect,
          personalAccessToken: config.personalAccessToken,
          priority: priority,
        );
        promotedTo = BangumiCollectionType.collect;
      }
    }

    _logStore?.logEvent(
      subsystem: DiagnosticSubsystem.bangumi,
      code: 'BGM_WORK_SYNCED',
      message:
          '作品「${work.title}」(#$subjectId) 同步完成：拉取 $pulledCount 集，上报 ${toPushIds.length} 集',
      source:
          'lib/application/sync/bangumi_progress_sync_service.dart:syncWork',
      context: <String, Object?>{
        'workId': work.id,
        'subjectId': subjectId,
        'pulled': pulledCount,
        'pushed': toPushIds.length,
        'promotedTo': ?promotedTo,
      },
    );

    return BangumiWorkSyncResult(
      workId: work.id,
      subjectId: subjectId,
      pulledWatchedCount: pulledCount,
      pushedWatchedCount: toPushIds.length,
      promotedCollectionTo: promotedTo,
    );
  }

  /// 对媒体库中全部已绑定 `bangumiId` 的作品执行限速全量同步（先冲刷离线队列）。
  Future<BangumiLibrarySyncReport> syncAllLibraryWorks(
    BangumiSyncConfig config,
  ) async {
    if (!config.hasToken) {
      throw const BangumiAuthException('请先填写 Bangumi 个人访问令牌（PAT）');
    }
    _logStore?.recordBreadcrumb(
      category: 'bangumi',
      label: '开始全库 Bangumi 进度同步',
      source:
          'lib/application/sync/bangumi_progress_sync_service.dart:syncAllLibraryWorks',
    );

    final queueFlushed = await flushPendingQueue(config, ignoreBackoff: true);
    final works = (await _repo.getAllWorks())
        .where((w) => w.bangumiId != null && w.bangumiId! > 0 && !w.isHidden)
        .toList(growable: false);

    var succeeded = 0;
    var failed = 0;
    var totalPulled = 0;
    var totalPushed = 0;
    String? firstError;

    // 限制并发度为 2，保护 Bangumi 官方接口不触发 429 限流风暴。
    var cursor = 0;
    var authAborted = false;
    Future<void> worker() async {
      while (!authAborted) {
        final idx = cursor++;
        if (idx >= works.length) return;
        final work = works[idx];
        try {
          final res = await syncWork(
            config: config,
            workId: work.id,
            priority: RequestPriority.background,
          );
          if (res.isSuccess) {
            succeeded++;
            totalPulled += res.pulledWatchedCount;
            totalPushed += res.pushedWatchedCount;
          } else {
            failed++;
            firstError ??= res.error;
          }
        } on BangumiAuthException catch (authErr) {
          authAborted = true;
          failed++;
          firstError ??= authErr.message;
          rethrow;
        } catch (error) {
          failed++;
          firstError ??= NetworkErrorSanitizer.toUserMessage(error);
        }
      }
    }

    await Future.wait(<Future<void>>[
      worker(),
      if (works.length > 1) worker(),
    ]);

    final remaining = (await _syncStore.readBangumiSyncQueue()).length;
    final report = BangumiLibrarySyncReport(
      worksProcessed: works.length,
      worksSucceeded: succeeded,
      worksFailed: failed,
      totalPulled: totalPulled,
      totalPushed: totalPushed,
      queueFlushed: queueFlushed,
      remainingQueued: remaining,
      firstError: firstError,
    );

    final nowMs = _clock().millisecondsSinceEpoch;
    final summary = report.toSummaryMessage();
    await _syncStore.writeMeta(
      KonataSyncStore.metaKeyBangumiLastSyncMs,
      nowMs.toString(),
      updatedAtMs: nowMs,
    );
    await _syncStore.writeMeta(
      KonataSyncStore.metaKeyBangumiLastSummary,
      summary,
      updatedAtMs: nowMs,
    );

    _logStore?.logEvent(
      subsystem: DiagnosticSubsystem.bangumi,
      code: 'BGM_LIBRARY_SYNC_COMPLETED',
      message: 'Bangumi 全库同步结束：$summary',
      source:
          'lib/application/sync/bangumi_progress_sync_service.dart:syncAllLibraryWorks',
      context: <String, Object?>{
        'worksProcessed': works.length,
        'succeeded': succeeded,
        'failed': failed,
        'totalPulled': totalPulled,
        'totalPushed': totalPushed,
        'remainingQueued': remaining,
      },
    );
    return report;
  }

  static int _backoffSeconds(int retryCount) {
    return switch (retryCount) {
      1 => 30,
      2 => 120,
      3 => 600,
      _ => 1800,
    };
  }
}
