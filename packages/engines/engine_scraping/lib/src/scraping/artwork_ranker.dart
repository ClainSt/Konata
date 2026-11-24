import '../models/fanart_models.dart';
import '../models/tmdb_models.dart';

/// 背景图画质与规范分档（数值越小优先级越高）。
enum BackdropQualityTier {
  /// 无字超清官方原画（`>= 2560×1440` 标准 16:9，动漫领域基本排除 1080p 动画随手截帧）。
  ultraHdTextless(0),

  /// 无字标准 1080p 原画（精确 `1920×1080` ± 2px 容差）。
  standard1080pTextless(1),

  /// 无字非标准高像素尺寸（如 `2008×1129`、`2024×1138`，多为低清拉大或扫图裁切，需触发精选源升级）。
  nonStandardHiResTextless(2),

  /// 无字 720p ~ 准 1080p 原画（`1280 <= width < 1920`）。
  hd720pTextless(3),

  /// 带语言文字标签的高清横图（`width >= 1280`）。
  textedHd(4),

  /// 低于 720p 或非 16:9 异常比例横图。
  lowResOrMalformed(5);

  const BackdropQualityTier(this.rank);

  /// 排序阶梯权重（越小越靠前）。
  final int rank;
}

/// 封面图与背景图多源统一排序与画质评估纯领域引擎（零 IO）。
///
/// 职责边界：
/// - 作为 TMDB 服务解析、刮削自动选图、Fanart.tv/Bangumi 协同升级与「编辑封面/背景图」弹窗的唯一排序真源；
/// - 消除「只看裸均分忽略投票数」「4K 原画与 1080p 动画截图混档」「非标拉伸糊图骗过 1920px 阈值」三类选图缺陷。
abstract final class ArtworkRanker {
  /// 高清无字背景图最小宽度阈值（低于此值触发低清升级）。
  static const int preferredBackdropMinWidth = 1920;

  /// 准高清背景图最小宽度阈值。
  static const int hdBackdropMinWidth = 1280;

  /// 超清 2K/4K 官方背景原画最小宽度与高度阈值。
  static const int ultraHdBackdropMinWidth = 2560;
  static const int ultraHdBackdropMinHeight = 1440;

  /// 标准 1080p 背景图宽高基准与容差。
  static const int standard1080pWidth = 1920;
  static const int standard1080pHeight = 1080;
  static const int standard1080pTolerance = 2;

  /// 方案 A：标准 1080p 无字 TMDB 背景图无需向 Fanart.tv 升级的最低社区投票共识数。
  static const int minTrustedStandard1080pVotes = 3;

  /// 标准 16:9 横版背景图宽高比合法区间（标准值为 `1.7778`）。
  static const double minBackdropAspectRatio = 1.70;
  static const double maxBackdropAspectRatio = 1.85;

  /// 清晰竖版封面海报最小像素宽度（低于该宽度在桌面端易出现明显糊化）。
  static const int minCrispPosterWidth = 680;

  /// 全高清竖版封面海报宽度档位（`1000×1500` / `2000×3000`）。
  static const int fullHdPosterWidth = 1000;

  /// 标准竖版海报宽高比合法区间（常见 `2:3 = 0.667` 与 B2 原画 `0.70`）。
  static const double minPosterAspectRatio = 0.55;
  static const double maxPosterAspectRatio = 0.78;

  /// 贝叶斯平滑评分先验参数：避免 1~2 票随机截图凭虚高裸均分反超多人投票的官方原画。
  static const double _bayesianPriorMean = 5.0;
  static const double _bayesianPriorWeight = 3.0;

  /// 判定语言代码是否代表无语言/无字纯净原画。
  static bool isTextlessLanguage(String? isoLanguage) {
    final lang = (isoLanguage ?? '').trim().toLowerCase();
    return lang.isEmpty || lang == 'null' || lang == 'xx' || lang == '00';
  }

  /// 计算融合投票人数与均分的贝叶斯平滑热度分。
  ///
  /// 当上游未提供 `voteCount`（为 `null`）但存在有效均分时，按 1 票处理以兼容轻量测试夹具。
  static double bayesianVoteScore(TmdbArtworkImage image) {
    final avg = image.voteAverage ?? 0.0;
    final rawCount = image.voteCount;
    final count = rawCount != null
        ? (rawCount < 0 ? 0 : rawCount)
        : (avg > 0 ? 1 : 0);
    if (count == 0 || avg <= 0) {
      return _bayesianPriorMean;
    }
    return (count * avg + _bayesianPriorWeight * _bayesianPriorMean) /
        (count + _bayesianPriorWeight);
  }

  /// 判定横版背景图宽高比是否符合标准 16:9 规范（尺寸未知时默认放行）。
  static bool isStandard16x9Aspect(int? width, int? height) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return true;
    }
    final ratio = width / height;
    return ratio >= minBackdropAspectRatio && ratio <= maxBackdropAspectRatio;
  }

  /// 判定是否为无字超清 2K/4K 官方背景原画（`>= 2560×1440` 且标准 16:9）。
  static bool isUltraHdBackdrop(int? width, int? height) {
    if (width == null || height == null) return false;
    return width >= ultraHdBackdropMinWidth &&
        height >= ultraHdBackdropMinHeight &&
        isStandard16x9Aspect(width, height);
  }

  /// 判定是否为标准 1080p 工业规格（`1920×1080`，允许 ±2px 边界取整误差）。
  static bool isStandard1080pBackdrop(int? width, int? height) {
    if (width == null || height == null) return false;
    return (width - standard1080pWidth).abs() <= standard1080pTolerance &&
        (height - standard1080pHeight).abs() <= standard1080pTolerance;
  }

  /// 判定背景图语言优先级（无字 `0` > 中文 `1` > 日文 `2` > 英文 `3` > 其他 `4`）。
  static int backdropLanguageRank(String? isoLanguage) {
    final lang = (isoLanguage ?? '').trim().toLowerCase();
    if (isTextlessLanguage(lang)) return 0;
    if (lang == 'zh' || lang == 'cn') return 1;
    if (lang == 'ja') return 2;
    if (lang == 'en') return 3;
    return 4;
  }

  /// 对单张 TMDB 候选背景图划分画质与规范阶梯。
  static BackdropQualityTier backdropQualityTier(TmdbArtworkImage image) {
    final w = image.width;
    final h = image.height;
    final hasDims = w != null && w > 0;
    if (hasDims && (w < hdBackdropMinWidth || !isStandard16x9Aspect(w, h))) {
      return BackdropQualityTier.lowResOrMalformed;
    }
    final textless = isTextlessLanguage(image.isoLanguage);
    if (!textless) {
      return BackdropQualityTier.textedHd;
    }
    if (!hasDims) {
      // 仅含路径无尺寸元数据时保守归为标准 1080p 兜底档。
      return BackdropQualityTier.standard1080pTextless;
    }
    if (isUltraHdBackdrop(w, h)) {
      return BackdropQualityTier.ultraHdTextless;
    }
    if (isStandard1080pBackdrop(w, h)) {
      return BackdropQualityTier.standard1080pTextless;
    }
    if (w >= preferredBackdropMinWidth) {
      // 如 2008×1129、2024×1138 等零头非标尺寸，显式降至标准 1080p 与 Fanart 之后。
      return BackdropQualityTier.nonStandardHiResTextless;
    }
    return BackdropQualityTier.hd720pTextless;
  }

  /// 判断单张 TMDB 候选背景图是否属于方案 A 定义的「高共识无字标准 1080p 或 4K/2K」。
  static bool isHighConfidenceCleanTmdbBackdrop(TmdbArtworkImage image) {
    final tier = backdropQualityTier(image);
    if (tier == BackdropQualityTier.ultraHdTextless) return true;
    if (tier == BackdropQualityTier.standard1080pTextless) {
      final votes = image.voteCount;
      return votes == null || votes >= minTrustedStandard1080pVotes;
    }
    return false;
  }

  /// 比较两张 TMDB 候选背景图优劣（返回值 `< 0` 表示 [a] 更优）。
  static int compareTmdbBackdrops(
    TmdbArtworkImage a,
    TmdbArtworkImage b, {
    String? primaryDefaultPath,
  }) {
    final tierCmp = backdropQualityTier(a).rank.compareTo(
      backdropQualityTier(b).rank,
    );
    if (tierCmp != 0) return tierCmp;

    final langCmp = backdropLanguageRank(
      a.isoLanguage,
    ).compareTo(backdropLanguageRank(b.isoLanguage));
    if (langCmp != 0) return langCmp;

    final aScore = bayesianVoteScore(a);
    final bScore = bayesianVoteScore(b);
    if ((bScore - aScore).abs() > 1e-6) {
      return bScore.compareTo(aScore);
    }

    final votesCmp = (b.voteCount ?? 0).compareTo(a.voteCount ?? 0);
    if (votesCmp != 0) return votesCmp;

    final cleanDefault = primaryDefaultPath?.trim();
    if (cleanDefault != null && cleanDefault.isNotEmpty) {
      final aPrimary = a.filePath.trim() == cleanDefault ? 0 : 1;
      final bPrimary = b.filePath.trim() == cleanDefault ? 0 : 1;
      if (aPrimary != bPrimary) return aPrimary.compareTo(bPrimary);
    }

    final aArea = (a.width ?? 0) * (a.height ?? 0);
    final bArea = (b.width ?? 0) * (b.height ?? 0);
    return bArea.compareTo(aArea);
  }

  /// 对 TMDB 候选背景图列表去重并按最优顺序排序（最多保留 [limit] 张）。
  static List<TmdbArtworkImage> rankTmdbBackdrops(
    Iterable<TmdbArtworkImage> raw, {
    String? primaryDefaultPath,
    int limit = 24,
  }) {
    final deduped = <TmdbArtworkImage>[];
    final seen = <String>{};
    for (final item in raw) {
      final key = item.filePath.trim();
      if (key.isEmpty || !seen.add(key)) continue;
      deduped.add(item);
    }
    deduped.sort(
      (a, b) => compareTmdbBackdrops(
        a,
        b,
        primaryDefaultPath: primaryDefaultPath,
      ),
    );
    if (deduped.length <= limit) return List<TmdbArtworkImage>.unmodifiable(deduped);
    return List<TmdbArtworkImage>.unmodifiable(deduped.take(limit));
  }

  /// 从已排序的 TMDB 候选背景图与接口默认路径中挑选最佳单源背景图。
  static String? selectBestTmdbBackdrop(
    List<TmdbArtworkImage> rankedBackdrops, {
    String? primaryDefaultPath,
  }) {
    final cleanDefault = _nonEmpty(primaryDefaultPath);
    final bestCleanHd = rankedBackdrops
        .where(
          (b) =>
              backdropQualityTier(b).rank <=
              BackdropQualityTier.hd720pTextless.rank,
        )
        .firstOrNull;
    if (bestCleanHd != null) return bestCleanHd.filePath.trim();
    if (cleanDefault != null) return cleanDefault;
    final bestAnyHd = rankedBackdrops
        .where((b) => (b.width ?? 0) >= hdBackdropMinWidth)
        .firstOrNull;
    return bestAnyHd?.filePath.trim();
  }

  /// 按方案 A 判断当前 TMDB 背景图是否欠佳、需要尝试用 Fanart.tv 精选 `1920×1080` 无字横图升级。
  ///
  /// 触发升级条件（满足任一）：
  /// 1. 缺图、低清（`< 1920px`）、非标准 16:9 或带文字语言标签；
  /// 2. 命中非标准零头高像素分辨率（如 `2008×1129`、`2024×1138`）；
  /// 3. 仅有标准 `1920×1080` 且明确携带低投票共识（`voteCount <= 2`，大概率为未审核动画截帧）。
  static bool isTmdbBackdropSuboptimal({
    required String? selectedBackdropPath,
    required List<TmdbArtworkImage> candidateBackdrops,
  }) {
    final selected = selectedBackdropPath?.trim() ?? '';
    if (selected.isEmpty) return true;
    if (candidateBackdrops.isEmpty) {
      // 仅拿到基础路径而未加载 `/images` 明细时保守不误判，避免无依据轰炸 Fanart 通道。
      return false;
    }
    TmdbArtworkImage? matched;
    for (final item in candidateBackdrops) {
      if (item.filePath.trim() == selected) {
        matched = item;
        break;
      }
    }
    if (matched == null) {
      return !candidateBackdrops.any(isHighConfidenceCleanTmdbBackdrop);
    }
    return !isHighConfidenceCleanTmdbBackdrop(matched);
  }

  /// 判定竖版封面海报宽高比是否符合正常海报比例（尺寸未知时默认放行）。
  static bool isStandardPosterAspect(int? width, int? height) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return true;
    }
    final ratio = width / height;
    return ratio >= minPosterAspectRatio && ratio <= maxPosterAspectRatio;
  }

  /// 判定竖版封面海报语言优先级：
  /// `简中 (0) < 繁中 (1) < 日文原版 (2) < 无字纯画 (3) < 英文 (4) < 其他 (5)`。
  static int posterLanguageRank(String? isoLanguage, String? isoCountry) {
    final lang = (isoLanguage ?? '').trim().toLowerCase();
    final country = (isoCountry ?? '').trim().toUpperCase();
    if (lang == 'zh' || lang == 'cn') {
      if (country == 'TW' || country == 'HK' || country == 'MO') {
        return 1;
      }
      return 0;
    }
    if (lang == 'ja') return 2;
    if (isTextlessLanguage(lang)) return 3;
    if (lang == 'en') return 4;
    return 5;
  }

  /// 判定封面图是否属于简繁中文、日文原版或无字纯净画作（非欧美英文版封面）。
  static bool isCjkOrTextlessPoster(String? isoLanguage, String? isoCountry) =>
      posterLanguageRank(isoLanguage, isoCountry) <= 3;

  static int _posterResolutionGate(TmdbArtworkImage image) {
    final w = image.width;
    final h = image.height;
    final hasDims = w != null && w > 0;
    if (hasDims && !isStandardPosterAspect(w, h)) return 2;
    if (hasDims && w < minCrispPosterWidth) return 1;
    return 0;
  }

  static bool _isExplicitSimplifiedRegion(String? isoCountry) {
    final country = (isoCountry ?? '').trim().toUpperCase();
    return country == 'CN' || country == 'SG';
  }

  /// 比较两张 TMDB 候选竖版封面优劣（返回值 `< 0` 表示 [a] 更优）。
  ///
  /// 规则：
  /// 1. 清晰度与竖版比例门槛：清晰标准竖版（`>= 680px`）严格压过模糊小图与异常横方比例图；
  /// 2. 语言序：`简中 > 繁中 > 日文原版 > 无字纯画 > 英文 > 其他`；
  /// 3. 同语言内优先全高清（`>= 1000px`）与明确 `zh-CN/SG` 地区标；
  /// 4. 贝叶斯平滑投票分 + 投票人数 + TMDB 默认主封面平票保护 + 像素宽度。
  static int compareTmdbPosters(
    TmdbArtworkImage a,
    TmdbArtworkImage b, {
    String? primaryDefaultPath,
  }) {
    final gateCmp = _posterResolutionGate(a).compareTo(_posterResolutionGate(b));
    if (gateCmp != 0) return gateCmp;

    final aLang = posterLanguageRank(a.isoLanguage, a.isoCountry);
    final bLang = posterLanguageRank(b.isoLanguage, b.isoCountry);
    if (aLang != bLang) return aLang.compareTo(bLang);

    // 同语言档内优先清晰全高清封面（如 1000×1500 / 2000×3000 优于 680×1000）。
    final aFull = (a.width == null || a.width == 0 || a.width! >= fullHdPosterWidth)
        ? 0
        : 1;
    final bFull = (b.width == null || b.width == 0 || b.width! >= fullHdPosterWidth)
        ? 0
        : 1;
    if (aFull != bFull) return aFull.compareTo(bFull);

    if (aLang == 0) {
      final aCn = _isExplicitSimplifiedRegion(a.isoCountry) ? 0 : 1;
      final bCn = _isExplicitSimplifiedRegion(b.isoCountry) ? 0 : 1;
      if (aCn != bCn) return aCn.compareTo(bCn);
    }

    final aScore = bayesianVoteScore(a);
    final bScore = bayesianVoteScore(b);
    if ((bScore - aScore).abs() > 1e-6) {
      return bScore.compareTo(aScore);
    }

    final votesCmp = (b.voteCount ?? 0).compareTo(a.voteCount ?? 0);
    if (votesCmp != 0) return votesCmp;

    final cleanDefault = primaryDefaultPath?.trim();
    if (cleanDefault != null && cleanDefault.isNotEmpty) {
      final aPrimary = a.filePath.trim() == cleanDefault ? 0 : 1;
      final bPrimary = b.filePath.trim() == cleanDefault ? 0 : 1;
      if (aPrimary != bPrimary) return aPrimary.compareTo(bPrimary);
    }

    return (b.width ?? 0).compareTo(a.width ?? 0);
  }

  /// 对 TMDB 候选封面海报去重并按最优顺序排序（最多保留 [limit] 张）。
  static List<TmdbArtworkImage> rankTmdbPosters(
    Iterable<TmdbArtworkImage> raw, {
    String? primaryDefaultPath,
    int limit = 24,
  }) {
    final deduped = <TmdbArtworkImage>[];
    final seen = <String>{};
    for (final item in raw) {
      final key = item.filePath.trim();
      if (key.isEmpty || !seen.add(key)) continue;
      deduped.add(item);
    }
    deduped.sort(
      (a, b) => compareTmdbPosters(
        a,
        b,
        primaryDefaultPath: primaryDefaultPath,
      ),
    );
    if (deduped.length <= limit) return List<TmdbArtworkImage>.unmodifiable(deduped);
    return List<TmdbArtworkImage>.unmodifiable(deduped.take(limit));
  }

  /// 从已排序的 TMDB 候选封面与接口默认路径中挑选最佳单源竖版封面。
  static String? selectBestTmdbPoster(
    List<TmdbArtworkImage> rankedPosters, {
    String? primaryDefaultPath,
  }) {
    if (rankedPosters.isNotEmpty) {
      return rankedPosters.first.filePath.trim();
    }
    return _nonEmpty(primaryDefaultPath);
  }

  /// 判断当前选中的 TMDB 封面是否欠佳（缺图、低清模糊 `< 680px`、异常比例，或仅有非中日无字的欧美英文版封面）。
  static bool isTmdbPosterSuboptimal({
    required String? selectedPosterPath,
    required List<TmdbArtworkImage> candidatePosters,
  }) {
    final selected = selectedPosterPath?.trim() ?? '';
    if (selected.isEmpty) return true;
    if (candidatePosters.isEmpty) return false;
    TmdbArtworkImage? matched;
    for (final item in candidatePosters) {
      if (item.filePath.trim() == selected) {
        matched = item;
        break;
      }
    }
    if (matched == null) return false;
    if (_posterResolutionGate(matched) > 0) return true;
    return !isCjkOrTextlessPoster(matched.isoLanguage, matched.isoCountry);
  }

  /// 判断当前选中的 TMDB 封面是否属于缺图、低清糊图（`< 680px`）或异常比例（区别于清晰的英文版封面）。
  static bool isTmdbPosterLowResOrMissing({
    required String? selectedPosterPath,
    required List<TmdbArtworkImage> candidatePosters,
  }) {
    final selected = selectedPosterPath?.trim() ?? '';
    if (selected.isEmpty) return true;
    if (candidatePosters.isEmpty) return false;
    for (final item in candidatePosters) {
      if (item.filePath.trim() == selected) {
        return _posterResolutionGate(item) > 0;
      }
    }
    return false;
  }

  /// 统一评估 TMDB 分季海报与系列主海报的生效优先级及画质状态（领域层与应用层唯一真源）。
  ///
  /// 当第 1 季（或未分季）的分季海报欠佳（模糊小图或仅英文版）而系列主海报本身为清晰中日/无字图时，
  /// 自动回退采用清晰主海报，避免低质分季图压过主海报或触发多余的跨源补图请求。
  static ({
    String? posterPath,
    String? fallbackPosterPath,
    bool isSuboptimal,
    bool isLowResOrMissing,
  })
  resolveEffectiveTmdbPoster({
    required TmdbWorkDetail detail,
    TmdbSeasonDetail? seasonDetail,
    int? matchedSeason,
  }) {
    final summary = matchedSeason == null
        ? null
        : detail.seasons
              .where((s) => s.seasonNumber == matchedSeason)
              .firstOrNull;
    final seasonPoster =
        _nonEmpty(seasonDetail?.posterPath) ?? _nonEmpty(summary?.posterPath);
    final seriesPoster = _nonEmpty(detail.posterPath);
    final seasonCandidates =
        (seasonDetail?.candidatePosters.isNotEmpty ?? false)
        ? seasonDetail!.candidatePosters
        : detail.candidatePosters;

    final seasonSuboptimal =
        seasonPoster != null &&
        isTmdbPosterSuboptimal(
          selectedPosterPath: seasonPoster,
          candidatePosters: seasonCandidates,
        );
    final seriesSuboptimal = isTmdbPosterSuboptimal(
      selectedPosterPath: seriesPoster,
      candidatePosters: detail.candidatePosters,
    );

    final useSeriesOverSuboptimalS1 =
        (matchedSeason == null || matchedSeason == 1) &&
        seasonSuboptimal &&
        seriesPoster != null &&
        !seriesSuboptimal;
    if (useSeriesOverSuboptimalS1) {
      return (
        posterPath: seriesPoster,
        fallbackPosterPath: seasonPoster,
        isSuboptimal: false,
        isLowResOrMissing: false,
      );
    }

    final effectivePath = seasonPoster ?? seriesPoster;
    final effectiveCandidates = seasonPoster != null
        ? seasonCandidates
        : detail.candidatePosters;
    return (
      posterPath: effectivePath,
      fallbackPosterPath: seasonPoster != null ? seriesPoster : null,
      isSuboptimal: seasonPoster != null ? seasonSuboptimal : seriesSuboptimal,
      isLowResOrMissing: isTmdbPosterLowResOrMissing(
        selectedPosterPath: effectivePath,
        candidatePosters: effectiveCandidates,
      ),
    );
  }

  /// 从 Fanart.tv 整包海报中挑选用于升级欠佳 TMDB 封面的候选地址。
  ///
  /// - 当 TMDB 缺图或低清糊图（[allowAnyLanguage] 为真）时，允许任意语言的 Fanart `1000×1426` 高清竖图补位；
  /// - 当 TMDB 仅有清晰英文版封面（[allowAnyLanguage] 为假）时，仅在 Fanart 拥有中文、日文或无字竖图时才执行升级；
  /// - 若 [requireExactSeasonMatch] 为真，则仅接受与 [matchedSeason] 严格一致的季海报。
  static String? selectFanartPosterForUpgrade(
    FanartArtworkResult bundle, {
    int? matchedSeason,
    required bool allowAnyLanguage,
    bool requireExactSeasonMatch = false,
  }) {
    if (bundle.posters.isEmpty) return null;
    bool acceptable(FanartPosterCandidate item) =>
        allowAnyLanguage || isCjkOrTextlessPoster(item.lang, null);

    if (matchedSeason != null) {
      for (final item in bundle.posters) {
        if (item.season == matchedSeason && acceptable(item)) {
          return item.url;
        }
      }
      if (requireExactSeasonMatch) return null;
    }
    for (final item in bundle.posters) {
      if (!item.isSeasonPoster && acceptable(item)) {
        return item.url;
      }
    }
    if (allowAnyLanguage) {
      return bundle.posters.first.url;
    }
    return null;
  }

  static String? _nonEmpty(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}
