import 'dart:developer' as developer;

import 'package:konata_contracts/konata_contracts.dart';

import '../models/media_variant.dart';
import '../models/series_group.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../network/bangumi_service.dart';
import '../network/tmdb_service.dart';
import '../parsing/season_number_parser.dart';
import '../scraping/bangumi_models.dart';
import 'library_repository.dart';

/// 系列（Series）自动编组协同器。
///
/// 综合参考 TMDB 同系列多季（相同 `tmdbId`）、TMDB 电影合集（相同
/// `tmdbCollectionId`）、物理合集根目录与 Bangumi 条目关联关系（前传/续集/
/// 剧场版/番外等），将媒体库中的相关独立作品自动归入同一 `SeriesGroup`，同时
/// 严格尊重人工锁定的 `seriesLocked` 归属与排序标签。
class SeriesAutoLinker {
  SeriesAutoLinker._();

  static const Set<String> _eligibleRelations = {
    '前传',
    '续集',
    '剧场版',
    '总集篇',
    '番外篇',
    '主线故事',
    '衍生',
    '不同演绎',
    'prequel',
    'sequel',
    'spin-off',
    'side story',
    'summary',
    'main story',
    'alternative version',
  };

  static const Set<String> _genericDirectoryNames = {
    '',
    '.',
    'anime',
    'animes',
    'animation',
    'bangumi',
    'tv',
    'tvs',
    'series',
    'shows',
    'movie',
    'movies',
    'film',
    'films',
    'ova',
    'ovas',
    'oad',
    'special',
    'specials',
    'download',
    'downloads',
    'media',
    'video',
    'videos',
    'bdrip',
    'raw',
    'raws',
    'collection',
    'collections',
    '动画',
    '动漫',
    '番剧',
    '新番',
    '连载',
    '完结',
    '剧场版',
    '电影',
    '合集',
    '待整理',
    '待分类',
    '未添加tmdb id',
    'unsorted',
    'uncategorized',
  };

  static final RegExp _seasonDirPattern = RegExp(
    r'^(?:season[\s._-]*\d+|s\d{1,2}|第\s*[0-9一二三四五六七八九十两]+\s*[季期]|part[\s._-]*\d+|cour[\s._-]*\d+|disc[\s._-]*\d+|bdmv|stream)$',
    caseSensitive: false,
  );

  static final RegExp _supplementaryDirPattern = RegExp(
    r'^(?:extra|extras|sp|sps|special|specials|bonus|ncop|nced|creditless|menu|menus|pv|pvs|cm|cms|mv|mvs|cd|cds|scan|scans|booklet|booklets|ova|oad)(?:[\s._-].*)?$',
    caseSensitive: false,
  );

  static final RegExp _yearFolderPattern = RegExp(
    r'^(?:19|20)\d{2}(?:[-._]\d{1,2})?(?:年.*)?$',
  );

  static final RegExp _seasonMarkerDirPattern = RegExp(
    r'(?:^|[\s._-])(?:season[\s._-]*\d+|s0?\d+|第\s*[0-9一二三四五六七八九十两]+\s*[季期]|系列|合集|全集|series|collection|剧场版|movie|ova|oad)(?:$|[\s._-])',
    caseSensitive: false,
  );

  static final RegExp _franchiseContainerPattern = RegExp(
    r'(?:系列|合集|全集|总集|series|collection|franchise)$',
    caseSensitive: false,
  );

  static final RegExp _trailingSeasonSuffixPattern = RegExp(
    r'(?:\s+(?:第\s*[0-9一二三四五六七八九十两]+\s*[季期]|season\s*\d+|s\d{1,2}|part\s*\d+|剧场版.*|the\s+movie.*))$',
    caseSensitive: false,
  );

  static final RegExp _subtitleBoundaryPattern = RegExp(
    r'^(?:[:：\-—～~·/／!！?？(（\[【\s]|剧场版|电影版|总集篇|特别篇|特別編|ova|oad|movie|the\s+movie)',
    caseSensitive: false,
  );

  static final RegExp _spinOffKeywordPattern = RegExp(
    r'(?:剧场版|电影版|总集篇|特别篇|特別編|ova|oad|movie|the\s+movie|infinite|burst)',
    caseSensitive: false,
  );

  static final RegExp _cjkCharPattern = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff]');
  static final RegExp _leadingSlashPattern = RegExp(r'^/+');
  static final RegExp _whitespaceCollapsePattern = RegExp(r'\s+');
  static final RegExp _compactStemStripPattern = RegExp(
    r'[\s\-_:：·・!！?？/／()（）\[\]【】]',
  );

  /// 在全库或局部分析后，对媒体库作品执行自动系列编组与 ClearLogo 交叉纠偏。
  ///
  /// 支持传入调用方已预载的 [preloadedWorks] 与 [preloadedVariants] 以避免启动期重复全表扫描。
  /// - 传入非空 [focusBangumiIds] 时，仅对本次新增或发生身份变动的 Bangumi ID 发起关联查询，
  ///   避免大库在增量重扫或单作品重绑收尾时重复对全部老作品发起冗余 Bangumi API 请求；
  /// - 传入非空 [focusWorkIds] 时，在线 TMDB 剧场版 ClearLogo 交叉校验仅针对含本次变更成员或新合并成员的
  ///   TV+电影混合系列执行，彻底消除扫描收尾对全库无关电影的串行网络请求；
  /// - 传入 [relationCache] 可在多次扫描间复用已查过的关联结果；
  /// - 传入 [isCancelled] 时在收尾在线请求间隙及时响应取消。
  /// 返回本次是否对作品归属、ClearLogo 或系列编组产生了持久化变更。
  static Future<bool> reconcileAll({
    required LibraryRepository repository,
    BangumiService? bangumiService,
    TmdbService? tmdbService,
    Map<int, int> tmdbCollectionIdByTmdbId = const {},
    List<Work>? preloadedWorks,
    List<MediaVariant>? preloadedVariants,
    Set<int>? focusBangumiIds,
    Set<String>? focusWorkIds,
    Map<int, List<BangumiRelatedSubject>>? relationCache,
    bool Function()? isCancelled,
    void Function(int completed, int total)? onRelationProgress,
  }) async {
    final allWorks = preloadedWorks ?? await repository.getAllWorks();
    final existingGroups = await repository.getAllSeriesGroups();
    final existingGroupById = {for (final g in existingGroups) g.id: g};
    var mutated = false;

    // 保留已有 SeriesGroup 上沉淀的 tmdbCollectionId。
    final effectiveCollectionByTmdbId = <int, int>{...tmdbCollectionIdByTmdbId};
    for (final w in allWorks) {
      final sid = w.seriesId;
      final tid = w.tmdbId;
      if (sid == null || tid == null) continue;
      final cid = existingGroupById[sid]?.tmdbCollectionId;
      if (cid != null && cid > 0) {
        effectiveCollectionByTmdbId.putIfAbsent(tid, () => cid);
      }
    }

    final eligibleWorks = allWorks.where((w) {
      if (w.isHidden) return false;
      return w.scrapeStatus == ScrapeStatus.matched ||
          w.isManualLocked ||
          w.seriesLocked;
    }).toList();

    if (eligibleWorks.isEmpty) {
      return false;
    }

    final uf = _UnionFind(eligibleWorks.length);
    final indexByWorkId = <String, int>{
      for (var i = 0; i < eligibleWorks.length; i++) eligibleWorks[i].id: i,
    };

    // 1. 同 TMDB ID 分组（例如同剧集 Season 1 / Season 2 / Season 0 拆出的独立作品）。
    final byTmdbKey = <String, List<int>>{};
    // 2. 同 TMDB Movie Collection ID 分组（例如正片剧集或系列电影合集）。
    final byCollectionId = <int, List<int>>{};
    // 3. 已有 seriesId 先保持同源。
    final byExistingSeriesId = <String, List<int>>{};
    // 4. Bangumi ID 索引。
    final byBangumiId = <int, List<int>>{};

    for (var i = 0; i < eligibleWorks.length; i++) {
      final w = eligibleWorks[i];
      if (w.tmdbId != null && w.tmdbId! > 0) {
        final key = '${w.tmdbMediaType?.name ?? 'tv'}::${w.tmdbId}';
        byTmdbKey.putIfAbsent(key, () => []).add(i);
        final cid = effectiveCollectionByTmdbId[w.tmdbId!];
        if (cid != null && cid > 0) {
          byCollectionId.putIfAbsent(cid, () => []).add(i);
        }
      }
      if (w.seriesId != null && w.seriesId!.isNotEmpty) {
        byExistingSeriesId.putIfAbsent(w.seriesId!, () => []).add(i);
      }
      if (w.bangumiId != null && w.bangumiId! > 0) {
        byBangumiId.putIfAbsent(w.bangumiId!, () => []).add(i);
      }
    }

    for (final group in byTmdbKey.values) {
      uf.unionAll(group);
    }
    for (final group in byCollectionId.values) {
      uf.unionAll(group);
    }
    for (final group in byExistingSeriesId.values) {
      uf.unionAll(group);
    }

    // 5. 物理合集根目录分组（优先复用预载全库变体，消除逐作品 N+1 与重复全表查询）。
    final allVariants = preloadedVariants ?? await repository.getAllVariants();
    final variantsByWorkId = <String, List<MediaVariant>>{};
    for (final v in allVariants) {
      variantsByWorkId.putIfAbsent(v.workId, () => <MediaVariant>[]).add(v);
    }
    final rootEntries = <_WorkFolderDescriptor>[];
    for (var i = 0; i < eligibleWorks.length; i++) {
      final w = eligibleWorks[i];
      final variants = variantsByWorkId[w.id];
      if (variants == null || variants.isEmpty) continue;
      final descriptor = _describeWorkFolder(
        workIndex: i,
        sourceId: variants.first.sourceId,
        relativePaths: variants.map((v) => v.relativePath).toList(),
      );
      if (descriptor != null) {
        rootEntries.add(descriptor);
      }
    }
    final byRootKey = <String, List<_WorkFolderDescriptor>>{};
    final bySameWorkDir = <String, List<int>>{};
    for (final desc in rootEntries) {
      if (desc.collectionRoot != null) {
        final key = '${desc.sourceId}::${desc.collectionRoot}';
        byRootKey.putIfAbsent(key, () => []).add(desc);
      }
      final workDirLeaf = desc.workDir.split('/').last;
      if (!_isGenericFolder(workDirLeaf)) {
        final sameDirKey = '${desc.sourceId}::${desc.workDir.toLowerCase()}';
        bySameWorkDir.putIfAbsent(sameDirKey, () => []).add(desc.workIndex);
      }
    }
    for (final entries in byRootKey.values) {
      if (entries.length < 2) continue;
      if (_shouldLinkFolderCluster(entries)) {
        uf.unionAll(entries.map((e) => e.workIndex).toList());
      }
    }
    for (final sameDirIndices in bySameWorkDir.values) {
      if (sameDirIndices.length >= 2) {
        uf.unionAll(sameDirIndices);
      }
    }

    // 6. Bangumi 条目关联分组（支持按 focusBangumiIds 增量查询与跨次缓存复用，避免大库收尾重复打爆接口）。
    if (bangumiService != null && byBangumiId.length >= 2) {
      final candidateIds = focusBangumiIds == null
          ? byBangumiId.keys.toList(growable: false)
          : [
              for (final id in byBangumiId.keys)
                if (focusBangumiIds.contains(id)) id,
            ];
      final relationsByBgmId = <int, List<BangumiRelatedSubject>>{};
      final idsToFetch = <int>[];
      for (final bgmId in candidateIds) {
        final cached = relationCache?[bgmId];
        if (cached != null) {
          if (cached.isNotEmpty) {
            relationsByBgmId[bgmId] = cached;
          }
        } else {
          idsToFetch.add(bgmId);
        }
      }
      const maxConcurrency = 5;
      const maxRelationCacheEntries = 600;
      var cursor = 0;
      var completedCount = 0;

      Future<void> worker() async {
        while (cursor < idsToFetch.length) {
          if (isCancelled?.call() ?? false) return;
          final bgmId = idsToFetch[cursor++];
          try {
            final relations = await bangumiService.getRelatedSubjects(bgmId);
            if (relationCache != null) {
              if (relationCache.length >= maxRelationCacheEntries &&
                  !relationCache.containsKey(bgmId)) {
                relationCache.remove(relationCache.keys.first);
              }
              relationCache[bgmId] = relations;
            }
            if (relations.isNotEmpty) {
              relationsByBgmId[bgmId] = relations;
            }
          } catch (error) {
            // Bangumi 关联查询失败（如离线测试或接口抖动）时不阻断主流程。
            developer.log(
              '可恢复异常已记录',
              name: 'konata.series_auto_linker',
              error: error,
            );
          } finally {
            completedCount++;
            onRelationProgress?.call(completedCount, idsToFetch.length);
          }
        }
      }

      if (idsToFetch.isNotEmpty && !(isCancelled?.call() ?? false)) {
        onRelationProgress?.call(0, idsToFetch.length);
        final workerCount = idsToFetch.length < maxConcurrency
            ? idsToFetch.length
            : maxConcurrency;
        await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
      }

      for (final bgmId in candidateIds) {
        final relations = relationsByBgmId[bgmId];
        if (relations == null) continue;
        for (final rel in relations) {
          final targetIndices = byBangumiId[rel.id];
          if (targetIndices == null || targetIndices.isEmpty) continue;
          if (!_isSeriesRelation(rel.relation)) continue;
          final sourceIndices = byBangumiId[bgmId] ?? const [];
          if (sourceIndices.isNotEmpty) {
            uf.unionAll([...sourceIndices, ...targetIndices]);
          }
        }
      }
    }

    // 7. 跨类型主标题归一化前缀聚类（如 TV 正片《加速世界》与剧场版《加速世界：无限超频》）。
    // 先在 O(N) 内预筛可能为剧场版/番外/OVA 的目标集合并预处理规范化标题，消除 O(N^2) 重复正则扫描。
    final spinOffEntries = <({int index, Work work, List<String> targets})>[];
    for (var j = 0; j < eligibleWorks.length; j++) {
      final candidate = eligibleWorks[j];
      final isMovieOrSpinOff =
          candidate.tmdbMediaType == TmdbMediaType.movie ||
          _spinOffKeywordPattern.hasMatch(
            '${candidate.title} ${candidate.originalTitle ?? ''}',
          );
      if (!isMovieOrSpinOff) continue;
      final targets = <String>[
        _normalizeSpace(candidate.title),
        if (candidate.originalTitle != null &&
            candidate.originalTitle!.trim().isNotEmpty)
          _normalizeSpace(candidate.originalTitle!),
      ];
      spinOffEntries.add((index: j, work: candidate, targets: targets));
    }

    // 对每部剧场版/衍生作仅择优关联「匹配词干最长且不跨子世界观」的 TV 正主，
    // 防止泛化母前缀（如 UC《机动战士高达》）把平行世界观衍生剧场版（如《铁血的奥尔芬斯 猎杀兀尔德》）误吸并组。
    final tvStemsList =
        <({int index, Work work, List<({String lower, int length})> stems})>[];
    for (var i = 0; i < eligibleWorks.length; i++) {
      final tvCandidate = eligibleWorks[i];
      if (!_isTvLikeWork(tvCandidate)) continue;
      final stems = _extractPreparedStems(tvCandidate);
      if (stems.isEmpty) continue;
      tvStemsList.add((index: i, work: tvCandidate, stems: stems));
    }

    if (spinOffEntries.isNotEmpty && tvStemsList.isNotEmpty) {
      for (final entry in spinOffEntries) {
        final j = entry.index;
        final spinOffCandidate = entry.work;
        var bestStemLen = 0;
        final bestTvIndices = <int>[];
        for (final tvEntry in tvStemsList) {
          final i = tvEntry.index;
          if (i == j) continue;
          final tvCandidate = tvEntry.work;
          if (tvCandidate.tmdbId != null &&
              spinOffCandidate.tmdbId == tvCandidate.tmdbId &&
              spinOffCandidate.tmdbMediaType == tvCandidate.tmdbMediaType) {
            continue;
          }
          if (_hasConflictingSubFranchise(tvCandidate, spinOffCandidate)) {
            continue;
          }
          final matchedLen = _longestMatchedCrossTypeStemLength(
            tvEntry.stems,
            entry.targets,
          );
          if (matchedLen <= 0) continue;
          if (matchedLen > bestStemLen) {
            bestStemLen = matchedLen;
            bestTvIndices
              ..clear()
              ..add(i);
          } else if (matchedLen == bestStemLen) {
            bestTvIndices.add(i);
          }
        }
        for (final bestI in bestTvIndices) {
          if (uf.find(bestI) != uf.find(j)) {
            uf.union(bestI, j);
          }
        }
      }
    }

    // 聚合连通分量并写入 SeriesGroup、ClearLogo 交叉纠偏与成员关联。
    final components = <int, List<Work>>{};
    for (var i = 0; i < eligibleWorks.length; i++) {
      final root = uf.find(i);
      components.putIfAbsent(root, () => []).add(eligibleWorks[i]);
    }

    final referencedGroupIds = <String>{};
    final updatedWorkIds = <String>{};

    for (final rawMembers in components.values) {
      final componentTouched = _shouldRunOnlineLogoReconcile(
        rawMembers,
        focusWorkIds: focusWorkIds,
      );
      final logoHealResult = await _reconcileSeriesClearLogos(
        members: rawMembers,
        tmdbService: componentTouched ? tmdbService : null,
        isCancelled: isCancelled,
      );
      final members = logoHealResult.healedMembers;
      final healedWorkIds = logoHealResult.healedWorkIds;

      final hasLockedMember = members.any(
        (w) => w.seriesLocked && w.seriesId != null && w.seriesId!.isNotEmpty,
      );
      if (members.length < 2 && !hasLockedMember) {
        for (final w in members) {
          final logoChanged = healedWorkIds.contains(w.id);
          final needClearSeries = !w.seriesLocked && w.seriesId != null;
          if (needClearSeries || logoChanged) {
            await repository.upsertWork(
              needClearSeries ? w.copyWith(clearSeries: true) : w,
            );
            updatedWorkIds.add(w.id);
            mutated = true;
          }
        }
        continue;
      }

      // 优先沿用被锁定成员或已有成员的 seriesId。
      final targetSeriesId = _pickSeriesId(members, existingGroupById);
      final existingGroup = existingGroupById[targetSeriesId];
      referencedGroupIds.add(targetSeriesId);

      // 计算系列关联的 TMDB Collection ID（若有）。
      int? groupCollectionId = existingGroup?.tmdbCollectionId;
      if (groupCollectionId == null) {
        for (final m in members) {
          if (m.tmdbId != null) {
            final cid = effectiveCollectionByTmdbId[m.tmdbId!];
            if (cid != null && cid > 0) {
              groupCollectionId = cid;
              break;
            }
          }
        }
      }

      // 将成员按领域层统一时间线（TV 季号 -> 首播年份 -> 剧场版/OVA 时间序）排列。
      final sortedMembers = SeriesSeasonFormatter.sortSeriesMembers(
        members,
        respectLockedOrder: false,
      );
      final groupTitle = _deriveSeriesTitle(
        existingGroup,
        sortedMembers,
        hasLockedMember: hasLockedMember,
      );
      final now = DateTime.now();
      if (existingGroup == null ||
          existingGroup.title != groupTitle ||
          existingGroup.tmdbCollectionId != groupCollectionId) {
        await repository.upsertSeriesGroup(
          SeriesGroup(
            id: targetSeriesId,
            title: groupTitle,
            tmdbCollectionId: groupCollectionId,
            createdAt: existingGroup?.createdAt ?? now,
            updatedAt: now,
          ),
        );
        mutated = true;
      }

      final usedOrders = <int>{};
      for (final w in sortedMembers) {
        if (w.seriesLocked && w.seriesOrder != null) {
          usedOrders.add(w.seriesOrder!);
        }
      }

      var nextOrder = 1;
      for (final w in sortedMembers) {
        final logoChanged = healedWorkIds.contains(w.id);
        if (w.seriesLocked) {
          // 严格尊重人工锁定的 seriesId / seriesOrder / seriesLabel。
          if (w.seriesId != null && w.seriesId!.isNotEmpty) {
            referencedGroupIds.add(w.seriesId!);
          }
          if (logoChanged) {
            await repository.upsertWork(w);
            updatedWorkIds.add(w.id);
            mutated = true;
          }
          continue;
        }
        while (usedOrders.contains(nextOrder)) {
          nextOrder++;
        }
        final assignedOrder = nextOrder;
        usedOrders.add(assignedOrder);
        nextOrder++;

        final keepCustomLabel =
            w.seriesId == targetSeriesId &&
            !SeriesSeasonFormatter.isGenericRoleLabel(w.seriesLabel);
        final assignedLabel = keepCustomLabel
            ? w.seriesLabel!.trim()
            : _defaultSeriesLabel(
                w,
                fallbackIndex: assignedOrder,
                sortedMembers: sortedMembers,
              );
        if (logoChanged ||
            w.seriesId != targetSeriesId ||
            w.seriesOrder != assignedOrder ||
            w.seriesLabel != assignedLabel) {
          await repository.upsertWork(
            w.copyWith(
              seriesId: targetSeriesId,
              seriesOrder: assignedOrder,
              seriesLabel: assignedLabel,
            ),
          );
          updatedWorkIds.add(w.id);
          mutated = true;
        }
      }
    }

    // 清理未被引用的残留单成员非锁定 seriesId 与空 SeriesGroup。
    for (final w in allWorks) {
      if (updatedWorkIds.contains(w.id) || indexByWorkId.containsKey(w.id)) {
        if (w.seriesId != null && w.seriesLocked) {
          referencedGroupIds.add(w.seriesId!);
        }
        continue;
      }
      if (w.seriesId != null && w.seriesId!.isNotEmpty) {
        if (w.seriesLocked) {
          referencedGroupIds.add(w.seriesId!);
        } else {
          await repository.upsertWork(w.copyWith(clearSeries: true));
          mutated = true;
        }
      }
    }

    for (final group in existingGroups) {
      if (!referencedGroupIds.contains(group.id)) {
        await repository.deleteSeriesGroup(group.id);
        mutated = true;
      }
    }

    return mutated;
  }

  static bool _isTvLikeWork(Work w) {
    return w.tmdbMediaType == TmdbMediaType.tv ||
        (w.tmdbMediaType == null && w.matchedSeason != null);
  }

  static String _normalizeSpace(String raw) =>
      raw.trim().replaceAll(_whitespaceCollapsePattern, ' ');

  static List<({String lower, int length})> _extractPreparedStems(Work tvWork) {
    final seen = <String>{};
    final result = <({String lower, int length})>[];
    for (final raw in [tvWork.title, tvWork.originalTitle]) {
      if (raw == null || raw.trim().isEmpty) continue;
      final stripped = raw
          .trim()
          .replaceFirst(_trailingSeasonSuffixPattern, '')
          .trim();
      final stem = _normalizeSpace(stripped);
      if (stem.isEmpty) continue;
      final lower = stem.toLowerCase();
      if (!seen.add(lower)) continue;
      final compactStem = stem.replaceAll(_compactStemStripPattern, '');
      final minLen = _cjkCharPattern.hasMatch(compactStem) ? 2 : 5;
      if (compactStem.length < minLen) continue;
      result.add((lower: lower, length: stem.length));
    }
    return result;
  }

  /// 独立世界观/平行子系列隔离表（主要用于避免高达各 AU 剧场版/衍生作借泛化前缀串入 UC 0079 等主线组）。
  static final _subFranchisePatterns = List<(String tag, RegExp pattern)>.unmodifiable([
    (
      'gundam_ibo',
      RegExp(
        r'铁血|鉄血|奥尔芬斯|オルフェンズ|\b(?:tekketsu|iron[\s-]*blooded|orphans|urdr[\s-]*hunt)\b|猎杀兀尔德|ウルズハント',
        caseSensitive: false,
      ),
    ),
    (
      'gundam_seed',
      RegExp(r'(?<![a-z])seed(?![a-z])|シード', caseSensitive: false),
    ),
    (
      'gundam_00',
      RegExp(r'(?:高达|ガンダム|gundam)[\s._-]*00(?![0-9])', caseSensitive: false),
    ),
    (
      'gundam_age',
      RegExp(r'(?:高达|ガンダム|gundam)[\s._-]*age(?![a-z])', caseSensitive: false),
    ),
    (
      'gundam_wing',
      RegExp(
        r'(?:高达|ガンダム|gundam)[\s._-]*(?:w(?![a-z])|wing\b)|无尽的华尔兹|エンドレスワルツ',
        caseSensitive: false,
      ),
    ),
    (
      'gundam_x',
      RegExp(r'(?:高达|ガンダム|gundam)[\s._-]*x(?![a-z])', caseSensitive: false),
    ),
    (
      'gundam_witch',
      RegExp(r'水星的魔女|水星の魔女|witch\s+from\s+mercury', caseSensitive: false),
    ),
    (
      'gundam_reco',
      RegExp(r'复国|レコンギスタ|reconguista', caseSensitive: false),
    ),
    (
      'gundam_turn_a',
      RegExp(r'∀|turn[\s._-]*a[\s._-]*gundam|倒a高达', caseSensitive: false),
    ),
    (
      'gundam_build',
      RegExp(r'创战者|创形者|ビルドファイターズ|ビルドダイバーズ|gundam\s+build', caseSensitive: false),
    ),
    (
      'gundam_sd',
      RegExp(r'(?<![a-z])sd[\s._-]*(?:高达|ガンダム|gundam)', caseSensitive: false),
    ),
    (
      'gundam_gqux',
      RegExp(r'gquuuuuux|ジークアクス', caseSensitive: false),
    ),
    (
      'gundam_g',
      RegExp(r'机动武斗传|機動武闘伝|g[\s._-]*gundam', caseSensitive: false),
    ),
  ]);

  static final RegExp _remasterLabelPattern = RegExp(
    r'(?:HD\s*)?(?:重制版|重製版|Remaster(?:ed)?)|リマスター',
    caseSensitive: false,
  );

  static final RegExp _spinOffTitleNoisePattern = RegExp(
    r'(?:^|[\s:：\-–—])(?:zoo|sd|mini|petit|chibi|ova|oad|sp|special)(?=$|[\s:：\-–—!！?？])|迷你|叛乱|绝望篇|未来篇|希望篇|外传|外伝|特别篇|特別編',
    caseSensitive: false,
  );

  static String? _extractSubFranchiseTag(Work w) {
    final text = '${w.title} ${w.originalTitle ?? ''}';
    for (final (tag, pattern) in _subFranchisePatterns) {
      if (pattern.hasMatch(text)) return tag;
    }
    return null;
  }

  static bool _hasConflictingSubFranchise(Work a, Work b) {
    final tagA = _extractSubFranchiseTag(a);
    final tagB = _extractSubFranchiseTag(b);
    if (tagA == null && tagB == null) return false;
    return tagA != tagB;
  }

  static int _longestMatchedCrossTypeStemLength(
    List<({String lower, int length})> stems,
    List<String> targets,
  ) {
    var best = 0;
    for (final target in targets) {
      final targetLower = target.toLowerCase();
      for (final stem in stems) {
        if (target.length <= stem.length) continue;
        if (!targetLower.startsWith(stem.lower)) continue;
        final suffix = target.substring(stem.length);
        if (_subtitleBoundaryPattern.hasMatch(suffix) && stem.length > best) {
          best = stem.length;
        }
      }
    }
    return best;
  }

  /// 判断连通分量是否需要发起在线 TMDB ClearLogo 交叉校验。
  ///
  /// 仅当未指定变更范围、分量包含本次变更成员，或本轮编组刚将尚未共享同一 `seriesId` 的成员合并时返回真；
  /// 离线已知误传表与已落库路径碰撞检查始终在内存中 0 耗时执行，不受此门控限制。
  static bool _shouldRunOnlineLogoReconcile(
    List<Work> members, {
    Set<String>? focusWorkIds,
  }) {
    if (focusWorkIds == null) return true;
    for (final w in members) {
      if (focusWorkIds.contains(w.id)) return true;
    }
    if (members.length < 2) return false;
    final firstSeriesId = members.first.seriesId;
    if (firstSeriesId == null || firstSeriesId.isEmpty) return true;
    for (final w in members.skip(1)) {
      if (w.seriesId != firstSeriesId) return true;
    }
    return false;
  }

  static Future<({List<Work> healedMembers, Set<String> healedWorkIds})>
  _reconcileSeriesClearLogos({
    required List<Work> members,
    TmdbService? tmdbService,
    bool Function()? isCancelled,
  }) async {
    final working = List<Work>.of(members);
    final healedIds = <String>{};

    final movieLogoPaths = <String>{};
    final movieIndicesToProbe = <int>[];
    var hasUnlockedTvWithLogo = false;
    for (var i = 0; i < working.length; i++) {
      final w = working[i];
      if (w.tmdbMediaType == TmdbMediaType.tv) {
        final logo = w.logoPath?.trim() ?? '';
        if (logo.isNotEmpty && !w.posterLocked && !w.metadataLocked) {
          hasUnlockedTvWithLogo = true;
        }
      } else if (w.tmdbMediaType == TmdbMediaType.movie) {
        final existingLogo = w.logoPath?.trim() ?? '';
        if (existingLogo.isNotEmpty) {
          movieLogoPaths.add(existingLogo);
        }
        if (w.tmdbId != null && w.tmdbId! > 0) {
          movieIndicesToProbe.add(i);
        }
      }
    }

    // 仅当同系列同时存在剧场版与未锁定带徽标 TV 作品时，才并发拉取剧场版候选徽标集合进行跨类型碰撞纠偏；
    // 独立电影或无 TV 碰撞风险的分量零网络请求。
    if (tmdbService != null &&
        hasUnlockedTvWithLogo &&
        movieIndicesToProbe.isNotEmpty &&
        !(isCancelled?.call() ?? false)) {
      final probed = await Future.wait<({int index, TmdbWorkDetail? detail})>([
        for (final idx in movieIndicesToProbe)
          () async {
            if (isCancelled?.call() ?? false) {
              return (index: idx, detail: null);
            }
            final m = working[idx];
            try {
              final detail = await tmdbService.getWorkDetail(
                m.tmdbId!,
                TmdbMediaType.movie,
                priority: RequestPriority.background,
              );
              return (index: idx, detail: detail);
            } catch (error) {
              // 离线或接口异常时不阻断本地编组修复。
              developer.log(
                '可恢复异常已记录',
                name: 'konata.series_auto_linker',
                error: error,
              );
              return (index: idx, detail: null);
            }
          }(),
      ]);
      for (final entry in probed) {
        final detail = entry.detail;
        if (detail == null) continue;
        final m = working[entry.index];
        final existingLogo = m.logoPath?.trim() ?? '';
        for (final logo in detail.candidateLogos) {
          if (logo.filePath.trim().isNotEmpty) {
            movieLogoPaths.add(logo.filePath.trim());
          }
        }
        if (existingLogo.isEmpty &&
            !m.posterLocked &&
            !m.metadataLocked &&
            detail.logoPath != null &&
            detail.logoPath!.trim().isNotEmpty) {
          working[entry.index] = m.copyWith(logoPath: detail.logoPath!.trim());
          healedIds.add(m.id);
          movieLogoPaths.add(detail.logoPath!.trim());
        }
      }
    }

    for (var i = 0; i < working.length; i++) {
      final tv = working[i];
      if (tv.tmdbMediaType != TmdbMediaType.tv) continue;
      final currentLogo = tv.logoPath?.trim() ?? '';
      if (currentLogo.isEmpty) continue;

      final mistaggedTargets = tv.tmdbId != null
          ? TmdbService.tmdbMistaggedTvLogoTargets[tv.tmdbId!]
          : null;
      final isKnownMistagged =
          mistaggedTargets != null && mistaggedTargets.containsKey(currentLogo);
      final collidesWithMovie =
          !tv.posterLocked &&
          !tv.metadataLocked &&
          movieLogoPaths.contains(currentLogo);

      if (!isKnownMistagged && !collidesWithMovie) {
        continue;
      }

      // 将明确属于同名剧场版的 Logo 归还给系列内缺失徽标的剧场版成员。
      if (isKnownMistagged) {
        final expectedMovieId = mistaggedTargets[currentLogo];
        for (var j = 0; j < working.length; j++) {
          final mv = working[j];
          if (mv.tmdbMediaType != TmdbMediaType.movie) continue;
          if (expectedMovieId != null && mv.tmdbId != expectedMovieId) {
            continue;
          }
          if ((mv.logoPath == null || mv.logoPath!.trim().isEmpty) &&
              !mv.posterLocked &&
              !mv.metadataLocked) {
            working[j] = mv.copyWith(logoPath: currentLogo);
            healedIds.add(mv.id);
          }
        }
      }

      String? replacementLogo;
      if (tmdbService != null &&
          tv.tmdbId != null &&
          tv.tmdbId! > 0 &&
          !(isCancelled?.call() ?? false)) {
        try {
          final detail = await tmdbService.getWorkDetail(
            tv.tmdbId!,
            TmdbMediaType.tv,
            priority: RequestPriority.background,
          );
          if (detail != null) {
            for (final candidate in detail.candidateLogos) {
              final path = candidate.filePath.trim();
              if (path.isEmpty || path == currentLogo) continue;
              if (mistaggedTargets != null &&
                  mistaggedTargets.containsKey(path)) {
                continue;
              }
              if (movieLogoPaths.contains(path)) continue;
              replacementLogo = path;
              break;
            }
          }
        } catch (error) {
          // 离线态直接清除错误 ClearLogo，由详情页文字标题稳妥接管。
          developer.log(
            '可恢复异常已记录',
            name: 'konata.series_auto_linker',
            error: error,
          );
        }
      }

      working[i] = replacementLogo != null
          ? tv.copyWith(logoPath: replacementLogo)
          : tv.copyWith(clearLogoPath: true);
      healedIds.add(tv.id);
    }

    return (healedMembers: working, healedWorkIds: healedIds);
  }

  static bool _isSeriesRelation(String relation) {
    final normalized = relation.trim().toLowerCase();
    for (final token in _eligibleRelations) {
      if (normalized.contains(token.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  static String _pickSeriesId(
    List<Work> members,
    Map<String, SeriesGroup> existingGroupById,
  ) {
    for (final w in members) {
      if (w.seriesLocked && w.seriesId != null && w.seriesId!.isNotEmpty) {
        return w.seriesId!;
      }
    }
    for (final w in members) {
      if (w.seriesId != null &&
          w.seriesId!.isNotEmpty &&
          existingGroupById.containsKey(w.seriesId)) {
        return w.seriesId!;
      }
    }
    final sortedIds = members.map((m) => m.id).toList()..sort();
    return _stableSeriesId('series::${sortedIds.first}');
  }

  static String _deriveSeriesTitle(
    SeriesGroup? existing,
    List<Work> sortedMembers, {
    bool hasLockedMember = false,
  }) {
    if (hasLockedMember &&
        existing != null &&
        existing.title.trim().isNotEmpty) {
      return existing.title.trim();
    }
    final countByTmdbId = <int, int>{};
    for (final m in sortedMembers) {
      if (m.tmdbMediaType == TmdbMediaType.tv && m.tmdbId != null) {
        countByTmdbId.update(m.tmdbId!, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    String cleanAnchorTitle(Work w) {
      final raw = w.title.trim();
      final stripped = raw.replaceFirst(_trailingSeasonSuffixPattern, '').trim();
      return stripped.isEmpty ? raw : stripped;
    }

    final ranked = List<Work>.of(sortedMembers)
      ..sort((a, b) {
        final aIsPrimaryTv =
            _isTvLikeWork(a) &&
            a.matchedSeason != 0 &&
            !_remasterLabelPattern.hasMatch(a.title);
        final bIsPrimaryTv =
            _isTvLikeWork(b) &&
            b.matchedSeason != 0 &&
            !_remasterLabelPattern.hasMatch(b.title);
        if (aIsPrimaryTv != bIsPrimaryTv) return aIsPrimaryTv ? -1 : 1;

        final aSpinOff = _spinOffTitleNoisePattern.hasMatch(a.title);
        final bSpinOff = _spinOffTitleNoisePattern.hasMatch(b.title);
        if (aSpinOff != bSpinOff) return aSpinOff ? 1 : -1;

        final aIsS1 = a.matchedSeason == 1 ? 0 : 1;
        final bIsS1 = b.matchedSeason == 1 ? 0 : 1;
        if (aIsS1 != bIsS1) return aIsS1.compareTo(bIsS1);

        final aYear = a.year ?? 9999;
        final bYear = b.year ?? 9999;
        if (aYear != bYear) return aYear.compareTo(bYear);

        final aCount =
            (a.tmdbMediaType == TmdbMediaType.tv && a.tmdbId != null)
            ? (countByTmdbId[a.tmdbId!] ?? 0)
            : 0;
        final bCount =
            (b.tmdbMediaType == TmdbMediaType.tv && b.tmdbId != null)
            ? (countByTmdbId[b.tmdbId!] ?? 0)
            : 0;
        if (aCount != bCount) return bCount.compareTo(aCount);

        final aClean = cleanAnchorTitle(a);
        final bClean = cleanAnchorTitle(b);
        if (aClean.length != bClean.length) {
          return aClean.length.compareTo(bClean.length);
        }
        return aClean.toLowerCase().compareTo(bClean.toLowerCase());
      });

    return cleanAnchorTitle(ranked.first);
  }

  static String _defaultSeriesLabel(
    Work w, {
    required int fallbackIndex,
    required List<Work> sortedMembers,
  }) {
    final tvMembers = sortedMembers
        .where((m) => m.tmdbMediaType == TmdbMediaType.tv && m.matchedSeason != 0)
        .toList(growable: false);
    final distinctTvTmdbIds = <int>{
      for (final m in tvMembers) ?m.tmdbId,
    };
    final tvSeasonCountByTmdbId = <int, int>{};
    for (final m in tvMembers) {
      if (m.tmdbId != null && (m.matchedSeason ?? 0) > 0) {
        tvSeasonCountByTmdbId.update(m.tmdbId!, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    if (w.tmdbMediaType == TmdbMediaType.tv &&
        w.matchedSeason != null &&
        w.matchedSeason! > 0) {
      final isSingleSeasonInMultiShowFranchise =
          distinctTvTmdbIds.length >= 2 &&
          w.matchedSeason == 1 &&
          w.tmdbId != null &&
          (tvSeasonCountByTmdbId[w.tmdbId!] ?? 0) <= 1;
      if (isSingleSeasonInMultiShowFranchise) {
        final normOwn = _normalizeSpace(w.title).toLowerCase();
        final hasSameTitleDiffYear = tvMembers.any(
          (other) =>
              other.id != w.id &&
              _normalizeSpace(other.title).toLowerCase() == normOwn &&
              other.year != w.year,
        );
        if (hasSameTitleDiffYear && w.year != null) {
          return '${w.year} 版';
        }
        if (_remasterLabelPattern.hasMatch(w.title)) {
          return 'HD重制版';
        }
        final trimmed = w.title.trim();
        return trimmed.isNotEmpty ? trimmed : 'TV';
      }
      return SeriesLabelPresets.seasonLabel(w.matchedSeason!);
    }
    if (w.tmdbMediaType == TmdbMediaType.movie) {
      final movieCount = sortedMembers
          .where((m) => m.tmdbMediaType == TmdbMediaType.movie)
          .length;
      if (movieCount <= 1) {
        return '剧场版';
      }
      return w.title.trim().length <= 18 ? w.title.trim() : '剧场版';
    }
    final upperTitle = '${w.title} ${w.originalTitle ?? ''}'.toUpperCase();
    if (upperTitle.contains('OAD')) return 'OAD';
    if (upperTitle.contains('OVA')) return 'OVA';
    if (w.tmdbMediaType == null &&
        (upperTitle.contains('剧场版') ||
            upperTitle.contains('劇場版') ||
            RegExp(r'\b(?:THE\s+)?MOVIE\b').hasMatch(upperTitle))) {
      return '剧场版';
    }
    if (w.matchedSeason == 0) return '特别篇';
    // 无有效季号时严禁拿列表序号伪造「第 5 季」等虚假季号，优先解析标题内显式季号或保留清晰作品短名。
    final parsedSeason = SeasonNumberParser.splitSeasonSuffix(
      w.title,
    ).seasonNumber;
    if (parsedSeason != null && parsedSeason > 0) {
      return SeriesLabelPresets.seasonLabel(parsedSeason);
    }
    if (_remasterLabelPattern.hasMatch(w.title)) {
      return 'HD重制版';
    }
    final cleanTitle = w.title.trim();
    return cleanTitle.isNotEmpty
        ? cleanTitle
        : SeriesLabelPresets.seasonLabel(fallbackIndex);
  }

  static _WorkFolderDescriptor? _describeWorkFolder({
    required int workIndex,
    required String sourceId,
    required List<String> relativePaths,
  }) {
    final dirChainCounts = <String, int>{};
    for (final raw in relativePaths) {
      final norm = raw
          .replaceAll('\\', '/')
          .replaceFirst(_leadingSlashPattern, '');
      final slashIdx = norm.lastIndexOf('/');
      if (slashIdx <= 0) continue;
      final dirPath = norm.substring(0, slashIdx);
      dirChainCounts[dirPath] = (dirChainCounts[dirPath] ?? 0) + 1;
    }
    if (dirChainCounts.isEmpty) return null;

    // 选取代表性目录（多数主视频所在目录）。
    final sortedDirs = dirChainCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final segments = sortedDirs.first.key
        .split('/')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (segments.isEmpty) return null;

    var hadSeasonSegment = false;
    while (segments.isNotEmpty) {
      final tail = segments.last.trim();
      if (_supplementaryDirPattern.hasMatch(tail)) {
        segments.removeLast();
        continue;
      }
      if (_seasonDirPattern.hasMatch(tail)) {
        hadSeasonSegment = true;
        segments.removeLast();
        continue;
      }
      break;
    }
    if (segments.isEmpty) return null;

    final workDirPath = segments.join('/');
    String? rootPath;
    if (_franchiseContainerPattern.hasMatch(segments.last.trim())) {
      // 例如：未添加TMDB ID/加速世界系列 -> 直接将系列容器目录作为合集根
      rootPath = workDirPath;
    } else if (hadSeasonSegment) {
      // 例如：[ReinForce] Spy x Family/Season 1 -> 合集根是 [ReinForce] Spy x Family
      rootPath = workDirPath;
    } else if (segments.length >= 2) {
      // 例如：[ReinForce] Spy x Family/Code White -> 检查父目录是否为泛化目录
      final parent = segments.sublist(0, segments.length - 1);
      final parentLeaf = parent.last.trim();
      if (!_isGenericFolder(parentLeaf)) {
        rootPath = parent.join('/');
      }
    }

    final validRootPath =
        rootPath != null && !_isGenericFolder(rootPath.split('/').last)
        ? rootPath
        : null;
    final workDirLeaf = sortedDirs.first.key.split('/').last;
    if (validRootPath == null && _isGenericFolder(workDirLeaf)) {
      return null;
    }

    return _WorkFolderDescriptor(
      workIndex: workIndex,
      sourceId: sourceId,
      workDir: sortedDirs.first.key,
      collectionRoot: validRootPath,
      hadSeasonSubdir: hadSeasonSegment,
    );
  }

  static bool _isGenericFolder(String name) {
    final normalized = name.trim().toLowerCase();
    if (_genericDirectoryNames.contains(normalized)) return true;
    if (_yearFolderPattern.hasMatch(normalized)) return true;
    return false;
  }

  static bool _shouldLinkFolderCluster(List<_WorkFolderDescriptor> entries) {
    // 1. 同一目录内有明确季子目录，或不同作品实际上源自同一剥离后合集根目录（如多季）。
    if (entries.any((e) => e.hadSeasonSubdir)) {
      return true;
    }
    // 2. 检查其中一个作品直接落在合集根目录，其余在子目录。
    final roots = entries.map((e) => e.collectionRoot).toSet();
    if (roots.length == 1) {
      final root = roots.first!;
      if (entries.any((e) => e.workDir == root)) {
        return true;
      }
    }
    // 3. 否则必须目录中带季/剧场版标识，或各子目录间有明显共用前缀，避免普通分类目录误合。
    for (final e in entries) {
      final leaf = e.workDir.split('/').last;
      if (_seasonMarkerDirPattern.hasMatch(leaf)) {
        return true;
      }
    }
    return false;
  }

  /// 基于 FNV-1a 32-bit 双路拼接生成确定性十六进制 ID，兼容全平台整数精度。
  static String _stableSeriesId(String input) {
    var h1 = 0x811c9dc5;
    var h2 = 0x9e3779b1;
    const prime1 = 0x01000193;
    const prime2 = 0x85ebca6b;
    for (final unit in input.codeUnits) {
      h1 ^= unit;
      h1 = (h1 * prime1) & 0xFFFFFFFF;
      h2 ^= (unit + 31);
      h2 = (h2 * prime2) & 0xFFFFFFFF;
    }
    final hex1 = h1.toRadixString(16).padLeft(8, '0');
    final hex2 = h2.toRadixString(16).padLeft(8, '0');
    return 'ser_$hex1$hex2';
  }
}

class _WorkFolderDescriptor {
  const _WorkFolderDescriptor({
    required this.workIndex,
    required this.sourceId,
    required this.workDir,
    required this.collectionRoot,
    required this.hadSeasonSubdir,
  });

  final int workIndex;
  final String sourceId;
  final String workDir;
  final String? collectionRoot;
  final bool hadSeasonSubdir;
}

class _UnionFind {
  _UnionFind(int n) : _parent = List<int>.generate(n, (i) => i);

  final List<int> _parent;

  int find(int x) {
    while (_parent[x] != x) {
      _parent[x] = _parent[_parent[x]];
      x = _parent[x];
    }
    return x;
  }

  void union(int a, int b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) {
      _parent[rb] = ra;
    }
  }

  void unionAll(List<int> items) {
    if (items.length < 2) return;
    final first = items.first;
    for (var i = 1; i < items.length; i++) {
      union(first, items[i]);
    }
  }
}
