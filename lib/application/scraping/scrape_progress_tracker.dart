import '../../domain/matching/directory_grouper.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/parsing/bdrip_parser.dart';
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
      folderVideoCounts:
          folderVideoCounts ?? Map.unmodifiable(_folderVideos),
      completedFolders: Set.unmodifiable(_completedFolders),
      cancelRequested: cancelRequested,
      errorMessage: errorMessage,
    );
    return _snapshot;
  }
}
