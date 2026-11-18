import 'dart:async';

import 'package:path/path.dart' as p;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/subtitle_and_audio_choices.dart';
import '../sources/source_gateway_factory.dart';
import '../sources/subtitle_matcher.dart';

/// 单个目录（含字幕/音轨子目录）内存索引快照，记录按语种维度的扫描完备性。
class SubtitleDirectorySnapshot {
  /// 创建目录索引快照。
  const SubtitleDirectorySnapshot({
    required this.siblingPaths,
    required this.cachedAt,
    required this.hasUnscannedSubdirs,
    required this.incompleteForSimplified,
    this.scannedSubdirCount = 0,
    this.unscannedSubdirs = const [],
  });

  /// 同级及已扫描子目录下的全部文件相对路径。
  final List<String> siblingPaths;

  /// 快照写入时间。
  final DateTime cachedAt;

  /// 是否存在超出扫描配额而尚未深入的子目录。
  final bool hasUnscannedSubdirs;

  /// 若存在未扫子目录且当前仅命中非简中字幕（如仅日文/繁中），置为真以防写入简中假阴性负缓存。
  final bool incompleteForSimplified;

  /// 实际已扫描的子目录数量。
  final int scannedSubdirCount;

  /// 尚未深入扫描的剩余候选子目录相对路径列表（供需要简中字幕时按需续扫）。
  final List<String> unscannedSubdirs;
}

/// 同级字幕与外挂音轨目录内存表（LRU + TTL 5 分钟，供详情页静默预热与起播 0 ms 查表）。
class SubtitleDirectoryIndex {
  /// 创建内存目录索引表。
  SubtitleDirectoryIndex({
    this.ttl = const Duration(minutes: 5),
    this.maxEntries = 64,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 单次自动目录扫描允许深入的最大候选子目录数量。
  static const int maxAutoSubdirScanCount = 4;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _clock;
  final Map<String, SubtitleDirectorySnapshot> _entries = {};

  static String _buildKey(String sourceId, String normalizedDir) {
    final norm = normalizedDir
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    return '$sourceId::$norm';
  }

  /// 查询有效期内缓存的同级目录快照；过期或未命中返回 `null`。
  SubtitleDirectorySnapshot? lookup(String sourceId, String dirRelativePath) {
    final key = _buildKey(sourceId, dirRelativePath);
    final entry = _entries[key];
    if (entry == null) return null;
    if (_clock().difference(entry.cachedAt) > ttl) {
      _entries.remove(key);
      return null;
    }
    // 命中时移至尾部维护 LRU 热点顺序
    _entries.remove(key);
    _entries[key] = entry;
    return entry;
  }

  /// 写入指定目录的索引快照，自动评估简体中文完备性标记并控制 LRU 容量上限。
  SubtitleDirectorySnapshot put({
    required String sourceId,
    required String dirRelativePath,
    required List<String> siblingPaths,
    required bool hasUnscannedSubdirs,
    required int scannedSubdirCount,
    List<String> unscannedSubdirs = const [],
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
/// 预热远程 WebDAV/SMB Keep-Alive 连接池、完成 Digest 首次 `401` 质询缓存 `nonce`，
/// 并单次列举同级字幕/音轨目录写入内存索引表，实现点播 0 ms 字幕查表与零握手起播。
class WorkDetailWarmupService {
  /// 创建详情页预热服务。
  WorkDetailWarmupService({
    required this.gatewayFactory,
    required this.directoryIndex,
  });

  final MediaSourceGatewayFactory gatewayFactory;
  final SubtitleDirectoryIndex directoryIndex;

  final Map<String, Future<SubtitleDirectorySnapshot?>> _inflight = {};
  int _generation = 0;

  static const Set<String> _preferredSubdirNames = {
    'subs',
    'sub',
    'subtitles',
    'subtitle',
    '字幕',
    'audio',
    'sp audio',
  };

  /// 递增预热代数，取消过时详情页残留的后续排队任务。
  void cancelPending() {
    _generation += 1;
  }

  /// 对指定作品所涉及的远程媒体源父目录执行静默预热（同一目录并发去重）。
  Future<void> warmupForVariants({
    required List<MediaVariant> variants,
    required Map<String, MediaSource> sourcesById,
  }) async {
    final gen = _generation;
    final targets = <String, ({MediaSource source, String parentDir})>{};
    for (final variant in variants) {
      if (variant.assetKind != AssetKind.video) continue;
      final source = sourcesById[variant.sourceId];
      if (source == null || source.kind == MediaSourceKind.local) continue;
      final parentDir = SubtitleAndAudioChoices.parentDirOf(
        variant.relativePath,
      );
      final key = '${source.id}::$parentDir';
      targets.putIfAbsent(key, () => (source: source, parentDir: parentDir));
      // 详情页静默预热最多预热 2 个主目录，避免多版本跨源风暴
      if (targets.length >= 2) break;
    }

    for (final target in targets.values) {
      if (gen != _generation) return;
      try {
        await warmupDirectory(
          source: target.source,
          dirRelativePath: target.parentDir,
        );
      } catch (_) {
        // 静默预热失败严禁弹出干扰提示，点播时正常走主流程兜底
      }
    }
  }

  /// 预热单个远程目录并将同级文件与最多 4 个字幕/音轨子目录写入内存索引表。
  Future<SubtitleDirectorySnapshot?> warmupDirectory({
    required MediaSource source,
    required String dirRelativePath,
  }) {
    final cached = directoryIndex.lookup(source.id, dirRelativePath);
    if (cached != null) {
      return Future<SubtitleDirectorySnapshot?>.value(cached);
    }
    final dedupKey = '${source.id}::$dirRelativePath';
    final inflight = _inflight[dedupKey];
    if (inflight != null) return inflight;

    final task = _runWarmup(source, dirRelativePath).whenComplete(() {
      _inflight.remove(dedupKey);
    });
    _inflight[dedupKey] = task;
    return task;
  }

  Future<SubtitleDirectorySnapshot?> _runWarmup(
    MediaSource source,
    String dirRelativePath,
  ) async {
    final gw = await gatewayFactory.create(source);
    try {
      final entries = await gw.listDirectory(dirRelativePath);
      final siblingPaths = <String>[];
      final candidateSubdirs = <String>[];

      for (final entry in entries) {
        if (!entry.isDirectory) {
          siblingPaths.add(entry.relativePath);
          continue;
        }
        final lowerName = entry.name.trim().toLowerCase();
        if (_preferredSubdirNames.contains(lowerName) ||
            lowerName.contains('sub') ||
            lowerName.contains('字幕')) {
          candidateSubdirs.add(entry.relativePath);
        }
      }

      var scanned = 0;
      for (final subDir in candidateSubdirs) {
        if (scanned >= SubtitleDirectoryIndex.maxAutoSubdirScanCount) break;
        scanned += 1;
        try {
          final subEntries = await gw.listDirectory(subDir);
          for (final sub in subEntries) {
            if (!sub.isDirectory) {
              siblingPaths.add(sub.relativePath);
            }
          }
        } catch (_) {}
      }

      final unscanned = scanned < candidateSubdirs.length
          ? candidateSubdirs.sublist(scanned)
          : const <String>[];
      return directoryIndex.put(
        sourceId: source.id,
        dirRelativePath: dirRelativePath,
        siblingPaths: siblingPaths,
        hasUnscannedSubdirs: unscanned.isNotEmpty,
        scannedSubdirCount: scanned,
        unscannedSubdirs: unscanned,
      );
    } finally {
      await gw.close();
    }
  }
}
