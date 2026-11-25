import '../matching/directory_grouper.dart';
import '../matching/work_matcher.dart';
import '../models/episode.dart';
import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import 'artwork_ranker.dart';
import 'bangumi_models.dart';
import 'directory_analyzer.dart';

/// 海报墙独立上墙资格、背景图质量评估与跨来源身份识别纯领域规则（零 IO）。
///
/// 职责边界：
/// - 将“是否拆分子簇”（由 `MultiWorkSplitter` 守卫）与“已归组作品是否具备独立上墙资格”解耦；
/// - 解除对 TMDB 正式 TV/Movie 的强绑定，同时以「含有效正片内容」为硬防线，杜绝纯特典碎文件夹被误晋升为海报卡片；
/// - 统一评估 TMDB 背景图是否低清或带文字，以驱动 Fanart.tv 1080p 无字横图兜底；
/// - 统一计算跨来源重复卡片身份键，供海报墙仅在多来源并存同名卡片时渲染右上角来源角标。
abstract final class WorkWallEligibility {
  /// 高清无字背景图最小达标像素宽度（低于该宽度如 `1280×720` 将触发 Fanart.tv `1920×1080` 升级）。
  static const int preferredBackdropMinWidth = 1920;

  /// Bangumi 中置信条目允许独立上墙的最低综合分阈值。
  static const double mediumBangumiPromoteMinScore = 36.0;

  static const Set<String> _hardConflictTokens = {
    'year conflict',
    'year mismatch',
    'type conflict',
    'media_type_conflict',
    'year_mismatch',
    'conflicting subtitle',
    'anthology',
  };

  /// 判断归组作品目录是否包含有效正片播放内容（防止 0 正片纯特典/NCOP/PV/CM/Menu/CD/Scan 目录误上墙）。
  static bool hasMainPlayableContent(GroupedWorkFolder folder) {
    final inv = folder.inventory;
    if (inv != null && inv.shape == WorkShape.anthology) {
      return false;
    }
    if (folder.mainEpisodeNumbers.isNotEmpty) {
      return true;
    }
    if (folder.slotAssignmentsByPath.isNotEmpty) {
      for (final slot in folder.slotAssignmentsByPath.values) {
        if (slot.category == EpisodeCategory.main) {
          return true;
        }
      }
      return false;
    }
    if (inv != null) {
      if (inv.episodeCount > 0 || inv.featureCount > 0) {
        return true;
      }
      return false;
    }
    // 兜底：无预解析槽位与画像时，仅当存在视频文件且非纯样片目录才放行。
    return folder.variants.any((v) => v.assetKind == AssetKind.video);
  }

  /// 判断无 TMDB 匹配、仅命中 Bangumi 的独立作品是否满足海报墙独立建卡资格。
  ///
  /// 规则：
  /// 1. 必须包含有效正片视频（非纯特典/合集未拆目录）；
  /// 2. 必须具备有效封面（Bangumi 官方封面、Fanart.tv 封面或本地磁盘封面）；
  /// 3. Bangumi 命中高置信直接晋升；命中中置信时需无年份/类型/副标题硬冲突且分值达标。
  static bool shouldPromoteBangumiOnly({
    required GroupedWorkFolder folder,
    required ScoredBangumiCandidate? bestBangumi,
    required MatchTier bangumiTier,
    required bool hasValidCover,
  }) {
    if (bestBangumi == null || !hasValidCover) return false;
    if (!hasMainPlayableContent(folder)) return false;
    if (bangumiTier == MatchTier.high) {
      return true;
    }
    if (bangumiTier == MatchTier.medium) {
      if (bestBangumi.score < mediumBangumiPromoteMinScore) return false;
      final hasHardConflict = bestBangumi.reasons.any((reason) {
        final lower = reason.toLowerCase();
        return _hardConflictTokens.any(lower.contains);
      });
      return !hasHardConflict;
    }
    return false;
  }

  /// 判断无 TMDB 且无 Bangumi 主匹配的条目，凭 Fanart.tv 封面或本地目录封面是否具备独立上墙资格。
  static bool shouldPromoteCoverFallback({
    required GroupedWorkFolder folder,
    required String? coverPath,
  }) {
    final cleanCover = coverPath?.trim() ?? '';
    if (cleanCover.isEmpty) return false;
    return hasMainPlayableContent(folder);
  }

  /// 判断当前 TMDB 背景图是否欠佳（缺图、低于 1080p、带文字、非标准零头分辨率如 `2008×1129`，
  /// 或缺乏社区共识的低票 1080p 截图），需要尝试用 Fanart.tv 精选 `1080p` 无字横图升级。
  static bool isTmdbBackdropSuboptimal({
    required String? selectedBackdropPath,
    required List<TmdbArtworkImage> candidateBackdrops,
  }) => ArtworkRanker.isTmdbBackdropSuboptimal(
    selectedBackdropPath: selectedBackdropPath,
    candidateBackdrops: candidateBackdrops,
  );

  /// 判断当前 TMDB 竖版封面是否欠佳（缺图、模糊小图 `< 680px`、异常比例或仅有欧美英文版封面）。
  static bool isTmdbPosterSuboptimal({
    required String? selectedPosterPath,
    required List<TmdbArtworkImage> candidatePosters,
  }) => ArtworkRanker.isTmdbPosterSuboptimal(
    selectedPosterPath: selectedPosterPath,
    candidatePosters: candidatePosters,
  );

  /// 计算作品在海报墙上的跨来源去重身份键（仅用于识别“不同来源存在相同作品卡片”，绝不用于合并跨源记录）。
  static String buildCrossSourceIdentityKey(Work work) {
    if (work.tmdbId != null && work.tmdbId! > 0) {
      final type = work.tmdbMediaType?.name ?? 'tv';
      final season = type == 'tv' ? (work.matchedSeason ?? 0) : 0;
      return 'tmdb:$type:${work.tmdbId}:s$season';
    }
    if (work.bangumiId != null && work.bangumiId! > 0) {
      return 'bgm:${work.bangumiId}';
    }
    if (work.tvdbId != null && work.tvdbId! > 0) {
      return 'tvdb:${work.tvdbId}:s${work.matchedSeason ?? 0}';
    }
    final normTitle = DirectoryAnalyzer.normalize(work.title);
    final keyTitle = normTitle.isNotEmpty
        ? normTitle
        : work.title.trim().toLowerCase();
    return 'title:$keyTitle:${work.year ?? 0}';
  }
}
