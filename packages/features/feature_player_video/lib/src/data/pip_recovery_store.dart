import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 系统画中画意外关闭或宿主页面重建后用于原地无缝复播的轻量快照。
@immutable
class PipPlaybackRecoverySnapshot {
  /// 创建画中画恢复状态快照。
  const PipPlaybackRecoverySnapshot({
    required this.workId,
    required this.episodeId,
    required this.variantId,
    required this.positionSeconds,
    required this.isPlaying,
    required this.updatedAtMs,
  });

  /// 作品唯一标识。
  final String workId;

  /// 逻辑剧集唯一标识。
  final String episodeId;

  /// 物理媒体版本唯一标识。
  final String variantId;

  /// 记录瞬间的播放时间点（整秒）。
  final int positionSeconds;

  /// 记录瞬间是否处于播放进行中。
  final bool isPlaying;

  /// 快照落盘时间戳（标准协调世界时毫秒）。
  final int updatedAtMs;

  /// 画中画恢复快照允许保留的最长有效窗口（6 小时）。
  static const Duration maxFreshAge = Duration(hours: 6);

  /// 校验当前快照是否仍在有效复播时间窗口内。
  bool isFresh({DateTime? now}) {
    if (workId.trim().isEmpty || variantId.trim().isEmpty) {
      return false;
    }
    final currentMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final ageMs = currentMs - updatedAtMs;
    return ageMs >= 0 && ageMs <= maxFreshAge.inMilliseconds;
  }

  /// 序列化为本机自治存储字典。
  Map<String, Object?> toJson() => <String, Object?>{
    'workId': workId,
    'episodeId': episodeId,
    'variantId': variantId,
    'positionSeconds': positionSeconds,
    'isPlaying': isPlaying,
    'updatedAtMs': updatedAtMs,
  };

  /// 从序列化字典还原恢复快照；字段缺失或格式无效时返回空值。
  static PipPlaybackRecoverySnapshot? tryFromJson(
    Map<String, Object?> json,
  ) {
    final workId = (json['workId'] as String?)?.trim() ?? '';
    final episodeId = (json['episodeId'] as String?)?.trim() ?? '';
    final variantId = (json['variantId'] as String?)?.trim() ?? '';
    final updatedAt = json['updatedAtMs'];
    if (workId.isEmpty || variantId.isEmpty || updatedAt is! int) {
      return null;
    }
    final rawPos = json['positionSeconds'];
    final posSeconds = rawPos is int ? rawPos : (rawPos is num ? rawPos.round() : 0);
    return PipPlaybackRecoverySnapshot(
      workId: workId,
      episodeId: episodeId,
      variantId: variantId,
      positionSeconds: posSeconds < 0 ? 0 : posSeconds,
      isPlaying: json['isPlaying'] as bool? ?? false,
      updatedAtMs: updatedAt,
    );
  }
}

/// 画中画与迷你小窗恢复状态持久化抽象仓储（支持数据库存储与测试替身替换）。
abstract interface class PipRecoveryStore {
  /// 写入最新的可恢复播放进度快照。
  Future<void> saveSnapshot(PipPlaybackRecoverySnapshot snapshot);

  /// 读取处于有效期内的恢复快照；过期或无记录时返回空值并自动清理。
  Future<PipPlaybackRecoverySnapshot?> readFreshSnapshot({DateTime? now});

  /// 清除已落盘的恢复快照。
  Future<void> clear();
}

/// 面向画中画恢复快照的仅本机配置切片定义。
final TypedPrefsSlice<PipPlaybackRecoverySnapshot?> _pipRecoveryPrefsSlice =
    TypedPrefsSlice<PipPlaybackRecoverySnapshot?>(
      namespace: ScopedPrefsPipRecoveryStore.prefsNamespace,
      schemaVersion: 1,
      syncPolicy: SyncPolicy.deviceLocal,
      defaultValue: null,
      encode: (value) => value?.toJson() ?? const <String, Object?>{},
      decode: (json, _) => json.isEmpty
          ? null
          : PipPlaybackRecoverySnapshot.tryFromJson(json),
    );

/// 基于 [ScopedPrefsStore] 的设备本地画中画恢复状态持久化实现。
final class ScopedPrefsPipRecoveryStore implements PipRecoveryStore {
  /// 创建画中画恢复状态持久化仓储。
  const ScopedPrefsPipRecoveryStore(this._prefsStore);

  /// 隔离配置命名空间标识。
  static const String prefsNamespace = 'playback_video.pip_recovery';

  final ScopedPrefsStore _prefsStore;

  @override
  Future<void> saveSnapshot(PipPlaybackRecoverySnapshot snapshot) async {
    _prefsStore.write(
      _pipRecoveryPrefsSlice,
      snapshot,
      updatedAtMs: snapshot.updatedAtMs,
    );
  }

  @override
  Future<PipPlaybackRecoverySnapshot?> readFreshSnapshot({
    DateTime? now,
  }) async {
    final snapshot = _prefsStore.read(_pipRecoveryPrefsSlice);
    if (snapshot == null) return null;
    if (!snapshot.isFresh(now: now)) {
      await clear();
      return null;
    }
    return snapshot;
  }

  @override
  Future<void> clear() async {
    _prefsStore.delete(prefsNamespace);
  }
}

/// 纯内存画中画恢复状态存储替身（专供无数据库单元测试注入）。
final class InMemoryPipRecoveryStore implements PipRecoveryStore {
  PipPlaybackRecoverySnapshot? _snapshot;

  @override
  Future<void> saveSnapshot(PipPlaybackRecoverySnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  Future<PipPlaybackRecoverySnapshot?> readFreshSnapshot({
    DateTime? now,
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    if (!snapshot.isFresh(now: now)) {
      _snapshot = null;
      return null;
    }
    return snapshot;
  }

  @override
  Future<void> clear() async {
    _snapshot = null;
  }
}
