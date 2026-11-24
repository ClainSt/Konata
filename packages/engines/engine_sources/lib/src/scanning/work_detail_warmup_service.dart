import 'dart:async';
import 'dart:developer' as developer;

import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import 'source_folder_rules.dart';
import 'subtitle_matcher.dart';

/// 详情页静默预热目标描述（与物理存储模型解耦）。
class WarmupVariantTarget {
  /// 创建预热目标描述。
  const WarmupVariantTarget({
    required this.sourceId,
    required this.relativePath,
    this.assetKind = AssetKind.video,
  });

  /// 所属媒体源主键文本。
  final String sourceId;

  /// 文件相对路径。
  final String relativePath;

  /// 物理资产类型。
  final AssetKind assetKind;
}

/// 同级字幕与外挂音轨目录内存表（基于有效期与最近最少使用淘汰，供详情页静默预热与起播零延迟查表）。
class SubtitleDirectoryIndex {
  /// 创建内存目录索引表。
  SubtitleDirectoryIndex({
    this.ttl = const Duration(minutes: 5),
    this.maxEntries = 64,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 单次自动目录扫描允许深入的最大候选子目录数量。
  static const int maxAutoSubdirScanCount = 4;

  /// 快照有效期。
  final Duration ttl;

  /// 最大缓存条目数。
  final int maxEntries;
  final DateTime Function() _clock;
  final Map<String, SubtitleDirectorySnapshot> _entries =
      <String, SubtitleDirectorySnapshot>{};

  static String _buildKey(String sourceId, String normalizedDir) {
    final norm = normalizedDir
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    return '$sourceId::$norm';
  }

  /// 查询有效期内缓存的同级目录快照；过期或未命中返回空。
  SubtitleDirectorySnapshot? lookup(String sourceId, String dirRelativePath) {
    final key = _buildKey(sourceId, dirRelativePath);
    final entry = _entries[key];
    if (entry == null) return null;
    if (_clock().difference(entry.cachedAt) > ttl) {
      _entries.remove(key);
      return null;
    }
    // 命中时移至尾部维护热点顺序。
    _entries.remove(key);
    _entries[key] = entry;
    return entry;
  }

  /// 写入指定目录的索引快照，自动评估简体中文完备性标记并控制容量上限。
  SubtitleDirectorySnapshot put({
    required String sourceId,
    required String dirRelativePath,
    required List<String> siblingPaths,
    required bool hasUnscannedSubdirs,
    required int scannedSubdirCount,
    List<String> unscannedSubdirs = const <String>[],
    Map<String, String> validatorsByPath = const <String, String>{},
  }) {
    final hasSimplifiedSub = siblingPaths.any(_isLikelySimplifiedSubtitlePath);
    final effectiveHasUnscanned =
        hasUnscannedSubdirs || unscannedSubdirs.isNotEmpty;
    final incompleteForSimplified = effectiveHasUnscanned && !hasSimplifiedSub;
    final snapshot = SubtitleDirectorySnapshot(
      siblingPaths: List<String>.unmodifiable(siblingPaths),
      cachedAt: _clock(),
      hasUnscannedSubdirs: effectiveHasUnscanned,
      incompleteForSimplified: incompleteForSimplified,
      scannedSubdirCount: scannedSubdirCount,
      unscannedSubdirs: List<String>.unmodifiable(unscannedSubdirs),
      validatorsByPath: Map<String, String>.unmodifiable(validatorsByPath),
    );
    final key = _buildKey(sourceId, dirRelativePath);
    _entries.remove(key);
    _entries[key] = snapshot;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return snapshot;
  }

  /// 清空指定媒体源的全部缓存条目（如用户重新扫描或修改媒体源后）。
  void invalidateSource(String sourceId) {
    final prefix = '$sourceId::';
    _entries.removeWhere((k, _) => k.startsWith(prefix));
  }

  /// 清空全部目录内存索引。
  void clear() => _entries.clear();

  /// 当前有效条目数（用于诊断与测试）。
  int get length => _entries.length;

  static bool _isLikelySimplifiedSubtitlePath(String path) {
    final name = p.posix.basename(path.replaceAll('\\', '/'));
    if (!SubtitleMatcher.isSubtitleFile(name)) return false;
    final lower = name.toLowerCase();
    return lower.contains('chs') ||
        lower.contains('jpsc') ||
        lower.contains('[sc]') ||
        lower.contains('.sc.') ||
        lower.contains('_sc') ||
        lower.contains('zh-cn') ||
        lower.contains('zh_cn') ||
        lower.contains('hans') ||
        lower.contains('简体') ||
        lower.contains('简日');
  }
}

/// 详情页浏览期零感知静默预热服务：
/// 预热远程保活连接池、完成质询缓存，并单次列举同级字幕或音轨目录写入内存索引表。
class WorkDetailWarmupService implements SubtitleDirectoryWarmupPort {
  /// 创建详情页预热服务。
  WorkDetailWarmupService({
    required this.gatewayFactory,
    required this.directoryIndex,
  });

  /// 媒体源网关构建端口。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 同级字幕目录内存索引表。
  final SubtitleDirectoryIndex directoryIndex;

  final Map<String, Future<SubtitleDirectorySnapshot?>> _inflight =
      <String, Future<SubtitleDirectorySnapshot?>>{};
  int _generation = 0;

  @override
  SubtitleDirectorySnapshot? lookupDirectorySnapshot(
    String sourceId,
    String dirRelativePath,
  ) => directoryIndex.lookup(sourceId, dirRelativePath);

  /// 递增预热代数，取消过时详情页残留的后续排队与在途循环任务。
  @override
  void cancelPending() {
    _generation += 1;
  }

  /// 对指定作品所涉及的远程媒体源父目录执行静默预热（同一目录并发去重）。
  Future<void> warmupForTargets({
    required List<WarmupVariantTarget> targets,
    required Map<String, MediaSourceView> sourcesById,
  }) async {
    final gen = _generation;
    final dirTargets = <String, ({MediaSourceView source, String parentDir})>{};
    for (final target in targets) {
      if (target.assetKind != AssetKind.video) continue;
      final source = sourcesById[target.sourceId];
      if (source == null || source.kind == MediaSourceKind.local) continue;
      final parentDir = SourcePathRules.parentDirOf(target.relativePath);
      final key = '${source.id.value}::$parentDir';
      dirTargets.putIfAbsent(
        key,
        () => (source: source, parentDir: parentDir),
      );
      // 详情页静默预热最多预热 2 个主目录，避免多版本跨源风暴。
      if (dirTargets.length >= 2) break;
    }

    for (final item in dirTargets.values) {
      if (gen != _generation) return;
      try {
        await warmupDirectory(
          source: item.source,
          dirRelativePath: item.parentDir,
          expectedGeneration: gen,
        );
      } on Object catch (error) {
        // 静默预热失败严禁弹出干扰提示，点播时正常走主流程兜底。
        developer.log(
          '静默预热目录忽略异常',
          name: 'konata.work_detail_warmup_service',
          error: error,
        );
      }
    }
  }

  /// 预热单个远程目录并将同级文件、真实源验证器与最多 4 个字幕或音轨子目录写入内存索引表。
  @override
  Future<SubtitleDirectorySnapshot?> warmupDirectory({
    required MediaSourceView source,
    required String dirRelativePath,
    int? expectedGeneration,
  }) {
    final gen = expectedGeneration ?? _generation;
    if (gen != _generation) {
      return Future<SubtitleDirectorySnapshot?>.value(null);
    }
    final sourceId = source.id.value;
    final cached = directoryIndex.lookup(sourceId, dirRelativePath);
    if (cached != null) {
      return Future<SubtitleDirectorySnapshot?>.value(cached);
    }
    final dedupKey = '$sourceId::$dirRelativePath::$gen';
    final inflight = _inflight[dedupKey];
    if (inflight != null) return inflight;

    final task = _runWarmup(
      source,
      dirRelativePath,
      generation: gen,
    ).whenComplete(() {
      _inflight.remove(dedupKey);
    });
    _inflight[dedupKey] = task;
    return task;
  }

  Future<SubtitleDirectorySnapshot?> _runWarmup(
    MediaSourceView source,
    String dirRelativePath, {
    required int generation,
  }) async {
    if (generation != _generation) return null;
    final gw = await gatewayFactory.create(source);
    try {
      if (generation != _generation) return null;
      final entries = await gw.listDirectory(dirRelativePath);
      if (generation != _generation) return null;

      final siblingPaths = <String>[];
      final candidateSubdirs = <String>[];
      final validatorsByPath = <String, String>{};

      for (final entry in entries) {
        if (!entry.isDirectory) {
          siblingPaths.add(entry.relativePath);
          final validator = entry.cacheValidator;
          if (validator != null) {
            validatorsByPath[entry.relativePath] = validator;
          }
          continue;
        }
        if (SourcePathRules.isSidecarSubdirName(entry.name)) {
          candidateSubdirs.add(entry.relativePath);
        }
      }

      var scanned = 0;
      for (final subDir in candidateSubdirs) {
        if (generation != _generation) return null;
        if (scanned >= SubtitleDirectoryIndex.maxAutoSubdirScanCount) break;
        scanned += 1;
        try {
          final subEntries = await gw.listDirectory(subDir);
          if (generation != _generation) return null;
          for (final sub in subEntries) {
            if (!sub.isDirectory) {
              siblingPaths.add(sub.relativePath);
              final validator = sub.cacheValidator;
              if (validator != null) {
                validatorsByPath[sub.relativePath] = validator;
              }
            }
          }
        } on Object {
          if (generation != _generation) return null;
        }
      }

      if (generation != _generation) return null;
      final unscanned = scanned < candidateSubdirs.length
          ? candidateSubdirs.sublist(scanned)
          : const <String>[];
      return directoryIndex.put(
        sourceId: source.id.value,
        dirRelativePath: dirRelativePath,
        siblingPaths: siblingPaths,
        hasUnscannedSubdirs: unscanned.isNotEmpty,
        scannedSubdirCount: scanned,
        unscannedSubdirs: unscanned,
        validatorsByPath: validatorsByPath,
      );
    } finally {
      await gw.close();
    }
  }
}
