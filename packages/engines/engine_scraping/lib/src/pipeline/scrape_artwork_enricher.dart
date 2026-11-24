import 'dart:developer' as developer;

import 'package:konata_contracts/konata_contracts.dart';

import '../matching/directory_grouper.dart';
import '../models/fanart_models.dart';
import '../models/tmdb_models.dart';
import '../network/fanart_service.dart';
import '../scraping/artwork_ranker.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/bangumi_tmdb_index.dart';
import '../scraping/work_matcher.dart' as legacy;
import '../scraping/work_wall_eligibility.dart';
import 'clear_logo_resolver.dart';

/// 剧集 `tvdbId` 解析来源分类（供评测诊断 Fanart.tv 剧集命中率瓶颈）。
enum TvdbIdSource {
  /// 来自 TMDB 详情附带的 `external_ids.tvdb_id`。
  tmdbExternalIds,

  /// 来自 Bangumi ↔ TMDB v2 离线二进制映射表。
  offlineMappingV2,

  /// 未解析到可用 `tvdbId`（或电影条目无需 `tvdbId`）。
  missing,
}

/// TMDB 优胜绑定条目与 Fanart.tv 整包艺术图协同富化结果（无库副作用）。
class TmdbFanartEnrichOutcome {
  /// 创建富化结果。
  const TmdbFanartEnrichOutcome({
    this.tvdbId,
    this.tvdbIdSource = TvdbIdSource.missing,
    this.posterFallback,
    this.posterOverride,
    this.backdropOverride,
    this.logoOverride,
    this.logoNegativeMask = 0,
    this.selectedLogo,
    this.tmdbTopLogo,
    this.needsPosterFallback = false,
    this.posterSuboptimal = false,
    this.backdropSuboptimal = false,
    this.fanartQueried = false,
    this.fanartAuthRejected = false,
    this.logoUpgradedByFanart = false,
    this.backdropUpgradedByFanart = false,
    this.posterFilledByFanart = false,
  });

  /// 解析后的 TheTVDB ID。
  final int? tvdbId;

  /// `tvdbId` 供给来源。
  final TvdbIdSource tvdbIdSource;

  /// TMDB 与 Bangumi 均缺封面时从 Fanart 整包选出的竖版封面（匹配季优先）。
  final String? posterFallback;

  /// TMDB 封面模糊（`< 680px`）或仅有欧美英文版时由 Fanart 整包升级的高清中日/无字竖版封面。
  final String? posterOverride;

  /// TMDB 背景图缺失、低清、带字、非标零头分辨率或低票疑似截帧时由 Fanart 整包升级的无字 1080p 横图。
  final String? backdropOverride;

  /// 跨源排序后应覆写至作品的透明徽标路径（`null` 表示沿用 TMDB 原值）。
  final String? logoOverride;

  /// 应写入作品的透明徽标负缓存与跨源升级位掩码。
  final int logoNegativeMask;

  /// 最终入选的最优透明徽标明细（含来源、语言与高清档位）。
  final RankedLogoCandidate? selectedLogo;

  /// TMDB 单源排名第一的透明徽标明细（用于计算 Fanart 跨源升级率）。
  final RankedLogoCandidate? tmdbTopLogo;

  /// 本条目是否处于缺封面待补状态。
  final bool needsPosterFallback;

  /// 本条目 TMDB 封面是否被判定为欠佳（低清模糊、异常比例或非中日无字英文封面）。
  final bool posterSuboptimal;

  /// 本条目 TMDB 背景图是否被判定为欠佳（缺图、低于 1080p、带字、非标尺寸或低票截帧）。
  final bool backdropSuboptimal;

  /// 本次富化是否实际发起了 Fanart 整包查询。
  final bool fanartQueried;

  /// Fanart 通道本次是否返回鉴权拒绝或触发中继熔断。
  final bool fanartAuthRejected;

  /// 最终透明徽标是否由 Fanart.tv 胜出（替代了 TMDB 缺失、英文或标清徽标）。
  final bool logoUpgradedByFanart;

  /// 最终背景图是否成功由 Fanart.tv 无字 1080p 横图升级。
  final bool backdropUpgradedByFanart;

  /// 最终封面是否成功由 Fanart.tv 竖版海报补齐。
  final bool posterFilledByFanart;
}

/// 通路 B（无 TMDB、仅命中 Bangumi）的 Fanart 补全与独立上墙判定结果。
class BangumiOnlyWallOutcome {
  /// 创建通路 B 判定结果。
  const BangumiOnlyWallOutcome({
    required this.canPromote,
    this.tvdbId,
    this.tvdbIdSource = TvdbIdSource.missing,
    this.fanartPoster,
    this.fanartBackdrop,
    this.fanartLogo,
    this.fanartTopLogo,
    this.effectiveCover,
    this.coverSource = 'none',
    this.fanartQueried = false,
  });

  /// 是否满足独立上墙资格。
  final bool canPromote;

  /// 离线映射表查得的 TheTVDB ID。
  final int? tvdbId;

  /// `tvdbId` 来源。
  final TvdbIdSource tvdbIdSource;

  /// Fanart 整包提供的竖版封面。
  final String? fanartPoster;

  /// Fanart 整包提供的无字 1080p 横图。
  final String? fanartBackdrop;

  /// Fanart 整包提供的最优透明徽标地址。
  final String? fanartLogo;

  /// Fanart 最优透明徽标明细。
  final RankedLogoCandidate? fanartTopLogo;

  /// 最终用于上墙资格校验的有效封面路径。
  final String? effectiveCover;

  /// 有效封面来源（`bangumi` / `fanart` / `local` / `none`）。
  final String coverSource;

  /// 本次是否触发了 Fanart 整包请求。
  final bool fanartQueried;
}

/// 通路 C / D（无 TMDB 与 Bangumi 主匹配）的 Fanart / 本地封面独立上墙判定结果。
class CoverFallbackWallOutcome {
  /// 创建通路 C / D 判定结果。
  const CoverFallbackWallOutcome({
    required this.canPromote,
    this.tvdbId,
    this.tvdbIdSource = TvdbIdSource.missing,
    this.posterPath,
    this.backdropPath,
    this.logoPath,
    this.fanartTopLogo,
    this.coverSource = 'none',
    this.fanartQueried = false,
  });

  /// 是否满足封面兜底独立上墙资格。
  final bool canPromote;

  /// 解析到的 TheTVDB ID。
  final int? tvdbId;

  /// `tvdbId` 来源。
  final TvdbIdSource tvdbIdSource;

  /// 选中的兜底封面路径（Fanart 优先，其次本地磁盘封面）。
  final String? posterPath;

  /// Fanart 提供的无字横图。
  final String? backdropPath;

  /// Fanart 提供的透明徽标地址。
  final String? logoPath;

  /// Fanart 最优透明徽标明细。
  final RankedLogoCandidate? fanartTopLogo;

  /// 封面来源（`fanart` / `local` / `none`）。
  final String coverSource;

  /// 本次是否触发了 Fanart 整包请求。
  final bool fanartQueried;
}

/// 无数据库依赖的刮削艺术图协同富化与四通道上墙判定器（生产调度器与离线/在线评测唯一复用）。
class ScrapeArtworkEnricher {
  /// 创建艺术图协同富化器。
  const ScrapeArtworkEnricher({
    this._fanartService,
    this._mappingIndex,
  });

  final FanartService? _fanartService;
  final BangumiTmdbIndex? _mappingIndex;

  /// 从离线映射表查询关联的 TheTVDB 剧集 ID（优先按 `bangumiId` 命中，其次按 TMDB TV ID 反查）。
  static int? lookupOfflineTvdbId({
    BangumiTmdbIndex? mappingIndex,
    int? bangumiId,
    int? tmdbId,
    TmdbMediaType? mediaType,
  }) {
    final index = mappingIndex;
    if (index == null || index.isEmpty) return null;
    if (bangumiId != null && bangumiId > 0) {
      for (final target in index.lookup(bangumiId)) {
        if (target.tvdbId != null && target.tvdbId! > 0) {
          if (tmdbId == null || target.id == tmdbId) {
            return target.tvdbId;
          }
        }
      }
    }
    if (tmdbId != null &&
        tmdbId > 0 &&
        (mediaType == null || mediaType == TmdbMediaType.tv)) {
      return index.lookupTvdbIdByTmdb(
        mediaType: TmdbMediaType.tv,
        tmdbId: tmdbId,
      );
    }
    return null;
  }

  /// 安全拉取 Fanart.tv 整包艺术图（遇异常静默降级返回 `null`，绝不阻断刮削主流程）。
  Future<FanartArtworkResult?> fetchFanartBundleIfAvailable({
    required TmdbMediaType mediaType,
    int? tmdbId,
    int? tvdbId,
    required RequestPriority priority,
    bool forceRefresh = false,
  }) async {
    final fanart = _fanartService;
    if (fanart == null || !fanart.isConfigured) return null;
    try {
      return await fanart.fetchArtworkBundle(
        mediaType: mediaType,
        tmdbId: tmdbId,
        tvdbId: tvdbId,
        priority: priority,
        bypassCircuitBreaker: forceRefresh,
        forceRefresh: forceRefresh,
      );
    } catch (error) {
      developer.log(
        '拉取 Fanart.tv 整包艺术图失败，继续走降级流程',
        name: 'konata.scrape_artwork_enricher',
        error: error,
      );
      return null;
    }
  }

  /// 通路 A：对已绑定的 TMDB 优胜条目执行 Fanart 整包艺术图协同富化（封面兜底、无字 1080p 背景升级、透明徽标跨源排序）。
  ///
  /// [upgradeNonZhCnLogo] 为 `true` 时（对应交互重抓或详情页完整补全模拟），只要 TMDB 缺少简中高清徽标即触发 Fanart 跨源择优；
  /// 为 `false` 时（对应后台批量入库）仅在缺封面或背景图欠佳时按需触发 Fanart，顺带完成徽标联合排序。
  Future<TmdbFanartEnrichOutcome> enrichTmdbDetail({
    required TmdbWorkDetail detail,
    required TmdbSeasonDetail? seasonDetail,
    required int? matchedSeason,
    required ScoredBangumiCandidate? bangumiCandidate,
    required RequestPriority priority,
    bool? upgradeNonZhCnLogo,
    bool forceRefresh = false,
  }) async {
    final offlineTvdbId = detail.tvdbId != null
        ? null
        : lookupOfflineTvdbId(
            mappingIndex: _mappingIndex,
            bangumiId: bangumiCandidate?.subject.id,
            tmdbId: detail.tmdbId,
            mediaType: detail.mediaType,
          );
    final resolvedTvdbId = detail.tvdbId ?? offlineTvdbId;
    final tvdbSource = detail.tvdbId != null
        ? TvdbIdSource.tmdbExternalIds
        : (offlineTvdbId != null
              ? TvdbIdSource.offlineMappingV2
              : TvdbIdSource.missing);

    final effectivePoster = ArtworkRanker.resolveEffectiveTmdbPoster(
      detail: detail,
      seasonDetail: seasonDetail,
      matchedSeason: matchedSeason,
    );
    final bgmPoster = _nonEmpty(bangumiCandidate?.subject.posterUrl);
    final needsPosterFallback =
        effectivePoster.posterPath == null && bgmPoster == null;
    final posterSuboptimal =
        !needsPosterFallback && effectivePoster.isSuboptimal;
    // 若 Bangumi 已提供官方封面，展示层会自动优先用 Bangumi 替代欠佳 TMDB 封面，无需为此额外消耗 Fanart 配额。
    final posterNeedsFanartUpgrade = posterSuboptimal && bgmPoster == null;
    final posterLowResOrMissing = effectivePoster.isLowResOrMissing;
    final backdropSuboptimal = WorkWallEligibility.isTmdbBackdropSuboptimal(
      selectedBackdropPath: detail.backdropPath,
      candidateBackdrops: detail.candidateBackdrops,
    );
    final tmdbRankedLogos = ClearLogoResolver.toRankedTmdbLogos(
      detail.candidateLogos,
      tmdbId: detail.tmdbId,
      tvdbId: resolvedTvdbId,
      mediaType: detail.mediaType,
      matchedSeason: matchedSeason,
    );
    final tmdbTopLogo = tmdbRankedLogos.isNotEmpty
        ? tmdbRankedLogos.first
        : (_nonEmpty(detail.logoPath) != null
              ? RankedLogoCandidate(
                  filePath: detail.logoPath!.trim(),
                  source: LogoSourceKind.tmdb,
                  isHd: true,
                  targetSeason: ClearLogoRanker.resolveKnownTargetSeason(
                    filePath: detail.logoPath!.trim(),
                    tmdbId: detail.tmdbId,
                    tvdbId: resolvedTvdbId,
                    mediaType: detail.mediaType,
                  ),
                )
              : null);
    final topTmdbLogoMismatch =
        tmdbRankedLogos.isNotEmpty &&
        matchedSeason != null &&
        tmdbRankedLogos.first.targetSeason != null &&
        tmdbRankedLogos.first.targetSeason != matchedSeason;
    final hasTopZhCnLogo =
        tmdbRankedLogos.isNotEmpty &&
        !topTmdbLogoMismatch &&
        ClearLogoRanker.languageRank(
              tmdbRankedLogos.first.isoLanguage,
              tmdbRankedLogos.first.isoCountry,
            ) ==
            0 &&
        tmdbRankedLogos.first.isHd;

    final allowLogoUpgrade =
        upgradeNonZhCnLogo ?? (priority == RequestPriority.interactive);
    final hasFanartKeyId = detail.mediaType == TmdbMediaType.movie
        ? detail.tmdbId > 0
        : (resolvedTvdbId != null && resolvedTvdbId > 0);
    final shouldQueryFanart =
        _fanartService != null &&
        _fanartService.isConfigured &&
        hasFanartKeyId &&
        (needsPosterFallback ||
            posterNeedsFanartUpgrade ||
            backdropSuboptimal ||
            (allowLogoUpgrade && !hasTopZhCnLogo));

    if (!shouldQueryFanart) {
      return TmdbFanartEnrichOutcome(
        tvdbId: resolvedTvdbId,
        tvdbIdSource: tvdbSource,
        selectedLogo: tmdbTopLogo,
        tmdbTopLogo: tmdbTopLogo,
        needsPosterFallback: needsPosterFallback,
        posterSuboptimal: posterSuboptimal,
        backdropSuboptimal: backdropSuboptimal,
      );
    }

    final bundle = await fetchFanartBundleIfAvailable(
      mediaType: detail.mediaType,
      tmdbId: detail.tmdbId,
      tvdbId: resolvedTvdbId,
      priority: priority,
      forceRefresh: forceRefresh,
    );
    if (bundle == null || bundle.authRejected) {
      return TmdbFanartEnrichOutcome(
        tvdbId: resolvedTvdbId,
        tvdbIdSource: tvdbSource,
        selectedLogo: tmdbTopLogo,
        tmdbTopLogo: tmdbTopLogo,
        needsPosterFallback: needsPosterFallback,
        posterSuboptimal: posterSuboptimal,
        backdropSuboptimal: backdropSuboptimal,
        fanartQueried: true,
        fanartAuthRejected: bundle?.authRejected ?? false,
      );
    }

    final posterFallback = needsPosterFallback
        ? bundle.bestPosterUrlForSeason(matchedSeason)
        : null;
    final String? posterOverride = posterNeedsFanartUpgrade
        ? ArtworkRanker.selectFanartPosterForUpgrade(
            bundle,
            matchedSeason: matchedSeason,
            allowAnyLanguage: posterLowResOrMissing,
          )
        : null;
    final backdropOverride = backdropSuboptimal
        ? bundle.bestBackgroundUrl
        : null;

    String? logoOverride;
    RankedLogoCandidate? selectedLogo = tmdbTopLogo;
    var nextMask = 0;
    if (bundle.logos.isNotEmpty || tmdbRankedLogos.isNotEmpty) {
      final merged = ClearLogoResolver.mergeAndRankLogos(
        tmdbLogos: detail.candidateLogos,
        fanartLogos: bundle.logos,
        tmdbId: detail.tmdbId,
        tvdbId: resolvedTvdbId,
        mediaType: detail.mediaType,
        matchedSeason: matchedSeason,
      );
      if (merged.isNotEmpty) {
        selectedLogo = merged.first;
        logoOverride = merged.first.filePath;
        if (logoOverride.startsWith('/')) {
          nextMask =
              ClearLogoNegativeMask.tmdb |
              ClearLogoNegativeMask.fanart |
              ClearLogoNegativeMask.multiSourceUpgraded;
        }
      }
    }

    final logoUpgraded =
        selectedLogo != null &&
        selectedLogo.source == LogoSourceKind.fanart &&
        (tmdbTopLogo == null || tmdbTopLogo.filePath != selectedLogo.filePath);

    return TmdbFanartEnrichOutcome(
      tvdbId: resolvedTvdbId,
      tvdbIdSource: tvdbSource,
      posterFallback: posterFallback,
      posterOverride: posterOverride,
      backdropOverride: backdropOverride,
      logoOverride: logoOverride,
      logoNegativeMask: nextMask,
      selectedLogo: selectedLogo,
      tmdbTopLogo: tmdbTopLogo,
      needsPosterFallback: needsPosterFallback,
      posterSuboptimal: posterSuboptimal,
      backdropSuboptimal: backdropSuboptimal,
      fanartQueried: true,
      logoUpgradedByFanart: logoUpgraded,
      backdropUpgradedByFanart: _nonEmpty(backdropOverride) != null,
      posterFilledByFanart:
          _nonEmpty(posterOverride) != null ||
          _nonEmpty(posterFallback) != null,
    );
  }

  /// 通路 B：评估无 TMDB 匹配、仅命中 Bangumi 的独立上墙资格与 Fanart 整包补全结果。
  Future<BangumiOnlyWallOutcome> evaluateBangumiOnly({
    required GroupedWorkFolder folder,
    required ScoredBangumiCandidate bangumiCandidate,
    required legacy.MatchTier bangumiTier,
    RequestPriority priority = RequestPriority.background,
  }) async {
    final offlineTvdbId = lookupOfflineTvdbId(
      mappingIndex: _mappingIndex,
      bangumiId: bangumiCandidate.subject.id,
    );
    final tvdbSource = offlineTvdbId != null
        ? TvdbIdSource.offlineMappingV2
        : TvdbIdSource.missing;

    FanartArtworkResult? fanartBundle;
    var queried = false;
    if (offlineTvdbId != null &&
        _fanartService != null &&
        _fanartService.isConfigured) {
      queried = true;
      fanartBundle = await fetchFanartBundleIfAvailable(
        mediaType: TmdbMediaType.tv,
        tvdbId: offlineTvdbId,
        priority: priority,
      );
    }

    final fanartPoster = fanartBundle?.bestPosterUrlForSeason(folder.seasonHint);
    final fanartBackdrop = fanartBundle?.bestBackgroundUrl;
    final rankedFanartLogos = ClearLogoResolver.toRankedFanartLogos(
      fanartBundle?.logos ?? const [],
      tmdbId: folder.explicitTmdbId,
      tvdbId: offlineTvdbId,
      mediaType: TmdbMediaType.tv,
      matchedSeason: folder.seasonHint,
    );
    final fanartLogo = rankedFanartLogos.isEmpty
        ? fanartBundle?.bestLogoUrl
        : rankedFanartLogos.first.filePath;

    final bgmCover = _nonEmpty(bangumiCandidate.subject.posterUrl);
    final cleanFanartPoster = _nonEmpty(fanartPoster);
    final cleanLocalCover = _nonEmpty(folder.localPosterPath);
    final effectiveCover = bgmCover ?? cleanFanartPoster ?? cleanLocalCover;
    final coverSource = bgmCover != null
        ? 'bangumi'
        : (cleanFanartPoster != null
              ? 'fanart'
              : (cleanLocalCover != null ? 'local' : 'none'));

    final canPromote = WorkWallEligibility.shouldPromoteBangumiOnly(
      folder: folder,
      bestBangumi: bangumiCandidate,
      bangumiTier: bangumiTier,
      hasValidCover: effectiveCover != null,
    );

    return BangumiOnlyWallOutcome(
      canPromote: canPromote,
      tvdbId: offlineTvdbId,
      tvdbIdSource: tvdbSource,
      fanartPoster: fanartPoster,
      fanartBackdrop: fanartBackdrop,
      fanartLogo: fanartLogo,
      fanartTopLogo: rankedFanartLogos.isEmpty ? null : rankedFanartLogos.first,
      effectiveCover: effectiveCover,
      coverSource: coverSource,
      fanartQueried: queried,
    );
  }

  /// 通路 C / D：评估无 TMDB 与 Bangumi 主匹配时，凭 Fanart 封面或本地目录封面独立上墙的资格。
  Future<CoverFallbackWallOutcome> evaluateCoverFallback({
    required GroupedWorkFolder folder,
    int? existingTvdbId,
    RequestPriority priority = RequestPriority.background,
  }) async {
    var fallbackTvdbId = existingTvdbId;
    var tvdbSource = existingTvdbId != null
        ? TvdbIdSource.tmdbExternalIds
        : TvdbIdSource.missing;
    if (fallbackTvdbId == null && folder.explicitTmdbId != null) {
      fallbackTvdbId = lookupOfflineTvdbId(
        mappingIndex: _mappingIndex,
        tmdbId: folder.explicitTmdbId,
        mediaType: folder.explicitMediaType ?? TmdbMediaType.tv,
      );
      if (fallbackTvdbId != null) {
        tvdbSource = TvdbIdSource.offlineMappingV2;
      }
    }

    FanartArtworkResult? fallbackFanart;
    var queried = false;
    if (_fanartService != null && _fanartService.isConfigured) {
      if (fallbackTvdbId != null) {
        queried = true;
        fallbackFanart = await fetchFanartBundleIfAvailable(
          mediaType: TmdbMediaType.tv,
          tvdbId: fallbackTvdbId,
          priority: priority,
        );
      } else if (folder.explicitTmdbId != null &&
          folder.explicitMediaType == TmdbMediaType.movie) {
        queried = true;
        fallbackFanart = await fetchFanartBundleIfAvailable(
          mediaType: TmdbMediaType.movie,
          tmdbId: folder.explicitTmdbId,
          priority: priority,
        );
      }
    }

    final fanartPoster = _nonEmpty(
      fallbackFanart?.bestPosterUrlForSeason(folder.seasonHint),
    );
    final localCover = _nonEmpty(folder.localPosterPath);
    final fallbackCover = fanartPoster ?? localCover;
    final coverSource = fanartPoster != null
        ? 'fanart'
        : (localCover != null ? 'local' : 'none');

    final canPromote = WorkWallEligibility.shouldPromoteCoverFallback(
      folder: folder,
      coverPath: fallbackCover,
    );
    final rankedFanartLogos = ClearLogoResolver.toRankedFanartLogos(
      fallbackFanart?.logos ?? const [],
      tmdbId: folder.explicitTmdbId,
      tvdbId: fallbackTvdbId,
      mediaType: fallbackTvdbId != null
          ? TmdbMediaType.tv
          : folder.explicitMediaType,
      matchedSeason: folder.seasonHint,
    );

    return CoverFallbackWallOutcome(
      canPromote: canPromote,
      tvdbId: fallbackTvdbId,
      tvdbIdSource: tvdbSource,
      posterPath: fallbackCover,
      backdropPath: fallbackFanart?.bestBackgroundUrl,
      logoPath: rankedFanartLogos.isEmpty
          ? fallbackFanart?.bestLogoUrl
          : rankedFanartLogos.first.filePath,
      fanartTopLogo: rankedFanartLogos.isEmpty ? null : rankedFanartLogos.first,
      coverSource: coverSource,
      fanartQueried: queried,
    );
  }

  static String? _nonEmpty(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}
