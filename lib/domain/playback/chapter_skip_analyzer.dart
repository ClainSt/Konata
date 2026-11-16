import 'playback_probe_stats.dart';

/// 章节识别触发的智能跳过动作类型。
enum SkipActionKind {
  /// 跳过片头曲 OP（跳转至 OP 结束时间）。
  skipOp,

  /// 跳过片尾曲 ED（片尾后仍有 >5s C-Part / 下集预告，跳转至 ED 结束时间）。
  skipEdToCPart,

  /// 跳过片尾曲 ED（片尾后 <=5s 无 C-Part，直接切至下一话）。
  skipEdToNextEpisode,
}

/// 已识别的片头 / 片尾章节窗口。
class DetectedSkipWindow {
  /// 创建跳过窗口描述。
  const DetectedSkipWindow({
    required this.kind,
    required this.startSeconds,
    required this.endSeconds,
    required this.label,
    required this.isTier1Named,
  });

  /// 动作类型。
  final SkipActionKind kind;

  /// 触发起点（秒）。
  final double startSeconds;

  /// 目标终点（秒）。
  final double endSeconds;

  /// 胶囊按钮提示文案。
  final String label;

  /// true = 层级一显式命名匹配；false = 层级二时长规则匹配。
  final bool isTier1Named;

  /// 是否覆盖指定时间点。
  bool containsPosition(double positionSeconds) {
    return positionSeconds >= startSeconds && positionSeconds < endSeconds;
  }
}

/// 全片自动计算出的跳过计划。
class ChapterSkipPlan {
  /// 创建章节跳过计划。
  const ChapterSkipPlan({this.opening, this.ending});

  /// 识别到的片头窗口。
  final DetectedSkipWindow? opening;

  /// 识别到的片尾窗口。
  final DetectedSkipWindow? ending;

  /// 根据当前播放进度返回激活的跳过窗口（若无则 null）。
  DetectedSkipWindow? activeWindowAt(double positionSeconds) {
    if (!positionSeconds.isFinite || positionSeconds < 0) return null;
    if (opening != null && opening!.containsPosition(positionSeconds)) {
      return opening;
    }
    if (ending != null && ending!.containsPosition(positionSeconds)) {
      return ending;
    }
    return null;
  }
}

/// 番剧 OP / ED 二级章节识别分析器（纯领域算法）。
///
/// 识别规则：
/// - **层级一（显式命名匹配）**：匹配中/英/日章节名中的 OP/Opening/片头 与 ED/Ending/片尾；
/// - **层级二（时长特征兜底）**：仅当单集总时长 `>= 18 分钟`（1080s）时，对未命名或通用章节名中
///   时长处于 `85s ~ 96s` 的前段与后段章节自动判定为 OP 与 ED；
/// - **ED 后置 C-Part 决策**：对比 ED 结束时间与总时长，剩余内容 `> 5s` 跳至 C-Part，
///   `<= 5s` 直接提示「跳过片尾 · 下一话 ⏭」。
class ChapterSkipAnalyzer {
  ChapterSkipAnalyzer._();

  /// 层级二启发式启用阈值（18 分钟）。
  static const double minDurationForDurationHeuristicSeconds = 18 * 60.0;

  /// 标准 90 秒 OP/ED 容差窗口。
  static const double minThemeDurationSeconds = 84.5;
  static const double maxThemeDurationSeconds = 96.5;

  /// ED 结束至片尾边界的 C-Part 阈值（5 秒）。
  static const double cPartRemainingThresholdSeconds = 5.0;

  static final RegExp _opNamedRegex = RegExp(
    r'(?:^|[\s\-_\[(/])(?:ncop|opening(?:\s*theme)?|op(?:\s*part)?)(?:$|[\s\-_\])/0-9])|(?:片头(?:曲)?|オープニング)',
    caseSensitive: false,
  );

  static final RegExp _edNamedRegex = RegExp(
    r'(?:^|[\s\-_\[(/])(?:nced|ending(?:\s*theme)?|ed(?:\s*part)?|credits)(?:$|[\s\-_\])/0-9])|(?:片尾(?:曲)?|エンディング)',
    caseSensitive: false,
  );

  static final RegExp _genericChapterRegex = RegExp(
    r'^(?:chapter\s*\d*|chap\.?\s*\d*|part\s*\d*|\d+|untitled|)$',
    caseSensitive: false,
  );

  /// 根据标准化章节列表与视频总时长构建 OP / ED 跳过计划。
  static ChapterSkipPlan analyze({
    required List<PlaybackChapter> rawChapters,
    required double totalDurationSeconds,
    bool hasNextEpisode = true,
  }) {
    if (rawChapters.isEmpty ||
        !totalDurationSeconds.isFinite ||
        totalDurationSeconds <= 0) {
      return const ChapterSkipPlan();
    }

    final chapters = PlaybackProbeStats.normalizeChapters(
      rawChapters,
      totalDurationSeconds: totalDurationSeconds,
    );

    DetectedSkipWindow? opening;
    DetectedSkipWindow? ending;

    // 1. 层级一：显式命名匹配
    for (final ch in chapters) {
      final end = ch.endSeconds;
      if (end == null || end <= ch.startSeconds) continue;
      final duration = end - ch.startSeconds;
      if (duration < 15.0 || duration > 240.0) continue;

      final title = ch.title.trim();
      if (opening == null &&
          ch.startSeconds <= totalDurationSeconds * 0.45 &&
          _opNamedRegex.hasMatch(title)) {
        opening = DetectedSkipWindow(
          kind: SkipActionKind.skipOp,
          startSeconds: ch.startSeconds,
          endSeconds: end,
          label: '跳过 OP',
          isTier1Named: true,
        );
        continue;
      }
      if (ending == null &&
          ch.startSeconds >= totalDurationSeconds * 0.45 &&
          _edNamedRegex.hasMatch(title)) {
        ending = _buildEndingWindow(
          startSeconds: ch.startSeconds,
          endSeconds: end,
          totalDurationSeconds: totalDurationSeconds,
          hasNextEpisode: hasNextEpisode,
          isTier1Named: true,
        );
      }
    }

    // 2. 层级二：单集 >= 18min 且未显式命名时，匹配 85s ~ 96s 通用章节
    if (totalDurationSeconds >= minDurationForDurationHeuristicSeconds) {
      for (final ch in chapters) {
        final end = ch.endSeconds;
        if (end == null) continue;
        final duration = end - ch.startSeconds;
        if (duration < minThemeDurationSeconds ||
            duration > maxThemeDurationSeconds) {
          continue;
        }
        if (!_genericChapterRegex.hasMatch(ch.title.trim())) {
          continue;
        }

        final opMaxStart = (totalDurationSeconds * 0.25) > 300.0
            ? totalDurationSeconds * 0.25
            : 300.0;
        if (opening == null && ch.startSeconds <= opMaxStart) {
          opening = DetectedSkipWindow(
            kind: SkipActionKind.skipOp,
            startSeconds: ch.startSeconds,
            endSeconds: end,
            label: '跳过 OP',
            isTier1Named: false,
          );
          continue;
        }

        if (ending == null &&
            ch.startSeconds >= totalDurationSeconds * 0.55 &&
            ch.startSeconds > 60.0) {
          ending = _buildEndingWindow(
            startSeconds: ch.startSeconds,
            endSeconds: end,
            totalDurationSeconds: totalDurationSeconds,
            hasNextEpisode: hasNextEpisode,
            isTier1Named: false,
          );
        }
      }
    }

    return ChapterSkipPlan(opening: opening, ending: ending);
  }

  static DetectedSkipWindow _buildEndingWindow({
    required double startSeconds,
    required double endSeconds,
    required double totalDurationSeconds,
    required bool hasNextEpisode,
    required bool isTier1Named,
  }) {
    final remaining = totalDurationSeconds - endSeconds;
    final hasCPart = remaining > cPartRemainingThresholdSeconds;
    if (hasCPart || !hasNextEpisode) {
      return DetectedSkipWindow(
        kind: SkipActionKind.skipEdToCPart,
        startSeconds: startSeconds,
        endSeconds: endSeconds,
        label: '跳过 ED',
        isTier1Named: isTier1Named,
      );
    }
    return DetectedSkipWindow(
      kind: SkipActionKind.skipEdToNextEpisode,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      label: '跳过片尾 · 下一话',
      isTier1Named: isTier1Named,
    );
  }
}
