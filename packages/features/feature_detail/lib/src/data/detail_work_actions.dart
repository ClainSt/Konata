import 'dart:developer' as developer;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'artwork_crop_math.dart';
import 'detail_edit_models.dart';
import 'detail_work_merge_actions.dart';
import 'detail_work_series_actions.dart';
import 'local_artwork_cropper.dart';

/// 将 [PhotosStorage] 适配为 `engine_scraping` 所需的 [WorkArtworkStoragePort] 端口。
final class PhotosStorageArtworkPortAdapter implements WorkArtworkStoragePort {
  /// 创建图片目录管理适配器。
  const PhotosStorageArtworkPortAdapter(this._photosStorage);

  final PhotosStorage _photosStorage;

  @override
  Future<void> renameWorkFolderIfNeeded(String workId, String newTitle) =>
      _photosStorage.renameWorkFolderIfNeeded(workId, newTitle);

  @override
  Future<void> mergeWorkPhotos({
    required String sourceWorkId,
    required String targetWorkId,
    String? targetTitle,
  }) => _photosStorage.mergeWorkPhotos(
    sourceWorkId: sourceWorkId,
    targetWorkId: targetWorkId,
    targetTitle: targetTitle,
  );

  @override
  Future<bool> deleteManagedStill(String workId, String path) =>
      _photosStorage.deleteManagedArtworkFile(
        workId: workId,
        subfolder: PhotoSubfolder.thumbnails,
        path: path,
      );

  @override
  Future<void> deleteWorkPhotos(String workId) =>
      _photosStorage.deleteWorkPhotos(workId);
}

/// 作品详情页全部元数据、映射、艺术图、系列与合拆持久化业务执行器（零 Riverpod）。
final class DetailWorkActionsService {
  /// 创建详情页写操作协调服务。
  DetailWorkActionsService({
    required this._repository,
    required this._databases,
    required this._photosStorage,
    required this._domainEventBus,
    required this._tmdbService,
    required this._bangumiService,
    required this._scrapePipeline,
    this.mappingIndexProvider,
    this.sourceDeviceId = '',
  });

  final LibraryRepository _repository;
  final KonataDatabaseBundle _databases;
  final PhotosStorage _photosStorage;
  final DomainEventBus _domainEventBus;
  final TmdbService _tmdbService;
  final BangumiService _bangumiService;
  final ScrapePipeline _scrapePipeline;

  /// 可选离线映射索引提供器。
  final Future<BangumiTmdbIndex?> Function()? mappingIndexProvider;

  /// 同步墓碑来源设备标识。
  final String sourceDeviceId;

  void _publishWorkChanged(String workId, String reason) {
    final cleanId = workId.trim();
    if (cleanId.isEmpty) return;
    _domainEventBus.publish(
      LibraryWorkChangedEvent(
        workId: WorkId.trusted(cleanId),
        reason: reason,
        occurredAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 为缺少 `Bangumi` 评分的已绑定作品按需静默补充 `Bangumi` 评分与封面。
  Future<void> ensureWorkBangumiScore(String workId) async {
    final work = await _repository.findWorkById(workId);
    if (work == null || work.bangumiScore != null) return;
    if (work.bangumiId == null && work.tmdbId == null) return;

    var resolvedBgmId = work.bangumiId;
    if (resolvedBgmId == null &&
        work.tmdbId != null &&
        work.tmdbMediaType != null &&
        mappingIndexProvider != null) {
      try {
        final index = await mappingIndexProvider!();
        if (index != null) {
          final matches = index.lookupBangumiIdsByTmdb(
            mediaType: work.tmdbMediaType!,
            tmdbId: work.tmdbId!,
            season: work.matchedSeason,
          );
          if (matches.isNotEmpty) {
            resolvedBgmId = matches.first.bangumiId;
          }
        }
      } catch (error) {
        developer.log(
          '离线索引反查 Bangumi ID 失败已忽略',
          name: 'konata.detail_work_actions',
          error: error,
        );
      }
    }

    BangumiSubjectCandidate? subject;
    if (resolvedBgmId != null) {
      try {
        subject = await _bangumiService.getSubjectDetail(
          resolvedBgmId,
          priority: RequestPriority.interactive,
        );
      } catch (error) {
        developer.log(
          '按 ID 拉取 Bangumi 详情失败',
          name: 'konata.detail_work_actions',
          error: error,
        );
      }
    }
    if (subject == null && work.title.trim().isNotEmpty) {
      try {
        final list = await _bangumiService.searchSubjectsProgressive(
          work.title,
          priority: RequestPriority.interactive,
        );
        if (list.isNotEmpty) subject = list.first;
      } catch (error) {
        developer.log(
          '按标题搜索 Bangumi 条目失败',
          name: 'konata.detail_work_actions',
          error: error,
        );
      }
    }

    if (subject == null) return;
    final latest = await _repository.findWorkById(workId);
    if (latest == null) return;
    final nextBgmId = latest.bangumiId ?? subject.id;
    final nextScore = latest.bangumiScore ?? subject.score;
    final nextPoster = latest.bangumiPosterPath ?? subject.posterUrl;
    if (nextBgmId == latest.bangumiId &&
        nextScore == latest.bangumiScore &&
        nextPoster == latest.bangumiPosterPath) {
      return;
    }
    await _repository.upsertWork(
      latest.copyWith(
        bangumiId: nextBgmId,
        bangumiScore: nextScore,
        bangumiPosterPath: nextPoster,
      ),
    );
    _publishWorkChanged(workId, 'edited');
  }

  /// 手动更新作品基础元数据并锁定，防止后续重扫或重刮覆盖。
  Future<void> updateWorkManualMetadata({
    required String workId,
    required String title,
    String? originalTitle,
    int? year,
    String? overview,
    bool lockMetadata = true,
  }) async {
    final existing = await _repository.findWorkById(workId);
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
      portraitBackdropPath: existing.portraitBackdropPath,
      logoPath: existing.logoPath,
      voteAverage: existing.voteAverage,
      bangumiScore: existing.bangumiScore,
      folderTmdbHint: existing.folderTmdbHint,
      isManualLocked: existing.isManualLocked || nextLocked,
      metadataLocked: nextLocked,
      posterLocked: existing.posterLocked,
      backdropLocked: existing.backdropLocked,
      portraitBackdropLocked: existing.portraitBackdropLocked,
      logoLocked: existing.logoLocked,
      logoNegativeUntil: existing.logoNegativeUntil,
      logoNegativeMask: existing.logoNegativeMask,
      scrapeStatus: existing.scrapeStatus,
      reviewReason: existing.reviewReason,
      seriesId: existing.seriesId,
      seriesOrder: existing.seriesOrder,
      seriesLabel: existing.seriesLabel,
      seriesLocked: existing.seriesLocked,
    );
    await _repository.upsertWork(next);
    await _photosStorage.renameWorkFolderIfNeeded(workId, next.title);
    _publishWorkChanged(workId, 'edited');
  }

  /// 批量重映射作品下物理视频文件的正片/特典归属、季号与集号，并持久化锁定。
  Future<void> saveEpisodeMappings({
    required String workId,
    required List<EpisodeFileMappingEdit> mappings,
  }) async {
    if (mappings.isEmpty) return;
    final existingEpisodes = await _repository.getEpisodesByWork(workId);
    final existingVariants = await _repository.getVariantsByWork(workId);

    final episodeByKey = <String, Episode>{
      for (final ep in existingEpisodes)
        '${ep.category.name}:${ep.seasonNumber}:${ep.episodeNumber}:${ep.extraType?.name ?? ''}':
            ep,
    };
    final variantById = <String, MediaVariant>{
      for (final v in existingVariants) v.id: v,
    };
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
        await _repository.upsertEpisode(targetEpisode);
        episodeByKey[key] = targetEpisode;
      }

      final changed = variant.episodeId != targetEpisode.id;
      final nextLock = edit.lockMapping || changed || variant.mappingLocked;
      if (nextLock) anyLocked = true;
      if (changed || variant.mappingLocked != nextLock) {
        await _repository.upsertMediaVariant(
          variant.copyWith(
            episodeId: targetEpisode.id,
            mappingLocked: nextLock,
          ),
        );
      }
    }

    if (anyLocked) {
      final work = await _repository.findWorkById(workId);
      if (work != null && !work.isManualLocked) {
        await _repository.upsertWork(work.copyWith(isManualLocked: true));
      }
    }

    await _repository.deleteOrphanEpisodes(workId);
    _publishWorkChanged(workId, 'edited');
  }

  /// 从磁盘读取本地图片原画句柄以供比例裁切框使用。
  Future<LoadedLocalArtwork> loadLocalArtworkForCrop(String filePath) {
    return LocalArtworkCropper.loadFromFilePath(filePath);
  }

  /// 裁切本地自定义图片并原子保存至受管图库目录，同时更新作品封面、背景或竖版原画与锁定状态。
  Future<String> cropAndSaveLocalArtwork({
    required Work work,
    required bool isPoster,
    bool isPortraitBackdrop = false,
    required LoadedLocalArtwork source,
    required ArtworkNormalizedCropRect cropRect,
  }) async {
    final saved = await LocalArtworkCropper.cropAndSave(
      photosStorage: _photosStorage,
      workId: work.id,
      workTitle: work.title,
      isPoster: isPoster || isPortraitBackdrop,
      subfolder: (isPoster || isPortraitBackdrop)
          ? PhotoSubfolder.posters
          : PhotoSubfolder.backdrops,
      source: source,
      cropRect: cropRect,
    );
    await updateWorkArtwork(
      workId: work.id,
      posterPath: isPoster && !isPortraitBackdrop ? saved.path : null,
      backdropPath: (!isPoster && !isPortraitBackdrop) ? saved.path : null,
      portraitBackdropPath: isPortraitBackdrop ? saved.path : null,
    );
    return saved.path;
  }

  /// 直接导入本地透明徽标保存至 `logos/` 并锁定。
  Future<String> saveLocalLogoArtwork({
    required Work work,
    required String sourceFilePath,
  }) async {
    final saved = await LocalArtworkCropper.saveRawLocalArtwork(
      photosStorage: _photosStorage,
      workId: work.id,
      workTitle: work.title,
      subfolder: PhotoSubfolder.logos,
      sourceFilePath: sourceFilePath,
    );
    await updateWorkArtwork(workId: work.id, logoPath: saved.path);
    return saved.path;
  }

  /// 规范化存储艺术图路径（自动还原 `Fanart.tv` 预览链接为原图地址）。
  static String? normalizeArtworkPathForPersist(String? rawPath) {
    final trimmed = rawPath?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.toLowerCase().contains('fanart.tv')) {
      return FanartUrlHelper.toOriginalUrl(trimmed);
    }
    return trimmed;
  }

  /// 替换作品海报、背景图、竖版原画或透明标题徽标路径并持久化锁定。
  Future<void> updateWorkArtwork({
    required String workId,
    String? posterPath,
    String? backdropPath,
    String? portraitBackdropPath,
    String? logoPath,
  }) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) return;
    final normalizedPoster = normalizeArtworkPathForPersist(posterPath);
    final normalizedBackdrop = normalizeArtworkPathForPersist(backdropPath);
    final normalizedPortraitBackdrop = normalizeArtworkPathForPersist(
      portraitBackdropPath,
    );
    final normalizedLogo = normalizeArtworkPathForPersist(logoPath);
    final lockPoster = normalizedPoster != null ? true : existing.posterLocked;
    final lockBackdrop = normalizedBackdrop != null
        ? true
        : existing.backdropLocked;
    final lockPortraitBackdrop = normalizedPortraitBackdrop != null
        ? true
        : existing.portraitBackdropLocked;
    final lockLogo = normalizedLogo != null ? true : existing.logoLocked;
    final next = existing.copyWith(
      posterPath: normalizedPoster ?? existing.posterPath,
      backdropPath: normalizedBackdrop ?? existing.backdropPath,
      portraitBackdropPath:
          normalizedPortraitBackdrop ?? existing.portraitBackdropPath,
      logoPath: normalizedLogo ?? existing.logoPath,
      posterLocked: lockPoster,
      backdropLocked: lockBackdrop,
      portraitBackdropLocked: lockPortraitBackdrop,
      logoLocked: lockLogo,
      clearLogoNegative: normalizedLogo != null,
      isManualLocked: true,
    );
    await _repository.upsertWork(next);
    await _photosStorage.renameWorkFolderIfNeeded(workId, next.title);
    _publishWorkChanged(workId, 'edited');
  }

  /// 解除作品基础元数据锁定，若已绑定 `TMDB` 则恢复自动抓取默认值。
  Future<Work?> resetMetadataLockToAuto(String workId) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) return null;
    final variants = await _repository.getVariantsByWork(workId);
    final hasAnyMappingLock = variants.any((v) => v.mappingLocked);
    await _repository.upsertWork(
      existing.copyWith(
        metadataLocked: false,
        isManualLocked:
            existing.tmdbId != null ||
            existing.posterLocked ||
            existing.backdropLocked ||
            existing.portraitBackdropLocked ||
            existing.logoLocked ||
            hasAnyMappingLock,
      ),
    );
    if (existing.tmdbId != null && existing.tmdbMediaType != null) {
      final updated = await _scrapePipeline.rebindWorkToTmdb(
        workId,
        existing.tmdbId!,
        existing.tmdbMediaType!,
        clearManualLockIfNoFieldLock: true,
      );
      _publishWorkChanged(workId, 'scraped');
      return updated;
    }
    _publishWorkChanged(workId, 'edited');
    return _repository.findWorkById(workId);
  }

  /// 解除海报、背景图、竖版原画或透明标题徽标锁定，并在具备条目 ID 时恢复自动抓取。
  Future<Work?> resetArtworkLockToAuto({
    required String workId,
    bool resetPoster = false,
    bool resetBackdrop = false,
    bool resetPortraitBackdrop = false,
    bool resetLogo = false,
  }) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) return null;
    final nextPosterLocked = resetPoster ? false : existing.posterLocked;
    final nextBackdropLocked = resetBackdrop ? false : existing.backdropLocked;
    final nextPortraitBackdropLocked = resetPortraitBackdrop
        ? false
        : existing.portraitBackdropLocked;
    final nextLogoLocked = resetLogo ? false : existing.logoLocked;
    final variants = await _repository.getVariantsByWork(workId);
    final hasAnyMappingLock = variants.any((v) => v.mappingLocked);
    await _repository.upsertWork(
      existing.copyWith(
        posterLocked: nextPosterLocked,
        backdropLocked: nextBackdropLocked,
        portraitBackdropLocked: nextPortraitBackdropLocked,
        clearPortraitBackdropPath: resetPortraitBackdrop,
        logoLocked: nextLogoLocked,
        clearLogoPath: resetLogo,
        clearLogoNegative: resetLogo,
        isManualLocked:
            existing.tmdbId != null ||
            existing.metadataLocked ||
            nextPosterLocked ||
            nextBackdropLocked ||
            nextPortraitBackdropLocked ||
            nextLogoLocked ||
            hasAnyMappingLock,
      ),
    );
    if (existing.tmdbId != null && existing.tmdbMediaType != null) {
      final Work? result;
      if (resetLogo &&
          !resetPoster &&
          !resetBackdrop &&
          !resetPortraitBackdrop) {
        result = await _scrapePipeline.autoBindOrBackfillWorkTmdb(
          workId,
          interactive: true,
        );
      } else {
        result = await _scrapePipeline.rebindWorkToTmdb(
          workId,
          existing.tmdbId!,
          existing.tmdbMediaType!,
          clearManualLockIfNoFieldLock: true,
          forceRefreshArtwork: true,
        );
      }
      _publishWorkChanged(workId, 'scraped');
      return result;
    }
    if (existing.bangumiId != null || existing.tvdbId != null) {
      final result = await _scrapePipeline.autoBindOrBackfillWorkTmdb(
        workId,
        interactive: true,
      );
      _publishWorkChanged(workId, 'scraped');
      return result;
    }
    _publishWorkChanged(workId, 'edited');
    return _repository.findWorkById(workId);
  }

  /// 解除作品下所有文件的人工映射锁定，并在已绑定 `TMDB` 时按自动规则重映射。
  Future<Work?> resetFileMappingsToAuto(String workId) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) return null;
    final variants = await _repository.getVariantsByWork(workId);
    for (final v in variants) {
      if (v.mappingLocked) {
        await _repository.upsertMediaVariant(v.copyWith(mappingLocked: false));
      }
    }
    await _repository.upsertWork(
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
      final updated = await _scrapePipeline.rebindWorkToTmdb(
        workId,
        existing.tmdbId!,
        existing.tmdbMediaType!,
        clearManualLockIfNoFieldLock: true,
      );
      _publishWorkChanged(workId, 'edited');
      return updated;
    }
    _publishWorkChanged(workId, 'edited');
    return _repository.findWorkById(workId);
  }

  /// 仅从媒体库数据库移除作品记录，可选写入忽略目录名单，绝不删除物理源文件。
  Future<void> deleteWorkFromLibrary(
    String workId, {
    bool addToIgnoreList = false,
  }) async {
    final id = WorkId.trusted(workId);
    final library = _databases.library;
    if (library.works.findById(id) == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final ignoredPairs = <(String, String)>{};
    if (addToIgnoreList) {
      for (final variant in await _repository.getVariantsByWork(workId)) {
        final folder = deriveFolderPath(variant.relativePath);
        if (folder.isNotEmpty) ignoredPairs.add((variant.sourceId, folder));
      }
      for (final (source, folder) in ignoredPairs) {
        await _repository.addIgnoredFolder(source, folder);
      }
    }
    library.works.softDelete(
      id,
      deletedAtMs: now,
      sourceDeviceId: sourceDeviceId,
    );
    await _repository.clearScrapeCandidates(workId);
    await _photosStorage.deleteWorkPhotos(workId);
    for (final source in ignoredPairs.map((pair) => pair.$1).toSet()) {
      _domainEventBus.publish(
        MediaSourceChangedEvent(
          sourceId: SourceId.trusted(source),
          reason: 'ignored_folder_added',
          occurredAtMs: now,
        ),
      );
    }
    _publishWorkChanged(workId, 'deleted');
  }

  /// 将全部正片剧集一键标记为已看完。
  Future<void> markAllMainEpisodesWatched(String workId) async {
    final eps = await _repository.getEpisodesByWork(workId);
    final variants = await _repository.getVariantsByWork(workId);
    final mainEps = eps
        .where((e) => e.category == EpisodeCategory.main)
        .toList(growable: false);
    if (mainEps.isEmpty) return;

    final now = DateTime.now();
    for (final ep in mainEps) {
      final epVariants = variants
          .where((v) => v.assetKind == AssetKind.video && v.episodeId == ep.id)
          .toList(growable: false);
      final variantId = epVariants.isNotEmpty ? epVariants.first.id : ep.id;
      final sourceId = epVariants.isNotEmpty ? epVariants.first.sourceId : null;
      final source = sourceId != null
          ? await _repository.findSourceById(sourceId)
          : null;
      await _repository.recordPlayback(
        PlaybackRecord(
          id: ScrapeWorkPersister.deterministicId('$workId::${ep.id}'),
          workId: workId,
          episodeId: ep.id,
          variantId: variantId,
          seasonNumber: ep.seasonNumber,
          episodeNumber: ep.episodeNumber,
          episodeTitle: ep.title ?? '第 ${ep.episodeNumber ?? 1} 话',
          sourceType: source?.kind ?? MediaSourceKind.local,
          playedAt: now,
          positionSeconds: 1,
          durationSeconds: 1,
          isCompleted: true,
        ),
      );
    }
    _publishWorkChanged(workId, 'edited');
  }

  /// 清空作品下所有观看历史记录，恢复为未观看状态。
  Future<void> clearWorkPlaybackHistory(String workId) async {
    final records = await _repository.getPlaybacksByWork(workId);
    for (final record in records) {
      await _repository.deletePlaybackRecord(record.id);
    }
    _publishWorkChanged(workId, 'edited');
  }

  /// 确认保留当前本地原名或既有元数据，解除待复核状态并加锁。
  Future<void> dismissWorkReview(String workId) async {
    final existing = await _repository.findWorkById(workId);
    if (existing == null) return;
    await _repository.clearScrapeCandidates(workId);
    await _repository.upsertWork(
      existing.copyWith(
        isManualLocked: true,
        metadataLocked: true,
        clearReviewReason: true,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );
    _publishWorkChanged(workId, 'edited');
  }

  /// 读取作品首个关联变体所在的相对目录路径。
  Future<String?> resolveWorkFolderPath(String workId) async {
    final variants = await _repository.getVariantsByWork(workId);
    if (variants.isEmpty) return null;
    final folder = deriveFolderPath(variants.first.relativePath);
    return folder.isEmpty ? variants.first.relativePath : folder;
  }

  /// 交互重绑作品到指定 `TMDB` 条目。
  Future<Work> rebindWorkToTmdb({
    required String workId,
    required int tmdbId,
    required TmdbMediaType mediaType,
  }) async {
    final updated = await _scrapePipeline.rebindWorkToTmdb(
      workId,
      tmdbId,
      mediaType,
      resetManualLocks: true,
      markManualLocked: true,
    );
    await _photosStorage.renameWorkFolderIfNeeded(updated.id, updated.title);
    _publishWorkChanged(updated.id, 'scraped');
    return updated;
  }

  /// 绑定作品为纯 `Bangumi` 独立条目并加锁。
  Future<Work> bindWorkBangumiOnly({
    required String workId,
    required BangumiSubjectCandidate bangumiSubject,
  }) async {
    final updated = await DetailWorkMergeHelper.bindWorkBangumiOnly(
      repository: _repository,
      photosStorage: _photosStorage,
      bangumiService: _bangumiService,
      workId: workId,
      bangumiSubject: bangumiSubject,
    );
    _publishWorkChanged(updated.id, 'scraped');
    return updated;
  }

  /// 执行 `Bangumi` 与 `TMDB` 双源混合绑定。
  Future<Work> bindWorkHybrid({
    required String workId,
    required HybridMatchRequest request,
  }) async {
    final updated = await DetailWorkMergeHelper.bindWorkHybrid(
      repository: _repository,
      photosStorage: _photosStorage,
      tmdbService: _tmdbService,
      bangumiService: _bangumiService,
      workId: workId,
      request: request,
    );
    _publishWorkChanged(updated.id, 'scraped');
    return updated;
  }

  /// 将整部作品直接并入库内已有作品。
  Future<WorkMergeOutcome> mergeWorkIntoExisting({
    required String sourceWorkId,
    required String targetWorkId,
    EpisodeCategory? forceCategory,
  }) async {
    final outcome = await DetailWorkMergeHelper.mergeWorkIntoExisting(
      repository: _repository,
      photosStorage: _photosStorage,
      sourceWorkId: sourceWorkId,
      targetWorkId: targetWorkId,
      forceCategory: forceCategory,
    );
    _publishWorkChanged(outcome.targetWork.id, 'merged');
    return outcome;
  }

  /// 将勾选物理文件迁移至其他库内作品。
  Future<WorkMergeOutcome> moveVariantsToExistingWork({
    required String sourceWorkId,
    required List<String> variantIds,
    required String targetWorkId,
    required EpisodeCategory targetCategory,
  }) async {
    final outcome = await DetailWorkMergeHelper.moveVariantsToExistingWork(
      repository: _repository,
      photosStorage: _photosStorage,
      sourceWorkId: sourceWorkId,
      variantIds: variantIds,
      targetWorkId: targetWorkId,
      targetCategory: targetCategory,
    );
    _publishWorkChanged(outcome.targetWork.id, 'merged');
    if (!outcome.sourceWorkDeleted) {
      _publishWorkChanged(sourceWorkId, 'edited');
    }
    return outcome;
  }

  /// 从原作品拆出选中物理视频文件为独立作品卡片。
  Future<Work> splitVariantsToIndependentWork({
    required String sourceWorkId,
    required List<String> variantIds,
    HybridMatchRequest? hybridRequest,
    ({int tmdbId, TmdbMediaType mediaType})? tmdbTarget,
    BangumiSubjectCandidate? bangumiOnlySubject,
  }) async {
    if (hybridRequest == null &&
        tmdbTarget == null &&
        bangumiOnlySubject == null) {
      throw ArgumentError('必须指定一种目标绑定方式');
    }
    final sourceWork = await _repository.findWorkById(sourceWorkId);
    if (sourceWork == null) {
      throw StateError('原作品不存在: $sourceWorkId');
    }
    final sourceVariants = await _repository.getVariantsByWork(sourceWorkId);
    final idSet = variantIds.toSet();
    final selected = sourceVariants.where((v) => idSet.contains(v.id)).toList()
      ..sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
          b.relativePath.toLowerCase(),
        ),
      );
    if (selected.isEmpty) {
      throw StateError('请至少选择一个有效源文件后再拆分');
    }

    final newWorkId = ScrapeWorkPersister.deterministicId(
      'split::$sourceWorkId::${DateTime.now().microsecondsSinceEpoch}::${selected.first.relativePath}',
    );
    final placeholderTitle =
        hybridRequest?.bangumiSubject.displayTitle ??
        bangumiOnlySubject?.displayTitle ??
        selected.first.fileName;

    await _repository.upsertWork(
      Work(
        id: newWorkId,
        title: placeholderTitle,
        tmdbId: tmdbTarget?.tmdbId ?? hybridRequest?.tmdbDetail.tmdbId,
        tmdbMediaType:
            tmdbTarget?.mediaType ?? hybridRequest?.tmdbDetail.mediaType,
        bangumiId: hybridRequest?.bangumiSubject.id ?? bangumiOnlySubject?.id,
        isManualLocked: true,
        scrapeStatus: ScrapeStatus.matched,
      ),
    );

    for (final variant in selected) {
      await _repository.upsertMediaVariant(
        variant.copyWith(
          workId: newWorkId,
          clearEpisodeId: true,
          mappingLocked: true,
          workLocked: true,
        ),
      );
    }

    late final Work boundWork;
    if (hybridRequest != null) {
      boundWork = await bindWorkHybrid(
        workId: newWorkId,
        request: hybridRequest,
      );
    } else if (tmdbTarget != null) {
      boundWork = await _scrapePipeline.rebindWorkToTmdb(
        newWorkId,
        tmdbTarget.tmdbId,
        tmdbTarget.mediaType,
        resetManualLocks: false,
      );
      final newVariants = await _repository.getVariantsByWork(newWorkId);
      for (final v in newVariants) {
        if (!v.workLocked) {
          await _repository.upsertMediaVariant(v.copyWith(workLocked: true));
        }
      }
    } else {
      boundWork = await bindWorkBangumiOnly(
        workId: newWorkId,
        bangumiSubject: bangumiOnlySubject!,
      );
    }

    await DetailWorkMergeHelper.cleanupSourceWorkAfterSplit(
      _repository,
      sourceWork,
    );
    await SeriesAutoLinker.reconcileAll(
      repository: _repository,
      bangumiService: _bangumiService,
      focusBangumiIds: {
        if ((boundWork.bangumiId ?? 0) > 0) boundWork.bangumiId!,
      },
      focusWorkIds: {boundWork.id, sourceWorkId},
    );
    final resolvedTarget =
        (await _repository.findWorkById(newWorkId)) ?? boundWork;
    _publishWorkChanged(resolvedTarget.id, 'edited');
    _publishWorkChanged(sourceWorkId, 'edited');
    return resolvedTarget;
  }

  /// 创建或更新系列编组、调整成员顺序/角色标签并人工锁定。
  Future<Set<String>> saveSeriesGroupConfig({
    String? seriesId,
    required String title,
    required List<SeriesMemberEdit> members,
    int? tmdbCollectionId,
  }) async {
    final affected = await DetailWorkSeriesActionsHelper.saveSeriesGroupConfig(
      repository: _repository,
      seriesId: seriesId,
      title: title,
      members: members,
      tmdbCollectionId: tmdbCollectionId,
    );
    for (final id in affected) {
      _publishWorkChanged(id, 'edited');
    }
    return affected;
  }

  /// 保存附属资源（特典 / CD / Scan）的共享或单作独享作用域，并持久化锁定。
  Future<Set<String>> updateSupplementaryScopes(
    List<SupplementaryScopeEdit> edits,
  ) async {
    final affected =
        await DetailWorkSeriesActionsHelper.updateSupplementaryScopes(
          repository: _repository,
          edits: edits,
        );
    for (final id in affected) {
      _publishWorkChanged(id, 'edited');
    }
    return affected;
  }

  /// 提取文件相对路径的父级目录。
  static String deriveFolderPath(String relativePath) {
    final norm = relativePath.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    if (idx <= 0) return '';
    return norm.substring(0, idx);
  }
}
