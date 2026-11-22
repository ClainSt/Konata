import 'dart:developer' as developer;
import '../../domain/models/media_variant.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/tmdb_service.dart';

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
  /// 返回本次是否对作品归属、ClearLogo 或系列编组产生了持久化变更。
  static Future<bool> reconcileAll({
    required LibraryRepository repository,
    BangumiService? bangumiService,
    TmdbService? tmdbService,
    Map<int, int> tmdbCollectionIdByTmdbId = const {},
    List<Work>? preloadedWorks,
    List<MediaVariant>? preloadedVariants,
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

    // 6. Bangumi 条目关联分组（受控 5 并发拉取关联条目，保持结果合并确定性）。
    if (bangumiService != null && byBangumiId.length >= 2) {
      final uniqueBgmIds = byBangumiId.keys.toList(growable: false);
      final relationsByBgmId = <int, List<BangumiRelatedSubject>>{};
      const maxConcurrency = 5;
      var cursor = 0;

      Future<void> worker() async {
        while (cursor < uniqueBgmIds.length) {
          final bgmId = uniqueBgmIds[cursor++];
          try {
            final relations = await bangumiService.getRelatedSubjects(bgmId);
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
          }
        }
      }

      final workerCount = uniqueBgmIds.length < maxConcurrency
          ? uniqueBgmIds.length
          : maxConcurrency;
      await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);

      for (final bgmId in uniqueBgmIds) {
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

    if (spinOffEntries.isNotEmpty) {
      for (var i = 0; i < eligibleWorks.length; i++) {
        final tvCandidate = eligibleWorks[i];
        if (!_isTvLikeWork(tvCandidate)) continue;
        final stems = _extractPreparedStems(tvCandidate);
        if (stems.isEmpty) continue;
        for (final entry in spinOffEntries) {
          final j = entry.index;
          if (i == j || uf.find(i) == uf.find(j)) continue;
          final spinOffCandidate = entry.work;
          if (tvCandidate.tmdbId != null &&
              spinOffCandidate.tmdbId == tvCandidate.tmdbId &&
              spinOffCandidate.tmdbMediaType == tvCandidate.tmdbMediaType) {
            continue;
          }
          if (_matchesPreparedCrossTypeStem(stems, entry.targets)) {
            uf.union(i, j);
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
      final logoHealResult = await _reconcileSeriesClearLogos(
        members: rawMembers,
        tmdbService: tmdbService,
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
      final groupTitle = _deriveSeriesTitle(existingGroup, sortedMembers);
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

  static bool _matchesPreparedCrossTypeStem(
    List<({String lower, int length})> stems,
    List<String> targets,
  ) {
    for (final target in targets) {
      final targetLower = target.toLowerCase();
      for (final stem in stems) {
        if (target.length <= stem.length) continue;
        if (!targetLower.startsWith(stem.lower)) continue;
        final suffix = target.substring(stem.length);
        if (_subtitleBoundaryPattern.hasMatch(suffix)) {
          return true;
        }
      }
    }
    return false;
  }

  static Future<({List<Work> healedMembers, Set<String> healedWorkIds})>
  _reconcileSeriesClearLogos({
    required List<Work> members,
    TmdbService? tmdbService,
  }) async {
    final working = List<Work>.of(members);
    final healedIds = <String>{};

    final movieLogoPaths = <String>{};
    for (var i = 0; i < working.length; i++) {
      final m = working[i];
      if (m.tmdbMediaType != TmdbMediaType.movie) continue;
      final existingLogo = m.logoPath?.trim() ?? '';
      if (existingLogo.isNotEmpty) {
        movieLogoPaths.add(existingLogo);
      }
      if (tmdbService != null && m.tmdbId != null && m.tmdbId! > 0) {
        try {
          final detail = await tmdbService.getWorkDetail(
            m.tmdbId!,
            TmdbMediaType.movie,
          );
          if (detail != null) {
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
              working[i] = m.copyWith(logoPath: detail.logoPath!.trim());
              healedIds.add(m.id);
              movieLogoPaths.add(detail.logoPath!.trim());
            }
          }
        } catch (error) {
      // 离线或接口异常时不阻断本地编组修复。
      developer.log('可恢复异常已记录', name: 'konata.series_auto_linker', error: error);
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
      if (tmdbService != null && tv.tmdbId != null && tv.tmdbId! > 0) {
        try {
          final detail = await tmdbService.getWorkDetail(
            tv.tmdbId!,
            TmdbMediaType.tv,
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
      developer.log('可恢复异常已记录', name: 'konata.series_auto_linker', error: error);
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
      if (w.seriesLocked &&
          w.seriesId != null &&
          w.seriesId!.isNotEmpty) {
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
    List<Work> sortedMembers,
  ) {
    if (existing != null && existing.title.trim().isNotEmpty) {
      return existing.title.trim();
    }
    final primary = sortedMembers.first;
    final raw = primary.title.trim();
    final stripped = raw.replaceFirst(_trailingSeasonSuffixPattern, '').trim();
    return stripped.isEmpty ? raw : stripped;
  }

  static String _defaultSeriesLabel(
    Work w, {
    required int fallbackIndex,
    required List<Work> sortedMembers,
  }) {
    if (w.tmdbMediaType == TmdbMediaType.tv &&
        w.matchedSeason != null &&
        w.matchedSeason! > 0) {
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
    if (w.matchedSeason == 0) return '特别篇';
    return SeriesLabelPresets.seasonLabel(fallbackIndex);
  }

  static _WorkFolderDescriptor? _describeWorkFolder({
    required int workIndex,
    required String sourceId,
    required List<String> relativePaths,
  }) {
    final dirChainCounts = <String, int>{};
    for (final raw in relativePaths) {
      final norm = raw.replaceAll('\\', '/').replaceFirst(_leadingSlashPattern, '');
      final slashIdx = norm.lastIndexOf('/');
      if (slashIdx <= 0) continue;
      final dirPath = norm.substring(0, slashIdx);
      dirChainCounts[dirPath] = (dirChainCounts[dirPath] ?? 0) + 1;
    }
    if (dirChainCounts.isEmpty) return null;

    // 选取代表性目录（多数主视频所在目录）。
    final sortedDirs = dirChainCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    var segments = sortedDirs.first.key
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
