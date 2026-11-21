import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_util;

import '../../domain/models/episode.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/sources/artwork_crop_math.dart';
import '../../infrastructure/cache/local_artwork_cropper.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/fanart_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_http_client.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../scraping/scrape_work_persister.dart';
import 'library_providers.dart';
import 'scraping_providers.dart';
import 'work_merge_actions.dart';
import 'work_split_and_series_actions.dart';

export 'work_merge_actions.dart' show WorkMergeOutcome;
export 'work_split_and_series_actions.dart' show HybridMatchRequest;

/// 作品详情页封面/背景图/透明徽标选择弹窗中的单张候选图片（支持 Bangumi、TMDB 与 Fanart.tv 混排标识）。
class WorkArtworkOption {
  /// 创建候选图条目。
  const WorkArtworkOption({
    required this.filePath,
    required this.sourceLabel,
    this.isBangumi = false,
    this.isFanart = false,
    this.isSeasonPoster = false,
    this.langTag,
    this.isHd = false,
    this.width,
    this.height,
  });

  /// 图片 URL、TMDB 路径或本地文件路径。
  final String filePath;

  /// 来源标签（如 `Bangumi`、`TMDB 第 2 季`、`TMDB`、`Fanart.tv`）。
  final String sourceLabel;

  /// 是否来自 Bangumi 官方封面。
  final bool isBangumi;

  /// 是否来自 Fanart.tv 透明徽标源。
  final bool isFanart;

  /// 是否为 TMDB 匹配季专属封面。
  final bool isSeasonPoster;

  /// 可选语言标签（如 `简中`、`繁中`、`日文`、`英文`、`无字`）。
  final String? langTag;

  /// 是否为高清透明徽标档位（如 Fanart.tv `hdtvlogo`/`hdmovielogo`）。
  final bool isHd;

  /// 原图真实像素宽度（若已知）。
  final int? width;

  /// 原图真实像素高度（若已知）。
  final int? height;

  /// 格式化原图分辨率文本（如 `2000×3000`）。
  String? get resolutionLabel =>
      (width != null && height != null && width! > 0 && height! > 0)
      ? '$width×$height'
      : (isHd ? 'HD' : null);
}

/// 作品可用的候选海报、背景图与透明徽标集合。
class WorkArtworkOptions {
  /// 创建候选集合实例。
  const WorkArtworkOptions({
    this.posters = const [],
    this.backdrops = const [],
    this.logos = const [],
  });

  /// 全部可选海报（含 Bangumi 与 TMDB 季/系列封面）。
  final List<WorkArtworkOption> posters;

  /// 全部可选横版背景图。
  final List<WorkArtworkOption> backdrops;

  /// 全部可选透明标题徽标（聚合 TMDB 与 Fanart.tv）。
  final List<WorkArtworkOption> logos;
}

/// 单个物理文件到逻辑剧集的手动重映射请求。
class EpisodeFileMappingEdit {
  /// 创建文件映射更新条目。
  const EpisodeFileMappingEdit({
    required this.variantId,
    required this.category,
    required this.seasonNumber,
    required this.episodeNumber,
    this.extraType,
    this.lockMapping = true,
  });

  /// 物理版本 ID。
  final String variantId;

  /// 目标分类（正片 / 特典）。
  final EpisodeCategory category;

  /// 目标季号（特典建议为 `0`）。
  final int seasonNumber;

  /// 目标集号或特典序号。
  final int episodeNumber;

  /// 特典细分类型。
  final ExtraKind? extraType;

  /// 是否持久化锁定该物理文件的映射关系（默认 `true`）。
  final bool lockMapping;
}

/// 作品管理操作服务 Provider（供详情页管理菜单、待复核抽屉与设置恢复列表使用）。
final workManagementProvider = Provider<WorkManagementActions>((ref) {
  return WorkManagementActions(ref);
});

/// 面向 UI 层的强类型作品管理协调器（隔离 DB、TMDB 与文件缓存细节）。
class WorkManagementActions {
  /// 创建作品管理协调器。
  WorkManagementActions(this._ref);

  final Ref _ref;
  final Set<String> _bangumiScoreBackfillInFlight = <String>{};

  /// 静默补齐既有作品缺失的 Bangumi 评分与关联 Bangumi ID（不阻塞 UI，失败安全忽略）。
  Future<void> ensureWorkBangumiScore(String workId) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existing = await repo.findWorkById(workId);
    if (existing == null ||
        (existing.bangumiScore != null && existing.bangumiScore! > 0)) {
      return;
    }
    if (!_bangumiScoreBackfillInFlight.add(workId)) return;
    try {
      final config = await _ref.read(tmdbNetworkConfigProvider.future);
      final scheduler = _ref.read(priorityHttpSchedulerProvider);
      final cooldown = _ref.read(domainCooldownRegistryProvider);
      final client = TmdbHttpClient(
        config: config,
        scheduler: scheduler,
        cooldownRegistry: cooldown,
      );
      final bgm = BangumiService(httpClient: client);

      var targetBangumiId = existing.bangumiId;
      double? resolvedScore;
      String? resolvedPoster = existing.bangumiPosterPath;

      if (targetBangumiId != null) {
        final detail = await bgm.getSubjectDetail(
          targetBangumiId,
          priority: RequestPriority.background,
        );
        resolvedScore = detail?.score;
        resolvedPoster ??= detail?.posterUrl;
      } else if (existing.title.trim().isNotEmpty) {
        final candidates = await bgm.searchSubjects(
          existing.title.trim(),
          priority: RequestPriority.background,
        );
        final normTitle = _normalizeCompareTitle(existing.title);
        final normOriginal = _normalizeCompareTitle(
          existing.originalTitle ?? '',
        );
        for (final c in candidates) {
          final yearMatch =
              existing.year == null ||
              c.year == null ||
              (existing.year! - c.year!).abs() <= 1;
          if (!yearMatch) continue;
          final cTitles = <String>{
            _normalizeCompareTitle(c.nameCn),
            _normalizeCompareTitle(c.name),
            ...c.aliases.map(_normalizeCompareTitle),
          }..removeWhere((s) => s.isEmpty);
          final exactHit =
              (normTitle.isNotEmpty && cTitles.contains(normTitle)) ||
              (normOriginal.isNotEmpty && cTitles.contains(normOriginal));
          if (!exactHit) continue;
          final detail = await bgm.getSubjectDetail(
            c.id,
            priority: RequestPriority.background,
          );
          if (detail != null && detail.score != null && detail.score! > 0) {
            targetBangumiId = detail.id;
            resolvedScore = detail.score;
            resolvedPoster ??= detail.posterUrl;
            break;
          }
        }
      }

      if (resolvedScore != null && resolvedScore > 0) {
        await repo.upsertWork(
          existing.copyWith(
            bangumiId: targetBangumiId ?? existing.bangumiId,
            bangumiScore: resolvedScore,
            bangumiPosterPath: resolvedPoster ?? existing.bangumiPosterPath,
          ),
        );
        _invalidateWork(workId);
      }
    } catch (error) {
      // 静默补全失败时保持无评分状态，不弹出报错干扰阅读。
      developer.log('可恢复异常已记录', name: 'konata.work_management_provider', error: error);
    } finally {
      _bangumiScoreBackfillInFlight.remove(workId);
    }
  }

  static String _normalizeCompareTitle(String raw) {
    return raw
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_:：·・!！?？,，.。/\\()（）\[\]【】「」『』]'), '')
        .trim();
  }

  /// 手动更新作品基础元数据并锁定，防止后续重扫或刷新覆盖。
  Future<void> updateWorkManualMetadata({
    required String workId,
    required String title,
    String? originalTitle,
    int? year,
    String? overview,
    bool lockMetadata = true,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existing = await repo.findWorkById(workId);
    if (existing == null) {
      throw StateError('作品不存在: $workId');
    }
    final nextLocked = lockMetadata || existing.metadataLocked;
    final next = Work(
      id: existing.id,
      tmdbId: existing.tmdbId,
      tmdbMediaType: existing.tmdbMediaType,
      bangumiId: existing.bangumiId,
      tvdbId: existing.tvdbId,
      matchedSeason: existing.matchedSeason,
      title: title.trim().isEmpty ? existing.title : title.trim(),
      originalTitle: (originalTitle ?? '').trim().isEmpty
          ? null
          : originalTitle!.trim(),
      year: year,
      overview: (overview ?? '').trim().isEmpty ? null : overview!.trim(),
      posterPath: existing.posterPath,
      posterFallback: existing.posterFallback,
      bangumiPosterPath: existing.bangumiPosterPath,
      backdropPath: existing.backdropPath,
      logoPath: existing.logoPath,
      voteAverage: existing.voteAverage,
      bangumiScore: existing.bangumiScore,
      folderTmdbHint: existing.folderTmdbHint,
      isManualLocked: existing.isManualLocked || nextLocked,
      metadataLocked: nextLocked,
      posterLocked: existing.posterLocked,
      backdropLocked: existing.backdropLocked,
      logoLocked: existing.logoLocked,
      logoNegativeUntil: existing.logoNegativeUntil,
      logoNegativeMask: existing.logoNegativeMask,
      isHidden: existing.isHidden,
      keepHidden: existing.keepHidden,
      scrapeStatus: existing.scrapeStatus,
      reviewReason: null,
      seriesId: existing.seriesId,
      seriesOrder: existing.seriesOrder,
      seriesLabel: existing.seriesLabel,
      seriesLocked: existing.seriesLocked,
    );
    await repo.upsertWork(next);
    await _ref.read(photosStorageProvider).renameWorkFolderIfNeeded(workId, next.title);
    _invalidateWork(workId);
  }

  /// 批量重映射作品下物理视频文件的正片/特典归属、季号与集号，并按需写入持久化锁定。
  Future<void> saveEpisodeMappings({
    required String workId,
    required List<EpisodeFileMappingEdit> mappings,
  }) async {
    if (mappings.isEmpty) return;
    final repo = _ref.read(libraryRepositoryProvider);
    final existingEpisodes = await repo.getEpisodesByWork(workId);
    final existingVariants = await repo.getVariantsByWork(workId);

    final episodeByKey = <String, Episode>{
      for (final ep in existingEpisodes)
        '${ep.category.name}:${ep.seasonNumber}:${ep.episodeNumber}:${ep.extraType?.name ?? ''}':
            ep,
    };
    final variantById = {for (final v in existingVariants) v.id: v};
    var anyLocked = false;

    for (final edit in mappings) {
      final variant = variantById[edit.variantId];
      if (variant == null) continue;

      final season = edit.category == EpisodeCategory.extra
          ? 0
          : (edit.seasonNumber <= 0 ? 1 : edit.seasonNumber);
      final epNum = edit.episodeNumber <= 0 ? 1 : edit.episodeNumber;
      final extraKind = edit.category == EpisodeCategory.extra
          ? (edit.extraType ?? ExtraKind.sp)
          : null;
      final key =
          '${edit.category.name}:$season:$epNum:${extraKind?.name ?? ''}';

      var targetEpisode = episodeByKey[key];
      if (targetEpisode == null) {
        final label = edit.category == EpisodeCategory.extra
            ? '${(extraKind?.name ?? 'SP').toUpperCase()} ${epNum.toString().padLeft(2, '0')}'
            : '第 $epNum 话';
        targetEpisode = Episode(
          id: ScrapeWorkPersister.deterministicId('$workId::$key'),
          workId: workId,
          seasonNumber: season,
          episodeNumber: epNum,
          category: edit.category,
          extraType: extraKind,
          title: label,
        );
        await repo.upsertEpisode(targetEpisode);
        episodeByKey[key] = targetEpisode;
      }

      final changed = variant.episodeId != targetEpisode.id;
      final nextLock = edit.lockMapping || changed || variant.mappingLocked;
      if (nextLock) anyLocked = true;
      if (changed || variant.mappingLocked != nextLock) {
        await repo.upsertMediaVariant(
          variant.copyWith(
            episodeId: targetEpisode.id,
            mappingLocked: nextLock,
          ),
        );
      }
    }

    if (anyLocked) {
      final work = await repo.findWorkById(workId);
      if (work != null && !work.isManualLocked) {
        await repo.upsertWork(work.copyWith(isManualLocked: true));
      }
    }

    await repo.deleteOrphanEpisodes(workId);
    _invalidateWork(workId);
  }

  /// 获取作品对应 Bangumi、TMDB 与 Fanart.tv 候选图像集合（支持海报、背景图与透明徽标）。
  Future<WorkArtworkOptions> fetchWorkArtworkOptions(
    Work work, {
    bool includeLogos = false,
  }) async {
    final posters = <WorkArtworkOption>[];
    final backdrops = <WorkArtworkOption>[];
    final logos = <WorkArtworkOption>[];
    final seenPosters = <String>{};
    final seenBackdrops = <String>{};
    final seenLogos = <String>{};

    void addPoster(
      String? path, {
      required String sourceLabel,
      bool isBangumi = false,
      bool isSeasonPoster = false,
      int? width,
      int? height,
    }) {
      final clean = path?.trim();
      if (clean == null || clean.isEmpty) return;
      if (seenPosters.add(clean)) {
        posters.add(
          WorkArtworkOption(
            filePath: clean,
            sourceLabel: sourceLabel,
            isBangumi: isBangumi,
            isSeasonPoster: isSeasonPoster,
            width: width,
            height: height,
          ),
        );
      }
    }

    void addBackdrop(
      String? path, {
      String sourceLabel = 'TMDB',
      int? width,
      int? height,
    }) {
      final clean = path?.trim();
      if (clean == null || clean.isEmpty) return;
      if (seenBackdrops.add(clean)) {
        backdrops.add(
          WorkArtworkOption(
            filePath: clean,
            sourceLabel: sourceLabel,
            width: width,
            height: height,
          ),
        );
      }
    }

    void addLogo(
      String? path, {
      required String sourceLabel,
      bool isFanart = false,
      String? langTag,
      bool isHd = false,
      int? width,
      int? height,
    }) {
      final clean = path?.trim();
      if (clean == null || clean.isEmpty) return;
      if (seenLogos.add(clean)) {
        logos.add(
          WorkArtworkOption(
            filePath: clean,
            sourceLabel: sourceLabel,
            isFanart: isFanart,
            langTag: langTag,
            isHd: isHd,
            width: width,
            height: height,
          ),
        );
      }
    }

    // 1. 优先加入已保存或在线拉取的 Bangumi 官方封面
    addPoster(
      work.bangumiPosterPath,
      sourceLabel: 'Bangumi',
      isBangumi: true,
    );

    final config = await _ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final cooldown = _ref.read(domainCooldownRegistryProvider);
    final client = TmdbHttpClient(
      config: config,
      scheduler: scheduler,
      cooldownRegistry: cooldown,
    );

    try {
      if (!includeLogos &&
          work.bangumiPosterPath == null &&
          work.bangumiId != null) {
        try {
          final bgm = BangumiService(httpClient: client);
          final subject = await bgm.getSubjectDetail(
            work.bangumiId!,
            priority: RequestPriority.interactive,
          );
          addPoster(
            subject?.posterUrl,
            sourceLabel: 'Bangumi',
            isBangumi: true,
          );
        } catch (error) {
          developer.log(
            '可恢复异常已记录',
            name: 'konata.work_management_provider',
            error: error,
          );
        }
      }

      int? resolvedTvdbId = work.tvdbId;

      // 2. 拉取 TMDB 分季封面、系列主封面、背景图及透明徽标候选集
      if (work.tmdbId != null &&
          work.tmdbMediaType != null &&
          config.credential.trim().isNotEmpty) {
        try {
          final tmdb = TmdbService(httpClient: client);
          final detail = await tmdb.getWorkDetail(
            work.tmdbId!,
            work.tmdbMediaType!,
            priority: RequestPriority.interactive,
            includeEnglishImages: true,
          );
          if (detail != null) {
            resolvedTvdbId ??= detail.tvdbId;
            final posterDimsByPath = <String, (int?, int?)>{
              for (final item in detail.candidatePosters)
                item.filePath.trim(): (item.width, item.height),
            };
            final backdropDimsByPath = <String, (int?, int?)>{
              for (final item in detail.candidateBackdrops)
                item.filePath.trim(): (item.width, item.height),
            };

            if (work.matchedSeason != null &&
                work.tmdbMediaType == TmdbMediaType.tv) {
              final seasonSummary = detail.seasons
                  .where((s) => s.seasonNumber == work.matchedSeason)
                  .firstOrNull;
              final seasonPath = seasonSummary?.posterPath?.trim();
              final seasonDims =
                  seasonPath != null ? posterDimsByPath[seasonPath] : null;
              addPoster(
                seasonSummary?.posterPath,
                sourceLabel: work.matchedSeason == 0
                    ? 'TMDB·SP'
                    : 'TMDB·S${work.matchedSeason}',
                isSeasonPoster: true,
                width: seasonDims?.$1,
                height: seasonDims?.$2,
              );
            }
            final defaultPosterDims = detail.posterPath != null
                ? posterDimsByPath[detail.posterPath!.trim()]
                : null;
            addPoster(
              detail.posterPath,
              sourceLabel: 'TMDB',
              width: defaultPosterDims?.$1,
              height: defaultPosterDims?.$2,
            );
            for (final item in detail.candidatePosters) {
              addPoster(
                item.filePath,
                sourceLabel: 'TMDB',
                width: item.width,
                height: item.height,
              );
            }
            final defaultBackdropDims = detail.backdropPath != null
                ? backdropDimsByPath[detail.backdropPath!.trim()]
                : null;
            addBackdrop(
              detail.backdropPath,
              width: defaultBackdropDims?.$1,
              height: defaultBackdropDims?.$2,
            );
            for (final item in detail.candidateBackdrops) {
              addBackdrop(
                item.filePath,
                width: item.width,
                height: item.height,
              );
            }

            if (includeLogos) {
              final mistagged = work.tmdbMediaType == TmdbMediaType.tv
                  ? TmdbService.tmdbMistaggedTvLogoTargets[work.tmdbId!]
                  : null;
              for (final item in detail.candidateLogos) {
                if (mistagged != null && mistagged.containsKey(item.filePath)) {
                  continue;
                }
                addLogo(
                  item.filePath,
                  sourceLabel: 'TMDB',
                  langTag: _formatLogoLanguageTag(
                    item.isoLanguage,
                    item.isoCountry,
                  ),
                  width: item.width,
                  height: item.height,
                );
              }
            }
          }
        } catch (error) {
          developer.log(
            '拉取 TMDB 候选图集失败，继续尝试其他来源',
            name: 'konata.work_management_provider',
            error: error,
          );
        }
      }

      // 3. 当打开「编辑标题徽标」时，实时聚合 Fanart.tv 透明徽标候选（自动绕过负缓存）
      if (includeLogos && config.isFanartAvailable) {
        if (resolvedTvdbId == null) {
          final snap = await _ref.read(bangumiTmdbSnapshotProvider.future);
          if (work.bangumiId != null && work.bangumiId! > 0) {
            for (final target in snap.index.lookup(work.bangumiId!)) {
              if (target.tvdbId != null && target.tvdbId! > 0) {
                resolvedTvdbId = target.tvdbId;
                break;
              }
            }
          }
          if (resolvedTvdbId == null &&
              work.tmdbId != null &&
              work.tmdbMediaType == TmdbMediaType.tv) {
            resolvedTvdbId = snap.index.lookupTvdbIdByTmdb(
              mediaType: TmdbMediaType.tv,
              tmdbId: work.tmdbId!,
            );
          }
        }
        final effectiveMediaType =
            work.tmdbMediaType ??
            (resolvedTvdbId != null ? TmdbMediaType.tv : null);
        if (effectiveMediaType != null) {
          final breaker = _ref.read(fanartCircuitBreakerProvider);
          final fanart = FanartService(
            httpClient: client,
            circuitBreaker: breaker,
          );
          try {
            final res = await fanart.fetchLogos(
              mediaType: effectiveMediaType,
              tmdbId: work.tmdbId,
              tvdbId: resolvedTvdbId,
              priority: RequestPriority.interactive,
            );
            _ref.read(fanartRelayHealthProvider.notifier).state =
                breaker.snapshot();
            for (final item in res.logos) {
              addLogo(
                item.url,
                sourceLabel: 'Fanart.tv',
                isFanart: true,
                langTag: _formatLogoLanguageTag(item.lang, null),
                isHd: item.kind.isHd,
              );
            }
          } catch (error) {
            _ref.read(fanartRelayHealthProvider.notifier).state =
                breaker.snapshot();
            developer.log(
              '拉取 Fanart.tv 候选透明徽标失败',
              name: 'konata.work_management_provider',
              error: error,
            );
          }
        }
      }
    } finally {
      client.close();
    }

    return WorkArtworkOptions(
      posters: posters,
      backdrops: backdrops,
      logos: logos,
    );
  }

  static String? _formatLogoLanguageTag(String? isoLang, String? isoCountry) {
    final rank = TmdbService.logoLanguageRank(isoLang, isoCountry);
    return switch (rank) {
      0 => '简中',
      1 => '繁中',
      2 => '日文',
      3 => '英文',
      4 => '无字',
      _ => null,
    };
  }

  /// 加载本地图片完整原分辨率位图句柄（供框选裁切弹窗无损预览与原图裁切使用）。
  Future<LoadedLocalArtwork> loadLocalArtworkForCrop(String filePath) {
    return LocalArtworkCropper.loadFullResolution(filePath);
  }

  /// 对本地原图执行固定比例高分辨率裁切，落盘写入统一 `photos/<作品名 [ID]>/` 目录并自动锁定生效。
  Future<String> cropAndSaveLocalArtwork({
    required Work work,
    required bool isPoster,
    required LoadedLocalArtwork source,
    required ArtworkNormalizedCropRect cropRect,
  }) async {
    final photos = _ref.read(photosStorageProvider);
    final savedPath = await LocalArtworkCropper.cropAndSaveToPhotos(
      source: source,
      cropRect: cropRect,
      photosStorage: photos,
      workId: work.id,
      workTitle: work.title,
      subfolder: isPoster ? PhotoSubfolder.posters : PhotoSubfolder.backdrops,
    );
    await updateWorkArtwork(
      workId: work.id,
      posterPath: isPoster ? savedPath : null,
      backdropPath: isPoster ? null : savedPath,
    );
    return savedPath;
  }

  /// 直接原样保存用户挑选的本地透明徽标图片至 `photos/<作品>/logos/`（保留透明通道不强制裁切）。
  Future<String> saveLocalLogoArtwork({
    required Work work,
    required String sourceFilePath,
  }) async {
    final file = File(sourceFilePath);
    if (!await file.exists()) {
      throw StateError('所选本地徽标文件不存在');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('所选本地徽标文件为空');
    }
    if (bytes.length > 8 * 1024 * 1024) {
      throw StateError('透明徽标文件体积超过 8 MB 上限');
    }
    final rawExt = path_util.extension(sourceFilePath).toLowerCase();
    final safeExt = switch (rawExt) {
      '.png' || '.webp' || '.jpg' || '.jpeg' || '.gif' => rawExt,
      _ => '.png',
    };
    final digest = PhotosStorage.shortDigest(
      '${work.id}::${bytes.length}::${DateTime.now().microsecondsSinceEpoch}',
    );
    final savedFile = await _ref.read(photosStorageProvider).writeArtwork(
      workId: work.id,
      subfolder: PhotoSubfolder.logos,
      fileKey: 'custom_$digest$safeExt',
      bytes: bytes,
      title: work.title,
    );
    if (savedFile == null) {
      throw StateError('保存本地透明徽标失败');
    }
    await updateWorkArtwork(workId: work.id, logoPath: savedFile.path);
    return savedFile.path;
  }

  /// 替换作品海报、背景图或透明标题徽标路径并分别持久化锁定。
  Future<void> updateWorkArtwork({
    required String workId,
    String? posterPath,
    String? backdropPath,
    String? logoPath,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existing = await repo.findWorkById(workId);
    if (existing == null) return;
    final lockPoster = posterPath != null ? true : existing.posterLocked;
    final lockBackdrop =
        backdropPath != null ? true : existing.backdropLocked;
    final lockLogo = logoPath != null ? true : existing.logoLocked;
    final next = existing.copyWith(
      posterPath: posterPath ?? existing.posterPath,
      backdropPath: backdropPath ?? existing.backdropPath,
      logoPath: logoPath ?? existing.logoPath,
      posterLocked: lockPoster,
      backdropLocked: lockBackdrop,
      logoLocked: lockLogo,
      clearLogoNegative: logoPath != null,
      isManualLocked: true,
    );
    await repo.upsertWork(next);
    await _ref.read(photosStorageProvider).renameWorkFolderIfNeeded(workId, next.title);
    _invalidateWork(workId);
  }

  /// 解除作品元数据锁定，并在已绑定 TMDB 时立即恢复自动抓取默认值。
  Future<Work?> resetMetadataLockToAuto(String workId) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existing = await repo.findWorkById(workId);
    if (existing == null) return null;
    final variants = await repo.getVariantsByWork(workId);
    final hasAnyMappingLock = variants.any((v) => v.mappingLocked);
    await repo.upsertWork(
      existing.copyWith(
        metadataLocked: false,
        isManualLocked:
            existing.tmdbId != null ||
            existing.posterLocked ||
            existing.backdropLocked ||
            existing.logoLocked ||
            hasAnyMappingLock,
      ),
    );
    if (existing.tmdbId != null && existing.tmdbMediaType != null) {
      return _ref.read(scrapeControllerProvider.notifier).rebindWork(
            workId: workId,
            tmdbId: existing.tmdbId!,
            mediaType: existing.tmdbMediaType!,
          );
    }
    _invalidateWork(workId);
    return repo.findWorkById(workId);
  }

  /// 解除海报、背景图或透明标题徽标锁定，并在具备条目 ID 时立即恢复自动抓取默认图像。
  Future<Work?> resetArtworkLockToAuto({
    required String workId,
    bool resetPoster = false,
    bool resetBackdrop = false,
    bool resetLogo = false,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existing = await repo.findWorkById(workId);
    if (existing == null) return null;
    final nextPosterLocked = resetPoster ? false : existing.posterLocked;
    final nextBackdropLocked = resetBackdrop ? false : existing.backdropLocked;
    final nextLogoLocked = resetLogo ? false : existing.logoLocked;
    final variants = await repo.getVariantsByWork(workId);
    final hasAnyMappingLock = variants.any((v) => v.mappingLocked);
    await repo.upsertWork(
      existing.copyWith(
        posterLocked: nextPosterLocked,
        backdropLocked: nextBackdropLocked,
        logoLocked: nextLogoLocked,
        clearLogoPath: resetLogo,
        clearLogoNegative: resetLogo,
        isManualLocked:
            existing.tmdbId != null ||
            existing.metadataLocked ||
            nextPosterLocked ||
            nextBackdropLocked ||
            nextLogoLocked ||
            hasAnyMappingLock,
      ),
    );
    if (existing.tmdbId != null && existing.tmdbMediaType != null) {
      if (resetLogo && !resetPoster && !resetBackdrop) {
        return _ref
            .read(scrapeControllerProvider.notifier)
            .ensureOrRescrapeWork(workId: workId, interactive: true);
      }
      return _ref.read(scrapeControllerProvider.notifier).rebindWork(
            workId: workId,
            tmdbId: existing.tmdbId!,
            mediaType: existing.tmdbMediaType!,
          );
    }
    _invalidateWork(workId);
    return repo.findWorkById(workId);
  }

  /// 解除作品下所有文件的人工映射锁定，并在已绑定 TMDB 时立即按自动规则重映射。
  Future<Work?> resetFileMappingsToAuto(String workId) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existing = await repo.findWorkById(workId);
    if (existing == null) return null;
    final variants = await repo.getVariantsByWork(workId);
    for (final v in variants) {
      if (v.mappingLocked) {
        await repo.upsertMediaVariant(v.copyWith(mappingLocked: false));
      }
    }
    await repo.upsertWork(
      existing.copyWith(
        isManualLocked:
            existing.tmdbId != null ||
            existing.metadataLocked ||
            existing.posterLocked ||
            existing.backdropLocked ||
            existing.logoLocked,
      ),
    );
    if (existing.tmdbId != null && existing.tmdbMediaType != null) {
      return _ref.read(scrapeControllerProvider.notifier).rebindWork(
            workId: workId,
            tmdbId: existing.tmdbId!,
            mediaType: existing.tmdbMediaType!,
          );
    }
    _invalidateWork(workId);
    return repo.findWorkById(workId);
  }

  /// 隐藏指定作品（从主媒体库视图剔除）。
  Future<void> hideWork(String workId, {bool keepHidden = true}) async {
    final repo = _ref.read(libraryRepositoryProvider);
    await repo.setWorkHidden(workId, isHidden: true, keepHidden: keepHidden);
    _invalidateWork(workId);
  }

  /// 恢复展示已隐藏的作品。
  Future<void> unhideWork(String workId) async {
    final repo = _ref.read(libraryRepositoryProvider);
    await repo.setWorkHidden(workId, isHidden: false, keepHidden: false);
    _invalidateWork(workId);
  }

  /// 仅从媒体库移除作品记录（绝不删除物理源文件），可选把所属目录写入忽略名单。
  Future<void> deleteWorkFromLibrary(
    String workId, {
    bool addToIgnoreList = false,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    if (addToIgnoreList) {
      final variants = await repo.getVariantsByWork(workId);
      if (variants.isNotEmpty) {
        final folderRel = _deriveFolderPath(variants.first.relativePath);
        if (folderRel.isNotEmpty) {
          await repo.addIgnoredFolder(variants.first.sourceId, folderRel);
        }
      }
    }
    await repo.deleteWork(workId);
    await _ref.read(photosStorageProvider).deleteWorkPhotos(workId);
    clearWorkRedirectsForWork(_ref, workId);
    _invalidateWork(workId);
  }

  /// 执行 Bangumi 独立条目 × TMDB 指定季/集双源混合绑定并写入锁定（0 正片附属条目自动并入已有同条目）。
  Future<Work> bindWorkHybrid({
    required String workId,
    required HybridMatchRequest request,
  }) async {
    final autoMerged = await tryAutoMergeSupplementaryWork(
      _ref,
      sourceWorkId: workId,
      bangumiId: request.bangumiSubject.id,
      tmdbId: request.tmdbDetail.tmdbId,
      tmdbMediaType: request.tmdbDetail.mediaType,
      matchedSeason: request.tmdbSeasonNumber,
    );
    if (autoMerged != null) return autoMerged;
    final updated = await executeHybridBind(
      _ref,
      workId: workId,
      request: request,
    );
    await _ref
        .read(photosStorageProvider)
        .renameWorkFolderIfNeeded(updated.id, updated.title);
    _invalidateWork(workId);
    return updated;
  }

  /// 将既有作品绑定到纯 Bangumi 独立条目（无需 TMDB）并写入锁定（0 正片附属条目自动并入已有同条目）。
  Future<Work> bindWorkBangumiOnly({
    required String workId,
    required BangumiSubjectCandidate bangumiSubject,
  }) async {
    final autoMerged = await tryAutoMergeSupplementaryWork(
      _ref,
      sourceWorkId: workId,
      bangumiId: bangumiSubject.id,
    );
    if (autoMerged != null) return autoMerged;
    final updated = await executeBangumiOnlyBind(
      _ref,
      workId: workId,
      bangumiSubject: bangumiSubject,
    );
    await _ref
        .read(photosStorageProvider)
        .renameWorkFolderIfNeeded(updated.id, updated.title);
    _invalidateWork(workId);
    return updated;
  }

  /// 将整部作品或指定变体集直接并入库内已确认作品，并在空壳时自动删除原条目。
  Future<WorkMergeOutcome> mergeWorkIntoExisting({
    required String sourceWorkId,
    required String targetWorkId,
    EpisodeCategory? forceCategory,
  }) {
    return executeMergeWorkIntoExisting(
      _ref,
      sourceWorkId: sourceWorkId,
      targetWorkId: targetWorkId,
      forceCategory: forceCategory,
    );
  }

  /// 将勾选的物理文件迁移至其他库内作品，若原条目无剩余文件则自动清理空壳。
  Future<WorkMergeOutcome> moveVariantsToExistingWork({
    required String sourceWorkId,
    required List<String> variantIds,
    required String targetWorkId,
    required EpisodeCategory targetCategory,
  }) {
    return executeMoveVariantsToExistingWork(
      _ref,
      sourceWorkId: sourceWorkId,
      variantIds: variantIds,
      targetWorkId: targetWorkId,
      targetCategory: targetCategory,
    );
  }

  /// 从原待复核或已入库作品中拆出选中文件生成独立作品卡片，并对拆出文件启用路径级永久锁。
  Future<Work> splitVariantsToIndependentWork({
    required String sourceWorkId,
    required List<String> variantIds,
    HybridMatchRequest? hybridRequest,
    ({int tmdbId, TmdbMediaType mediaType})? tmdbTarget,
    BangumiSubjectCandidate? bangumiOnlySubject,
    bool writeTmdbIdToFolderName = false,
  }) async {
    final created = await executeSplitVariantsToIndependentWork(
      _ref,
      sourceWorkId: sourceWorkId,
      variantIds: variantIds,
      hybridRequest: hybridRequest,
      tmdbTarget: tmdbTarget,
      bangumiOnlySubject: bangumiOnlySubject,
      writeTmdbIdToFolderName: writeTmdbIdToFolderName,
    );
    _invalidateWork(sourceWorkId);
    _invalidateWork(created.id);
    return created;
  }

  /// 待复核队列「忽略复核」：确认为本地原名或既有元数据正式入库并移出待复核队列。
  Future<void> dismissWorkReview(String workId) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final existing = await repo.findWorkById(workId);
    if (existing == null) return;
    await repo.clearScrapeCandidates(workId);
    await repo.upsertWork(
      existing.copyWith(
        isManualLocked: true,
        metadataLocked: true,
        clearReviewReason: true,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    _invalidateWork(workId);
  }

  /// 读取作品首个关联变体所在的相对目录路径，用于待复核抽屉显示出处。
  Future<String?> resolveWorkFolderPath(String workId) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final variants = await repo.getVariantsByWork(workId);
    if (variants.isEmpty) return null;
    final folder = _deriveFolderPath(variants.first.relativePath);
    return folder.isEmpty ? variants.first.relativePath : folder;
  }

  /// 保存系列编组及成员排序、角色标签（自动锁定 `seriesLocked` 避免重扫覆盖）。
  Future<void> saveSeriesGroupConfig({
    String? seriesId,
    required String title,
    required List<SeriesMemberEdit> members,
    int? tmdbCollectionId,
  }) async {
    final res = await executeSaveSeriesGroupConfig(
      _ref,
      seriesId: seriesId,
      title: title,
      members: members,
      tmdbCollectionId: tmdbCollectionId,
    );
    _invalidateWorks(res.affectedWorkIds);
  }

  /// 保存附属资源（特典 / CD / Scan）的共享或单作独享作用域，并永久写入 `scopeLocked`。
  Future<void> updateSupplementaryScopes(
    List<SupplementaryScopeEdit> edits,
  ) async {
    final affected = await executeUpdateSupplementaryScopes(
      _ref,
      edits: edits,
    );
    _invalidateWorks(affected);
  }

  static String _deriveFolderPath(String relativePath) {
    final norm = relativePath.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    if (idx <= 0) return '';
    return norm.substring(0, idx);
  }

  void _invalidateWork(String workId) {
    _invalidateWorks({workId});
  }

  void _invalidateWorks(Set<String> workIds) {
    _ref.invalidate(libraryItemsProvider);
    _ref.invalidate(worksCountProvider);
    _ref.invalidate(hiddenWorksProvider);
    _ref.invalidate(seriesGroupsProvider);
    for (final id in workIds) {
      _ref.invalidate(workDetailBundleProvider(id));
      _ref.invalidate(workScrapeCandidatesProvider(id));
    }
  }
}
