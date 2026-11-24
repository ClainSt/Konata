import 'package:konata_contracts/konata_contracts.dart';

import 'work.dart';

/// 透明徽标负缓存探测位掩码（标记上次结论已覆盖哪些能力源）。
abstract final class ClearLogoNegativeMask {
  /// 未记录任何负缓存。
  static const int none = 0;

  /// 已探测 TMDB `/images` 透明徽标。
  static const int tmdb = 1 << 0;

  /// 已探测 Fanart.tv 透明徽标（内置中继或自定义项目 Key）。
  static const int fanart = 1 << 1;

  /// 已携带用户 Personal Key（`client-key`）探测 Fanart.tv。
  static const int fanartWithClientKey = 1 << 2;

  /// 已在详情页完成过 TMDB 与 Fanart.tv 透明徽标多源联合择优（避免对仅有英文图的作品反复探测）。
  static const int multiSourceUpgraded = 1 << 3;
}

/// Fanart.tv 图片地址归一化与缩略图预览转换工具（纯领域，零 IO）。
abstract final class FanartUrlHelper {
  /// Fanart.tv 标准竖版海报分辨率宽度（`tvposter` / `seasonposter` / `movieposter`）。
  static const int defaultPosterWidth = 1000;

  /// Fanart.tv 标准竖版海报分辨率高度。
  static const int defaultPosterHeight = 1426;

  /// Fanart.tv 标准无字横版背景分辨率宽度（`showbackground` / `moviebackground`）。
  static const int defaultBackdropWidth = 1920;

  /// Fanart.tv 标准无字横版背景分辨率高度。
  static const int defaultBackdropHeight = 1080;

  /// 规范化 Fanart.tv 返回的图片 URL（统一强制 HTTPS，去除首尾空白）。
  static String normalizeOriginalUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://')) {
      return 'https://${trimmed.substring(7)}';
    }
    return trimmed;
  }

  /// 判断是否为 Fanart.tv 原图或预览图链接。
  static bool isFanartImageUrl(String raw) {
    final lower = raw.trim().toLowerCase();
    return lower.contains('/fanart/') &&
        (lower.contains('assets.fanart.tv') ||
            lower.contains('/tvposter/') ||
            lower.contains('/seasonposter/') ||
            lower.contains('/movieposter/') ||
            lower.contains('/showbackground/') ||
            lower.contains('/moviebackground/') ||
            lower.contains('/hdtvlogo/') ||
            lower.contains('/clearlogo/') ||
            lower.contains('/hdmovielogo/') ||
            lower.contains('/movielogo/'));
  }

  /// 将 Fanart.tv 原图链接中的首个 `/fanart/` 替换为 `/preview/`，用于弹窗网格轻量预览。
  static String toPreviewUrl(String raw) {
    final normalized = normalizeOriginalUrl(raw);
    if (normalized.isEmpty) return '';
    final uri = Uri.tryParse(normalized);
    if (uri == null) return normalized;
    if (uri.path.startsWith('/preview/')) return normalized;
    final idx = uri.path.indexOf('/fanart/');
    if (idx < 0) return normalized;
    final previewPath = uri.path.replaceFirst('/fanart/', '/preview/');
    return uri.replace(path: previewPath).toString();
  }

  /// 将预览链接还原为原图 `/fanart/` 链接，确保存库与应用永远拉取原图。
  static String toOriginalUrl(String raw) {
    final normalized = normalizeOriginalUrl(raw);
    if (normalized.isEmpty) return '';
    final uri = Uri.tryParse(normalized);
    if (uri == null) return normalized;
    final idx = uri.path.indexOf('/preview/');
    if (idx < 0) return normalized;
    final origPath = uri.path.replaceFirst('/preview/', '/fanart/');
    return uri.replace(path: origPath).toString();
  }
}

/// Fanart.tv 透明标题徽标分类档位。
enum FanartLogoKind {
  /// 高清剧集透明徽标（`hdtvlogo`，通常为 `800×310`）。
  hdTvLogo('hdtvlogo', 2),

  /// 标清剧集透明徽标（`clearlogo`，通常为 `400×155`）。
  clearLogo('clearlogo', 1),

  /// 高清电影透明徽标（`hdmovielogo`，通常为 `800×310`）。
  hdMovieLogo('hdmovielogo', 2),

  /// 标清电影透明徽标（`movielogo`，通常为 `400×155`）。
  movieLogo('movielogo', 1);

  const FanartLogoKind(this.jsonKey, this.qualityRank);

  /// Fanart.tv v3 响应体中的数组字段键名。
  final String jsonKey;

  /// 画质排序权重（高清优先于标清）。
  final int qualityRank;

  /// 是否为高清透明徽标。
  bool get isHd => qualityRank >= 2;
}

/// Fanart.tv 单张透明标题徽标候选条目。
class FanartLogoCandidate {
  /// 创建 Fanart.tv 透明徽标候选。
  const FanartLogoCandidate({
    required this.id,
    required this.url,
    required this.kind,
    this.lang,
    this.likes = 0,
  });

  /// Fanart.tv 资产唯一标识。
  final String id;

  /// 原始 HTTPS 透明 PNG 地址（通常位于 `assets.fanart.tv`）。
  final String url;

  /// 资产清晰度与媒体分类档位。
  final FanartLogoKind kind;

  /// 语言代码（如 `zh`、`ja`、`en`、`00` 或空）。
  final String? lang;

  /// 社区点赞数（用于同语言同画质内择优）。
  final int likes;
}

/// Fanart.tv 单张竖版海报候选条目（`tvposter` / `movieposter` / `seasonposter`）。
class FanartPosterCandidate {
  /// 创建 Fanart.tv 竖版海报候选。
  const FanartPosterCandidate({
    required this.id,
    required this.url,
    this.lang,
    this.likes = 0,
    this.season,
  });

  /// Fanart.tv 资产唯一标识。
  final String id;

  /// 原图 HTTPS 地址（`1000×1426`）。
  final String url;

  /// 语言代码（如 `zh`、`ja`、`en`、`00` 或空）。
  final String? lang;

  /// 社区点赞数。
  final int likes;

  /// 季号（`seasonposter` 时非空：`0` 表示特别篇、`>0` 表示第 N 季；主海报与电影海报为 `null`）。
  final int? season;

  /// 是否属于单季专属海报。
  bool get isSeasonPoster => season != null;

  /// 网格缩略图预览地址（将 `/fanart/` 替换为 `/preview/`）。
  String get previewUrl => FanartUrlHelper.toPreviewUrl(url);

  /// 固定规范像素宽度。
  int get width => FanartUrlHelper.defaultPosterWidth;

  /// 固定规范像素高度。
  int get height => FanartUrlHelper.defaultPosterHeight;

  /// 对齐 `TMDB·S1` / `TMDB·SP` 样式的来源角标文案。
  String get sourceLabel {
    final s = season;
    if (s == null) return 'Fanart.tv';
    if (s == 0) return 'Fanart.tv·SP';
    return 'Fanart.tv·S$s';
  }
}

/// Fanart.tv 单张无字横版背景图候选条目（仅 `showbackground` / `moviebackground`，严禁含文字缩略图）。
class FanartBackgroundCandidate {
  /// 创建 Fanart.tv 无字背景图候选。
  const FanartBackgroundCandidate({
    required this.id,
    required this.url,
    this.likes = 0,
  });

  /// Fanart.tv 资产唯一标识。
  final String id;

  /// 原图 HTTPS 地址（`1920×1080` 无字横图）。
  final String url;

  /// 社区点赞数。
  final int likes;

  /// 网格缩略图预览地址（将 `/fanart/` 替换为 `/preview/`）。
  String get previewUrl => FanartUrlHelper.toPreviewUrl(url);

  /// 固定规范像素宽度。
  int get width => FanartUrlHelper.defaultBackdropWidth;

  /// 固定规范像素高度。
  int get height => FanartUrlHelper.defaultBackdropHeight;
}

/// 单次 Fanart.tv 整包艺术图拉取结果（一次上游请求同时覆盖徽标、封面与无字背景图）。
class FanartArtworkResult {
  /// 创建整包结果。
  const FanartArtworkResult({
    this.logos = const [],
    this.posters = const [],
    this.backgrounds = const [],
    this.notFound = false,
    this.authRejected = false,
  });

  /// 已按语言、高清档位与点赞数排序的透明徽标候选集。
  final List<FanartLogoCandidate> logos;

  /// 已排序的竖版海报候选集（含主海报与分季海报）。
  final List<FanartPosterCandidate> posters;

  /// 已按社区点赞数降序排列的无字 `1920×1080` 横版背景图候选集。
  final List<FanartBackgroundCandidate> backgrounds;

  /// 上游明确返回 404（条目在 Fanart.tv 尚无建档）。
  final bool notFound;

  /// 上游返回 401/403/429/503（用于触发内置通道短时熔断）。
  final bool authRejected;

  /// 排序第一的最优透明徽标地址。
  String? get bestLogoUrl => logos.isEmpty ? null : logos.first.url;

  /// 排序第一的最高赞无字 `1080p` 横版背景图地址。
  String? get bestBackgroundUrl =>
      backgrounds.isEmpty ? null : backgrounds.first.url;

  /// 为指定季号挑选最优竖版封面（命中该季 `seasonposter` 优先，其次通用主海报）。
  String? bestPosterUrlForSeason(int? matchedSeason) {
    if (posters.isEmpty) return null;
    if (matchedSeason != null) {
      for (final p in posters) {
        if (p.season == matchedSeason) {
          return p.url;
        }
      }
    }
    for (final p in posters) {
      if (!p.isSeasonPoster) {
        return p.url;
      }
    }
    return posters.first.url;
  }
}

/// 多源透明徽标候选来源枚举。
enum LogoSourceKind {
  /// TMDB 透明标题徽标。
  tmdb,

  /// Fanart.tv 透明标题徽标。
  fanart,
}

/// 参与 TMDB / Fanart.tv 跨源统一排序的透明徽标候选实体。
class RankedLogoCandidate {
  /// 创建跨源徽标候选。
  const RankedLogoCandidate({
    required this.filePath,
    required this.source,
    this.isoLanguage,
    this.isoCountry,
    required this.isHd,
    this.width,
    this.height,
    this.likes = 0,
    this.voteAverage = 0.0,
    this.voteCount = 0,
    this.targetSeason,
  });

  /// 图片路径（TMDB 相对路径或 Fanart.tv HTTPS 地址）。
  final String filePath;

  /// 来源平台。
  final LogoSourceKind source;

  /// ISO 639-1 语言代码（如 `zh`、`ja`、`en`、`00`）。
  final String? isoLanguage;

  /// ISO 3166-1 地区代码（用于区分 `zh-CN` 与 `zh-TW/HK`）。
  final String? isoCountry;

  /// 是否属于高清透明徽标档位。
  final bool isHd;

  /// 已知像素宽度。
  final int? width;

  /// 已知像素高度。
  final int? height;

  /// Fanart.tv 点赞数。
  final int likes;

  /// TMDB 评分均分。
  final double voteAverage;

  /// TMDB 评分人数。
  final int voteCount;

  /// 该透明徽标已知明确归属的季号（如第 2 季副标题徽标为 `2`；系列通用徽标为 `null`）。
  final int? targetSeason;
}

/// TMDB 与 Fanart.tv 透明徽标跨源统一排序器（自动选图与「编辑标题徽标」弹窗唯一复用）。
///
/// 排序规则（严格字典序）：
/// 1. 季号冲突防错位：当目标季号明确且候选已知归属于其他季（如第 2 季副标题徽标用于第 1 季）时沉底避让；
/// 2. 语言权重：`简中 (0) < 繁中 (1) < 日文 (2) < 英文 (3) < 无语言 (4) < 其他 (5)`；
/// 3. 同语种内优先精确命中当前季的专属徽标；
/// 4. 清晰度档位：高清（Fanart `hdtvlogo`/`hdmovielogo` 或 TMDB 宽度 ≥ 700px）优先于标清；
/// 5. 格式与地区加权：PNG 优先、显式 `zh-CN/SG` 优先于未标注地区的中文；
/// 6. 社区认可度：TMDB 采用贝叶斯平滑评分消除 1 票虚高偏差，Fanart.tv 按点赞数择优。
abstract final class ClearLogoRanker {
  /// 判定 TMDB 透明徽标是否为高清档位的最小像素宽度阈值。
  static const int tmdbHdMinWidth = 700;

  /// TMDB 徽标贝叶斯平滑评分先验参数（与背景图/封面图排序引擎保持同源）。
  static const double _bayesianPriorMean = 5.0;
  static const double _bayesianPriorWeight = 3.0;

  /// 《魔具少女！》分季透明标题纠偏项：区分第 1 季（`マケン姫っ!`）与第 2 季（`マケン姫っ! 通`）。
  static const Map<String, int> _makenKiSeasonLogos = {
    '145609': 2,
    'maken-ki-battling-venus-621c4c6a4c46c.png': 2,
    '59138': 1,
    'maken-ki-5678d8daa917e.png': 1,
    '14777': 1,
    'maken-ki-4ee2c66ca3f34.png': 1,
  };

  /// 按 TMDB TV ID 索引的已知分季透明徽标映射（弥补上游徽标接口无 `season` 字段的局限）。
  ///
  /// 值为 `{徽标标识(TMDB file_path / Fanart id / Fanart 文件名): 所属季号}`。
  static const Map<int, Map<String, int>> tmdbSeasonScopedTvLogos = {
    // 《魔具少女！》TMDB TV 60732（对应 Fanart TVDB 252474）
    60732: _makenKiSeasonLogos,
  };

  /// 按 TheTVDB ID 索引的已知分季 Fanart.tv 透明徽标映射（覆盖仅持 `tvdbId` 的补全通路）。
  static const Map<int, Map<String, int>> tvdbSeasonScopedLogos = {
    // 《魔具少女！》TVDB 252474
    252474: _makenKiSeasonLogos,
  };

  /// 解析候选透明徽标已知归属的季号（无记录或电影条目返回 `null`）。
  static int? resolveKnownTargetSeason({
    required String filePath,
    String? candidateId,
    int? tmdbId,
    int? tvdbId,
    TmdbMediaType? mediaType,
  }) {
    if (mediaType == TmdbMediaType.movie) return null;
    final cleanPath = filePath.trim();
    if (cleanPath.isEmpty) return null;

    final lookupKeys = <String>[
      if (candidateId != null && candidateId.trim().isNotEmpty)
        candidateId.trim().toLowerCase(),
      cleanPath.toLowerCase(),
      _extractFileBasenameLower(cleanPath),
    ];

    int? lookupIn(Map<String, int>? table) {
      if (table == null || table.isEmpty) return null;
      for (final key in lookupKeys) {
        if (key.isEmpty) continue;
        final hit = table[key];
        if (hit != null) return hit;
      }
      return null;
    }

    if (tmdbId != null && tmdbId > 0) {
      final byTmdb = lookupIn(tmdbSeasonScopedTvLogos[tmdbId]);
      if (byTmdb != null) return byTmdb;
    }
    if (tvdbId != null && tvdbId > 0) {
      final byTvdb = lookupIn(tvdbSeasonScopedLogos[tvdbId]);
      if (byTvdb != null) return byTvdb;
    }
    return null;
  }

  /// 判断当前作品已落盘的透明徽标是否明确属于同剧集的其他季（用于详情页自动纠偏自愈）。
  static bool isKnownSeasonMismatchLogo({
    required String? filePath,
    required int? matchedSeason,
    int? tmdbId,
    int? tvdbId,
    TmdbMediaType? mediaType,
  }) {
    if (matchedSeason == null || filePath == null || filePath.trim().isEmpty) {
      return false;
    }
    final targetSeason = resolveKnownTargetSeason(
      filePath: filePath,
      tmdbId: tmdbId,
      tvdbId: tvdbId,
      mediaType: mediaType,
    );
    return targetSeason != null && targetSeason != matchedSeason;
  }

  /// 计算 TMDB 透明徽标的贝叶斯平滑热度分（无票条目返回 `0.0`，避免压过带赞 Fanart 徽标）。
  static double bayesianTmdbVoteScore(double voteAverage, int voteCount) {
    if (voteAverage <= 0) return 0.0;
    final effectiveCount = voteCount > 0 ? voteCount : 1;
    return (effectiveCount * voteAverage +
            _bayesianPriorWeight * _bayesianPriorMean) /
        (effectiveCount + _bayesianPriorWeight);
  }

  /// 计算语言优先级（0:简中, 1:繁中, 2:日文, 3:英文, 4:无语言, 5:其他）。
  static int languageRank(String? isoLanguage, [String? isoCountry]) {
    final lang = (isoLanguage ?? '').trim().toLowerCase();
    final country = (isoCountry ?? '').trim().toUpperCase();
    if (lang == 'zh' || lang == 'cn') {
      if (country == 'TW' || country == 'HK' || country == 'MO') {
        return 1;
      }
      return 0;
    }
    if (lang == 'ja' || lang == 'jp') return 2;
    if (lang == 'en') return 3;
    if (lang.isEmpty || lang == 'null' || lang == 'xx' || lang == '00') {
      return 4;
    }
    return 5;
  }

  /// 判断候选是否已达到最高梯队（简中/繁中/日文高清），满足时无需再做跨源升级探测。
  static bool isPreferredCjkHd(RankedLogoCandidate candidate) {
    final rank = languageRank(candidate.isoLanguage, candidate.isoCountry);
    return rank <= 2 && candidate.isHd;
  }

  /// 比较两个跨源透明徽标候选的优劣（返回负值表示 `a` 更优）。
  static int compare(
    RankedLogoCandidate a,
    RankedLogoCandidate b, {
    int? matchedSeason,
  }) {
    if (matchedSeason != null) {
      final aMismatch =
          (a.targetSeason != null && a.targetSeason != matchedSeason) ? 1 : 0;
      final bMismatch =
          (b.targetSeason != null && b.targetSeason != matchedSeason) ? 1 : 0;
      if (aMismatch != bMismatch) return aMismatch.compareTo(bMismatch);
    }

    final langCmp = languageRank(a.isoLanguage, a.isoCountry).compareTo(
      languageRank(b.isoLanguage, b.isoCountry),
    );
    if (langCmp != 0) return langCmp;

    if (matchedSeason != null) {
      final aExact = a.targetSeason == matchedSeason ? 0 : 1;
      final bExact = b.targetSeason == matchedSeason ? 0 : 1;
      if (aExact != bExact) return aExact.compareTo(bExact);
    }

    final hdCmp = (b.isHd ? 1 : 0).compareTo(a.isHd ? 1 : 0);
    if (hdCmp != 0) return hdCmp;

    final aPng = a.filePath.toLowerCase().endsWith('.png') ? 1 : 0;
    final bPng = b.filePath.toLowerCase().endsWith('.png') ? 1 : 0;
    if (aPng != bPng) return bPng.compareTo(aPng);

    if (languageRank(a.isoLanguage, a.isoCountry) == 0) {
      final aCn = _isExplicitSimplified(a.isoCountry) ? 1 : 0;
      final bCn = _isExplicitSimplified(b.isoCountry) ? 1 : 0;
      if (aCn != bCn) return bCn.compareTo(aCn);
    }

    final scoreDiff = _popularityScore(b) - _popularityScore(a);
    if (scoreDiff.abs() > 1e-6) {
      return scoreDiff > 0 ? 1 : -1;
    }

    // 语言、高清档位与热度均持平时，优先像素宽度更大者，再优先 Fanart.tv 人工审核徽标。
    final widthCmp = (b.width ?? 0).compareTo(a.width ?? 0);
    if (widthCmp != 0) return widthCmp;
    return (b.source == LogoSourceKind.fanart ? 1 : 0).compareTo(
      a.source == LogoSourceKind.fanart ? 1 : 0,
    );
  }

  /// 对跨源候选列表按统一规则排序并返回去重后的不可变列表。
  static List<RankedLogoCandidate> sortMerged(
    Iterable<RankedLogoCandidate> candidates, {
    int? matchedSeason,
  }) {
    final seen = <String>{};
    final list = <RankedLogoCandidate>[];
    for (final c in candidates) {
      final key = c.filePath.trim();
      if (key.isEmpty || !seen.add(key)) continue;
      list.add(c);
    }
    list.sort((a, b) => compare(a, b, matchedSeason: matchedSeason));
    return List<RankedLogoCandidate>.unmodifiable(list);
  }

  /// 判断 TMDB 候选像素尺寸是否达到高清徽标档位。
  static bool isTmdbLogoHd(int? width) {
    if (width == null || width <= 0) return true;
    return width >= tmdbHdMinWidth;
  }

  static bool _isExplicitSimplified(String? isoCountry) {
    final c = (isoCountry ?? '').trim().toUpperCase();
    return c == 'CN' || c == 'SG';
  }

  static String _extractFileBasenameLower(String rawPath) {
    final noQuery = rawPath.split('?').first.split('#').first;
    final slash = noQuery.lastIndexOf('/');
    final base = slash >= 0 ? noQuery.substring(slash + 1) : noQuery;
    return base.trim().toLowerCase();
  }

  static double _popularityScore(RankedLogoCandidate c) {
    if (c.source == LogoSourceKind.fanart) {
      return c.likes.toDouble() + (c.likes > 0 ? 1.0 : 0.0);
    }
    final smoothed = bayesianTmdbVoteScore(c.voteAverage, c.voteCount);
    if (smoothed <= 0) return 0.0;
    return smoothed + (c.voteCount > 0 ? 0.5 : 0.0);
  }
}
