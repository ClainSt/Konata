import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/episode_remapper.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/matching/work_matcher.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/parsing/bdrip_parser.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/scrape_domain_adapter.dart';

/// 刮削结果持久化器。
///
/// 负责将归组作品、季级详情、Top-5 复核候选、逻辑剧集与多版本物理文件写入仓储。
class ScrapeWorkPersister {
  /// 创建持久化器。
  const ScrapeWorkPersister(this._repository);

  final LibraryRepository _repository;

  static String? _nonEmpty(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  /// 根据 TMDB 与可选 Bangumi/Fanart 详情及季级身份解析结果构造已匹配的强类型 [Work] 实体。
  static Work buildMatchedWork({
    required String id,
    required TmdbWorkDetail detail,
    GroupedWorkFolder? folder,
    int? matchedSeason,
    TmdbSeasonDetail? seasonDetail,
    ScoredBangumiCandidate? bangumiCandidate,
    int? tvdbIdOverride,
    String? fanartPosterFallback,
    String? fanartBackdropOverride,
    String? fanartLogoOverride,
    String? localPosterFallback,
    int? fallbackYear,
    int? folderTmdbHint,
    required bool isManualLocked,
    bool metadataLocked = false,
    bool posterLocked = false,
    bool backdropLocked = false,
    bool logoLocked = false,
    int logoNegativeMask = 0,
    bool isHidden = false,
    bool keepHidden = false,
  }) {
    final bgmSubject = bangumiCandidate?.subject;
    final resolved = folder != null
        ? ScrapeDomainAdapter.resolveSeasonPresentation(
            folder: folder,
            detail: detail,
            matchedSeason: matchedSeason,
            seasonDetail: seasonDetail,
            bangumiCandidate: bangumiCandidate,
          )
        : (
            title: detail.title,
            year: detail.year ?? bgmSubject?.year ?? fallbackYear,
            posterPath:
                seasonDetail?.posterPath ??
                detail.posterPath ??
                bgmSubject?.posterUrl,
            posterFallback: seasonDetail?.posterPath != null
                ? (detail.posterPath ?? bgmSubject?.posterUrl)
                : bgmSubject?.posterUrl,
            bangumiPosterPath: bgmSubject?.posterUrl,
            overview:
                seasonDetail?.overview ??
                detail.overview ??
                bgmSubject?.summary,
          );

    final effectiveFanartPoster = _nonEmpty(fanartPosterFallback);
    final effectiveLocalPoster =
        _nonEmpty(localPosterFallback) ?? _nonEmpty(folder?.localPosterPath);
    final effectivePoster =
        _nonEmpty(resolved.posterPath) ??
        effectiveFanartPoster ??
        effectiveLocalPoster;
    String? effectivePosterFallback = _nonEmpty(resolved.posterFallback);
    if (effectivePosterFallback == null &&
        effectiveFanartPoster != null &&
        effectiveFanartPoster != effectivePoster) {
      effectivePosterFallback = effectiveFanartPoster;
    }
    if (effectivePosterFallback == null &&
        effectiveLocalPoster != null &&
        effectiveLocalPoster != effectivePoster) {
      effectivePosterFallback = effectiveLocalPoster;
    }

    return Work(
      id: id,
      tmdbId: detail.tmdbId,
      tmdbMediaType: detail.mediaType,
      bangumiId: bgmSubject?.id,
      tvdbId: detail.tvdbId ?? tvdbIdOverride,
      matchedSeason: matchedSeason,
      title: resolved.title,
      originalTitle: detail.originalTitle ?? bgmSubject?.name,
      year: resolved.year ?? fallbackYear,
      overview: resolved.overview,
      posterPath: effectivePoster,
      posterFallback: effectivePosterFallback,
      bangumiPosterPath: resolved.bangumiPosterPath,
      backdropPath:
          _nonEmpty(fanartBackdropOverride) ?? _nonEmpty(detail.backdropPath),
      logoPath: _nonEmpty(fanartLogoOverride) ?? _nonEmpty(detail.logoPath),
      voteAverage: detail.voteAverage,
      bangumiScore: bgmSubject?.score,
      folderTmdbHint: folderTmdbHint,
      isManualLocked: isManualLocked,
      metadataLocked: metadataLocked,
      posterLocked: posterLocked,
      backdropLocked: backdropLocked,
      logoLocked: logoLocked,
      logoNegativeMask: logoNegativeMask,
      isHidden: isHidden,
      keepHidden: keepHidden,
      scrapeStatus: ScrapeStatus.matched,
    );
  }

  /// 将新抓取的元数据与既有作品的人工锁定字段合并（仅刷新未锁定字段，主动更换新条目并重置时除外）。
  static Work mergeWorkWithLocks({
    required Work? existing,
    required Work candidate,
    bool resetManualLocks = false,
  }) {
    if (existing == null || resetManualLocks) {
      return candidate;
    }
    final nextLogoPath = existing.logoLocked
        ? existing.logoPath
        : (candidate.logoPath ?? existing.logoPath);
    final hasResolvedLogo =
        nextLogoPath != null && nextLogoPath.trim().isNotEmpty;
    final nextLogoNegativeMask = hasResolvedLogo
        ? (candidate.logoNegativeMask != 0
              ? candidate.logoNegativeMask
              : (nextLogoPath == existing.logoPath
                    ? existing.logoNegativeMask
                    : 0))
        : existing.logoNegativeMask;
    return candidate.copyWith(
      tvdbId: candidate.tvdbId ?? existing.tvdbId,
      matchedSeason: existing.metadataLocked
          ? (existing.matchedSeason ?? candidate.matchedSeason)
          : candidate.matchedSeason,
      title: existing.metadataLocked ? existing.title : candidate.title,
      originalTitle: existing.metadataLocked
          ? existing.originalTitle
          : candidate.originalTitle,
      year: existing.metadataLocked ? existing.year : candidate.year,
      overview: existing.metadataLocked
          ? existing.overview
          : candidate.overview,
      posterPath: existing.posterLocked
          ? existing.posterPath
          : (candidate.posterPath ?? existing.posterPath),
      posterFallback: existing.posterLocked
          ? existing.posterFallback
          : (candidate.posterFallback ?? existing.posterFallback),
      backdropPath: existing.backdropLocked
          ? existing.backdropPath
          : (candidate.backdropPath ?? existing.backdropPath),
      logoPath: nextLogoPath,
      clearLogoPath: !hasResolvedLogo,
      clearLogoNegative: hasResolvedLogo && nextLogoNegativeMask == 0,
      logoNegativeUntil: hasResolvedLogo ? null : existing.logoNegativeUntil,
      logoNegativeMask: nextLogoNegativeMask,
      bangumiId: (existing.metadataLocked && existing.bangumiId != null)
          ? existing.bangumiId
          : (candidate.bangumiId ?? existing.bangumiId),
      bangumiPosterPath:
          (existing.posterLocked && existing.bangumiPosterPath != null)
          ? existing.bangumiPosterPath
          : (candidate.bangumiPosterPath ?? existing.bangumiPosterPath),
      bangumiScore: candidate.bangumiScore ?? existing.bangumiScore,
      seriesId: existing.seriesLocked
          ? existing.seriesId
          : (candidate.seriesId ?? existing.seriesId),
      seriesOrder: existing.seriesLocked
          ? existing.seriesOrder
          : (candidate.seriesOrder ?? existing.seriesOrder),
      seriesLabel: existing.seriesLocked
          ? existing.seriesLabel
          : (candidate.seriesLabel ?? existing.seriesLabel),
      seriesLocked: existing.seriesLocked,
      isManualLocked:
          candidate.isManualLocked ||
          existing.isManualLocked ||
          existing.metadataLocked ||
          existing.posterLocked ||
          existing.backdropLocked ||
          existing.logoLocked,
      metadataLocked: existing.metadataLocked,
      posterLocked: existing.posterLocked,
      backdropLocked: existing.backdropLocked,
      logoLocked: existing.logoLocked,
    );
  }

  /// 构造仅命中 Bangumi 在线条目时的强类型 [Work] 实体（支持联合 Fanart.tv / 本地封面保底独立上墙）。
  static Work buildBangumiOnlyWork({
    required String id,
    required GroupedWorkFolder folder,
    required ScoredBangumiCandidate bangumiCandidate,
    required ScrapeStatus status,
    String? reviewReason,
    int? tvdbId,
    String? posterPathOverride,
    String? backdropPath,
    String? logoPath,
    required bool isManualLocked,
    bool metadataLocked = false,
    bool posterLocked = false,
    bool backdropLocked = false,
    bool logoLocked = false,
    bool isHidden = false,
    bool keepHidden = false,
  }) {
    final resolved = ScrapeDomainAdapter.resolveSeasonPresentation(
      folder: folder,
      bangumiCandidate: bangumiCandidate,
    );
    final subject = bangumiCandidate.subject;
    final overridePoster = _nonEmpty(posterPathOverride);
    final localPoster = _nonEmpty(folder.localPosterPath);
    final effectivePoster =
        _nonEmpty(resolved.posterPath) ?? overridePoster ?? localPoster;
    String? effectiveFallback = _nonEmpty(resolved.posterFallback);
    if (effectiveFallback == null &&
        overridePoster != null &&
        overridePoster != effectivePoster) {
      effectiveFallback = overridePoster;
    }
    if (effectiveFallback == null &&
        localPoster != null &&
        localPoster != effectivePoster) {
      effectiveFallback = localPoster;
    }
    return Work(
      id: id,
      bangumiId: subject.id,
      tvdbId: tvdbId,
      matchedSeason: folder.seasonHint,
      title: resolved.title,
      originalTitle: subject.name.isNotEmpty ? subject.name : null,
      year: resolved.year ?? folder.year,
      overview: resolved.overview,
      posterPath: effectivePoster,
      posterFallback: effectiveFallback,
      bangumiPosterPath: resolved.bangumiPosterPath,
      backdropPath: _nonEmpty(backdropPath),
      logoPath: _nonEmpty(logoPath),
      bangumiScore: subject.score,
      folderTmdbHint: folder.explicitTmdbId,
      isManualLocked: isManualLocked,
      metadataLocked: metadataLocked,
      posterLocked: posterLocked,
      backdropLocked: backdropLocked,
      logoLocked: logoLocked,
      isHidden: isHidden,
      keepHidden: keepHidden,
      scrapeStatus: status,
      reviewReason: reviewReason,
    );
  }

  /// 构造无 TMDB 与 Bangumi 主匹配、但凭 Fanart.tv 封面或本地磁盘封面独立上墙的 [Work] 实体。
  static Work buildCoverFallbackWork({
    required String id,
    required GroupedWorkFolder folder,
    required String posterPath,
    int? tvdbId,
    String? backdropPath,
    String? logoPath,
    bool isManualLocked = false,
    bool isHidden = false,
    bool keepHidden = false,
  }) {
    return Work(
      id: id,
      tvdbId: tvdbId,
      matchedSeason: folder.seasonHint,
      title: folder.cleanTitle,
      year: folder.year,
      posterPath: posterPath.trim(),
      backdropPath: _nonEmpty(backdropPath),
      logoPath: _nonEmpty(logoPath),
      folderTmdbHint: folder.explicitTmdbId,
      isManualLocked: isManualLocked,
      isHidden: isHidden,
      keepHidden: keepHidden,
      scrapeStatus: ScrapeStatus.matched,
    );
  }

  /// 计算稳定的确定性 UUID 风格标识，避免重复扫描生成重复记录。
  static String deterministicId(String seed) {
    final digest = sha1.convert(utf8.encode(seed)).toString();
    return '${digest.substring(0, 8)}-'
        '${digest.substring(8, 12)}-'
        '${digest.substring(12, 16)}-'
        '${digest.substring(16, 20)}-'
        '${digest.substring(20, 32)}';
  }

  /// 根据媒体源内已有物理文件映射，定位已存在的 `workId`（用于增量扫描与锁定保护）。
  ///
  /// 批量扫描期间可注入预载的 [workIdByRelPath] 与 [worksById] 索引，避免每部作品执行 O(N) 全表查库。
  Future<Work?> findExistingWorkForFolder(
    String sourceId,
    GroupedWorkFolder folder, {
    Map<String, String>? workIdByRelPath,
    Map<String, Work>? worksById,
  }) async {
    final stableId = deterministicId('$sourceId::${folder.folderRelativePath}');
    final cachedExact = worksById?[stableId];
    if (cachedExact != null) return cachedExact;
    final exact = worksById == null
        ? await _repository.findWorkById(stableId)
        : null;
    if (exact != null) return exact;
    // 多作品合集拆簇后禁止回退抢占共享父目录旧 `workId`，否则同目录拆出的多部子作品会互相覆盖。
    if (folder.isSplitCluster) return null;

    if (workIdByRelPath != null) {
      if (workIdByRelPath.isEmpty) return null;
      final hitCountByWorkId = <String, int>{};
      for (final f in folder.variants) {
        final ownerId = workIdByRelPath[f.relativePath];
        if (ownerId == null) continue;
        hitCountByWorkId[ownerId] = (hitCountByWorkId[ownerId] ?? 0) + 1;
      }
      if (hitCountByWorkId.isEmpty) return null;
      String? bestWorkId;
      var bestHitCount = 0;
      for (final entry in hitCountByWorkId.entries) {
        if (entry.value > bestHitCount) {
          bestHitCount = entry.value;
          bestWorkId = entry.key;
        }
      }
      if (bestWorkId == null) return null;
      return worksById?[bestWorkId] ?? await _repository.findWorkById(bestWorkId);
    }

    final allWorks = await _repository.getAllWorks();
    if (allWorks.isEmpty) return null;

    final filePaths = folder.variants.map((f) => f.relativePath).toSet();
    Work? bestWork;
    var bestHitCount = 0;
    for (final work in allWorks) {
      final variants = await _repository.getVariantsByWork(work.id);
      var hitCount = 0;
      for (final v in variants) {
        if (v.sourceId == sourceId && filePaths.contains(v.relativePath)) {
          hitCount++;
        }
      }
      if (hitCount > bestHitCount) {
        bestHitCount = hitCount;
        bestWork = work;
      }
    }
    return bestWork;
  }

  /// 同步一个作品文件夹下的所有逻辑剧集、特典（Season 0 对齐）与多版本物理文件。
  ///
  /// 全部剧集与物理文件写入收口至单一 SQLite 事务批量提交；当提供 [preloadedSourceVariantsById]
  /// 时直接复用内存中的源级变体索引并同步维护更新，消除批量扫描期间重复反序列化整源数据。
  Future<void> syncEpisodesAndVariants({
    required Work work,
    required GroupedWorkFolder folder,
    required List<TmdbEpisodeDetail> tmdbEpisodes,
    List<BangumiEpisodeEntry> bangumiEpisodes = const [],
    EpisodeRemapPlan? remapPlan,
    String? seasonName,
    bool resetManualLocks = false,
    Map<String, MediaVariant>? preloadedSourceVariantsById,
  }) async {
    final tmdbByKey = <String, TmdbEpisodeDetail>{
      for (final ep in tmdbEpisodes)
        '${ep.seasonNumber}:${ep.episodeNumber}': ep,
    };
    final bgmByEp = <int, BangumiEpisodeEntry>{};
    for (final be in bangumiEpisodes) {
      if (be.type != 0) continue;
      final epNum = be.ep?.round();
      final sortNum = be.sort?.round();
      if (epNum != null && epNum > 0) {
        bgmByEp.putIfAbsent(epNum, () => be);
      }
      if (sortNum != null && sortNum > 0 && sortNum != epNum) {
        bgmByEp.putIfAbsent(sortNum, () => be);
      }
    }
    final seasonZeroEpisodes = tmdbEpisodes
        .where((e) => e.seasonNumber == 0)
        .toList(growable: false);
    final existingVariants = await _repository.getVariantsByWork(work.id);
    final existingVariantById = <String, MediaVariant>{
      for (final v in existingVariants) v.id: v,
    };
    final Map<String, MediaVariant> sourceVariantById;
    if (preloadedSourceVariantsById != null) {
      sourceVariantById = preloadedSourceVariantsById;
    } else {
      sourceVariantById = <String, MediaVariant>{};
      final sourceIds = {for (final v in folder.variants) v.sourceId};
      for (final sid in sourceIds) {
        final list = await _repository.getVariantsBySource(sid);
        for (final sv in list) {
          sourceVariantById[sv.id] = sv;
        }
      }
    }
    final existingEpisodes = await _repository.getEpisodesByWork(work.id);
    final episodeById = <String, Episode>{
      for (final ep in existingEpisodes) ep.id: ep,
    };

    final extraVariants = folder.variants
        .where((v) {
          if (v.assetKind != AssetKind.video) return false;
          final vId = deterministicId('${v.sourceId}::${v.relativePath}');
          final globalExisting = sourceVariantById[vId];
          if (!resetManualLocks &&
              globalExisting != null &&
              globalExisting.workId != work.id &&
              (globalExisting.workLocked || globalExisting.scopeLocked)) {
            return false;
          }
          final existingVariant = existingVariantById[vId];
          if (!resetManualLocks &&
              existingVariant != null &&
              existingVariant.mappingLocked &&
              existingVariant.episodeId != null) {
            return false;
          }
          return (folder.slotAssignmentsByPath[v.relativePath]?.category ??
                  BdripParser.parseFileName(
                    v.fileName,
                    relativePath: v.relativePath,
                    folderTitle: folder.cleanTitle,
                    folderSeasonHint: folder.seasonHint,
                  ).category) ==
              EpisodeCategory.extra;
        })
        .toList(growable: false);
    final mappedSpecialsByPath = ScrapeDomainAdapter.mapSpecialEpisodes(
      work: work,
      extraVariants: extraVariants,
      seasonZeroEpisodes: seasonZeroEpisodes,
      seasonName: seasonName,
    );

    final parsedByVariantId = <String, ParsedBdripRelease>{};
    final strongMainEpisodes = <int>{};
    for (final rawVariant in folder.variants) {
      if (rawVariant.assetKind != AssetKind.video) continue;
      final parsed = BdripParser.parseFileName(
        rawVariant.fileName,
        relativePath: rawVariant.relativePath,
        folderTitle: folder.cleanTitle,
        folderSeasonHint: folder.seasonHint,
      );
      parsedByVariantId[rawVariant.id] = parsed;
      final preSlot = folder.slotAssignmentsByPath[rawVariant.relativePath];
      if (preSlot != null) {
        if (preSlot.category == EpisodeCategory.main &&
            preSlot.episodeNumber != null) {
          final lastCovered = preSlot.episodeEnd ?? preSlot.episodeNumber!;
          for (var e = preSlot.episodeNumber!; e <= lastCovered; e++) {
            strongMainEpisodes.add(e);
          }
        }
      } else if (parsed.category == EpisodeCategory.main &&
          parsed.episode != null) {
        strongMainEpisodes.add(parsed.episode!);
      }
    }

    final episodesToUpsert = <String, Episode>{};
    final variantsToUpsert = <MediaVariant>[];

    for (final rawVariant in folder.variants) {
      String? episodeId;
      ParsedBdripRelease? parsed;
      final variantId = deterministicId(
        '${rawVariant.sourceId}::${rawVariant.relativePath}',
      );
      final globalExisting = sourceVariantById[variantId];
      if (!resetManualLocks &&
          globalExisting != null &&
          globalExisting.workId != work.id &&
          (globalExisting.workLocked || globalExisting.scopeLocked)) {
        continue;
      }
      final existingVariant = existingVariantById[variantId];
      final lockedExistingEp =
          (!resetManualLocks &&
              existingVariant != null &&
              existingVariant.mappingLocked &&
              existingVariant.episodeId != null)
          ? episodeById[existingVariant.episodeId!]
          : null;
      final preserveVariantLock = lockedExistingEp != null;

      if (rawVariant.assetKind == AssetKind.video) {
        parsed = parsedByVariantId[rawVariant.id]!;
        var resolved = _ResolvedEpisodeSlot(
          seasonNumber: lockedExistingEp?.seasonNumber ?? 1,
          episodeNumber: lockedExistingEp?.episodeNumber,
          episodeEnd: lockedExistingEp?.episodeNumberEnd,
          category: lockedExistingEp?.category ?? EpisodeCategory.main,
          extraType: lockedExistingEp?.extraType,
        );
        InterspersedSpecialMapping? specialMapping;

        if (lockedExistingEp == null) {
          final preSlot = folder.slotAssignmentsByPath[rawVariant.relativePath];
          final _ResolvedEpisodeSlot resolved0;
          if (preSlot != null) {
            var targetSeason = preSlot.seasonNumber;
            var targetEp = preSlot.episodeNumber;
            var targetEpEnd = preSlot.category == EpisodeCategory.main
                ? preSlot.episodeEnd
                : null;
            if (preSlot.category == EpisodeCategory.main) {
              if (work.tmdbMediaType == TmdbMediaType.movie &&
                  folder.mainEpisodeNumbers.length <= 1) {
                targetSeason = 1;
                targetEp = null;
                targetEpEnd = null;
              } else if (work.matchedSeason != null &&
                  work.matchedSeason! > 0) {
                targetSeason = work.matchedSeason!;
              }
            }
            resolved0 = _ResolvedEpisodeSlot(
              seasonNumber: targetSeason,
              episodeNumber: targetEp,
              episodeEnd: targetEp == null ? null : targetEpEnd,
              category: preSlot.category,
              extraType: preSlot.extraType,
              fractionalLabel: preSlot.fractionalLabel,
              extraTitleHint: preSlot.extraTitleHint,
              unnumberedStemKey: preSlot.category == EpisodeCategory.extra
                  ? (preSlot.unnumberedStemKey ??
                        (targetEp == null
                            ? _extraCollisionKey(rawVariant.fileName)
                            : null))
                  : (targetEp == null
                        ? (preSlot.unnumberedStemKey ??
                              _extraCollisionKey(rawVariant.fileName))
                        : null),
            );
          } else {
            final restoreToMain = shouldRestoreWeakExtraToMain(
              parsed,
              strongMainEpisodes,
            );
            resolved0 = _resolveEpisodeSlot(
              parsed: parsed,
              forceMain: restoreToMain,
              fallbackSeason: work.matchedSeason ?? folder.seasonHint ?? 1,
              isSingleMovieWork:
                  work.tmdbMediaType == TmdbMediaType.movie &&
                  folder.mainEpisodeNumbers.length <= 1,
              fileNameForKey: rawVariant.fileName,
              relativePathForKey: rawVariant.relativePath,
              folderTitle: folder.cleanTitle,
            );
          }

          resolved = resolved0;
          if (resolved.category == EpisodeCategory.main &&
              resolved.episodeNumber != null) {
            specialMapping = remapPlan?.resolveSpecial(
              resolved.seasonNumber,
              resolved.episodeNumber!,
            );
            if (specialMapping != null) {
              final bgmTitle = specialMapping.bangumiEpisode?.displayName
                  .trim();
              resolved = _ResolvedEpisodeSlot(
                seasonNumber: 0,
                episodeNumber:
                    specialMapping.tmdbSpecialEpisodeNumber ??
                    resolved0.episodeNumber,
                category: EpisodeCategory.extra,
                extraType: ExtraKind.sp,
                extraTitleHint: (bgmTitle != null && bgmTitle.isNotEmpty)
                    ? bgmTitle
                    : specialMapping.fallbackTitle,
                unnumberedStemKey:
                    specialMapping.tmdbSpecialEpisodeNumber == null
                    ? 'interspersed_${resolved0.episodeNumber}'
                    : null,
              );
            } else {
              final remapped = remapPlan?.resolve(
                resolved.seasonNumber,
                resolved.episodeNumber!,
              );
              // 多集合并区间：两端都能映射到同一目标季才保留区间，否则退化为起始集单集。
              final rangeEnd = resolved.episodeEnd;
              final remappedEnd = rangeEnd == null || remapPlan == null
                  ? rangeEnd
                  : remapPlan.resolveEpisodeEnd(
                      resolved.seasonNumber,
                      resolved.episodeNumber!,
                      rangeEnd,
                    );
              if (remapped != null) {
                resolved = _ResolvedEpisodeSlot(
                  seasonNumber: remapped.seasonNumber,
                  episodeNumber: remapped.episodeNumber,
                  episodeEnd: remappedEnd,
                  category: resolved.category,
                  extraType: resolved.extraType,
                  fractionalLabel: resolved.fractionalLabel,
                  extraTitleHint: resolved.extraTitleHint,
                );
              } else if (rangeEnd != remappedEnd) {
                resolved = _ResolvedEpisodeSlot(
                  seasonNumber: resolved.seasonNumber,
                  episodeNumber: resolved.episodeNumber,
                  episodeEnd: remappedEnd,
                  category: resolved.category,
                  extraType: resolved.extraType,
                  fractionalLabel: resolved.fractionalLabel,
                  extraTitleHint: resolved.extraTitleHint,
                  unnumberedStemKey: resolved.unnumberedStemKey,
                );
              }
            }
          }
        }

        final mappedSpecial =
            (resolved.category == EpisodeCategory.extra &&
                lockedExistingEp == null &&
                specialMapping == null)
            ? mappedSpecialsByPath[rawVariant.relativePath]
            : null;
        final isSingleMovieFeature =
            resolved.category == EpisodeCategory.main &&
            resolved.episodeNumber == null;
        final extraTagDisambiguator = _extraSubTagKey(
          resolved.category,
          resolved.extraType,
          resolved.extraTitleHint,
        );
        final isUnmappedExtra =
            resolved.category == EpisodeCategory.extra &&
            mappedSpecial == null &&
            specialMapping == null;
        final stemKey = isSingleMovieFeature
            ? 'feature'
            : isUnmappedExtra
            ? (resolved.unnumberedStemKey ??
                  SupplementarySubclassifier.buildExtraCanonicalMergeKey(
                    fileName: rawVariant.fileName,
                    relativePath: rawVariant.relativePath,
                    extraType: resolved.extraType,
                    titleHint: resolved.extraTitleHint,
                    workTitle: work.title,
                  ))
            : (resolved.episodeNumber == null
                  ? (resolved.unnumberedStemKey ??
                        _extraCollisionKey(rawVariant.fileName))
                  : (specialMapping != null
                        ? (resolved.unnumberedStemKey ?? extraTagDisambiguator)
                        : extraTagDisambiguator));
        final key =
            '${resolved.category.name}:${resolved.seasonNumber}:${resolved.episodeNumber ?? 'unnumbered'}${resolved.episodeEnd == null ? '' : '-${resolved.episodeEnd}'}:${resolved.extraType?.name ?? ''}:$stemKey';
        final epId =
            lockedExistingEp?.id ?? deterministicId('${work.id}::$key');

        var episode = episodeById[epId];
        final tmdbEp =
            mappedSpecial ??
            ((resolved.category == EpisodeCategory.main ||
                        specialMapping != null ||
                        lockedExistingEp != null) &&
                    resolved.episodeNumber != null
                ? tmdbByKey['${resolved.seasonNumber}:${resolved.episodeNumber}']
                : null);
        final bgmEp =
            specialMapping?.bangumiEpisode ??
            ((resolved.category == EpisodeCategory.main &&
                    resolved.episodeNumber != null)
                ? bgmByEp[resolved.episodeNumber!]
                : null);

        final defaultTitle = _buildDefaultEpisodeTitle(
          resolved,
          workTitle: work.title,
        );
        final resolvedEpNumber =
            mappedSpecial?.episodeNumber ?? resolved.episodeNumber;
        final tmdbTitle = tmdbEp?.title.trim();
        final bgmTitle = bgmEp?.displayName.trim();
        final rangeEnd =
            (resolved.category == EpisodeCategory.main &&
                resolved.episodeNumber != null &&
                specialMapping == null)
            ? resolved.episodeEnd
            : null;
        final rangeInfo = (rangeEnd == null)
            ? null
            : _composeRangeMetadata(
                season: resolved.seasonNumber,
                start: resolved.episodeNumber!,
                end: rangeEnd,
                tmdbByKey: tmdbByKey,
                bgmByEp: bgmByEp,
              );
        final String desiredTitle;
        if (rangeInfo?.title != null) {
          desiredTitle = rangeInfo!.title!;
        } else if (specialMapping != null) {
          final hasTmdbCjk =
              tmdbTitle != null &&
              RegExp(r'[\u4e00-\u9fff]').hasMatch(tmdbTitle);
          if (tmdbTitle != null &&
              tmdbTitle.isNotEmpty &&
              (hasTmdbCjk || bgmTitle == null || bgmTitle.isEmpty)) {
            desiredTitle = tmdbTitle;
          } else if (bgmTitle != null && bgmTitle.isNotEmpty) {
            desiredTitle = bgmTitle;
          } else {
            desiredTitle = defaultTitle;
          }
        } else {
          desiredTitle = (tmdbTitle != null && tmdbTitle.isNotEmpty)
              ? tmdbTitle
              : ((bgmTitle != null && bgmTitle.isNotEmpty)
                    ? bgmTitle
                    : (lockedExistingEp?.title?.trim().isNotEmpty == true
                          ? lockedExistingEp!.title!.trim()
                          : defaultTitle));
        }

        if (episode == null) {
          episode = Episode(
            id: epId,
            workId: work.id,
            seasonNumber: resolved.seasonNumber,
            episodeNumber: resolvedEpNumber,
            episodeNumberEnd: rangeEnd,
            category: resolved.category,
            extraType: resolved.extraType,
            title: desiredTitle,
            overview: rangeInfo?.overview ?? tmdbEp?.overview,
            stillPath: tmdbEp?.stillPath,
          );
          episodesToUpsert[epId] = episode;
          episodeById[epId] = episode;
        } else if ((tmdbEp != null &&
                (episode.title != tmdbEp.title ||
                    episode.stillPath != tmdbEp.stillPath)) ||
            episode.episodeNumber != resolvedEpNumber ||
            episode.episodeNumberEnd != rangeEnd ||
            episode.extraType != resolved.extraType ||
            episode.title != desiredTitle) {
          episode = Episode(
            id: episode.id,
            workId: episode.workId,
            seasonNumber: resolved.seasonNumber,
            episodeNumber: resolvedEpNumber,
            episodeNumberEnd: rangeEnd,
            category: resolved.category,
            extraType: resolved.extraType,
            title: desiredTitle,
            overview:
                rangeInfo?.overview ?? tmdbEp?.overview ?? episode.overview,
            stillPath: tmdbEp?.stillPath ?? episode.stillPath,
          );
          episodesToUpsert[epId] = episode;
          episodeById[epId] = episode;
        }
        episodeId = episode.id;
      }

      final subtitleGroup =
          rawVariant.subtitleGroup ??
          parsed?.subtitleGroup ??
          _extractSubtitleGroupFromPaths(rawVariant.externalSubtitles);
      final variant = MediaVariant(
        id: variantId,
        workId: work.id,
        episodeId: episodeId,
        sourceId: rawVariant.sourceId,
        relativePath: rawVariant.relativePath,
        fileName: rawVariant.fileName,
        fileSize: rawVariant.fileSize,
        assetKind: rawVariant.assetKind,
        releaseGroup: rawVariant.releaseGroup ?? parsed?.releaseGroup,
        subtitleGroup: subtitleGroup,
        videoCodec: rawVariant.videoCodec ?? parsed?.videoCodec,
        bitDepth: rawVariant.bitDepth ?? parsed?.bitDepth,
        resolution: rawVariant.resolution ?? parsed?.resolution,
        audioCodec: rawVariant.audioCodec ?? parsed?.audioCodec,
        externalSubtitles: rawVariant.externalSubtitles,
        mappingLocked: preserveVariantLock,
        workLocked: existingVariant?.workLocked ?? rawVariant.workLocked,
        assetScope: (existingVariant != null && existingVariant.scopeLocked)
            ? existingVariant.assetScope
            : rawVariant.assetScope,
        scopeLocked: existingVariant?.scopeLocked ?? rawVariant.scopeLocked,
      );
      variantsToUpsert.add(variant);
    }

    await _repository.runInTransaction(() async {
      if (episodesToUpsert.isNotEmpty) {
        await _repository.upsertEpisodesBatch(
          episodesToUpsert.values.toList(growable: false),
        );
      }
      if (variantsToUpsert.isNotEmpty) {
        await _repository.upsertMediaVariantsBatch(variantsToUpsert);
      }
      await _repository.deleteOrphanEpisodes(work.id);
    });

    if (preloadedSourceVariantsById != null) {
      for (final variant in variantsToUpsert) {
        preloadedSourceVariantsById[variant.id] = variant;
      }
    }
  }

  /// 保存待人工复核的 Top-5 候选列表。
  Future<void> saveTopCandidates(
    String workId,
    List<ScoredTmdbCandidate> candidates,
  ) async {
    final top = candidates.take(5).toList();
    final summaries = <ScrapeCandidateSummary>[];
    for (var i = 0; i < top.length; i++) {
      final item = top[i];
      int? episodeCount;
      if (item.detail.mediaType == TmdbMediaType.movie) {
        episodeCount = 1;
      } else if (item.detail.seasons.isNotEmpty) {
        final mainTotal = item.detail.seasons
            .where((s) => s.seasonNumber > 0)
            .fold<int>(0, (sum, s) => sum + s.episodeCount);
        if (mainTotal > 0) episodeCount = mainTotal;
      }
      summaries.add(
        ScrapeCandidateSummary(
          workId: workId,
          tmdbId: item.detail.tmdbId,
          mediaType: item.detail.mediaType,
          title: item.detail.title,
          originalTitle: item.detail.originalTitle,
          year: item.detail.year,
          posterPath: item.detail.posterPath,
          episodeCount: episodeCount,
          score: item.score,
          rank: i + 1,
          reasons: item.reasons,
        ),
      );
    }
    await _repository.saveScrapeCandidates(workId, summaries);
  }

  String _extraCollisionKey(String fileName) {
    final bracketExtras = RegExp(r'\[([^\]]+)\]')
        .allMatches(fileName)
        .map((m) => m.group(1)!.trim().toLowerCase())
        .where(
          (t) =>
              t.isNotEmpty &&
              !RegExp(
                r'^(?:ma10p|hi10p|10bit|8bit|x264|x265|hevc|avc|flac|aac|ac3|dts|\d+x\d+|\d+p|[0-9a-f]{8})$',
              ).hasMatch(t),
        )
        .join('_');
    final strippedStem = fileName
        .toLowerCase()
        .replaceAll(RegExp(r'\[[^\]]+\]|\([^)]+\)'), ' ')
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (bracketExtras.isEmpty) return strippedStem;
    return '$strippedStem::$bracketExtras';
  }

  static String _extraSubTagKey(
    EpisodeCategory category,
    ExtraKind? extraType,
    String? titleHint,
  ) {
    if (category != EpisodeCategory.extra || titleHint == null) return '';
    final upper = titleHint.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    if (upper.startsWith('TVCM')) return 'tvcm';
    if (upper.startsWith('BDCM')) return 'bdcm';
    if (upper.startsWith('PVCM')) return 'pvcm';
    if (upper.startsWith('CM')) return 'cm';
    if (upper.startsWith('TRAILER')) return 'trailer';
    if (upper.startsWith('TEASER')) return 'teaser';
    if (upper.startsWith('WEBPREVIEW')) return 'webpreview';
    if (upper.startsWith('PREVIEW') || upper.startsWith('预告')) {
      return 'preview';
    }
    if (upper.startsWith('SPOT')) return 'spot';
    if (upper.startsWith('PV')) return 'pv';
    if (upper.startsWith('MENUEX')) return 'menuex';
    if (upper.startsWith('MENU')) return 'menu';
    if (upper.startsWith('NCOPED')) return 'ncoped';
    if (upper.startsWith('NCOP')) return 'ncop';
    if (upper.startsWith('NCED')) return 'nced';
    if (upper.startsWith('MAKING')) return 'making';
    if (upper.startsWith('INTERVIEW') || upper.startsWith('IV')) {
      return 'interview';
    }
    if (upper.startsWith('DIGEST')) return 'digest';
    if (upper.startsWith('EVENT')) return 'event';
    return '';
  }

  _ResolvedEpisodeSlot _resolveEpisodeSlot({
    required ParsedBdripRelease parsed,
    bool forceMain = false,
    int fallbackSeason = 1,
    bool isSingleMovieWork = false,
    String? fileNameForKey,
    String? relativePathForKey,
    String? folderTitle,
  }) {
    if (parsed.category == EpisodeCategory.extra && !forceMain) {
      if (fileNameForKey != null) {
        final slot = ScrapeDomainAdapter.resolveExtraSlotAssignment(
          fileName: fileNameForKey,
          relativePath: relativePathForKey ?? fileNameForKey,
          parsed: parsed,
          folderCleanTitle: folderTitle,
        );
        return _ResolvedEpisodeSlot(
          seasonNumber: slot.seasonNumber,
          episodeNumber: slot.episodeNumber,
          category: slot.category,
          extraType: slot.extraType,
          fractionalLabel: slot.fractionalLabel,
          extraTitleHint: slot.extraTitleHint,
          unnumberedStemKey: slot.unnumberedStemKey,
        );
      }
      final isSeasonZeroSpecial =
          parsed.extraType == ExtraKind.ova ||
          parsed.extraType == ExtraKind.sp ||
          parsed.extraType == ExtraKind.mv;
      return _ResolvedEpisodeSlot(
        seasonNumber: isSeasonZeroSpecial ? 0 : parsed.season,
        episodeNumber: parsed.episode,
        category: EpisodeCategory.extra,
        extraType: parsed.extraType,
        fractionalLabel: parsed.fractionalEpisode,
      );
    }

    return _ResolvedEpisodeSlot(
      seasonNumber: isSingleMovieWork
          ? 1
          : (forceMain && parsed.season == 0 ? fallbackSeason : parsed.season),
      episodeNumber: isSingleMovieWork ? null : parsed.episode,
      category: EpisodeCategory.main,
      extraType: null,
      unnumberedStemKey: parsed.episode == null && fileNameForKey != null
          ? _extraCollisionKey(fileNameForKey)
          : null,
    );
  }

  String _buildDefaultEpisodeTitle(
    _ResolvedEpisodeSlot slot, {
    String? workTitle,
  }) {
    if (slot.fractionalLabel != null && slot.fractionalLabel!.isNotEmpty) {
      return 'SP ${slot.fractionalLabel}';
    }
    if (slot.category == EpisodeCategory.extra) {
      final hint = slot.extraTitleHint?.trim();
      if (hint != null && hint.isNotEmpty) {
        return hint;
      }
      final label = (slot.extraType?.name ?? 'EXTRA').toUpperCase();
      if (slot.episodeNumber == null) return label;
      return '$label ${slot.episodeNumber.toString().padLeft(2, '0')}';
    }
    if (slot.episodeNumber == null) {
      final trimmed = workTitle?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
      return '正片';
    }
    if (slot.episodeEnd != null) {
      return '第 ${slot.episodeNumber}-${slot.episodeEnd} 话';
    }
    return '第 ${slot.episodeNumber} 话';
  }

  /// 为多集合并条目合成标题与简介。
  ///
  /// 标题：优先 TMDB 各集标题、缺失回退 Bangumi 标题；跨度 2–3 集用 ` / ` 连接，
  /// 更大跨度用 `{首集标题} ～ {末集标题}`；任一所需标题缺失则返回 `null`（由调用方回退默认标题）。
  /// 简介：跨度不超过 3 集时用空行连接各集简介，否则 `null`（沿用首集简介）。
  static ({String? title, String? overview}) _composeRangeMetadata({
    required int season,
    required int start,
    required int end,
    required Map<String, TmdbEpisodeDetail> tmdbByKey,
    required Map<int, BangumiEpisodeEntry> bgmByEp,
  }) {
    String? titleOf(int ep) {
      final tmdb = tmdbByKey['$season:$ep']?.title.trim();
      if (tmdb != null && tmdb.isNotEmpty) return tmdb;
      final bgm = bgmByEp[ep]?.displayName.trim();
      if (bgm != null && bgm.isNotEmpty) return bgm;
      return null;
    }

    final span = end - start + 1;
    String? title;
    if (span <= 3) {
      final titles = [for (var e = start; e <= end; e++) titleOf(e)];
      if (titles.every((t) => t != null)) title = titles.join(' / ');
    } else {
      final first = titleOf(start);
      final last = titleOf(end);
      if (first != null && last != null) title = '$first ～ $last';
    }
    String? overview;
    if (span <= 3) {
      final parts = [
        for (var e = start; e <= end; e++)
          if (tmdbByKey['$season:$e']?.overview?.trim().isNotEmpty ?? false)
            tmdbByKey['$season:$e']!.overview!.trim(),
      ];
      if (parts.isNotEmpty) overview = parts.join('\n\n');
    }
    return (title: title, overview: overview);
  }

  String? _extractSubtitleGroupFromPaths(List<String> paths) {
    for (final path in paths) {
      final fileName = path.split('/').last;
      final parsed = BdripParser.parseFileName(fileName);
      if (parsed.subtitleGroup != null && parsed.subtitleGroup!.isNotEmpty) {
        return parsed.subtitleGroup;
      }
      if (parsed.releaseGroup != null && parsed.releaseGroup!.isNotEmpty) {
        return parsed.releaseGroup;
      }
    }
    return null;
  }

  /// 将人工指定的 TMDB ID 写回本地顶层目录名称并同步更新变体路径。
  Future<List<MediaVariant>> tryAppendTmdbIdToLocalFolder(
    List<MediaVariant> variants,
    int tmdbId,
  ) async {
    final first = variants.first;
    final source = await _repository.findSourceById(first.sourceId);
    if (source == null || source.kind != MediaSourceKind.local) return variants;

    final topFolder = first.relativePath.split('/').first;
    if (topFolder.isEmpty || topFolder == first.fileName) return variants;
    if (RegExp(r'\[tmdbid=\d+\]', caseSensitive: false).hasMatch(topFolder)) {
      return variants;
    }

    final oldDir = Directory(p.join(source.location, topFolder));
    if (!await oldDir.exists()) return variants;

    final newFolderName = '$topFolder [tmdbid=$tmdbId]';
    final newDir = Directory(p.join(source.location, newFolderName));
    if (await newDir.exists()) return variants;

    await oldDir.rename(newDir.path);
    final updatedVariants = <MediaVariant>[];
    for (final variant in variants) {
      if (!variant.relativePath.startsWith('$topFolder/')) {
        updatedVariants.add(variant);
        continue;
      }
      final newRel =
          '$newFolderName/${variant.relativePath.substring(topFolder.length + 1)}';
      final nextVariant = variant.copyWith(relativePath: newRel);
      await _repository.upsertMediaVariant(nextVariant);
      updatedVariants.add(nextVariant);
    }
    return updatedVariants;
  }
}

class _ResolvedEpisodeSlot {
  const _ResolvedEpisodeSlot({
    required this.seasonNumber,
    required this.episodeNumber,
    required this.category,
    required this.extraType,
    this.episodeEnd,
    this.fractionalLabel,
    this.extraTitleHint,
    this.unnumberedStemKey,
  });

  final int seasonNumber;
  final int? episodeNumber;

  /// 多集合并区间的结束集（仅正片）。
  final int? episodeEnd;
  final EpisodeCategory category;
  final ExtraKind? extraType;
  final String? fractionalLabel;
  final String? extraTitleHint;
  final String? unnumberedStemKey;
}
