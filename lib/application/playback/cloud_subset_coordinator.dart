import '../../domain/playback/ass_semantic_verifier.dart';
import '../../infrastructure/subtitles/fontinass_cloud_client.dart';
import 'unified_playback_engine.dart';

/// 云端子集化按域编排协调器（严格绑定 `PlaybackTaskDomain.cloudSubset` 与逐 Origin 撤权即时中止）。
///
/// 当用户在途关闭云端子集化开关或撤销某 Origin 授权时，仅递增 `PlaybackTaskDomain.cloudSubset`
/// 域代数并立即中断当前活跃网络请求，绝不误杀原始字幕拉取、歌词检索或封面取色等其余三域任务。
class CloudSubsetCoordinator {
  /// 创建云端子集化协调器。
  CloudSubsetCoordinator({
    required this.playbackEngine,
    required this.cloudClient,
  });

  /// 统一播放四维代数引擎。
  final UnifiedPlaybackEngine playbackEngine;

  /// FontInAss 纯净云端子集化客户端。
  final FontInAssCloudClient cloudClient;

  final Map<CloudSubsetOrigin, Set<CloudSubsetCancellationHandle>>
  _activeHandlesByOrigin = {};

  /// 授权指定服务地址 Origin。
  CloudSubsetOrigin authorizeOrigin(Uri endpointUri) {
    return cloudClient.authorizationStore.grant(endpointUri);
  }

  /// 撤销指定 Origin 授权并即时中止该 Origin 上全部在途云端子集化请求，
  /// 仅取消 `PlaybackTaskDomain.cloudSubset` 域而不影响其余三个异步域。
  void revokeOriginAndCancel(Uri endpointUri) {
    final origin = CloudSubsetOrigin.fromUri(endpointUri);
    cloudClient.authorizationStore.revoke(endpointUri);
    playbackEngine.cancelTaskDomain(PlaybackTaskDomain.cloudSubset);
    final handles = _activeHandlesByOrigin.remove(origin);
    if (handles != null) {
      for (final handle in handles) {
        handle.cancel();
      }
    }
  }

  /// 仅取消全部在途云端子集化任务（不触碰其他播放任务域）。
  void cancelAllCloudSubsetTasks() {
    playbackEngine.cancelTaskDomain(PlaybackTaskDomain.cloudSubset);
    for (final handles in _activeHandlesByOrigin.values) {
      for (final handle in handles) {
        handle.cancel();
      }
    }
    _activeHandlesByOrigin.clear();
  }

  /// 在 `PlaybackTaskDomain.cloudSubset` 独立分域内执行云端字体子集化。
  Future<CloudSubsetResult> runCloudSubset({
    required Uri endpointUri,
    required String originalAssContent,
  }) async {
    final origin = CloudSubsetOrigin.fromUri(endpointUri);
    final token = playbackEngine.acquireTaskToken(
      PlaybackTaskDomain.cloudSubset,
    );
    final handle = CloudSubsetCancellationHandle();
    _activeHandlesByOrigin
        .putIfAbsent(origin, () => <CloudSubsetCancellationHandle>{})
        .add(handle);

    try {
      return await cloudClient.requestSubset(
        endpointUri: endpointUri,
        originalAssContent: originalAssContent,
        cancellation: handle,
        isTaskAlive: () => playbackEngine.isTaskAlive(token),
      );
    } finally {
      final bucket = _activeHandlesByOrigin[origin];
      bucket?.remove(handle);
      if (bucket != null && bucket.isEmpty) {
        _activeHandlesByOrigin.remove(origin);
      }
    }
  }
}
