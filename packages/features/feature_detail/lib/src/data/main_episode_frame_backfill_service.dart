import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart'
    show EpisodeTitleFormatter;
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import 'main_episode_frame_extractor.dart';

/// 正片视频抽帧补图编排服务（零 Riverpod，严格仅对 `EpisodeCategory.main` 正片抽帧，绝不碰特典）。
final class MainEpisodeFrameBackfillService {
  /// 创建正片抽帧编排服务。
  MainEpisodeFrameBackfillService({
    required this._repository,
    required this._photosStorage,
    required this._extractor,
    this.onWorkUpdated,
  });

  final LibraryRepository _repository;
  final PhotosStorage _photosStorage;
  final MainEpisodeFrameExtractor _extractor;

  /// 当作品或分集剧照落盘更新时触发的轻量通知回调。
  final void Function(String workId)? onWorkUpdated;

  final Set<String> _inFlightWorkIds = <String>{};

  static const int _maxRemoteAutoEpisodes = 5;
  static const int _maxLocalAutoEpisodes = 8;

  /// 是否属于旧版自动随机背景图缓存。
  static bool isLegacyAutoBackdropPath(String? path) =>
      VideoFrameSamplePlan.isLegacyAutoBackdropPath(path);

  /// 是否属于旧版低清自动抽帧单集剧照。
  static bool isLegacyAutoEpisodeStillPath(String? path) =>
      VideoFrameSamplePlan.isLegacyAutoEpisodeStillPath(path);

  /// 是否属于任意版本的本地自动视频抽帧剧照（含 `video_still_*.png` 与 `thumbnails/` 落盘缓存）。
  static bool isAutoExtractedEpisodeStillPath(String? path) {
    if (VideoFrameSamplePlan.isAutoExtractedStillPath(path)) return true;
    final norm = (path ?? '').trim().replaceAll('\\', '/').toLowerCase();
    return norm.contains('/thumbnails/');
  }

  /// 判断 TMDB 已匹配剧集是否存在尚待从 TMDB 官方季接口补拉的正片剧照或占位集名。
  static bool needsTmdbEpisodeStillBackfill({
    required Work work,
    required List<Episode> episodes,
  }) {
    if (work.tmdbId == null ||
        work.tmdbId! <= 0 ||
        work.tmdbMediaType != TmdbMediaType.tv ||
        work.matchedSeason == 0) {
      return false;
    }
    for (final ep in episodes) {
      if (ep.category != EpisodeCategory.main) continue;
      if (ep.episodeNumber == null || ep.episodeNumber! <= 0) continue;
      final targetSeason = ep.seasonNumber > 0
          ? ep.seasonNumber
          : (work.matchedSeason != null && work.matchedSeason! > 0
                ? work.matchedSeason!
                : 0);
      if (targetSeason <= 0) continue;
      final still = ep.stillPath?.trim() ?? '';
      if (still.isEmpty || isAutoExtractedEpisodeStillPath(still)) {
        return true;
      }
      if (EpisodeTitleFormatter.isGenericEpisodePlaceholder(ep.title ?? '')) {
        return true;
      }
    }
    return false;
  }

  /// 判断作品是否存在可用官方竖版封面。
  static bool hasOfficialPoster(Work work) {
    return (work.posterPath?.trim().isNotEmpty ?? false) ||
        (work.bangumiPosterPath?.trim().isNotEmpty ?? false);
  }

  /// 判断作品是否已拥有有效的非自动横版背景图。
  static bool hasOfficialLandscapeBackdrop(Work work) {
    final bg = work.backdropPath?.trim() ?? '';
    return bg.isNotEmpty && !isLegacyAutoBackdropPath(bg);
  }

  /// 判断单集正片是否需要自动补抽剧照（绝不对 `EpisodeCategory.extra` 特典返回真）。
  static bool needsAutoMainEpisodeStill(Episode ep) {
    if (ep.category != EpisodeCategory.main) return false;
    final still = ep.stillPath?.trim() ?? '';
    return still.isEmpty || isLegacyAutoEpisodeStillPath(still);
  }

  /// 判断整部作品在详情页是否需要对正片执行自动抽帧补图（仅针对 `EpisodeCategory.main`）。
  static bool shouldBackfillMainEpisodeFrames({
    required Work work,
    required List<Episode> episodes,
  }) {
    final hasPoster = hasOfficialPoster(work);
    final needLegacyBgCleanup =
        hasPoster &&
        !work.backdropLocked &&
        isLegacyAutoBackdropPath(work.backdropPath);
    if (needLegacyBgCleanup) return true;

    final mainEpisodes = episodes
        .where((e) => e.category == EpisodeCategory.main)
        .toList(growable: false);
    if (mainEpisodes.isEmpty) return false;

    final needZeroPosterBackdrop =
        !hasPoster &&
        !work.backdropLocked &&
        (work.backdropPath == null || work.backdropPath!.trim().isEmpty);
    if (needZeroPosterBackdrop) return true;

    if (mainEpisodes.length == 1 && hasOfficialLandscapeBackdrop(work)) {
      return false;
    }
    return mainEpisodes.any(needsAutoMainEpisodeStill);
  }

  /// 为缺少正片剧照的作品自动执行正片流式抽帧补图（严格限定 `EpisodeCategory.main`，绝不抽特典）。
  Future<bool> backfillMissingMainVisuals({
    required Work work,
    required List<Episode> episodes,
    required List<MediaVariant> variants,
    required Map<String, MediaSource> sourcesById,
    bool Function()? isCancelled,
  }) async {
    if (!_inFlightWorkIds.add(work.id)) return false;

    try {
      final hasPoster = hasOfficialPoster(work);
      var anyChanged = false;

      if (hasPoster &&
          !work.backdropLocked &&
          isLegacyAutoBackdropPath(work.backdropPath)) {
        final legacyFile = File(work.backdropPath!);
        final latestWork = await _repository.findWorkById(work.id);
        if (latestWork != null &&
            !latestWork.backdropLocked &&
            isLegacyAutoBackdropPath(latestWork.backdropPath)) {
          await _repository.upsertWork(
            latestWork.copyWith(clearBackdropPath: true),
          );
          anyChanged = true;
          try {
            if (legacyFile.existsSync()) {
              legacyFile.deleteSync();
            }
          } catch (error) {
            developer.log(
              '清理旧版抽帧背景缓存失败已忽略',
              name: 'konata.main_episode_frame_backfill',
              error: error,
            );
          }
        }
      }

      // 严格只筛选正片逻辑集（EpisodeCategory.main），严禁特典进入任何抽帧管线。
      final mainEpisodes = episodes
          .where((e) => e.category == EpisodeCategory.main)
          .toList(growable: false);
      if (mainEpisodes.isEmpty) {
        if (anyChanged) onWorkUpdated?.call(work.id);
        return anyChanged;
      }

      final needBackdrop =
          !hasPoster &&
          !work.backdropLocked &&
          (work.backdropPath == null || work.backdropPath!.trim().isEmpty);
      final skipSingleEpWithOfficialBackdrop =
          mainEpisodes.length == 1 &&
          hasOfficialLandscapeBackdrop(work) &&
          !needBackdrop;
      final missingMainEpisodes = skipSingleEpWithOfficialBackdrop
          ? const <Episode>[]
          : mainEpisodes
                .where(needsAutoMainEpisodeStill)
                .toList(growable: false);
      if (!needBackdrop && missingMainEpisodes.isEmpty) {
        if (anyChanged) onWorkUpdated?.call(work.id);
        return anyChanged;
      }

      final variantsByEpId = <String, List<MediaVariant>>{};
      for (final v in variants) {
        if (v.assetKind != AssetKind.video || v.episodeId == null) continue;
        variantsByEpId.putIfAbsent(v.episodeId!, () => <MediaVariant>[]).add(v);
      }

      MediaVariant? pickBestMainVariant(Episode ep) {
        final list = variantsByEpId[ep.id];
        if (list == null || list.isEmpty) return null;
        final sorted = List<MediaVariant>.of(list)
          ..sort((a, b) => b.fileSize.compareTo(a.fileSize));
        return sorted.first;
      }

      String? sharedBackdropPath;
      final firstVariant = pickBestMainVariant(mainEpisodes.first);
      final firstSource = firstVariant != null
          ? sourcesById[firstVariant.sourceId]
          : null;
      final isRemote =
          firstSource != null && firstSource.kind != MediaSourceKind.local;
      final maxEpisodes = isRemote
          ? _maxRemoteAutoEpisodes
          : _maxLocalAutoEpisodes;

      if (needBackdrop) {
        final backdropDir = await _photosStorage.resolveSubfolderDirectory(
          work.id,
          PhotoSubfolder.backdrops,
          title: work.title,
        );
        final autoBgDigest = PhotosStorage.shortDigest('video_frame_auto_v2');
        final cachedByKey = File(p.join(backdropDir.path, '$autoBgDigest.png'));
        final cachedByLiteral = File(
          p.join(backdropDir.path, 'video_frame_auto_v2.png'),
        );
        if (cachedByKey.existsSync() && cachedByKey.lengthSync() > 0) {
          sharedBackdropPath = cachedByKey.path;
        } else if (cachedByLiteral.existsSync() &&
            cachedByLiteral.lengthSync() > 0) {
          sharedBackdropPath = cachedByLiteral.path;
        }
      }

      final episodesToProcess = <Episode>[
        ...missingMainEpisodes.take(maxEpisodes),
        if (needBackdrop &&
            sharedBackdropPath == null &&
            missingMainEpisodes.isEmpty)
          mainEpisodes.first,
      ];

      final thumbDir = await _photosStorage.resolveSubfolderDirectory(
        work.id,
        PhotoSubfolder.thumbnails,
        title: work.title,
      );

      Future<void> persistBackdropIfNeeded(Uint8List bytes) async {
        if (!needBackdrop || sharedBackdropPath != null || bytes.isEmpty) {
          return;
        }
        final writtenBg = await _photosStorage.writeArtwork(
          workId: work.id,
          subfolder: PhotoSubfolder.backdrops,
          cacheKey: 'video_frame_auto_v2',
          bytes: bytes,
          extension: '.png',
          title: work.title,
        );
        final path = writtenBg.path;
        if (path.trim().isEmpty) return;
        sharedBackdropPath = path;
        final latestWork = await _repository.findWorkById(work.id);
        if (latestWork != null &&
            !hasOfficialPoster(latestWork) &&
            !latestWork.backdropLocked &&
            (latestWork.backdropPath == null ||
                latestWork.backdropPath!.trim().isEmpty)) {
          await _repository.upsertWork(latestWork.copyWith(backdropPath: path));
          anyChanged = true;
          onWorkUpdated?.call(work.id);
        }
      }

      final cachedUpdatedEpisodes = <Episode>[];
      final pendingTasks = <MainEpisodeFrameTask>[];
      final epById = <String, Episode>{};
      for (final ep in episodesToProcess) {
        if (isCancelled?.call() ?? false) break;
        if (ep.category != EpisodeCategory.main) continue;
        final variant = pickBestMainVariant(ep);
        if (variant == null) continue;
        final stillFileName =
            'video_still_v2_${PhotosStorage.shortDigest(ep.id)}.png';
        final cachedStillFile = File(p.join(thumbDir.path, stillFileName));
        if (cachedStillFile.existsSync() && cachedStillFile.lengthSync() > 0) {
          if (needBackdrop && sharedBackdropPath == null) {
            final bytes = await cachedStillFile.readAsBytes();
            await persistBackdropIfNeeded(bytes);
          }
          if (needsAutoMainEpisodeStill(ep)) {
            final oldStill = ep.stillPath;
            cachedUpdatedEpisodes.add(
              ep.copyWith(stillPath: cachedStillFile.path),
            );
            await _deleteLegacyStillIfNeeded(oldStill, cachedStillFile.path);
          }
        } else {
          epById[ep.id] = ep;
          pendingTasks.add(
            MainEpisodeFrameTask(
              key: ep.id,
              variant: variant,
              source: sourcesById[variant.sourceId],
            ),
          );
        }
      }

      if (cachedUpdatedEpisodes.isNotEmpty) {
        await _repository.upsertEpisodesBatch(cachedUpdatedEpisodes);
        anyChanged = true;
        onWorkUpdated?.call(work.id);
      }

      if (needBackdrop &&
          sharedBackdropPath != null &&
          sharedBackdropPath!.trim().isNotEmpty) {
        final latestWork = await _repository.findWorkById(work.id);
        if (latestWork != null &&
            !hasOfficialPoster(latestWork) &&
            !latestWork.backdropLocked &&
            (latestWork.backdropPath == null ||
                latestWork.backdropPath!.trim().isEmpty)) {
          await _repository.upsertWork(
            latestWork.copyWith(backdropPath: sharedBackdropPath),
          );
          anyChanged = true;
          onWorkUpdated?.call(work.id);
        }
      }

      if (pendingTasks.isNotEmpty && !(isCancelled?.call() ?? false)) {
        final targetW = needBackdrop
            ? MainEpisodeFrameExtractor.defaultBackdropWidth
            : MainEpisodeFrameExtractor.defaultStillWidth;
        final targetH = needBackdrop
            ? MainEpisodeFrameExtractor.defaultBackdropHeight
            : MainEpisodeFrameExtractor.defaultStillHeight;

        await _extractor.extractBestMainFramesBatch(
          tasks: pendingTasks,
          sampleCount: 5,
          targetWidth: targetW,
          targetHeight: targetH,
          isCancelled: isCancelled,
          onExtracted: (epId, pngBytes) async {
            final ep = epById[epId];
            if (ep == null ||
                ep.category != EpisodeCategory.main ||
                pngBytes.isEmpty) {
              return;
            }

            await persistBackdropIfNeeded(pngBytes);

            if (!needsAutoMainEpisodeStill(ep)) return;
            final latestEps = await _repository.getEpisodesByWork(work.id);
            Episode? latestEp;
            for (final item in latestEps) {
              if (item.id == ep.id) {
                latestEp = item;
                break;
              }
            }
            if (latestEp == null || !needsAutoMainEpisodeStill(latestEp)) {
              return;
            }

            final writtenStill = await _writeEpisodeStillFile(
              dir: thumbDir,
              episodeId: ep.id,
              bytes: pngBytes,
            );
            final oldStill = latestEp.stillPath;
            await _repository.upsertEpisode(
              latestEp.copyWith(stillPath: writtenStill.path),
            );
            await _deleteLegacyStillIfNeeded(oldStill, writtenStill.path);
            anyChanged = true;
            onWorkUpdated?.call(work.id);
          },
        );
      }

      if (anyChanged) {
        onWorkUpdated?.call(work.id);
      }
      return anyChanged;
    } catch (error) {
      developer.log(
        '正片自动抽帧补图失败，保持清晰海报兜底',
        name: 'konata.main_episode_frame_backfill',
        error: error,
      );
      return false;
    } finally {
      _inFlightWorkIds.remove(work.id);
    }
  }

  Future<File> _writeEpisodeStillFile({
    required Directory dir,
    required String episodeId,
    required Uint8List bytes,
  }) async {
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final fileName =
        'video_still_v2_${PhotosStorage.shortDigest(episodeId)}.png';
    final target = File(p.join(dir.path, fileName));
    final tmp = File(
      '${target.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await tmp.writeAsBytes(bytes, flush: true);
    if (target.existsSync()) {
      await target.delete();
    }
    await tmp.rename(target.path);
    await _photosStorage.onEvictImageFile?.call(target);
    return target;
  }

  Future<void> _deleteLegacyStillIfNeeded(
    String? oldStill,
    String newStill,
  ) async {
    if (oldStill == null ||
        oldStill == newStill ||
        !isLegacyAutoEpisodeStillPath(oldStill)) {
      return;
    }
    try {
      final oldFile = File(oldStill);
      if (oldFile.existsSync()) {
        oldFile.deleteSync();
      }
    } catch (error) {
      developer.log(
        '清理旧版抽帧剧照缓存失败已忽略',
        name: 'konata.main_episode_frame_backfill',
        error: error,
      );
    }
  }

  /// 为「编辑背景图」弹窗从作品首个正片视频抽取多张候选画面（严格排除特典视频）。
  Future<List<VideoFrameSample>> extractBackdropCandidatesForWork(
    String workId, {
    int sampleCount = 8,
    double phaseOffset = 0.0,
    bool Function()? isCancelled,
  }) async {
    final episodes = await _repository.getEpisodesByWork(workId);
    final mainEpisodeIds = <String>{
      for (final e in episodes)
        if (e.category == EpisodeCategory.main) e.id,
    };
    if (mainEpisodeIds.isEmpty) return const <VideoFrameSample>[];

    final variants = await _repository.getVariantsByWork(workId);
    final mainVideos = variants
        .where(
          (v) =>
              v.assetKind == AssetKind.video &&
              v.episodeId != null &&
              mainEpisodeIds.contains(v.episodeId),
        )
        .toList();
    if (mainVideos.isEmpty) return const <VideoFrameSample>[];

    final epOrder = <String, int>{};
    for (var i = 0; i < episodes.length; i++) {
      epOrder[episodes[i].id] = i;
    }
    mainVideos.sort((a, b) {
      final oa = epOrder[a.episodeId] ?? 999999;
      final ob = epOrder[b.episodeId] ?? 999999;
      if (oa != ob) return oa.compareTo(ob);
      return b.fileSize.compareTo(a.fileSize);
    });
    final chosenVariant = mainVideos.first;
    final source = await _repository.findSourceById(chosenVariant.sourceId);

    return _extractor.extractCandidateFrames(
      variant: chosenVariant,
      source: source,
      sampleCount: sampleCount,
      phaseOffset: phaseOffset,
      isCancelled: isCancelled,
    );
  }

  /// 将用户在弹窗中选中的正片抽帧落盘至 `backdrops/` 并持久化为锁定背景图。
  Future<String> applyExtractedBackdropFrame({
    required Work work,
    required Uint8List pngBytes,
  }) async {
    if (pngBytes.isEmpty) {
      throw StateError('选中的抽帧画面为空');
    }
    final savedFile = await _photosStorage.saveCustomArtwork(
      workId: work.id,
      subfolder: PhotoSubfolder.backdrops,
      bytes: pngBytes,
      extension: '.png',
      title: work.title,
    );
    final latest = await _repository.findWorkById(work.id) ?? work;
    await _repository.upsertWork(
      latest.copyWith(backdropPath: savedFile.path, backdropLocked: true),
    );

    final mainEpisodes = (await _repository.getEpisodesByWork(
      work.id,
    )).where((e) => e.category == EpisodeCategory.main).toList(growable: false);
    if (mainEpisodes.length == 1 &&
        needsAutoMainEpisodeStill(mainEpisodes.single)) {
      await _repository.upsertEpisode(
        mainEpisodes.single.copyWith(stillPath: savedFile.path),
      );
    }
    onWorkUpdated?.call(work.id);
    return savedFile.path;
  }
}
