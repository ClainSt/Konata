import 'dart:developer' as developer;

import 'package:engine_sources/engine_sources.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import '../matching/directory_grouper.dart';
import '../matching/episode_remapper.dart';
import '../matching/supplementary_folder_rules.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../network/tmdb_service.dart';
import '../parsing/bdrip_parser.dart';
import '../parsing/release_groups.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/scrape_rules.dart' as rules;
import 'library_repository.dart';
import 'scrape_candidate_fetcher.dart';
import 'scrape_compute_worker.dart';
import 'scrape_source_scanner.dart';
import 'scrape_work_persister.dart';
import 'work_artwork_storage.dart';

/// 单作品目录自动同步结果。
class SingleWorkSyncResult {
  /// 创建同步结果。
  const SingleWorkSyncResult({
    required this.changed,
    this.addedFileCount = 0,
    this.removedFileCount = 0,
    this.workRemoved = false,
    this.skippedDueToError = false,
    this.work,
  });

  /// 目录无任何变更（零写库、零外部元数据请求）。
  static const SingleWorkSyncResult unchanged = SingleWorkSyncResult(
    changed: false,
  );

  /// 媒体源离线、限流或网络异常时安全跳过（绝不误删库内已有剧集）。
  static const SingleWorkSyncResult errorSkipped = SingleWorkSyncResult(
    changed: false,
    skippedDueToError: true,
  );

  /// 本次同步是否产生了数据库增删改。
  final bool changed;

  /// 本次新增或发生变更的物理文件数量（含新增集数、特典或外挂字幕变更）。
  final int addedFileCount;

  /// 本次从媒体库清理掉的已删除物理文件数量。
  final int removedFileCount;

  /// 该作品全部物理文件均已移除且已从媒体库清理。
  final bool workRemoved;

  /// 本次是否因网络/权限/限流等访问异常安全跳过。
  final bool skippedDueToError;

  /// 同步后的作品实体（作品被清理时为 `null`）。
  final Work? work;
}

class _WorkRootScope {
  const _WorkRootScope({
    required this.rootDir,
    required this.sharedWithOtherWorks,
    required this.existingVariants,
  });

  final String rootDir;
  final bool sharedWithOtherWorks;
  final List<MediaVariant> existingVariants;
}

/// 单作品目录增量同步与已匹配作品快通道服务。
///
/// 职责边界：
/// 1. 追番增量加集/换字幕时走零搜索快通道，仅按需拉取目标季单集标题与剧照，不重跑搜索与艺术图；
/// 2. 源文件被删时精准移除失效变体并立即清理孤儿剧集，杜绝详情页残留不可播幽灵集；
/// 3. 仅在确认媒体源可达且目标文件/目录真实缺失时才执行清理，断网、CD2 未启动或 429 限流时严格保护库记录。
class WorkDirectorySyncService {
  /// 创建单作品目录同步服务。
  WorkDirectorySyncService({
    required this._repository,
    required this._tmdbService,
    required this._candidateFetcher,
    required this._persister,
    required this._gatewayBuilder,
    this._scanner = const ScrapeDirectoryScanner(),
    this._computeWorker = const ScrapeComputeWorker(),
    this._photosStorage,
  });

  static final RegExp _trimSlashes = RegExp(r'^/+|/+$');
  static final RegExp _discOrBdSegment = RegExp(
    r'^(?:bdmv|stream|video_ts|disc[\s._-]*\d+|disk[\s._-]*\d+|vol(?:ume)?[\s._-]*\d+|subs?|subtitles?)$',
    caseSensitive: false,
  );
  static final RegExp _nonAlnumCjk = RegExp(
    r'[^a-z0-9\u4e00-\u9fff\u3040-\u30ff]+',
    caseSensitive: false,
  );
  static final RegExp _genericZhEpTitle = RegExp(r'^第\s*\d+\s*[集话話]$');
  static final RegExp _genericEnEpTitle = RegExp(
    r'^Episode\s*\d+$',
    caseSensitive: false,
  );

  final LibraryRepository _repository;
  final TmdbService _tmdbService;
  final ScrapeCandidateFetcher _candidateFetcher;
  final ScrapeWorkPersister _persister;
  final Future<MediaSourceGateway> Function(MediaSource source) _gatewayBuilder;
  final DirectoryScanner _scanner;
  final ScrapeComputeWorker _computeWorker;
  final WorkArtworkStoragePort? _photosStorage;

  /// 已匹配作品增量加集/同步快通道（全量重扫与单作品自动同步共用）。
  ///
  /// 跳过全部 TMDB/Bangumi 候选搜索、打分、Fanart 与 ClearLogo，仅当新增了尚未缓存标题的剧集时
  /// 才按需请求目标季单集清单，实现追番加集亚秒级入库。
  Future<void> syncMatchedWorkEpisodesOnly({
    required Work work,
    required GroupedWorkFolder folder,
    Map<String, MediaVariant>? preloadedSourceVariantsById,
    Future<void> Function(Future<void> Function() action)? runPersist,
    bool Function()? isCancelled,
  }) async {
    Future<void> persist(Future<void> Function() action) =>
        runPersist != null ? runPersist(action) : action();

    if (isCancelled?.call() ?? false) return;
    await ReleaseGroups.prepare();

    final existingEpisodes = await _repository.getEpisodesByWork(work.id);
    final existingMainNumbers = <int>{
      for (final ep in existingEpisodes)
        if (ep.category == EpisodeCategory.main &&
            ep.episodeNumber != null &&
            ep.title != null &&
            ep.title!.trim().isNotEmpty &&
            !_isGenericEpisodeTitle(ep.title!))
          ep.episodeNumber!,
    };

    final existingVariants = await _repository.getVariantsByWork(work.id);
    final existingVariantPaths = <String>{
      for (final v in existingVariants) _normalizePath(v.relativePath),
    };
    final needTmdbFetch =
        work.tmdbId != null &&
        work.tmdbMediaType != null &&
        _needsRemoteEpisodeMetadata(
          work: work,
          folder: folder,
          existingTitledMainNumbers: existingMainNumbers,
          existingVariantPaths: existingVariantPaths,
        );

    TmdbWorkDetail? liteDetail;
    List<TmdbEpisodeDetail> tmdbEpisodes = const [];
    String? seasonName;
    EpisodeRemapPlan? remapPlan;

    if (needTmdbFetch) {
      final seasons = <int>{
        ...rules.referencedSeasonsToFetch(
          folder,
          matchedSeason: work.matchedSeason,
        ),
        if (work.matchedSeason != null && work.matchedSeason! > 0)
          work.matchedSeason!,
      };
      if (work.tmdbMediaType == TmdbMediaType.tv) {
        try {
          liteDetail = await _tmdbService.getWorkDetail(
            work.tmdbId!,
            work.tmdbMediaType!,
            priority: RequestPriority.background,
            includeImages: false,
          );
        } catch (error) {
          developer.log(
            '追番增量快通道预拉基础剧季结构失败，继续同步单集文件',
            name: 'konata.work_directory_sync',
            error: error,
          );
        }
      }

      final preRemap =
          (liteDetail != null &&
              liteDetail.mediaType == TmdbMediaType.tv &&
              liteDetail.seasons.isNotEmpty)
          ? EpisodeRemapper.buildPlan(
              folder: folder,
              tmdbSeasons: liteDetail.seasons,
              matchedSeason: work.matchedSeason,
            )
          : null;
      if (preRemap != null) {
        seasons.addAll(preRemap.referencedSeasons);
      }

      if (seasons.isNotEmpty) {
        final bundle = await _candidateFetcher.fetchSeasonBundle(
          work.tmdbId!,
          work.tmdbMediaType!,
          seasons,
        );
        tmdbEpisodes = bundle.episodes;
        if (work.matchedSeason != null) {
          seasonName = bundle.seasonDetails[work.matchedSeason!]?.name;
        }
      }

      final needBgmEpisodes =
          work.bangumiId != null &&
          EpisodeRemapper.shouldFetchBangumiEpisodes(
            matchedSeason: work.matchedSeason,
            tmdbEpisodes: tmdbEpisodes,
            preRemap: preRemap,
          );
      final expectedMainCount = folder.mainEpisodeNumbers.toSet().length;
      final bgmEpisodes = needBgmEpisodes
          ? (work.matchedSeason == 0
                ? await _candidateFetcher.fetchBangumiEpisodesForSeasonZero(
                    work.bangumiId!,
                    expectedMainCount: expectedMainCount > 0
                        ? expectedMainCount
                        : 1,
                  )
                : await _candidateFetcher.fetchBangumiEpisodes(
                    work.bangumiId!,
                    type: null,
                  ))
          : const <BangumiEpisodeEntry>[];

      remapPlan =
          (liteDetail != null &&
              liteDetail.mediaType == TmdbMediaType.tv &&
              liteDetail.seasons.isNotEmpty)
          ? EpisodeRemapper.buildPlan(
              folder: folder,
              tmdbSeasons: liteDetail.seasons,
              matchedSeason: work.matchedSeason,
              tmdbEpisodes: tmdbEpisodes,
              bangumiEpisodes: bgmEpisodes,
            )
          : preRemap;

      if (isCancelled?.call() ?? false) return;
      await persist(() async {
        await _persister.syncEpisodesAndVariants(
          work: work,
          folder: folder,
          tmdbEpisodes: tmdbEpisodes,
          bangumiEpisodes: bgmEpisodes,
          remapPlan: remapPlan,
          seasonName: seasonName,
          preloadedSourceVariantsById: preloadedSourceVariantsById,
        );
      });
      return;
    }

    // 仅 Bangumi 绑定（无 TMDB）且新增了正片集数时，直接拉取 Bangumi 分集标题。
    final needBgmOnly =
        work.tmdbId == null &&
        work.bangumiId != null &&
        _needsRemoteEpisodeMetadata(
          work: work,
          folder: folder,
          existingTitledMainNumbers: existingMainNumbers,
        );
    final bgmEpisodes = needBgmOnly
        ? await _candidateFetcher.fetchBangumiEpisodes(
            work.bangumiId!,
            type: null,
          )
        : const <BangumiEpisodeEntry>[];

    if (isCancelled?.call() ?? false) return;
    await persist(() async {
      await _persister.syncEpisodesAndVariants(
        work: work,
        folder: folder,
        tmdbEpisodes: const [],
        bangumiEpisodes: bgmEpisodes,
        preloadedSourceVariantsById: preloadedSourceVariantsById,
      );
    });
  }

  /// 对单个作品所在目录执行轻量增量同步：自动追加新集/特典/字幕，自动清理已删除文件与孤儿剧集。
  Future<SingleWorkSyncResult> syncSingleWork(
    String workId, {
    bool Function()? isCancelled,
  }) async {
    final work = await _repository.findWorkById(workId);
    if (work == null) return SingleWorkSyncResult.unchanged;

    final workVariants = await _repository.getVariantsByWork(workId);
    if (workVariants.isEmpty) return SingleWorkSyncResult.unchanged;
    await ReleaseGroups.prepare();

    final variantsBySource = <String, List<MediaVariant>>{};
    for (final v in workVariants) {
      variantsBySource.putIfAbsent(v.sourceId, () => <MediaVariant>[]).add(v);
    }

    var totalAdded = 0;
    var totalRemoved = 0;
    var anyErrorSkipped = false;
    var anyChanged = false;

    for (final entry in variantsBySource.entries) {
      if (isCancelled?.call() ?? false) break;
      final sourceId = entry.key;
      final sourceWorkVariants = entry.value;
      final source = await _repository.findSourceById(sourceId);
      if (source == null) continue;

      final allSourceVariants = await _repository.getVariantsBySource(sourceId);
      final scopes = _resolveWorkRootScopes(
        workId: workId,
        workVariants: sourceWorkVariants,
        allSourceVariants: allSourceVariants,
      );
      if (scopes.isEmpty) continue;

      final otherWorkPaths = <String>{
        for (final v in allSourceVariants)
          if (v.workId != workId) _normalizePath(v.relativePath),
      };

      MediaSourceGateway? gateway;
      try {
        gateway = await _gatewayBuilder(source);
        final outcome = await _syncSourceScopes(
          work: work,
          source: source,
          gateway: gateway,
          scopes: scopes,
          otherWorkPaths: otherWorkPaths,
          allSourceVariants: allSourceVariants,
          isCancelled: isCancelled,
        );
        totalAdded += outcome.added;
        totalRemoved += outcome.removed;
        if (outcome.changed) anyChanged = true;
        if (outcome.errorSkipped) anyErrorSkipped = true;
      } catch (error) {
        anyErrorSkipped = true;
        developer.log(
          '单作品目录自动同步遇到访问异常，已安全跳过保护库记录（workId=$workId）',
          name: 'konata.work_directory_sync',
          error: error,
        );
      } finally {
        if (gateway != null) {
          try {
            await gateway.close();
          } catch (closeError) {
            developer.log(
              '关闭单作品同步网关异常忽略',
              name: 'konata.work_directory_sync',
              error: closeError,
            );
          }
        }
      }
    }

    if (!anyChanged) {
      return anyErrorSkipped
          ? SingleWorkSyncResult.errorSkipped
          : SingleWorkSyncResult.unchanged;
    }

    // 若本作品全部物理文件均已被确认删除（且无访问异常），清理空作品及本地图片缓存目录。
    final remainingVariants = await _repository.getVariantsByWork(workId);
    if (remainingVariants.isEmpty && !anyErrorSkipped) {
      await _repository.deleteWork(workId);
      try {
        await _photosStorage?.deleteWorkPhotos(workId);
      } catch (photoErr) {
        developer.log(
          '清理已移除作品图片目录失败，忽略不影响主流程',
          name: 'konata.work_directory_sync',
          error: photoErr,
        );
      }
      return SingleWorkSyncResult(
        changed: true,
        addedFileCount: totalAdded,
        removedFileCount: totalRemoved,
        workRemoved: true,
      );
    }

    await _repository.deleteOrphanEpisodes(workId);
    final refreshedWork = await _repository.findWorkById(workId);
    return SingleWorkSyncResult(
      changed: true,
      addedFileCount: totalAdded,
      removedFileCount: totalRemoved,
      workRemoved: false,
      skippedDueToError: anyErrorSkipped,
      work: refreshedWork ?? work,
    );
  }

  Future<({bool changed, int added, int removed, bool errorSkipped})>
  _syncSourceScopes({
    required Work work,
    required MediaSource source,
    required MediaSourceGateway gateway,
    required List<_WorkRootScope> scopes,
    required Set<String> otherWorkPaths,
    required List<MediaVariant> allSourceVariants,
    bool Function()? isCancelled,
  }) async {
    final removedVariantIds = <String>[];
    final survivingAndNewFiles = <ScannedFileInput>[];
    var addedOrChangedCount = 0;
    var errorSkipped = false;

    for (final scope in scopes) {
      if (isCancelled?.call() ?? false) break;

      final scanOutcome = await _scanSingleScopeSafely(
        gateway: gateway,
        sourceKind: source.kind,
        rootDir: scope.rootDir,
        hadExistingVariants: scope.existingVariants.isNotEmpty,
        isCancelled: isCancelled,
      );
      if (scanOutcome.errorSkipped) {
        errorSkipped = true;
        continue;
      }

      final liveFiles = scanOutcome.files;
      final liveByNormPath = <String, ScannedFileInput>{
        for (final f in liveFiles) _normalizePath(f.relativePath): f,
      };
      final existingByNormPath = <String, MediaVariant>{
        for (final v in scope.existingVariants)
          _normalizePath(v.relativePath): v,
      };

      // 1) 识别已从目录中删除的旧文件变体（独占目录与共享目录均可 100% 精确判定）。
      final survivingNormPaths = <String>{};
      for (final entry in existingByNormPath.entries) {
        if (!liveByNormPath.containsKey(entry.key)) {
          removedVariantIds.add(entry.value.id);
        } else {
          survivingNormPaths.add(entry.key);
        }
      }

      // 2) 识别新增或发生大小/字幕变更的文件。
      final candidateFiles = <ScannedFileInput>[];
      if (!scope.sharedWithOtherWorks) {
        for (final f in liveFiles) {
          final norm = _normalizePath(f.relativePath);
          if (otherWorkPaths.contains(norm)) continue;
          candidateFiles.add(f);
        }
      } else {
        // 共享混放目录：绝不窃取其他作品或兄弟拆簇的文件，优先按完整目录实时拆簇边界筛选本作品归属文件。
        final unownedFiles = [
          for (final f in liveFiles)
            if (!otherWorkPaths.contains(_normalizePath(f.relativePath))) f,
        ];
        final picked = await _pickOwnedFilesInSharedScope(
          work: work,
          sourceId: source.id,
          liveFiles: liveFiles,
          unownedFiles: unownedFiles,
          survivingNormPaths: survivingNormPaths,
          otherWorkPaths: otherWorkPaths,
        );
        candidateFiles.addAll(picked);
      }

      for (final f in candidateFiles) {
        final norm = _normalizePath(f.relativePath);
        final prev = existingByNormPath[norm];
        if (prev == null || _hasVariantChanged(prev, f)) {
          addedOrChangedCount++;
        }
        survivingAndNewFiles.add(f);
      }
    }

    if (removedVariantIds.isEmpty && addedOrChangedCount == 0) {
      return (
        changed: false,
        added: 0,
        removed: 0,
        errorSkipped: errorSkipped,
      );
    }

    // 先删除已移除文件的物理变体记录，随后按需补齐新增集数与孤儿剧集清理。
    if (removedVariantIds.isNotEmpty) {
      await _repository.deleteMediaVariantsBatch(removedVariantIds);
    }

    if (addedOrChangedCount > 0 && survivingAndNewFiles.isNotEmpty) {
      final preloadedById = <String, MediaVariant>{
        for (final v in allSourceVariants)
          if (!removedVariantIds.contains(v.id)) v.id: v,
      };
      final folder = await _buildMergedFolderForWork(
        work: work,
        sourceId: source.id,
        files: survivingAndNewFiles,
        primaryRootDir: scopes.first.rootDir,
      );
      if (folder != null) {
        await syncMatchedWorkEpisodesOnly(
          work: work,
          folder: folder,
          preloadedSourceVariantsById: preloadedById,
          isCancelled: isCancelled,
        );
      }
    }

    return (
      changed: true,
      added: addedOrChangedCount,
      removed: removedVariantIds.length,
      errorSkipped: errorSkipped,
    );
  }

  /// 安全扫描单个作品子目录：遇到路径 404/不存在时二次校验父目录可达性，严防断网/盘符未挂载误删库记录。
  Future<({List<ScannedFileInput> files, bool errorSkipped})>
  _scanSingleScopeSafely({
    required MediaSourceGateway gateway,
    required MediaSourceKind sourceKind,
    required String rootDir,
    required bool hadExistingVariants,
    bool Function()? isCancelled,
  }) async {
    try {
      final res = await _scanner.scan(
        gateway,
        scanRoots: rootDir.isEmpty ? const [] : [rootDir],
        profileOverride: DirectoryScanProfile.forSourceKind(sourceKind),
        detectLocalCovers: false,
        isCancelled: isCancelled,
      );
      if (res.cancelled) {
        return (files: const <ScannedFileInput>[], errorSkipped: true);
      }
      // 远程目录若返回完全空集但原先有文件，二次确认父目录可正常列举，防网盘临时返回空目录视图误删。
      if (res.files.isEmpty &&
          hadExistingVariants &&
          rootDir.isNotEmpty &&
          sourceKind != MediaSourceKind.local) {
        final reachable = await _isParentDirectoryReachable(gateway, rootDir);
        if (!reachable) {
          return (files: const <ScannedFileInput>[], errorSkipped: true);
        }
      }
      return (files: res.files, errorSkipped: false);
    } catch (error) {
      final kind = SourceAccessErrorClassifier.classify(error, sourceKind).kind;
      if (kind == SourceAccessProblemKind.path && rootDir.isNotEmpty) {
        final confirmedMissing = await _confirmDirectoryRemovedOnReachableSource(
          gateway,
          rootDir,
        );
        if (confirmedMissing) {
          return (files: const <ScannedFileInput>[], errorSkipped: false);
        }
      }
      developer.log(
        '扫描单作品目录失败，保守跳过避免误删（dir=$rootDir）',
        name: 'konata.work_directory_sync',
        error: error,
      );
      return (files: const <ScannedFileInput>[], errorSkipped: true);
    }
  }

  Future<bool> _isParentDirectoryReachable(
    MediaSourceGateway gateway,
    String dirPath,
  ) async {
    final parent = _parentDirOf(dirPath);
    try {
      await gateway.listDirectory(parent);
      return true;
    } catch (error) {
      developer.log(
        '父目录可达性校验失败（parent=$parent）',
        name: 'konata.work_directory_sync',
        error: error,
      );
      return false;
    }
  }

  /// 二次校验目标目录是否确实已从可达媒体源中删除（要求父目录或源根目录本身可正常列出且不再包含该目录）。
  Future<bool> _confirmDirectoryRemovedOnReachableSource(
    MediaSourceGateway gateway,
    String missingDir,
  ) async {
    final norm = _normalizePath(missingDir);
    if (norm.isEmpty) return false;
    final parent = _parentDirOf(norm);
    final leaf = norm.split('/').last.toLowerCase();
    try {
      final siblings = await gateway.listDirectory(parent);
      final stillExists = siblings.any(
        (e) => e.isDirectory && e.name.trim().toLowerCase() == leaf,
      );
      return !stillExists;
    } catch (parentError) {
      // 若直接父目录也消失（例如连同系列父目录一起删了），再向上核验源根目录是否仍在线。
      if (parent.isEmpty) {
        developer.log(
          '源根目录不可达，拒绝判定目录删除（dir=$norm）',
          name: 'konata.work_directory_sync',
          error: parentError,
        );
        return false;
      }
      try {
        final rootEntries = await gateway.listDirectory('');
        final topSegment = norm.split('/').first.toLowerCase();
        final topExists = rootEntries.any(
          (e) => e.isDirectory && e.name.trim().toLowerCase() == topSegment,
        );
        return !topExists;
      } catch (rootError) {
        developer.log(
          '媒体源根目录不可达，中止删除判定（dir=$norm）',
          name: 'konata.work_directory_sync',
          error: rootError,
        );
        return false;
      }
    }
  }

  /// 根据作品既有变体与同源全部变体，精确解析每个待扫描作品根目录及其独占/共享属性。
  static List<_WorkRootScope> _resolveWorkRootScopes({
    required String workId,
    required List<MediaVariant> workVariants,
    required List<MediaVariant> allSourceVariants,
  }) {
    final otherWorkDirs = <String>{};
    for (final v in allSourceVariants) {
      if (v.workId == workId) continue;
      final norm = _normalizePath(v.relativePath);
      final dir = _parentDirOf(norm);
      if (dir.isNotEmpty) {
        otherWorkDirs.add(dir);
      }
    }

    bool hasOtherWorkUnder(String candidateRoot) {
      if (candidateRoot.isEmpty) return otherWorkDirs.isNotEmpty;
      final prefix = '$candidateRoot/';
      for (final otherDir in otherWorkDirs) {
        if (otherDir == candidateRoot || otherDir.startsWith(prefix)) {
          return true;
        }
      }
      return false;
    }

    // 先把每个变体向上归并到跳过季/特典/BDMV子目录后的候选作品根目录。
    final candidateByVariant = <String, List<MediaVariant>>{};
    for (final v in workVariants) {
      final norm = _normalizePath(v.relativePath);
      final leafDir = _parentDirOf(norm);
      final logicalRoot = _climbPastSubfolders(leafDir);
      // 若向上爬升后意外撞到了包含其他作品的公共父目录，则退回叶目录并标记共享。
      final chosenRoot =
          (logicalRoot != leafDir && hasOtherWorkUnder(logicalRoot))
          ? leafDir
          : logicalRoot;
      candidateByVariant
          .putIfAbsent(chosenRoot, () => <MediaVariant>[])
          .add(v);
    }

    // 合并存在父子包含关系的候选根（仅当父目录不与其他作品冲突时）。
    final sortedRoots = candidateByVariant.keys.toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    final mergedBuckets = <String, List<MediaVariant>>{};
    for (final root in sortedRoots) {
      final variants = candidateByVariant[root]!;
      String? coveredParent;
      for (final existingRoot in mergedBuckets.keys) {
        if (existingRoot.isEmpty) continue;
        if ((root == existingRoot || root.startsWith('$existingRoot/')) &&
            !hasOtherWorkUnder(existingRoot)) {
          coveredParent = existingRoot;
          break;
        }
      }
      if (coveredParent != null) {
        mergedBuckets[coveredParent]!.addAll(variants);
      } else {
        mergedBuckets[root] = [...variants];
      }
    }

    return [
      for (final e in mergedBuckets.entries)
        _WorkRootScope(
          rootDir: e.key,
          sharedWithOtherWorks: e.key.isEmpty || hasOtherWorkUnder(e.key),
          existingVariants: e.value,
        ),
    ];
  }

  /// 跳过 `Season 1` / `SPs` / `CDs` / `Scans` / `BDMV/STREAM` 等作品内部子目录，定位作品根文件夹。
  static String _climbPastSubfolders(String leafDir) {
    final norm = _normalizePath(leafDir);
    if (norm.isEmpty) return '';
    final segments = norm.split('/');
    var end = segments.length;
    while (end > 1) {
      final seg = segments[end - 1].trim();
      if (SupplementaryFolderRules.isSupplementarySegment(seg) ||
          SupplementaryFolderRules.isSeasonOrVolumeSegment(seg) ||
          _discOrBdSegment.hasMatch(seg)) {
        end--;
      } else {
        break;
      }
    }
    return segments.sublist(0, end).join('/');
  }

  Future<List<ScannedFileInput>> _pickOwnedFilesInSharedScope({
    required Work work,
    required String sourceId,
    required List<ScannedFileInput> liveFiles,
    required List<ScannedFileInput> unownedFiles,
    required Set<String> survivingNormPaths,
    required Set<String> otherWorkPaths,
  }) async {
    if (unownedFiles.isEmpty) return const [];

    // 优先使用与全量扫描同源的确定性拆簇引擎划定共享目录内各子作品边界
    // （如 `TV + Movie 1 + Movie 2` 或 `剧场版前篇 + 后篇` 混放目录），
    // 严格只接纳落入当前作品所属子簇的新增文件，彻底杜绝兄弟子簇特典/CD/Scan 串吸。
    if (survivingNormPaths.isNotEmpty && liveFiles.length >= 2) {
      final grouped = await _computeWorker.groupFiles(
        sourceId: sourceId,
        files: liveFiles,
      );
      if (grouped.length >= 2) {
        final allowedClusterPaths = <String>{};
        for (final cluster in grouped) {
          final clusterPaths = <String>{
            for (final v in cluster.variants) _normalizePath(v.relativePath),
          };
          var ownHits = 0;
          var otherHits = 0;
          for (final path in clusterPaths) {
            if (survivingNormPaths.contains(path)) ownHits++;
            if (otherWorkPaths.contains(path)) otherHits++;
          }
          if (ownHits > 0 && ownHits >= otherHits) {
            allowedClusterPaths.addAll(clusterPaths);
          }
        }
        if (allowedClusterPaths.isNotEmpty) {
          return [
            for (final f in unownedFiles)
              if (survivingNormPaths.contains(_normalizePath(f.relativePath)) ||
                  allowedClusterPaths.contains(_normalizePath(f.relativePath)))
                f,
          ];
        }
      }
    }

    // 非多作拆簇的扁平共享目录回落至片名词干归属核验，同时剔除明显指向兄弟篇章/年份的新文件。
    final workStems = <String>{
      _normalizeTitleKey(work.title),
      if (work.originalTitle != null) _normalizeTitleKey(work.originalTitle!),
      for (final path in survivingNormPaths)
        _normalizeTitleKey(
          BdripParser.parseFileName(p.posix.basename(path)).cleanTitle,
        ),
    }..removeWhere((s) => s.length < 2);

    bool matchesWorkStem(String fileName) {
      if (workStems.isEmpty) return false;
      final candidateStem = _normalizeTitleKey(
        BdripParser.parseFileName(fileName).cleanTitle,
      );
      if (candidateStem.length < 2) return false;
      for (final stem in workStems) {
        if (candidateStem == stem ||
            (candidateStem.length >= 3 &&
                stem.length >= 3 &&
                (candidateStem.contains(stem) ||
                    stem.contains(candidateStem)))) {
          return true;
        }
      }
      return false;
    }

    return [
      for (final f in unownedFiles)
        if (survivingNormPaths.contains(_normalizePath(f.relativePath)) ||
            matchesWorkStem(f.fileName))
          f,
    ];
  }

  Future<GroupedWorkFolder?> _buildMergedFolderForWork({
    required Work work,
    required String sourceId,
    required List<ScannedFileInput> files,
    required String primaryRootDir,
  }) async {
    final grouped = await _computeWorker.groupFiles(
      sourceId: sourceId,
      files: files,
    );
    if (grouped.isEmpty) return null;
    if (grouped.length == 1) return grouped.first;

    // 同一独占作品目录下多压制组子文件夹并存时，将全部变体合并归入本作品同步（不拆裂为多张卡）。
    final first = grouped.first;
    final allVariants = <MediaVariant>[];
    final seenPaths = <String>{};
    final allMainEps = <int>{};
    for (final g in grouped) {
      for (final v in g.variants) {
        final norm = _normalizePath(v.relativePath);
        if (seenPaths.add(norm)) {
          allVariants.add(v);
        }
      }
      allMainEps.addAll(g.mainEpisodeNumbers);
    }
    final sortedMainEps = allMainEps.toList()..sort();
    return GroupedWorkFolder(
      folderRelativePath: primaryRootDir.isNotEmpty
          ? primaryRootDir
          : first.folderRelativePath,
      folderName: primaryRootDir.isNotEmpty
          ? primaryRootDir.split('/').last
          : first.folderName,
      cleanTitle: work.title.trim().isNotEmpty ? work.title : first.cleanTitle,
      explicitTmdbId: work.tmdbId ?? first.explicitTmdbId,
      explicitMediaType: work.tmdbMediaType ?? first.explicitMediaType,
      year: work.year ?? first.year,
      seasonHint: work.matchedSeason ?? first.seasonHint,
      mainEpisodeNumbers: sortedMainEps,
      isMovieHint: work.tmdbMediaType == TmdbMediaType.movie,
      variants: allVariants,
      inventory: first.inventory,
      physicalRootFolder: primaryRootDir.isNotEmpty
          ? primaryRootDir
          : first.physicalRootFolder,
      localPosterPath: first.localPosterPath,
    );
  }

  static bool _needsRemoteEpisodeMetadata({
    required Work work,
    required GroupedWorkFolder folder,
    required Set<int> existingTitledMainNumbers,
    Set<String> existingVariantPaths = const {},
  }) {
    if (work.tmdbMediaType == TmdbMediaType.movie) {
      return false;
    }
    // 若存在任何尚无正式标题的新增正片集号，才需要向 TMDB / Bangumi 请求单季分集列表。
    for (final epNum in folder.mainEpisodeNumbers) {
      if (!existingTitledMainNumbers.contains(epNum)) {
        return true;
      }
    }
    // 新增了未入库的特典/SP 视频文件时，同样需拉取 Season 0 单集清单以完成特别篇标题与剧照对齐。
    if (work.tmdbMediaType == TmdbMediaType.tv &&
        existingVariantPaths.isNotEmpty) {
      for (final v in folder.variants) {
        if (v.assetKind != AssetKind.video) continue;
        if (!existingVariantPaths.contains(_normalizePath(v.relativePath))) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _isGenericEpisodeTitle(String title) {
    final trimmed = title.trim();
    return _genericZhEpTitle.hasMatch(trimmed) ||
        _genericEnEpTitle.hasMatch(trimmed);
  }

  static bool _hasVariantChanged(MediaVariant prev, ScannedFileInput live) {
    if (prev.fileSize != live.fileSize || prev.assetKind != live.assetKind) {
      return true;
    }
    if (prev.externalSubtitles.length != live.externalSubtitles.length) {
      return true;
    }
    if (prev.externalSubtitles.isEmpty) return false;
    final a = List<String>.of(prev.externalSubtitles)..sort();
    final b = List<String>.of(live.externalSubtitles)..sort();
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return true;
    }
    return false;
  }

  static String _normalizePath(String raw) =>
      raw.trim().replaceAll('\\', '/').replaceAll(_trimSlashes, '');

  static String _parentDirOf(String normalizedPath) {
    final parent = p.posix.dirname(normalizedPath);
    return (parent == '.' || parent == '/') ? '' : parent;
  }

  static String _normalizeTitleKey(String raw) =>
      raw.trim().toLowerCase().replaceAll(_nonAlnumCjk, '');
}
