import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android 画中画（PiP）与后台返回时的双态恢复判定结果。
enum PipRecoveryMode {
  /// 无需恢复（无活跃会话亦无有效快照）。
  none,

  /// 进程与底层解码引擎仍存活：保持解码器不断流，按需重绑底层 `Surface` 与音频焦点。
  engineAliveRebind,

  /// 进程已被系统回收：从持久化快照按精确秒数冷重建播放会话。
  coldSnapshotRestore,
}

/// 轻量级 Android 画中画/后台视频播放恢复快照（仅保存标识符与精确秒数，严禁携带大对象）。
@immutable
class PipPlaybackRecoverySnapshot {
  /// 创建视频恢复快照。
  const PipPlaybackRecoverySnapshot({
    required this.workId,
    required this.episodeId,
    required this.variantId,
    required this.positionSeconds,
    required this.audioOnly,
    required this.wasInPip,
    required this.savedAtEpochMs,
  });

  /// 快照默认有效时长上限（24 小时）。
  static const Duration maxAge = Duration(hours: 24);

  /// 作品唯一 ID。
  final String workId;

  /// 分集唯一 ID。
  final String episodeId;

  /// 物理媒体变体 ID。
  final String variantId;

  /// 退入后台/画中画时的精确播放进度（秒）。
  final double positionSeconds;

  /// 是否处于后台纯音频模式。
  final bool audioOnly;

  /// 保存时是否处于系统画中画状态。
  final bool wasInPip;

  /// 保存时间戳（Unix 毫秒）。
  final int savedAtEpochMs;

  /// 判断快照是否在允许的有效恢复时间窗内。
  bool isFreshAt(DateTime now) {
    final ageMs = now.millisecondsSinceEpoch - savedAtEpochMs;
    return ageMs >= 0 && ageMs <= maxAge.inMilliseconds;
  }

  /// 编码为紧凑 JSON 字符串。
  String encodeJson() {
    return jsonEncode(<String, Object?>{
      'workId': workId,
      'episodeId': episodeId,
      'variantId': variantId,
      'positionSeconds': positionSeconds,
      'audioOnly': audioOnly,
      'wasInPip': wasInPip,
      'savedAtEpochMs': savedAtEpochMs,
    });
  }

  /// 从 JSON 字符串解码；若数据损坏或缺关键字段返回 `null`。
  static PipPlaybackRecoverySnapshot? tryDecodeJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final workId = decoded['workId']?.toString().trim() ?? '';
      final episodeId = decoded['episodeId']?.toString().trim() ?? '';
      final variantId = decoded['variantId']?.toString().trim() ?? '';
      final pos = (decoded['positionSeconds'] as num?)?.toDouble() ?? 0.0;
      final savedAt = (decoded['savedAtEpochMs'] as num?)?.toInt() ?? 0;
      if (workId.isEmpty || episodeId.isEmpty || variantId.isEmpty) {
        return null;
      }
      return PipPlaybackRecoverySnapshot(
        workId: workId,
        episodeId: episodeId,
        variantId: variantId,
        positionSeconds: pos.isFinite && pos >= 0 ? pos : 0.0,
        audioOnly: decoded['audioOnly'] == true,
        wasInPip: decoded['wasInPip'] == true,
        savedAtEpochMs: savedAt,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 画中画冷恢复快照持久化仓储抽象（便于单测注入内存替身）。
abstract interface class PipRecoveryStore {
  /// 原子写入最新恢复快照。
  Future<void> save(PipPlaybackRecoverySnapshot snapshot);

  /// 读取当前持久化快照（若不存在或已损坏返回 `null`）。
  Future<PipPlaybackRecoverySnapshot?> load();

  /// 清空已消费或已主动退出的恢复快照。
  Future<void> clear();
}

/// 基于 `SharedPreferences` 的画中画恢复快照持久化实现。
class SharedPrefsPipRecoveryStore implements PipRecoveryStore {
  /// 创建持久化仓储。
  const SharedPrefsPipRecoveryStore();

  static const String storageKey = 'konata.pip.recovery.snapshot.v1';

  @override
  Future<void> save(PipPlaybackRecoverySnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, snapshot.encodeJson());
    } catch (_) {}
  }

  @override
  Future<PipPlaybackRecoverySnapshot?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return PipPlaybackRecoverySnapshot.tryDecodeJson(
        prefs.getString(storageKey),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (_) {}
  }
}

/// 全局画中画冷恢复快照仓储 Provider。
final pipRecoveryStoreProvider = Provider<PipRecoveryStore>(
  (ref) => const SharedPrefsPipRecoveryStore(),
);
