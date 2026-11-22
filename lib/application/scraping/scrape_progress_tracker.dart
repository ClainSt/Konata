import 'dart:async';

import '../../domain/matching/directory_grouper.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/parsing/bdrip_parser.dart';
import '../../domain/scraping/match_difficulty_classifier.dart';
import 'scrape_progress.dart';

/// 刮削调度过程中的进度累加与不可变快照生成器。
class ScrapeProgressTracker {
  /// 从归组文件夹内解析涉及的 TMDB 正片季号集合（有特典时一并拉取 Season 0 元数据）。
  static Set<int> extractReferencedSeasons(GroupedWorkFolder folder) {
    final seasons = <int>{};
    var hasExtra = false;
    for (final variant in folder.variants) {
      if (variant.assetKind != AssetKind.video) continue;
      final parsed = BdripParser.parseFileName(
        variant.fileName,
        relativePath: variant.relativePath,
        folderTitle: folder.cleanTitle,
        folderSeasonHint: folder.seasonHint,
      );
      if (parsed.category == EpisodeCategory.main) {
        seasons.add(parsed.season);
      } else {
        hasExtra = true;
      }
    }
    if (seasons.isEmpty) {
      seasons.add(folder.seasonHint ?? 1);
    }
    if (hasExtra) {
      seasons.add(0);
    }
    return seasons;
  }
  /// 创建进度追踪器。
  ScrapeProgressTracker({
    required String sourceId,
    required String sourceLabel,
    required List<String> selectedRoots,
  }) : _snapshot = ScrapeProgress(
         phase: ScrapePhase.scanning,
         sourceId: sourceId,
         sourceLabel: sourceLabel,
         currentItemName: sourceLabel,
         selectedRoots: List.unmodifiable(selectedRoots),
       );

  final Map<String, int> _folderVideos = {};
  final Set<String> _completedFolders = {};
  ScrapeProgress _snapshot;

  /// 获取最新只读快照。
  ScrapeProgress get snapshot => _snapshot;

  /// 记录单个目录的遍历状态与视频数。
  void recordFolderVisited(String folder, int videoCount, bool completed) {
    _folderVideos[folder] = videoCount;
    if (completed) {
      _completedFolders.add(folder);
    }
  }

  /// 更新目录遍历进度快照。
  ScrapeProgress updateScanProgress({
    required String currentDir,
    required int scannedDirectories,
    required int foundFiles,
    required bool cancelRequested,
  }) {
    _snapshot = _snapshot.copyWith(
      phase: ScrapePhase.scanning,
      currentItemName: currentDir.isEmpty ? _snapshot.sourceLabel : currentDir,
      scannedDirectories: scannedDirectories,
      foundFiles: foundFiles,
      folderVideoCounts: Map.unmodifiable(_folderVideos),
      completedFolders: Set.unmodifiable(_completedFolders),
      cancelRequested: cancelRequested,
    );
    return _snapshot;
  }

  /// 通用状态递进封装。
  ScrapeProgress advance({
    ScrapePhase? phase,
    String? currentItemName,
    int? scannedDirectories,
    int? foundFiles,
    int? totalWorks,
    int? processedWorks,
    int? matchedWorks,
    int? reviewWorks,
    int? unmatchedWorks,
    int? easyWorks,
    int? mediumWorks,
    int? hardWorks,
    MatchDifficulty? currentDifficulty,
    int? hardRescuedWorks,
    String? lastMatchedTitle,
    Map<String, int>? folderVideoCounts,
    bool? cancelRequested,
    String? errorMessage,
  }) {
    _snapshot = _snapshot.copyWith(
      phase: phase,
      currentItemName: currentItemName,
      scannedDirectories: scannedDirectories,
      foundFiles: foundFiles,
      totalWorks: totalWorks,
      processedWorks: processedWorks,
      matchedWorks: matchedWorks,
      reviewWorks: reviewWorks,
      unmatchedWorks: unmatchedWorks,
      easyWorks: easyWorks,
      mediumWorks: mediumWorks,
      hardWorks: hardWorks,
      currentDifficulty: currentDifficulty,
      hardRescuedWorks: hardRescuedWorks,
      lastMatchedTitle: lastMatchedTitle,
      folderVideoCounts:
          folderVideoCounts ?? Map.unmodifiable(_folderVideos),
      completedFolders: Set.unmodifiable(_completedFolders),
      cancelRequested: cancelRequested,
      errorMessage: errorMessage,
    );
    return _snapshot;
  }
}

/// 刮削期间媒体库实时刷新节流器：
/// - 首批匹配成功作品立即刷新（首帧可见，消除空墙等待感）；
/// - 后续新匹配作品按时间窗（默认 `800ms`）或累计条数（默认 `8` 部）合并刷新，
///   在保证海报墙实时流动展示的同时避免高频全库查询拖慢 SQLite 与 UI 渲染；
/// - 结束或取消时通过 [flush] / [dispose] 清理定时器，杜绝泄漏。
class ScrapeLibraryRefreshThrottler {
  /// 创建媒体库实时刷新节流器。
  ScrapeLibraryRefreshThrottler({
    required this.onRefresh,
    this.interval = const Duration(milliseconds: 800),
    this.batchThreshold = 8,
  });

  /// 执行媒体库刷新的回调。
  final void Function() onRefresh;

  /// 两次连续刷新的最短时间间隔。
  final Duration interval;

  /// 单个时间窗内累计新匹配达到该数量时提前触发刷新。
  final int batchThreshold;

  Timer? _trailingTimer;
  DateTime? _lastFlushAt;
  int _pendingCount = 0;
  bool _hasEmittedFirst = false;
  bool _disposed = false;

  /// 通知有一部作品刚完成落库；仅在新匹配（或首条可见作品）到达时调度媒体库刷新。
  void notifyMatched() {
    if (_disposed) return;
    _pendingCount++;
    final now = DateTime.now();
    if (!_hasEmittedFirst) {
      _hasEmittedFirst = true;
      _triggerNow(now);
      return;
    }
    final elapsed = _lastFlushAt == null
        ? interval
        : now.difference(_lastFlushAt!);
    if (elapsed >= interval || _pendingCount >= batchThreshold) {
      _triggerNow(now);
      return;
    }
    _trailingTimer ??= Timer(interval - elapsed, () {
      _trailingTimer = null;
      if (!_disposed && _pendingCount > 0) {
        _triggerNow(DateTime.now());
      }
    });
  }

  /// 立即刷出全部尚未触发的挂起刷新（若无挂起项则静默跳过）。
  void flush() {
    if (_disposed) return;
    _trailingTimer?.cancel();
    _trailingTimer = null;
    if (_pendingCount > 0) {
      _triggerNow(DateTime.now());
    }
  }

  /// 释放挂起定时器，防止会话结束后触发残留回调。
  void dispose() {
    _disposed = true;
    _trailingTimer?.cancel();
    _trailingTimer = null;
    _pendingCount = 0;
  }

  void _triggerNow(DateTime now) {
    _trailingTimer?.cancel();
    _trailingTimer = null;
    _pendingCount = 0;
    _lastFlushAt = now;
    onRefresh();
  }
}
