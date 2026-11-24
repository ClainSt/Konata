import 'dart:developer' as developer;

import 'package:engine_scraping/engine_scraping.dart';

/// 作品详情页封面 / 背景图 / 透明徽标选择弹窗中的单张候选图片。
class WorkArtworkOption {
  /// 创建候选图条目。
  const WorkArtworkOption({
    required this.filePath,
    required this.sourceLabel,
    this.previewPath,
    this.isBangumi = false,
    this.isFanart = false,
    this.isSeasonPoster = false,
    this.langTag,
    this.isHd = false,
    this.width,
    this.height,
  });

  /// 图片原图地址或相对路径（应用时落盘该值）。
  final String filePath;

  /// 可选网格预览缩略图地址（为空时回落 [filePath]）。
  final String? previewPath;

  /// 来源标签（如 `Bangumi`、`TMDB·S2`、`TMDB`、`Fanart.tv`）。
  final String sourceLabel;

  /// 是否来自 Bangumi 官方封面。
  final bool isBangumi;

  /// 是否来自 Fanart.tv 艺术图源。
  final bool isFanart;

  /// 是否为单季专属封面。
  final bool isSeasonPoster;

  /// 可选语言标签（如 `简中`、`日文`、`英文`、`无字`）。
  final String? langTag;

  /// 是否为高清透明徽标档位。
  final bool isHd;

  /// 原图像素宽度。
  final int? width;

  /// 原图像素高度。
  final int? height;

  /// 格式化原图分辨率文本。
  String? get resolutionLabel =>
      (width != null && height != null && width! > 0 && height! > 0)
      ? '$width×$height'
      : (isHd ? 'HD' : null);
}

/// 作品可用的候选海报、背景图、竖版原画与透明徽标集合。
class WorkArtworkOptions {
  /// 创建候选集合实例。
  const WorkArtworkOptions({
    this.posters = const <WorkArtworkOption>[],
    this.backdrops = const <WorkArtworkOption>[],
    this.portraitBackdrops = const <WorkArtworkOption>[],
    this.logos = const <WorkArtworkOption>[],
  });

  /// 全部可选竖版封面。
  final List<WorkArtworkOption> posters;

  /// 全部可选横版背景图。
  final List<WorkArtworkOption> backdrops;

  /// 全部可选竖版无字原画（用于手机/平板竖屏沉浸顶栏背景）。
  final List<WorkArtworkOption> portraitBackdrops;

  /// 全部可选透明标题徽标。
  final List<WorkArtworkOption> logos;
}

/// 作品多源候选艺术图拉取与统一排序服务（零 Riverpod，纯构造函数注入）。
final class WorkArtworkOptionsService {
  /// 创建多源候选艺术图服务。
  WorkArtworkOptionsService({
    required this._httpClient,
    required this._tmdbService,
    required this._bangumiService,
    required this._fanartService,
    this.circuitBreaker,
    this.mappingIndexProvider,
  });

  final KonataHttpClientPort _httpClient;
  final TmdbService _tmdbService;
  final BangumiService _bangumiService;
  final FanartService _fanartService;

  /// 可选 Fanart 熔断器实例（用于对外读取中继降级状态）。
  final FanartCircuitBreaker? circuitBreaker;

  /// 可选离线 Bangumi/TVDB 映射索引提供器。
  final Future<BangumiTmdbIndex?> Function()? mappingIndexProvider;

  /// 查询当前 Fanart.tv 中继健康快照。
  FanartRelayHealthSnapshot get fanartRelayHealth =>
      circuitBreaker?.snapshot() ?? FanartRelayHealthSnapshot.ok;

  /// 拉取作品对应 Bangumi、TMDB 与 Fanart.tv 候选图像集合。
  Future<WorkArtworkOptions> fetchForWork(
    Work work, {
    bool includeLogos = false,
  }) async {
    final logos = <WorkArtworkOption>[];
    var bangumiPosterPath = work.bangumiPosterPath;
    final config = _httpClient.config;

    TmdbWorkDetail? tmdbDetail;
    TmdbSeasonDetail? tmdbSeasonDetail;
    FanartArtworkResult? fanartBundle;
    int? resolvedTvdbId = work.tvdbId;

    if (!includeLogos && bangumiPosterPath == null && work.bangumiId != null) {
      try {
        final subject = await _bangumiService.getSubjectDetail(
          work.bangumiId!,
          priority: RequestPriority.interactive,
        );
        bangumiPosterPath = subject?.posterUrl;
      } catch (error) {
        developer.log(
          '拉取 Bangumi 封面补充失败，继续其他来源',
          name: 'konata.work_artwork_options',
          error: error,
        );
      }
    }

    if (work.tmdbId != null &&
        work.tmdbMediaType != null &&
        config.credential.trim().isNotEmpty) {
      try {
        tmdbDetail = await _tmdbService.getWorkDetail(
          work.tmdbId!,
          work.tmdbMediaType!,
          priority: RequestPriority.interactive,
          includeEnglishImages: true,
        );
        if (tmdbDetail != null) {
          resolvedTvdbId ??= tmdbDetail.tvdbId;
          if (!includeLogos &&
              work.tmdbMediaType == TmdbMediaType.tv &&
              work.matchedSeason != null) {
            try {
              tmdbSeasonDetail = await _tmdbService.getSeasonDetail(
                work.tmdbId!,
                work.matchedSeason!,
                priority: RequestPriority.interactive,
              );
            } catch (error) {
              developer.log(
                '拉取 TMDB 单季候选海报失败，回退系列候选集',
                name: 'konata.work_artwork_options',
                error: error,
              );
            }
          }
        }
      } catch (error) {
        developer.log(
          '拉取 TMDB 候选图集失败，继续尝试其他来源',
          name: 'konata.work_artwork_options',
          error: error,
        );
      }
    }

    if (config.isFanartAvailable) {
      if (resolvedTvdbId == null && mappingIndexProvider != null) {
        try {
          final index = await mappingIndexProvider!();
          if (index != null) {
            if (work.bangumiId != null && work.bangumiId! > 0) {
              for (final target in index.lookup(work.bangumiId!)) {
                if (target.tvdbId != null && target.tvdbId! > 0) {
                  if (work.tmdbId == null || target.id == work.tmdbId) {
                    resolvedTvdbId = target.tvdbId;
                    break;
                  }
                }
              }
            }
            if (resolvedTvdbId == null &&
                work.tmdbId != null &&
                work.tmdbMediaType == TmdbMediaType.tv) {
              resolvedTvdbId = index.lookupTvdbIdByTmdb(
                mediaType: TmdbMediaType.tv,
                tmdbId: work.tmdbId!,
              );
            }
          }
        } catch (error) {
          developer.log(
            '离线查询 TVDB 映射失败已忽略',
            name: 'konata.work_artwork_options',
            error: error,
          );
        }
      }
      final effectiveMediaType =
          work.tmdbMediaType ??
          (resolvedTvdbId != null ? TmdbMediaType.tv : null);
      final canQueryFanart =
          effectiveMediaType != null &&
          (effectiveMediaType == TmdbMediaType.movie
              ? work.tmdbId != null
              : resolvedTvdbId != null);
      if (canQueryFanart) {
        try {
          fanartBundle = await _fanartService.fetchArtworkBundle(
            mediaType: effectiveMediaType,
            tmdbId: work.tmdbId,
            tvdbId: resolvedTvdbId,
            priority: RequestPriority.interactive,
          );
        } catch (error) {
          developer.log(
            '拉取 Fanart.tv 整包艺术图失败',
            name: 'konata.work_artwork_options',
            error: error,
          );
        }
      }
    }

    final posters = mergePosterOptions(
      bangumiPosterPath: bangumiPosterPath,
      tmdbDetail: tmdbDetail,
      tmdbSeasonDetail: tmdbSeasonDetail,
      matchedSeason: work.matchedSeason,
      fanartPosters: fanartBundle?.posters ?? const <FanartPosterCandidate>[],
    );
    final backdrops = mergeBackdropOptions(
      tmdbDetail: tmdbDetail,
      fanartBackgrounds:
          fanartBundle?.backgrounds ?? const <FanartBackgroundCandidate>[],
    );
    final portraitBackdrops = mergePortraitBackdropOptions(
      currentPortraitBackdropPath: work.portraitBackdropPath,
      tmdbDetail: tmdbDetail,
      tmdbSeasonDetail: tmdbSeasonDetail,
      matchedSeason: work.matchedSeason,
      fanartPosters: fanartBundle?.posters ?? const <FanartPosterCandidate>[],
    );

    if (includeLogos) {
      final rankedLogos = ClearLogoResolver.mergeAndRankLogos(
        tmdbLogos: tmdbDetail?.candidateLogos ?? const <TmdbArtworkImage>[],
        fanartLogos: fanartBundle?.logos ?? const <FanartLogoCandidate>[],
        tmdbId: work.tmdbId,
        tvdbId: resolvedTvdbId,
        mediaType: work.tmdbMediaType,
        matchedSeason: work.matchedSeason,
      );
      for (final item in rankedLogos) {
        logos.add(
          WorkArtworkOption(
            filePath: item.filePath,
            sourceLabel: item.source == LogoSourceKind.fanart
                ? 'Fanart.tv'
                : 'TMDB',
            isFanart: item.source == LogoSourceKind.fanart,
            langTag: formatLanguageTag(item.isoLanguage, item.isoCountry),
            isHd: item.isHd,
            width: item.width,
            height: item.height,
          ),
        );
      }
    }

    return WorkArtworkOptions(
      posters: posters,
      backdrops: backdrops,
      portraitBackdrops: portraitBackdrops,
      logos: logos,
    );
  }

  /// 合并竖版封面候选集。
  static List<WorkArtworkOption> mergePosterOptions({
    String? bangumiPosterPath,
    TmdbWorkDetail? tmdbDetail,
    TmdbSeasonDetail? tmdbSeasonDetail,
    int? matchedSeason,
    List<FanartPosterCandidate> fanartPosters =
        const <FanartPosterCandidate>[],
  }) {
    final posters = <WorkArtworkOption>[];
    final seenPosters = <String>{};

    void addPoster(
      String? path, {
      required String sourceLabel,
      String? previewPath,
      bool isBangumi = false,
      bool isFanart = false,
      bool isSeasonPoster = false,
      String? langTag,
      int? width,
      int? height,
    }) {
      final clean = path?.trim();
      if (clean == null || clean.isEmpty) return;
      if (seenPosters.add(clean)) {
        posters.add(
          WorkArtworkOption(
            filePath: clean,
            previewPath: previewPath,
            sourceLabel: sourceLabel,
            isBangumi: isBangumi,
            isFanart: isFanart,
            isSeasonPoster: isSeasonPoster,
            langTag: langTag,
            width: width,
            height: height,
          ),
        );
      }
    }

    addPoster(bangumiPosterPath, sourceLabel: 'Bangumi', isBangumi: true);

    final seriesPosterByPath = <String, TmdbArtworkImage>{
      for (final item
          in tmdbDetail?.candidatePosters ?? const <TmdbArtworkImage>[])
        item.filePath.trim(): item,
    };

    if (matchedSeason != null &&
        (tmdbDetail?.mediaType == TmdbMediaType.tv ||
            tmdbSeasonDetail != null)) {
      final seasonLabel = matchedSeason == 0
          ? 'TMDB·SP'
          : 'TMDB·S$matchedSeason';
      final seasonMetaByPath = <String, TmdbArtworkImage>{
        for (final item
            in tmdbSeasonDetail?.candidatePosters ?? const <TmdbArtworkImage>[])
          item.filePath.trim(): item,
      };
      if (tmdbSeasonDetail != null) {
        final rankedSeasonPosters = ArtworkRanker.rankTmdbPosters(
          tmdbSeasonDetail.candidatePosters,
          primaryDefaultPath: tmdbSeasonDetail.posterPath,
        );
        final topSeasonPath = tmdbSeasonDetail.posterPath?.trim();
        if (topSeasonPath != null && topSeasonPath.isNotEmpty) {
          final meta =
              seasonMetaByPath[topSeasonPath] ??
              seriesPosterByPath[topSeasonPath];
          addPoster(
            topSeasonPath,
            sourceLabel: seasonLabel,
            isSeasonPoster: true,
            langTag: meta != null
                ? formatLanguageTag(meta.isoLanguage, meta.isoCountry)
                : null,
            width: meta?.width,
            height: meta?.height,
          );
        }
        for (final item in rankedSeasonPosters) {
          addPoster(
            item.filePath,
            sourceLabel: seasonLabel,
            isSeasonPoster: true,
            langTag: formatLanguageTag(item.isoLanguage, item.isoCountry),
            width: item.width,
            height: item.height,
          );
        }
      }
      final seasonSummary = tmdbDetail?.seasons
          .where((s) => s.seasonNumber == matchedSeason)
          .firstOrNull;
      final summaryPath = seasonSummary?.posterPath?.trim();
      if (summaryPath != null && summaryPath.isNotEmpty) {
        final meta =
            seasonMetaByPath[summaryPath] ?? seriesPosterByPath[summaryPath];
        addPoster(
          summaryPath,
          sourceLabel: seasonLabel,
          isSeasonPoster: true,
          langTag: meta != null
              ? formatLanguageTag(meta.isoLanguage, meta.isoCountry)
              : null,
          width: meta?.width,
          height: meta?.height,
        );
      }
    }

    if (matchedSeason != null) {
      for (final item in fanartPosters) {
        if (item.season != matchedSeason) continue;
        addPoster(
          item.url,
          previewPath: item.previewUrl,
          sourceLabel: item.sourceLabel,
          isFanart: true,
          isSeasonPoster: true,
          langTag: formatLanguageTag(item.lang, null),
          width: item.width,
          height: item.height,
        );
      }
    }

    if (tmdbDetail != null) {
      final rankedSeriesPosters = ArtworkRanker.rankTmdbPosters(
        tmdbDetail.candidatePosters,
        primaryDefaultPath: tmdbDetail.posterPath,
      );
      final defPath = tmdbDetail.posterPath?.trim();
      if (defPath != null && defPath.isNotEmpty) {
        final meta = seriesPosterByPath[defPath];
        addPoster(
          defPath,
          sourceLabel: 'TMDB',
          langTag: meta != null
              ? formatLanguageTag(meta.isoLanguage, meta.isoCountry)
              : null,
          width: meta?.width,
          height: meta?.height,
        );
      }
      for (final item in rankedSeriesPosters) {
        addPoster(
          item.filePath,
          sourceLabel: 'TMDB',
          langTag: formatLanguageTag(item.isoLanguage, item.isoCountry),
          width: item.width,
          height: item.height,
        );
      }
    }

    for (final item in fanartPosters) {
      if (item.isSeasonPoster) continue;
      addPoster(
        item.url,
        previewPath: item.previewUrl,
        sourceLabel: item.sourceLabel,
        isFanart: true,
        langTag: formatLanguageTag(item.lang, null),
        width: item.width,
        height: item.height,
      );
    }
    for (final item in fanartPosters) {
      if (!item.isSeasonPoster) continue;
      addPoster(
        item.url,
        previewPath: item.previewUrl,
        sourceLabel: item.sourceLabel,
        isFanart: true,
        isSeasonPoster: true,
        langTag: formatLanguageTag(item.lang, null),
        width: item.width,
        height: item.height,
      );
    }

    return posters;
  }

  /// 合并横版背景图候选集，确保与自动选图口径一致。
  static List<WorkArtworkOption> mergeBackdropOptions({
    TmdbWorkDetail? tmdbDetail,
    List<FanartBackgroundCandidate> fanartBackgrounds =
        const <FanartBackgroundCandidate>[],
  }) {
    final backdrops = <WorkArtworkOption>[];
    final seenBackdrops = <String>{};

    void pushBackdrop(WorkArtworkOption option) {
      if (seenBackdrops.add(option.filePath)) {
        backdrops.add(option);
      }
    }

    final rawTmdb = <TmdbArtworkImage>[];
    if (tmdbDetail != null) {
      rawTmdb.addAll(tmdbDetail.candidateBackdrops);
      final defPath = tmdbDetail.backdropPath?.trim();
      if (defPath != null &&
          defPath.isNotEmpty &&
          !rawTmdb.any((item) => item.filePath.trim() == defPath)) {
        rawTmdb.add(TmdbArtworkImage(filePath: defPath));
      }
    }
    final rankedTmdb = ArtworkRanker.rankTmdbBackdrops(
      rawTmdb,
      primaryDefaultPath: tmdbDetail?.backdropPath,
      limit: 48,
    );

    void pushTmdb(TmdbArtworkImage item, {bool withLangTag = false}) {
      pushBackdrop(
        WorkArtworkOption(
          filePath: item.filePath.trim(),
          sourceLabel: 'TMDB',
          langTag: withLangTag
              ? formatLanguageTag(item.isoLanguage, item.isoCountry)
              : null,
          width: item.width,
          height: item.height,
        ),
      );
    }

    for (final item in rankedTmdb) {
      if (ArtworkRanker.backdropQualityTier(item) ==
          BackdropQualityTier.ultraHdTextless) {
        pushTmdb(item);
      }
    }
    for (final item in rankedTmdb) {
      if (ArtworkRanker.backdropQualityTier(item) ==
              BackdropQualityTier.standard1080pTextless &&
          ArtworkRanker.isHighConfidenceCleanTmdbBackdrop(item)) {
        pushTmdb(item);
      }
    }
    for (final item in fanartBackgrounds) {
      pushBackdrop(
        WorkArtworkOption(
          filePath: item.url,
          previewPath: item.previewUrl,
          sourceLabel: 'Fanart.tv',
          isFanart: true,
          width: item.width,
          height: item.height,
        ),
      );
    }
    for (final item in rankedTmdb) {
      if (ArtworkRanker.backdropQualityTier(item) ==
              BackdropQualityTier.standard1080pTextless &&
          !ArtworkRanker.isHighConfidenceCleanTmdbBackdrop(item)) {
        pushTmdb(item);
      }
    }
    for (final item in rankedTmdb) {
      if (ArtworkRanker.backdropQualityTier(item) ==
          BackdropQualityTier.nonStandardHiResTextless) {
        pushTmdb(item);
      }
    }
    for (final item in rankedTmdb) {
      if (ArtworkRanker.backdropQualityTier(item) ==
          BackdropQualityTier.hd720pTextless) {
        pushTmdb(item);
      }
    }
    for (final item in rankedTmdb) {
      final tier = ArtworkRanker.backdropQualityTier(item);
      if (tier == BackdropQualityTier.textedHd ||
          tier == BackdropQualityTier.lowResOrMalformed) {
        pushTmdb(
          item,
          withLangTag: !ArtworkRanker.isTextlessLanguage(item.isoLanguage),
        );
      }
    }

    return backdrops;
  }

  /// 合并竖版无字原画候选集（无字竖版原画优先，其余竖版海报作为补充备选）。
  static List<WorkArtworkOption> mergePortraitBackdropOptions({
    String? currentPortraitBackdropPath,
    TmdbWorkDetail? tmdbDetail,
    TmdbSeasonDetail? tmdbSeasonDetail,
    int? matchedSeason,
    List<FanartPosterCandidate> fanartPosters =
        const <FanartPosterCandidate>[],
  }) {
    final mergedPosters = mergePosterOptions(
      tmdbDetail: tmdbDetail,
      tmdbSeasonDetail: tmdbSeasonDetail,
      matchedSeason: matchedSeason,
      fanartPosters: fanartPosters,
    );
    final result = <WorkArtworkOption>[];
    final seen = <String>{};

    void pushUnique(WorkArtworkOption option) {
      if (seen.add(option.filePath)) {
        result.add(option);
      }
    }

    final current = currentPortraitBackdropPath?.trim();
    if (current != null && current.isNotEmpty) {
      final matched = mergedPosters.where((e) => e.filePath == current).firstOrNull;
      pushUnique(
        matched ??
            WorkArtworkOption(
              filePath: current,
              sourceLabel: '当前竖版原画',
              langTag: '当前',
            ),
      );
    }

    for (final item in mergedPosters) {
      if (item.langTag == '无字') {
        pushUnique(item);
      }
    }
    for (final item in mergedPosters) {
      if (item.langTag != '无字') {
        pushUnique(item);
      }
    }
    return result;
  }

  /// 将语言与国家地区代码格式化为选图角标文案（兼容 Fanart.tv `'00'` 无字标识）。
  static String? formatLanguageTag(String? isoLang, String? isoCountry) {
    final normalizedLang = isoLang?.trim() == '00' ? null : isoLang;
    final rank = TmdbService.logoLanguageRank(normalizedLang, isoCountry);
    return switch (rank) {
      0 => '简中',
      1 => '繁中',
      2 => '日文',
      3 => '英文',
      4 => '无字',
      _ => null,
    };
  }
}
