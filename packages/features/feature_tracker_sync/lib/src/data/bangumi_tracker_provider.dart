import 'package:konata_contracts/konata_contracts.dart';

import 'bangumi_sync_client.dart';
import 'bangumi_sync_config_store.dart';
import 'bangumi_sync_models.dart';

/// Bangumi 官方进度同步提供者实现。
///
/// 实现共享契约 [ProgressTrackerProvider]，由追番协调器统一编排入队与重试。
final class BangumiTrackerProvider implements ProgressTrackerProvider {
  /// 创建 Bangumi 追番提供者适配器。
  BangumiTrackerProvider({
    required this._configStore,
    required this._client,
  });

  /// Bangumi 提供者固定标识。
  static const String trackerKey = 'bangumi';

  /// Bangumi 中文显示名称。
  static const String trackerDisplayName = 'Bangumi 番组计划';

  final BangumiSyncConfigStore _configStore;
  final BangumiSyncClient _client;

  @override
  String get trackerId => trackerKey;

  @override
  String get displayName => trackerDisplayName;

  @override
  Future<bool> isConfigured() => _configStore.hasToken();

  @override
  Future<TrackerSyncResult> pushProgress(TrackerProgressPayload payload) async {
    final subjectId = int.tryParse(payload.externalSubjectId.trim());
    if (subjectId == null || subjectId <= 0) {
      return const TrackerSyncResult.failed(
        errorMessage: '缺少有效的 Bangumi 条目编号',
        retryable: false,
      );
    }

    final episodeNumber = payload.episodeNumber;
    if (episodeNumber == null || episodeNumber <= 0) {
      return const TrackerSyncResult.failed(
        errorMessage: '缺少有效的正片集号映射',
        retryable: false,
      );
    }

    final token = await _configStore.readToken();
    if (token == null || token.isEmpty) {
      return const TrackerSyncResult.failed(
        errorMessage: '鉴权失效：尚未绑定 Bangumi PAT',
        retryable: false,
      );
    }

    try {
      final config = _configStore.readConfig();
      var collectionChanged = false;
      final existingCollection = await _client.fetchUserSubjectCollection(
        token: token,
        subjectId: subjectId,
      );

      if (payload.completed &&
          (existingCollection == null ||
              existingCollection == BangumiCollectionType.wish)) {
        await _client.upsertUserSubjectCollection(
          token: token,
          subjectId: subjectId,
          type: BangumiCollectionType.doing,
        );
        collectionChanged = true;
      }

      final remoteEpisodes = await _client.fetchSubjectEpisodes(
        token: token,
        subjectId: subjectId,
        type: 0,
      );
      final targetEpisode = BangumiEpisodeAligner.matchRemoteMainEpisode(
        remoteEpisodes,
        episodeNumber,
      );
      if (targetEpisode == null) {
        return TrackerSyncResult.failed(
          errorMessage: 'Bangumi 条目 $subjectId 未找到第 $episodeNumber 集',
          retryable: false,
        );
      }

      final targetStatus = payload.completed
          ? BangumiEpisodeWatchStatus.watched
          : BangumiEpisodeWatchStatus.unwatched;
      if (targetEpisode.status != targetStatus) {
        await _client.setEpisodeStatus(
          token: token,
          episodeId: targetEpisode.episodeId,
          status: targetStatus,
        );
      }

      final autoMarkAll =
          payload.extraMetadata['autoMarkCollectionCompleted'] == true ||
          config.autoMarkCollectionCompleted;
      if (payload.completed &&
          autoMarkAll &&
          config.syncMode == BangumiSyncMode.autoCompleteAndPush) {
        final localTotalMain = payload.extraMetadata['localMainEpisodeCount'];
        final localCompletedCount =
            payload.extraMetadata['localCompletedCount'];
        final allLocalDone =
            localTotalMain is int &&
            localCompletedCount is int &&
            localTotalMain > 0 &&
            localCompletedCount >= localTotalMain;
        final allRemoteDone =
            remoteEpisodes.isNotEmpty &&
            remoteEpisodes.every(
              (ep) =>
                  ep.episodeId == targetEpisode.episodeId ||
                  ep.status == BangumiEpisodeWatchStatus.watched,
            );
        if (allLocalDone && allRemoteDone) {
          await _client.upsertUserSubjectCollection(
            token: token,
            subjectId: subjectId,
            type: BangumiCollectionType.collect,
          );
          collectionChanged = true;
        }
      }

      return TrackerSyncResult.succeeded(
        remoteSummary:
            'subject=$subjectId ep=$episodeNumber${collectionChanged ? ' (收藏已更新)' : ''}',
      );
    } on BangumiAuthException catch (error) {
      return TrackerSyncResult.failed(
        errorMessage: '鉴权失效：${error.message}',
        retryable: false,
      );
    } on BangumiApiException catch (error) {
      return TrackerSyncResult.failed(
        errorMessage: error.message,
        retryable: error.retryable,
      );
    } catch (error) {
      final redacted = NetworkErrorSanitizer.redactSecrets(error.toString());
      return TrackerSyncResult.failed(
        errorMessage: DiagnosticTextSanitizer.redactSecrets(redacted),
        retryable: true,
      );
    }
  }
}

/// 供静态模块清单使用的延迟代理提供者。
///
/// 在运行时依赖完成装配后自动委派至真实 [BangumiTrackerProvider] 实例。
final class DelegatingBangumiTrackerProvider implements ProgressTrackerProvider {
  /// 创建延迟代理实例。
  DelegatingBangumiTrackerProvider();

  BangumiTrackerProvider? _delegate;

  /// 绑定真实 Bangumi 提供者实现。
  void bind(BangumiTrackerProvider delegate) {
    _delegate = delegate;
  }

  /// 解除当前绑定实例。
  void unbind(BangumiTrackerProvider delegate) {
    if (identical(_delegate, delegate)) {
      _delegate = null;
    }
  }

  @override
  String get trackerId => BangumiTrackerProvider.trackerKey;

  @override
  String get displayName => BangumiTrackerProvider.trackerDisplayName;

  @override
  Future<bool> isConfigured() async {
    final delegate = _delegate;
    if (delegate == null) {
      return false;
    }
    return delegate.isConfigured();
  }

  @override
  Future<TrackerSyncResult> pushProgress(TrackerProgressPayload payload) async {
    final delegate = _delegate;
    if (delegate == null) {
      return const TrackerSyncResult.failed(
        errorMessage: 'Bangumi 同步提供者尚未完成装配',
        retryable: true,
      );
    }
    return delegate.pushProgress(payload);
  }
}
