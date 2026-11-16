/// 刮削调度阶段枚举。
enum ScrapePhase {
  /// 空闲就绪状态。
  idle,

  /// 正在遍历媒体源目录树。
  scanning,

  /// 正在后台 Isolate 执行目录聚合与词法解析。
  grouping,

  /// 正在执行 TMDB 元数据刮削与入库。
  scraping,

  /// 全部阶段已完成。
  completed,

  /// 已被用户主动取消。
  cancelled,

  /// 刮削流程发生异常中止。
  failed,
}

/// 强类型刮削进度状态快照。
class ScrapeProgress {
  /// 创建刮削进度快照。
  const ScrapeProgress({
    this.phase = ScrapePhase.idle,
    this.sourceId,
    this.sourceLabel = '',
    this.currentItemName = '',
    this.scannedDirectories = 0,
    this.foundFiles = 0,
    this.totalWorks = 0,
    this.processedWorks = 0,
    this.matchedWorks = 0,
    this.reviewWorks = 0,
    this.unmatchedWorks = 0,
    this.selectedRoots = const [],
    this.folderVideoCounts = const {},
    this.completedFolders = const {},
    this.cancelRequested = false,
    this.errorMessage,
  });

  /// 当前所处阶段。
  final ScrapePhase phase;

  /// 当前正在处理的媒体源 ID。
  final String? sourceId;

  /// 当前正在处理的媒体源显示名称。
  final String sourceLabel;

  /// 当前正在扫描的目录或正在刮削的作品名称。
  final String currentItemName;

  /// 已扫描目录总数。
  final int scannedDirectories;

  /// 已发现的媒体文件总数。
  final int foundFiles;

  /// 归组后的作品总数。
  final int totalWorks;

  /// 已完成刮削处理的作品数。
  final int processedWorks;

  /// 自动高置信匹配的作品数。
  final int matchedWorks;

  /// 进入待人工复核队列的作品数。
  final int reviewWorks;

  /// 未识别到匹配条目的作品数。
  final int unmatchedWorks;

  /// 本次扫描所选的相对子目录作用域（空表示全库根目录）。
  final List<String> selectedRoots;

  /// 各已访问目录对应的视频文件计数映射。
  final Map<String, int> folderVideoCounts;

  /// 已完成目录列表枚举的路径集合。
  final Set<String> completedFolders;

  /// 是否已发出取消请求。
  final bool cancelRequested;

  /// 失败时的错误提示。
  final String? errorMessage;

  /// 是否处于运行中。
  bool get isRunning =>
      phase == ScrapePhase.scanning ||
      phase == ScrapePhase.grouping ||
      phase == ScrapePhase.scraping;

  /// 按目录层级顺序排列的已访问目录列表。
  List<String> get visitedFolders {
    final list = folderVideoCounts.keys.toList()..sort();
    return list;
  }

  /// 统计本次发现的纯视频文件总数。
  int get totalVideos {
    var sum = 0;
    for (final v in folderVideoCounts.values) {
      sum += v;
    }
    return sum;
  }

  /// 统计指定勾选子目录树下累计发现的视频文件数。
  int videosUnderRoot(String root) {
    final norm = root.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    if (norm.isEmpty) return totalVideos;
    var sum = 0;
    folderVideoCounts.forEach((folder, count) {
      final f = folder.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
      if (f == norm || f.startsWith('$norm/')) {
        sum += count;
      }
    });
    return sum;
  }

  /// 计算当前刮削进度比例（0.0 ~ 1.0）。
  double get fraction {
    if (phase == ScrapePhase.completed) return 1.0;
    if (totalWorks <= 0) return 0.0;
    return (processedWorks / totalWorks).clamp(0.0, 1.0);
  }

  /// 生成更新部分字段后的新进度快照。
  ScrapeProgress copyWith({
    ScrapePhase? phase,
    String? sourceId,
    String? sourceLabel,
    String? currentItemName,
    int? scannedDirectories,
    int? foundFiles,
    int? totalWorks,
    int? processedWorks,
    int? matchedWorks,
    int? reviewWorks,
    int? unmatchedWorks,
    List<String>? selectedRoots,
    Map<String, int>? folderVideoCounts,
    Set<String>? completedFolders,
    bool? cancelRequested,
    String? errorMessage,
  }) {
    return ScrapeProgress(
      phase: phase ?? this.phase,
      sourceId: sourceId ?? this.sourceId,
      sourceLabel: sourceLabel ?? this.sourceLabel,
      currentItemName: currentItemName ?? this.currentItemName,
      scannedDirectories: scannedDirectories ?? this.scannedDirectories,
      foundFiles: foundFiles ?? this.foundFiles,
      totalWorks: totalWorks ?? this.totalWorks,
      processedWorks: processedWorks ?? this.processedWorks,
      matchedWorks: matchedWorks ?? this.matchedWorks,
      reviewWorks: reviewWorks ?? this.reviewWorks,
      unmatchedWorks: unmatchedWorks ?? this.unmatchedWorks,
      selectedRoots: selectedRoots ?? this.selectedRoots,
      folderVideoCounts: folderVideoCounts ?? this.folderVideoCounts,
      completedFolders: completedFolders ?? this.completedFolders,
      cancelRequested: cancelRequested ?? this.cancelRequested,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
