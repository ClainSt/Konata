import 'package:engine_scraping/engine_scraping.dart';

/// 扫库与元数据刮削任务对外暴露的高层阶段枚举。
enum ScrapeTaskStage {
  /// 当前无进行中或刚结束的刮削任务。
  idle,

  /// 正在检查与加载本地或远程映射表索引。
  checkingIndex,

  /// 正在遍历媒体源目录结构。
  scanning,

  /// 正在执行分集解析与多源元数据刮削。
  running,

  /// 本轮扫描与刮削已全部完成。
  completed,

  /// 用户主动取消了本轮扫描。
  cancelled,

  /// 扫描或刮削过程中因异常中止。
  failed,
}

/// 媒体源扫描与刮削状态机不可变状态基类（零 Riverpod 纯 Dart 模型）。
///
/// 由 `SourceScrapeController` 驱动并在状态切换时通知监听方；UI 与测试可直接基于
/// Dart 3 穷尽式模式匹配消费具体子状态。
sealed class ScrapeTaskPhase {
  /// 构造扫库任务阶段基类。
  const ScrapeTaskPhase({
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
    this.easyWorks = 0,
    this.mediumWorks = 0,
    this.hardWorks = 0,
    this.hardRescuedWorks = 0,
    this.currentDifficulty,
    this.lastMatchedTitle,
    this.selectedRoots = const <String>[],
    this.folderVideoCounts = const <String, int>{},
    this.completedFolders = const <String>{},
    this.cancelRequested = false,
    this.errorMessage,
  });

  /// 从底层 `ScrapeProgress` 快照构造对应的强类型阶段实例。
  factory ScrapeTaskPhase.fromProgress(ScrapeProgress progress) {
    return switch (progress.phase) {
      ScrapePhase.idle => const ScrapeIdlePhase(),
      ScrapePhase.scanning || ScrapePhase.grouping => ScrapeScanningPhase(
        sourceId: progress.sourceId,
        sourceLabel: progress.sourceLabel,
        currentItemName: progress.currentItemName,
        scannedDirectories: progress.scannedDirectories,
        foundFiles: progress.foundFiles,
        totalWorks: progress.totalWorks,
        selectedRoots: progress.selectedRoots,
        folderVideoCounts: progress.folderVideoCounts,
        completedFolders: progress.completedFolders,
        cancelRequested: progress.cancelRequested,
      ),
      ScrapePhase.scraping => ScrapeRunningPhase(
        sourceId: progress.sourceId,
        sourceLabel: progress.sourceLabel,
        currentItemName: progress.currentItemName,
        scannedDirectories: progress.scannedDirectories,
        foundFiles: progress.foundFiles,
        totalWorks: progress.totalWorks,
        processedWorks: progress.processedWorks,
        matchedWorks: progress.matchedWorks,
        reviewWorks: progress.reviewWorks,
        unmatchedWorks: progress.unmatchedWorks,
        easyWorks: progress.easyWorks,
        mediumWorks: progress.mediumWorks,
        hardWorks: progress.hardWorks,
        hardRescuedWorks: progress.hardRescuedWorks,
        currentDifficulty: progress.currentDifficulty,
        lastMatchedTitle: progress.lastMatchedTitle,
        selectedRoots: progress.selectedRoots,
        folderVideoCounts: progress.folderVideoCounts,
        completedFolders: progress.completedFolders,
        cancelRequested: progress.cancelRequested,
      ),
      ScrapePhase.completed => ScrapeCompletedPhase(
        sourceId: progress.sourceId,
        sourceLabel: progress.sourceLabel,
        currentItemName: progress.currentItemName,
        scannedDirectories: progress.scannedDirectories,
        foundFiles: progress.foundFiles,
        totalWorks: progress.totalWorks,
        processedWorks: progress.processedWorks,
        matchedWorks: progress.matchedWorks,
        reviewWorks: progress.reviewWorks,
        unmatchedWorks: progress.unmatchedWorks,
        easyWorks: progress.easyWorks,
        mediumWorks: progress.mediumWorks,
        hardWorks: progress.hardWorks,
        hardRescuedWorks: progress.hardRescuedWorks,
        lastMatchedTitle: progress.lastMatchedTitle,
        selectedRoots: progress.selectedRoots,
        folderVideoCounts: progress.folderVideoCounts,
        completedFolders: progress.completedFolders,
      ),
      ScrapePhase.cancelled => ScrapeCancelledPhase(
        sourceId: progress.sourceId,
        sourceLabel: progress.sourceLabel,
        currentItemName: progress.currentItemName,
        scannedDirectories: progress.scannedDirectories,
        foundFiles: progress.foundFiles,
        totalWorks: progress.totalWorks,
        processedWorks: progress.processedWorks,
        matchedWorks: progress.matchedWorks,
        reviewWorks: progress.reviewWorks,
        unmatchedWorks: progress.unmatchedWorks,
        easyWorks: progress.easyWorks,
        mediumWorks: progress.mediumWorks,
        hardWorks: progress.hardWorks,
        hardRescuedWorks: progress.hardRescuedWorks,
        lastMatchedTitle: progress.lastMatchedTitle,
        selectedRoots: progress.selectedRoots,
        folderVideoCounts: progress.folderVideoCounts,
        completedFolders: progress.completedFolders,
        errorMessage: progress.errorMessage,
      ),
      ScrapePhase.failed => ScrapeFailedPhase(
        sourceId: progress.sourceId,
        sourceLabel: progress.sourceLabel,
        currentItemName: progress.currentItemName,
        scannedDirectories: progress.scannedDirectories,
        foundFiles: progress.foundFiles,
        totalWorks: progress.totalWorks,
        processedWorks: progress.processedWorks,
        matchedWorks: progress.matchedWorks,
        reviewWorks: progress.reviewWorks,
        unmatchedWorks: progress.unmatchedWorks,
        easyWorks: progress.easyWorks,
        mediumWorks: progress.mediumWorks,
        hardWorks: progress.hardWorks,
        hardRescuedWorks: progress.hardRescuedWorks,
        lastMatchedTitle: progress.lastMatchedTitle,
        selectedRoots: progress.selectedRoots,
        folderVideoCounts: progress.folderVideoCounts,
        completedFolders: progress.completedFolders,
        errorMessage: progress.errorMessage ?? '扫库过程发生未知错误',
      ),
    };
  }

  /// 当前正在处理的媒体源 ID。
  final String? sourceId;

  /// 当前正在处理的媒体源显示名称。
  final String sourceLabel;

  /// 当前正在扫描的目录或正在刮削的作品名。
  final String currentItemName;

  /// 已扫描目录数。
  final int scannedDirectories;

  /// 已发现的媒体文件总数。
  final int foundFiles;

  /// 归组待刮削的作品总数。
  final int totalWorks;

  /// 已处理完毕的作品数。
  final int processedWorks;

  /// 自动高置信匹配的作品数。
  final int matchedWorks;

  /// 进入待人工复核的作品数。
  final int reviewWorks;

  /// 未能匹配任何元数据的作品数。
  final int unmatchedWorks;

  /// 识别为「简单」档位的作品数。
  final int easyWorks;

  /// 识别为「中等」档位的作品数。
  final int mediumWorks;

  /// 识别为「困难」档位的作品数。
  final int hardWorks;

  /// 困难档位中由联合纠偏救回的作品数。
  final int hardRescuedWorks;

  /// 当前正在处理条目的难度档位。
  final MatchDifficulty? currentDifficulty;

  /// 最近一次成功匹配的中文或标准标题。
  final String? lastMatchedTitle;

  /// 本轮扫描勾选的子目录集合。
  final List<String> selectedRoots;

  /// 已发现的各目录视频计数快照。
  final Map<String, int> folderVideoCounts;

  /// 已完成处理或已复用的目录路径集合。
  final Set<String> completedFolders;

  /// 是否已触发取消指令（任务正在收尾退出）。
  final bool cancelRequested;

  /// 异常中止时的中文错误原因。
  final String? errorMessage;

  /// 当前阶段枚举标识。
  ScrapeTaskStage get stage;

  /// 任务是否正在运行（横幅应展示实时进度与取消按钮）。
  bool get isActive =>
      stage == ScrapeTaskStage.checkingIndex ||
      stage == ScrapeTaskStage.scanning ||
      stage == ScrapeTaskStage.running;

  /// 任务是否已进入终态。
  bool get isTerminal =>
      stage == ScrapeTaskStage.completed ||
      stage == ScrapeTaskStage.cancelled ||
      stage == ScrapeTaskStage.failed;

  /// 整体完成进度比例（无确定总数时返回 `null` 以显示不定长进度条）。
  double? get progressRatio {
    if (stage == ScrapeTaskStage.completed) return 1.0;
    if (totalWorks <= 0) return null;
    return (processedWorks / totalWorks).clamp(0.0, 1.0);
  }

  /// 适配 UI 展示的简短阶段标题。
  String get statusLabel => switch (stage) {
    ScrapeTaskStage.idle => '空闲就绪',
    ScrapeTaskStage.checkingIndex => '准备离线索引与映射表',
    ScrapeTaskStage.scanning => '正在遍历媒体源目录',
    ScrapeTaskStage.running => cancelRequested ? '正在安全中止当前扫描…' : '正在匹配与刮削元数据',
    ScrapeTaskStage.completed => '扫库刮削已完成',
    ScrapeTaskStage.cancelled => '已取消本轮扫描',
    ScrapeTaskStage.failed => '扫库刮削失败',
  };

  /// 适配进度横幅与弹窗副标题的摘要说明文本。
  String get detailLabel {
    return switch (this) {
      ScrapeIdlePhase() => '尚未发起扫描任务',
      ScrapeCheckingIndexPhase(:final statusMessage) => statusMessage,
      ScrapeScanningPhase() =>
        currentItemName.isEmpty
            ? '已扫描 $scannedDirectories 个目录 · 发现 $foundFiles 个媒体文件'
            : '正在浏览：$currentItemName（$scannedDirectories 个目录，$foundFiles 个文件）',
      ScrapeRunningPhase() =>
        totalWorks > 0
            ? '进度 $processedWorks / $totalWorks · ${currentItemName.isEmpty ? "正在处理" : currentItemName}'
            : currentItemName,
      ScrapeCompletedPhase() =>
        '共 $totalWorks 部 · 已匹配 $matchedWorks · 待复核 $reviewWorks · 未匹配 $unmatchedWorks',
      ScrapeCancelledPhase() =>
        '已处理 $processedWorks / $totalWorks 部（已保存进度随时可继续）',
      ScrapeFailedPhase(:final errorMessage) => errorMessage ?? '扫库发生未知错误',
    };
  }
}

/// 空闲态阶段。
final class ScrapeIdlePhase extends ScrapeTaskPhase {
  /// 构造空闲态。
  const ScrapeIdlePhase() : super();

  @override
  ScrapeTaskStage get stage => ScrapeTaskStage.idle;
}

/// 索引检查与映射表热更新准备阶段。
final class ScrapeCheckingIndexPhase extends ScrapeTaskPhase {
  /// 构造索引检查阶段。
  const ScrapeCheckingIndexPhase({
    super.sourceId,
    super.sourceLabel,
    this.statusMessage = '正在载入离线映射索引…',
  });

  /// 准备阶段的实时说明文本。
  final String statusMessage;

  @override
  ScrapeTaskStage get stage => ScrapeTaskStage.checkingIndex;
}

/// 目录扫描与归组阶段。
final class ScrapeScanningPhase extends ScrapeTaskPhase {
  /// 构造目录扫描阶段。
  const ScrapeScanningPhase({
    super.sourceId,
    super.sourceLabel,
    super.currentItemName,
    super.scannedDirectories,
    super.foundFiles,
    super.totalWorks,
    super.selectedRoots,
    super.folderVideoCounts,
    super.completedFolders,
    super.cancelRequested,
  });

  @override
  ScrapeTaskStage get stage => ScrapeTaskStage.scanning;
}

/// 分集与多源元数据刮削进行中阶段。
final class ScrapeRunningPhase extends ScrapeTaskPhase {
  /// 构造刮削运行阶段。
  const ScrapeRunningPhase({
    super.sourceId,
    super.sourceLabel,
    super.currentItemName,
    super.scannedDirectories,
    super.foundFiles,
    super.totalWorks,
    super.processedWorks,
    super.matchedWorks,
    super.reviewWorks,
    super.unmatchedWorks,
    super.easyWorks,
    super.mediumWorks,
    super.hardWorks,
    super.hardRescuedWorks,
    super.currentDifficulty,
    super.lastMatchedTitle,
    super.selectedRoots,
    super.folderVideoCounts,
    super.completedFolders,
    super.cancelRequested,
  });

  @override
  ScrapeTaskStage get stage => ScrapeTaskStage.running;

  /// 复制并标记已发起取消请求（保留已有进度统计）。
  ScrapeRunningPhase withCancelRequested() {
    return ScrapeRunningPhase(
      sourceId: sourceId,
      sourceLabel: sourceLabel,
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
      hardRescuedWorks: hardRescuedWorks,
      currentDifficulty: currentDifficulty,
      lastMatchedTitle: lastMatchedTitle,
      selectedRoots: selectedRoots,
      folderVideoCounts: folderVideoCounts,
      completedFolders: completedFolders,
      cancelRequested: true,
    );
  }
}

/// 扫描正常完成阶段。
final class ScrapeCompletedPhase extends ScrapeTaskPhase {
  /// 构造扫描完成阶段。
  const ScrapeCompletedPhase({
    super.sourceId,
    super.sourceLabel,
    super.currentItemName,
    super.scannedDirectories,
    super.foundFiles,
    super.totalWorks,
    super.processedWorks,
    super.matchedWorks,
    super.reviewWorks,
    super.unmatchedWorks,
    super.easyWorks,
    super.mediumWorks,
    super.hardWorks,
    super.hardRescuedWorks,
    super.lastMatchedTitle,
    super.selectedRoots,
    super.folderVideoCounts,
    super.completedFolders,
  });

  @override
  ScrapeTaskStage get stage => ScrapeTaskStage.completed;
}

/// 扫描被用户取消阶段。
final class ScrapeCancelledPhase extends ScrapeTaskPhase {
  /// 构造扫描取消阶段。
  const ScrapeCancelledPhase({
    super.sourceId,
    super.sourceLabel,
    super.currentItemName,
    super.scannedDirectories,
    super.foundFiles,
    super.totalWorks,
    super.processedWorks,
    super.matchedWorks,
    super.reviewWorks,
    super.unmatchedWorks,
    super.easyWorks,
    super.mediumWorks,
    super.hardWorks,
    super.hardRescuedWorks,
    super.lastMatchedTitle,
    super.selectedRoots,
    super.folderVideoCounts,
    super.completedFolders,
    super.errorMessage,
  });

  @override
  ScrapeTaskStage get stage => ScrapeTaskStage.cancelled;
}

/// 扫描异常失败阶段。
final class ScrapeFailedPhase extends ScrapeTaskPhase {
  /// 构造扫描失败阶段。
  const ScrapeFailedPhase({
    super.sourceId,
    super.sourceLabel,
    super.currentItemName,
    super.scannedDirectories,
    super.foundFiles,
    super.totalWorks,
    super.processedWorks,
    super.matchedWorks,
    super.reviewWorks,
    super.unmatchedWorks,
    super.easyWorks,
    super.mediumWorks,
    super.hardWorks,
    super.hardRescuedWorks,
    super.lastMatchedTitle,
    super.selectedRoots,
    super.folderVideoCounts,
    super.completedFolders,
    required String super.errorMessage,
  });

  @override
  ScrapeTaskStage get stage => ScrapeTaskStage.failed;
}
