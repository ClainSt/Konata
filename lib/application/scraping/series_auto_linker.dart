import '../../domain/models/series_group.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/library_repository.dart';
import '../../infrastructure/network/bangumi_service.dart';

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
    r'(?:^|[\s._-])(?:season[\s._-]*\d+|s0?\d+|第\s*[0-9一二三四五六七八九十两]+\s*[季期]|剧场版|movie|ova|oad)(?:$|[\s._-])',
    caseSensitive: false,
  );

  static final RegExp _trailingSeasonSuffixPattern = RegExp(
    r'(?:\s+(?:第\s*[0-9一二三四五六七八九十两]+\s*[季期]|season\s*\d+|s\d{1,2}|part\s*\d+|剧场版.*|the\s+movie.*))$',
    caseSensitive: false,
  );

  /// 在全库或局部分析后，对媒体库作品执行自动系列编组对账与持久化。
  static Future<void> reconcileAll({
    required LibraryRepository repository,
    BangumiService? bangumiService,
    Map<int, int> tmdbCollectionIdByTmdbId = const {},
  }) async {
    final allWorks = await repository.getAllWorks();
    final existingGroups = await repository.getAllSeriesGroups();
    final existingGroupById = {for (final g in existingGroups) g.id: g};

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
      return;
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

    // 5. 物理合集根目录分组（例如 [ReinForce] Spy x Family 下各季与剧场版）。
    final rootEntries = <_WorkFolderDescriptor>[];
    for (var i = 0; i < eligibleWorks.length; i++) {
      final w = eligibleWorks[i];
      final variants = await repository.getVariantsByWork(w.id);
      if (variants.isEmpty) continue;
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
    for (final desc in rootEntries) {
      if (desc.collectionRoot != null) {
        final key = '${desc.sourceId}::${desc.collectionRoot}';
        byRootKey.putIfAbsent(key, () => []).add(desc);
      }
    }
    for (final entries in byRootKey.values) {
      if (entries.length < 2) continue;
      if (_shouldLinkFolderCluster(entries)) {
        uf.unionAll(entries.map((e) => e.workIndex).toList());
      }
    }

    // 6. Bangumi 条目关联分组（前传 / 续集 / 剧场版 / 番外等）。
    if (bangumiService != null && byBangumiId.length >= 2) {
      final queriedIds = <int>{};
      for (final bgmId in byBangumiId.keys) {
        if (!queriedIds.add(bgmId)) continue;
        try {
          final relations = await bangumiService.getRelatedSubjects(bgmId);
          for (final rel in relations) {
            final targetId = rel.id;
            final targetIndices = byBangumiId[targetId];
            if (targetIndices == null || targetIndices.isEmpty) continue;
            if (!_isSeriesRelation(rel.relation)) continue;
            final sourceIndices = byBangumiId[bgmId] ?? const [];
            if (sourceIndices.isNotEmpty) {
              uf.unionAll([...sourceIndices, ...targetIndices]);
            }
          }
        } catch (_) {
          // Bangumi 关联查询失败（如离线测试或接口抖动）时不阻断主流程。
        }
      }
    }

    // 聚合连通分量并写入 SeriesGroup 与成员关联。
    final components = <int, List<Work>>{};
    for (var i = 0; i < eligibleWorks.length; i++) {
      final root = uf.find(i);
      components.putIfAbsent(root, () => []).add(eligibleWorks[i]);
    }

    final referencedGroupIds = <String>{};
    final updatedWorkIds = <String>{};

    for (final members in components.values) {
      final hasLockedMember = members.any(
        (w) => w.seriesLocked && w.seriesId != null && w.seriesId!.isNotEmpty,
      );
      if (members.length < 2 && !hasLockedMember) {
        for (final w in members) {
          if (!w.seriesLocked && w.seriesId != null) {
            await repository.upsertWork(w.copyWith(clearSeries: true));
            updatedWorkIds.add(w.id);
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
      await repository.upsertSeriesGroup(
        SeriesGroup(
          id: targetSeriesId,
          title: groupTitle,
          tmdbCollectionId: groupCollectionId,
          createdAt: existingGroup?.createdAt ?? now,
          updatedAt: now,
        ),
      );

      final usedOrders = <int>{};
      for (final w in sortedMembers) {
        if (w.seriesLocked && w.seriesOrder != null) {
          usedOrders.add(w.seriesOrder!);
        }
      }

      var nextOrder = 1;
      for (final w in sortedMembers) {
        if (w.seriesLocked) {
          // 严格尊重人工锁定的 seriesId / seriesOrder / seriesLabel。
          if (w.seriesId != null && w.seriesId!.isNotEmpty) {
            referencedGroupIds.add(w.seriesId!);
          }
          continue;
        }
        while (usedOrders.contains(nextOrder)) {
          nextOrder++;
        }
        final assignedOrder = nextOrder;
        usedOrders.add(assignedOrder);
        nextOrder++;

        final assignedLabel = _defaultSeriesLabel(
          w,
          fallbackIndex: assignedOrder,
          sortedMembers: sortedMembers,
        );
        if (w.seriesId != targetSeriesId ||
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
        }
      }
    }

    for (final group in existingGroups) {
      if (!referencedGroupIds.contains(group.id)) {
        await repository.deleteSeriesGroup(group.id);
      }
    }
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
      final norm = raw.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
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

    String? rootPath;
    if (hadSeasonSegment) {
      // e.g. [ReinForce] Spy x Family/Season 1 -> 合集根是 [ReinForce] Spy x Family
      rootPath = segments.join('/');
    } else if (segments.length >= 2) {
      // e.g. [ReinForce] Spy x Family/Code White -> 检查父目录是否为泛化目录
      final parent = segments.sublist(0, segments.length - 1);
      final parentLeaf = parent.last.trim();
      if (!_isGenericFolder(parentLeaf)) {
        rootPath = parent.join('/');
      }
    }

    if (rootPath == null || _isGenericFolder(rootPath.split('/').last)) {
      return null;
    }

    return _WorkFolderDescriptor(
      workIndex: workIndex,
      sourceId: sourceId,
      workDir: sortedDirs.first.key,
      collectionRoot: rootPath,
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
