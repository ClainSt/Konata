import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';

/// 单作元数据重新抓取与在线补全实时状态机（驱动详情页进度胶囊，严禁使用 Riverpod）。
sealed class WorkRescrapeState {
  /// 创建基础重刮状态节点。
  const WorkRescrapeState();
}

/// 空闲就绪态：未在执行单作重刮任务。
final class WorkRescrapeIdle extends WorkRescrapeState {
  /// 创建空闲态。
  const WorkRescrapeIdle();
}

/// 正在重刮进行态：承载当前阶段提示与真实进度分步计数。
final class WorkRescrapeRunning extends WorkRescrapeState {
  /// 创建重刮进行态。
  const WorkRescrapeRunning({
    required this.workId,
    required this.stageLabel,
    required this.stepIndex,
    required this.totalSteps,
    this.detailText,
  });

  /// 正在重新抓取的作品标识。
  final WorkId workId;

  /// 当前阶段中文提示文案。
  final String stageLabel;

  /// 当前步骤序号（从 `1` 起）。
  final int stepIndex;

  /// 预计总步骤数。
  final int totalSteps;

  /// 可选阶段补充说明。
  final String? detailText;

  /// 完成比例（`0.0 ~ 1.0`）。
  double get fraction {
    if (totalSteps <= 0) return 0.0;
    return (stepIndex / totalSteps).clamp(0.0, 1.0);
  }

  /// 完成百分比整数（`0 ~ 100`）。
  int get percent => (fraction * 100).round();
}

/// 重刮成功完成态：包含更新后作品快照与可选自动归并跳转提示。
final class WorkRescrapeSucceeded extends WorkRescrapeState {
  /// 创建重刮完成态。
  const WorkRescrapeSucceeded({
    required this.workId,
    required this.message,
    this.updatedWork,
    this.autoMerged = false,
    this.redirectedWorkId,
  });

  /// 触发重刮的作品标识。
  final WorkId workId;

  /// 中文完成摘要。
  final String message;

  /// 最新作品实体快照。
  final Work? updatedWork;

  /// 是否触发同源强身份多版本自动归并。
  final bool autoMerged;

  /// 当原条目被并入已有作品时，提供跳转目标作品标识。
  final WorkId? redirectedWorkId;
}

/// 重刮异常失败态：记录已脱敏的中文失败原因。
final class WorkRescrapeFailed extends WorkRescrapeState {
  /// 创建重刮失败态。
  const WorkRescrapeFailed({
    required this.workId,
    required this.errorMessage,
  });

  /// 触发重刮的作品标识。
  final WorkId workId;

  /// 面向用户的中文错误提示。
  final String errorMessage;
}
