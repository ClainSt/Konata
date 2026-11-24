import '../models/episode.dart';
import '../models/playback_record.dart';
import '../models/work.dart';

/// 追番与近期活跃作品后台静默巡检的节流与配额配置（统一收口防硬编码）。
class OngoingWorkAutoSyncConfig {
  const OngoingWorkAutoSyncConfig._();

  /// 应用启动后等待首屏与海报墙渲染稳定的延迟时长。
  static const Duration startupDelay = Duration(seconds: 5);

  /// 两次后台自动巡检之间的最短冷静间隔（避免频繁前后台切换触发网盘风控）。
  static const Duration minAutoSyncInterval = Duration(minutes: 10);

  /// 单个作品在详情页内自动同步的最短冷却间隔（防反复进出同一详情页重复列目录）。
  static const Duration perWorkDetailSyncCooldown = Duration(seconds: 30);

  /// 每次后台静默巡检最多检查的作品数量上限（3,500 部大库每次只巡检最活跃的少数追番目录）。
  static const int maxWorksPerCycle = 12;

  /// 最近播放优先巡检的时间窗口（天）。
  static const int recentPlaybackWindowDays = 30;

  /// 后台巡检相邻作品之间的温和起搏间隔（兼顾 CD2 / 光鸭防风控）。
  static const Duration betweenWorksPacing = Duration(milliseconds: 150);
}

/// 从媒体库中精准挑选最可能出现「追番新增集数 / 看完删集」的活跃作品候选集。
///
/// 纯领域计算逻辑，零 I/O 与 UI 依赖：
/// 1. 第一梯队：最近 30 天内有观看记录的作品（按最后观看时间倒序，最符合追番与看完删集场景）；
/// 2. 第二梯队：近期年份（近两年）连载中或当前仅收录少量集数（1~11 集）的已匹配剧集作品；
/// 3. 严格受 [maxCount] 上限约束，绝不对数千部已归档老番发起批量网盘扫描。
class OngoingWorkAutoSyncPlanner {
  const OngoingWorkAutoSyncPlanner._();

  /// 选出本轮后台静默巡检的作品 ID 列表（去重并按优先级排序）。
  static List<String> selectCandidateWorkIds({
    required List<Work> works,
    required List<PlaybackRecord> recentPlaybacks,
    Map<String, int> mainEpisodeCountByWorkId = const {},
    DateTime? now,
    int maxCount = OngoingWorkAutoSyncConfig.maxWorksPerCycle,
  }) {
    if (works.isEmpty || maxCount <= 0) return const [];
    final current = now ?? DateTime.now();
    final cutoff = current.subtract(
      const Duration(days: OngoingWorkAutoSyncConfig.recentPlaybackWindowDays),
    );
    final workById = <String, Work>{
      for (final w in works)
        if (!w.isHidden) w.id: w,
    };
    if (workById.isEmpty) return const [];

    final picked = <String>[];
    final seen = <String>{};

    // 梯队 1：近期实际在追/刚看过的作品（按最近播放时间倒序）。
    final sortedPlaybacks = List<PlaybackRecord>.of(recentPlaybacks)
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    for (final rec in sortedPlaybacks) {
      if (picked.length >= maxCount) break;
      if (rec.playedAt.isBefore(cutoff)) continue;
      if (!workById.containsKey(rec.workId)) continue;
      if (seen.add(rec.workId)) {
        picked.add(rec.workId);
      }
    }

    if (picked.length >= maxCount) return picked;

    // 梯队 2：近两年新番或正片集数较少（1~11 集，大概率仍在周更/分卷增量更新）的剧集作品。
    final minOngoingYear = current.year - 1;
    final secondary = <Work>[];
    for (final w in workById.values) {
      if (seen.contains(w.id)) continue;
      if (w.tmdbMediaType == TmdbMediaType.movie) continue;
      final epCount = mainEpisodeCountByWorkId[w.id];
      final isRecentYear = w.year != null && w.year! >= minOngoingYear;
      final isLikelyIncompleteTv = epCount != null && epCount >= 1 && epCount < 12;
      if (isRecentYear || isLikelyIncompleteTv) {
        secondary.add(w);
      }
    }
    secondary.sort((a, b) {
      final ya = a.year ?? 0;
      final yb = b.year ?? 0;
      if (ya != yb) return yb.compareTo(ya);
      final ea = mainEpisodeCountByWorkId[a.id] ?? 999;
      final eb = mainEpisodeCountByWorkId[b.id] ?? 999;
      if (ea != eb) return ea.compareTo(eb);
      return a.id.compareTo(b.id);
    });

    for (final w in secondary) {
      if (picked.length >= maxCount) break;
      if (seen.add(w.id)) {
        picked.add(w.id);
      }
    }
    return picked;
  }

  /// 根据剧集列表统计每部作品的正片集数映射（供梯队 2 判定连载残缺度）。
  static Map<String, int> countMainEpisodesByWork(Iterable<Episode> episodes) {
    final counts = <String, int>{};
    for (final ep in episodes) {
      if (ep.category != EpisodeCategory.main) continue;
      counts.update(ep.workId, (v) => v + 1, ifAbsent: () => 1);
    }
    return counts;
  }
}
