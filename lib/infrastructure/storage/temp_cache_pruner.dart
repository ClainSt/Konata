import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'storage_root_provider.dart';

/// 单类便携临时缓存目录的容量与过期淘汰配额。
class TempCacheBucketPolicy {
  /// 创建单类缓存配额策略。
  const TempCacheBucketPolicy({
    required this.relativeSegments,
    required this.maxBytes,
    required this.maxAge,
  });

  /// 相对于 `<Root>/cache/` 的子目录路径段。
  final List<String> relativeSegments;

  /// 该缓存桶允许占用的最大磁盘字节数（超限时按最旧修改时间淘汰）。
  final int maxBytes;

  /// 该缓存桶单文件最长保留时长（超期直接清理）。
  final Duration maxAge;
}

/// 一次便携临时缓存清理巡检的回收结果统计。
class TempCachePruneResult {
  /// 创建清理结果快照。
  const TempCachePruneResult({
    required this.removedFiles,
    required this.reclaimedBytes,
    required this.remainingBytes,
    this.skippedByThrottle = false,
  });

  /// 被节流跳过的空结果常量。
  static const TempCachePruneResult throttled = TempCachePruneResult(
    removedFiles: 0,
    reclaimedBytes: 0,
    remainingBytes: 0,
    skippedByThrottle: true,
  );

  /// 本次删除的文件总数（含孤儿 `.part.*` 半成品与过期/超额缓存）。
  final int removedFiles;

  /// 本次释放的磁盘字节数。
  final int reclaimedBytes;

  /// 巡检后各托管缓存桶剩余占用的总字节数。
  final int remainingBytes;

  /// 是否因处于冷却节流期内而跳过本次扫描。
  final bool skippedByThrottle;
}

/// 便携临时缓存有界容量与过期淘汰管理器（覆盖外挂字幕、云端子集字幕、影子 CUE、GPU 着色器与 ICC 缓存）。
///
/// 采用按修改时间（`mtime`）排序的磁盘 LRU 与 TTL 双门限淘汰，并回收中断残留的 `.part.*` 临时文件与空目录，
/// 同时内置单飞防重入与默认 30 分钟节流冷却，确保不阻塞播放启动与界面帧率。
class TempCachePruner {
  /// 创建便携缓存淘汰管理器。
  TempCachePruner({
    StorageRootService? storageRoot,
    this.policies = defaultPolicies,
    this.minInterval = defaultMinInterval,
    this.orphanPartMaxAge = const Duration(hours: 1),
    DateTime Function()? clock,
  }) : _storageRoot = storageRoot ?? const StorageRootService(),
       _clock = clock ?? DateTime.now;

  /// 默认两次后台自动巡检的最短间隔（30 分钟）。
  static const Duration defaultMinInterval = Duration(minutes: 30);

  /// 全站便携临时缓存目录默认配额表（总计严格受控，严禁无限膨胀）。
  static const List<TempCacheBucketPolicy> defaultPolicies = [
    TempCacheBucketPolicy(
      relativeSegments: [
        StoragePathConfig.tempSubdirName,
        StoragePathConfig.subtitleStageSubdirName,
      ],
      maxBytes: 48 * 1024 * 1024,
      maxAge: Duration(days: 14),
    ),
    TempCacheBucketPolicy(
      relativeSegments: [
        StoragePathConfig.tempSubdirName,
        StoragePathConfig.cloudSubsetCacheSubdirName,
      ],
      maxBytes: 48 * 1024 * 1024,
      maxAge: Duration(days: 14),
    ),
    TempCacheBucketPolicy(
      relativeSegments: [
        StoragePathConfig.tempSubdirName,
        StoragePathConfig.cueStageSubdirName,
      ],
      maxBytes: 8 * 1024 * 1024,
      maxAge: Duration(days: 7),
    ),
    TempCacheBucketPolicy(
      relativeSegments: [StoragePathConfig.mpvShaderCacheSubdirName],
      maxBytes: 48 * 1024 * 1024,
      maxAge: Duration(days: 30),
    ),
    TempCacheBucketPolicy(
      relativeSegments: [StoragePathConfig.mpvIccCacheSubdirName],
      maxBytes: 16 * 1024 * 1024,
      maxAge: Duration(days: 30),
    ),
  ];

  final StorageRootService _storageRoot;
  final List<TempCacheBucketPolicy> policies;
  final Duration minInterval;
  final Duration orphanPartMaxAge;
  final DateTime Function() _clock;

  DateTime? _lastPrunedAt;
  Future<TempCachePruneResult>? _inFlight;

  /// 在超过节流冷却间隔时异步执行一次有界缓存巡检（并发调用共享单飞任务）。
  Future<TempCachePruneResult> pruneIfDue({bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    final now = _clock();
    final last = _lastPrunedAt;
    if (!force && last != null && now.difference(last) < minInterval) {
      return Future<TempCachePruneResult>.value(TempCachePruneResult.throttled);
    }
    final future = _runPrune(now);
    _inFlight = future;
    future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
    return future;
  }

  Future<TempCachePruneResult> _runPrune(DateTime now) async {
    _lastPrunedAt = now;
    var removedFiles = 0;
    var reclaimedBytes = 0;
    var remainingBytes = 0;

    try {
      final cacheRoot = await _storageRoot.resolveCacheRootDir();
      if (!await cacheRoot.exists()) {
        return const TempCachePruneResult(
          removedFiles: 0,
          reclaimedBytes: 0,
          remainingBytes: 0,
        );
      }

      for (final policy in policies) {
        final bucketDir = Directory(
          p.joinAll([cacheRoot.path, ...policy.relativeSegments]),
        );
        if (!await bucketDir.exists()) continue;
        final bucketStat = await _pruneBucket(bucketDir, policy, now);
        removedFiles += bucketStat.removedFiles;
        reclaimedBytes += bucketStat.reclaimedBytes;
        remainingBytes += bucketStat.remainingBytes;
      }
    } on Object catch (error) {
      developer.log(
        '便携缓存巡检遇可恢复异常已忽略',
        name: 'konata.temp_cache_pruner',
        error: error,
      );
    }

    return TempCachePruneResult(
      removedFiles: removedFiles,
      reclaimedBytes: reclaimedBytes,
      remainingBytes: remainingBytes,
    );
  }

  Future<({int removedFiles, int reclaimedBytes, int remainingBytes})>
  _pruneBucket(
    Directory bucketDir,
    TempCacheBucketPolicy policy,
    DateTime now,
  ) async {
    final entries = <({File file, int size, DateTime modified})>[];
    final subDirs = <Directory>[];

    await for (final entity in bucketDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Directory) {
        subDirs.add(entity);
        continue;
      }
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        entries.add((file: entity, size: stat.size, modified: stat.modified));
      } on Object catch (error) {
        developer.log(
          '读取缓存文件元信息失败已跳过',
          name: 'konata.temp_cache_pruner',
          error: error,
        );
      }
    }

    var removedFiles = 0;
    var reclaimedBytes = 0;
    final survivors = <({File file, int size, DateTime modified})>[];
    final expireBefore = now.subtract(policy.maxAge);
    final partExpireBefore = now.subtract(orphanPartMaxAge);

    for (final item in entries) {
      final name = p.basename(item.file.path);
      final isOrphanPart = name.contains('.part.');
      final expired = isOrphanPart
          ? item.modified.isBefore(partExpireBefore)
          : item.modified.isBefore(expireBefore);
      if (expired) {
        if (await _deleteQuietly(item.file)) {
          removedFiles += 1;
          reclaimedBytes += item.size;
        }
      } else {
        survivors.add(item);
      }
    }

    var totalBytes = survivors.fold<int>(0, (sum, e) => sum + e.size);
    if (totalBytes > policy.maxBytes) {
      // 按修改时间从旧到新排序，优先淘汰最久未使用的文件直至回落至容量上限内。
      survivors.sort((a, b) => a.modified.compareTo(b.modified));
      for (final item in survivors) {
        if (totalBytes <= policy.maxBytes) break;
        if (await _deleteQuietly(item.file)) {
          removedFiles += 1;
          reclaimedBytes += item.size;
          totalBytes -= item.size;
        }
      }
    }

    // 自深至浅清理已变空的嵌套子目录，保持便携目录树洁净。
    subDirs.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final dir in subDirs) {
      try {
        if (await dir.exists()) {
          final isEmpty = await dir.list(followLinks: false).isEmpty;
          if (isEmpty) {
            await dir.delete();
          }
        }
      } on Object catch (error) {
        developer.log(
          '清理空缓存子目录失败已忽略',
          name: 'konata.temp_cache_pruner',
          error: error,
        );
      }
    }

    return (
      removedFiles: removedFiles,
      reclaimedBytes: reclaimedBytes,
      remainingBytes: totalBytes < 0 ? 0 : totalBytes,
    );
  }

  Future<bool> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
        return true;
      }
    } on Object catch (error) {
      developer.log(
        '删除过期临时缓存文件失败已跳过',
        name: 'konata.temp_cache_pruner',
        error: error,
      );
    }
    return false;
  }
}

/// 全局便携临时缓存有界淘汰管理器 Provider（由 Riverpod 托管，零全局静态可变状态）。
final tempCachePrunerProvider = Provider<TempCachePruner>((ref) {
  return TempCachePruner(storageRoot: ref.read(storageRootProvider));
});
