import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/library_search_matcher.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/parsing/bdrip_parser.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/scraping/scrape_domain_adapter.dart';
import '../../domain/scraping/work_wall_eligibility.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../../infrastructure/database/drift_library_repository.dart';
import '../../infrastructure/database/konata_database.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../scraping/scrape_work_persister.dart';
import '../scraping/series_auto_linker.dart';
import 'konata_value_notifier.dart';

/// 顶部胶囊导航栏固定 4 个一级页面标签。
enum KonataNavSection {
  /// 媒体库海报墙。
  library,

  /// 媒体源管理。
  sources,

  /// 播放记录时间轴。
  history,

  /// 网络与外部播放器设置。
  settings,
}

/// 作品列表项聚合视图模型（含版本数、媒体源归属与主力压制组摘要，供海报卡片与搜索过滤使用）。
class WorkLibraryItem {
  /// 创建媒体库列表项。
  const WorkLibraryItem({
    required this.work,
    required this.variants,
    required this.episodeCount,
    required this.releaseGroups,
    this.maxEpisodeVariantCount = 1,
    this.sourceIds = const [],
    this.primarySourceKind,
    this.primarySourceLabel,
    this.crossSourceBadgeLabel,
  });

  /// 作品实体。
  final Work work;

  /// 关联物理版本列表。
  final List<MediaVariant> variants;

  /// 正片逻辑剧集数量。
  final int episodeCount;

  /// 单集正片最高多版本数量（仅用于卡片右上角 `N版本` 角标展示）。
  final int maxEpisodeVariantCount;

  /// 压制组/字幕组摘要集合。
  final List<String> releaseGroups;

  /// 关联的去重媒体源 ID 列表。
  final List<String> sourceIds;

  /// 主媒体源协议类型（本地 / WebDAV / SMB）。
  final MediaSourceKind? primarySourceKind;

  /// 主媒体源显示名称（同协议多源同名冲突时用于区分）。
  final String? primarySourceLabel;

  /// 仅当不同媒体源存在相同作品卡片时计算出的右上角来源角标文案（单源唯一作品恒为 `null`）。
  final String? crossSourceBadgeLabel;

  /// 是否包含同一正片剧集的真实多版本压制文件。
  bool get hasMultiVariants => maxEpisodeVariantCount > 1;

  /// 复制并更新跨来源角标文案。
  WorkLibraryItem copyWithCrossSourceBadge(String? badgeLabel) {
    if (badgeLabel == crossSourceBadgeLabel) return this;
    return WorkLibraryItem(
      work: work,
      variants: variants,
      episodeCount: episodeCount,
      releaseGroups: releaseGroups,
      maxEpisodeVariantCount: maxEpisodeVariantCount,
      sourceIds: sourceIds,
      primarySourceKind: primarySourceKind,
      primarySourceLabel: primarySourceLabel,
      crossSourceBadgeLabel: badgeLabel,
    );
  }
}

/// 可在手动编辑弹窗中调整共享/独享作用域的附属条目描述。
class SupplementaryEditableItem {
  /// 创建附属条目范围描述项。
  const SupplementaryEditableItem({
    required this.variant,
    this.episode,
    required this.ownerWorkId,
    required this.ownerLabel,
  });

  /// 物理媒体文件变体。
  final MediaVariant variant;

  /// 若为特典视频，则为所属逻辑分集。
  final Episode? episode;

  /// 当前所属作品 ID。
  final String ownerWorkId;

  /// 当前所属条目展示名称或系列标签。
  final String ownerLabel;
}

/// 作品详情页强类型聚合数据包。
class WorkDetailBundle {
  /// 创建详情数据包。
  const WorkDetailBundle({
    required this.work,
    required this.episodes,
    required this.variants,
    required this.sourcesById,
    required this.latestPlayback,
    this.playbackByEpisodeId = const {},
    this.seriesGroup,
    this.seriesMembers = const [],
    this.cdVariants = const [],
    this.scanVariants = const [],
    this.editableSupplementaryItems = const [],
    this.variantsByEpisodeId,
  });

  /// 作品实体。
  final Work work;

  /// 所属作品（含系列共用特典）的逻辑剧集。
  final List<Episode> episodes;

  /// 所属物理变体列表（含系列共用特典变体）。
  final List<MediaVariant> variants;

  /// 媒体源字典（按 sourceId 索引）。
  final Map<String, MediaSource> sourcesById;

  /// 最近一次播放记录。
  final PlaybackRecord? latestPlayback;

  /// 按 `episodeId` 索引的最新播放记录（用于进度条与续播定位）。
  final Map<String, PlaybackRecord> playbackByEpisodeId;

  /// 所属系列编组（若未加入任何系列或仅单作则为 `null`）。
  final SeriesGroup? seriesGroup;

  /// 同一系列下按排序顺序排列的全部作品成员。
  final List<Work> seriesMembers;

  /// 当前作品可见的附属音乐 CD 音轨（自身全部 + 同系列共用项）。
  final List<MediaVariant> cdVariants;

  /// 当前作品可见的附属 Scan 画集图包（自身全部 + 同系列共用项）。
  final List<MediaVariant> scanVariants;

  /// 当前系列/作品下所有可调整共享范围的特典、CD 与 Scan 条目。
  final List<SupplementaryEditableItem> editableSupplementaryItems;

  /// 按 `episodeId` 预建的变体查找表（O(1) 访问，缺省时兼容回退线性过滤）。
  final Map<String, List<MediaVariant>>? variantsByEpisodeId;

  /// 取得指定逻辑分集的物理文件变体。
  List<MediaVariant> variantsForEpisode(String episodeId) {
    final indexed = variantsByEpisodeId;
    if (indexed != null) {
      return indexed[episodeId] ?? const <MediaVariant>[];
    }
    return variants.where((v) => v.episodeId == episodeId).toList();
  }
}

/// 全局 Drift 数据库 Provider（生命周期随 ProviderScope 自动释放）。
final konataDatabaseProvider = Provider<KonataDatabase>((ref) {
  final db = KonataDatabase.openDefault();
  ref.onDispose(db.close);
  return db;
});

/// 统一根目录 `photos/` 图片存储管理器 Provider。
final photosStorageProvider = Provider<PhotosStorage>((ref) {
  final storageRoot = ref.watch(storageRootProvider);
  return PhotosStorage(storageRoot: storageRoot);
});

/// 强类型媒体库仓储 Provider。
final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  final db = ref.watch(konataDatabaseProvider);
  return DriftLibraryRepository(db);
});

/// 当前激活的一级导航页面状态。
final selectedNavSectionProvider =
    NotifierProvider<KonataValueNotifier<KonataNavSection>, KonataNavSection>(
      () => KonataValueNotifier<KonataNavSection>.value(
        KonataNavSection.library,
      ),
    );

/// 媒体库实时搜索关键词。
final librarySearchQueryProvider =
    NotifierProvider<KonataValueNotifier<String>, String>(
      () => KonataValueNotifier<String>.value(''),
    );

/// 启动期系列归组与 ClearLogo 一次无感自愈标记（由 Riverpod 托管，避免重复扫描数据库）。
final _initialSeriesReconcileDoneProvider =
    NotifierProvider<KonataValueNotifier<bool>, bool>(
      () => KonataValueNotifier<bool>.value(false),
    );

/// 媒体库全量作品列表（默认自动过滤已隐藏作品，含版本与压制组摘要）。
final libraryItemsProvider = FutureProvider<List<WorkLibraryItem>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  final photos = ref.watch(photosStorageProvider);

  // 4 条并行全量批量查询取代 2N+2 次逐作品 N+1 查询。
  final initial = await Future.wait<Object>([
    repo.getAllWorks(),
    repo.getMediaSources(),
    repo.getAllVariants(),
    repo.getAllEpisodes(),
  ]);
  var works = initial[0] as List<Work>;
  final sources = initial[1] as List<MediaSource>;
  final allVariants = initial[2] as List<MediaVariant>;
  final allEpisodes = initial[3] as List<Episode>;

  if (!ref.read(_initialSeriesReconcileDoneProvider) && works.isNotEmpty) {
    ref.read(_initialSeriesReconcileDoneProvider.notifier).state = true;
    try {
      final changed = await SeriesAutoLinker.reconcileAll(
        repository: repo,
        preloadedWorks: works,
        preloadedVariants: allVariants,
      );
      if (changed) {
        ref.invalidate(seriesGroupsProvider);
        ref.invalidate(workDetailBundleProvider);
        works = await repo.getAllWorks();
      }
    } catch (error) {
      // 无网络或裁剪 mock 仓储下静默跳过自愈，不影响首屏加载。
      developer.log('可恢复异常已记录', name: 'konata.library_providers', error: error);
    }
  }

  final sourcesById = <String, MediaSource>{
    for (final s in sources) s.id: s,
  };
  final variantsByWorkId = <String, List<MediaVariant>>{};
  for (final v in allVariants) {
    variantsByWorkId.putIfAbsent(v.workId, () => <MediaVariant>[]).add(v);
  }
  final mainEpisodeIdsByWorkId = <String, Set<String>>{};
  for (final ep in allEpisodes) {
    if (ep.category == EpisodeCategory.main) {
      mainEpisodeIdsByWorkId
          .putIfAbsent(ep.workId, () => <String>{})
          .add(ep.id);
    }
  }

  final items = <WorkLibraryItem>[];
  for (final work in works) {
    photos.cacheWorkTitle(work.id, work.title);
    if (work.isHidden) continue;
    final variants = variantsByWorkId[work.id] ?? const <MediaVariant>[];
    final mainEpisodeIds =
        mainEpisodeIdsByWorkId[work.id] ?? const <String>{};
    final countByEpisode = <String, int>{};
    final groups = <String>{};
    final sourceIdSet = <String>{};
    for (final v in variants) {
      if (v.releaseGroup != null && v.releaseGroup!.isNotEmpty) {
        groups.add(v.releaseGroup!);
      }
      if (v.sourceId.isNotEmpty) {
        sourceIdSet.add(v.sourceId);
      }
      if (v.assetKind != AssetKind.video) continue;
      final epId = v.episodeId;
      if (epId == null || !mainEpisodeIds.contains(epId)) continue;
      countByEpisode[epId] = (countByEpisode[epId] ?? 0) + 1;
    }
    var maxVariantCount = 1;
    for (final count in countByEpisode.values) {
      if (count > maxVariantCount) {
        maxVariantCount = count;
      }
    }

    final sourceIds = sourceIdSet.toList(growable: false);
    final primarySource = sourceIds.isNotEmpty
        ? sourcesById[sourceIds.first]
        : null;
    items.add(
      WorkLibraryItem(
        work: work,
        variants: variants,
        episodeCount: mainEpisodeIds.length,
        maxEpisodeVariantCount: maxVariantCount,
        releaseGroups: groups.toList(growable: false),
        sourceIds: sourceIds,
        primarySourceKind: primarySource?.kind,
        primarySourceLabel: primarySource?.label,
      ),
    );
  }
  return items;
});

/// 为跨不同媒体源并存相同作品卡片的条目按需标注右上角来源角标（单源唯一卡片保持干净无角标）。
List<WorkLibraryItem> annotateCrossSourceBadges(List<WorkLibraryItem> items) {
  if (items.length < 2) return items;
  final buckets = <String, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    final key = WorkWallEligibility.buildCrossSourceIdentityKey(items[i].work);
    buckets.putIfAbsent(key, () => <int>[]).add(i);
  }

  List<WorkLibraryItem>? updated;
  for (final indices in buckets.values) {
    if (indices.length < 2) continue;
    final distinctSources = <String>{};
    for (final idx in indices) {
      distinctSources.addAll(items[idx].sourceIds);
    }
    if (distinctSources.length < 2) continue;

    final kindCounts = <MediaSourceKind, int>{};
    for (final idx in indices) {
      final kind = items[idx].primarySourceKind;
      if (kind != null) {
        kindCounts[kind] = (kindCounts[kind] ?? 0) + 1;
      }
    }

    updated ??= List<WorkLibraryItem>.of(items);
    for (final idx in indices) {
      final item = items[idx];
      final String? badge;
      if (item.sourceIds.length > 1) {
        badge = '多源';
      } else if (item.primarySourceKind != null) {
        final kind = item.primarySourceKind!;
        final kindText = switch (kind) {
          MediaSourceKind.local => '本地',
          MediaSourceKind.webdav => 'WebDAV',
          MediaSourceKind.smb => 'SMB',
        };
        final sameKindCollision = (kindCounts[kind] ?? 0) > 1;
        final label = item.primarySourceLabel?.trim() ?? '';
        badge = (sameKindCollision && label.isNotEmpty) ? label : kindText;
      } else {
        final label = item.primarySourceLabel?.trim() ?? '';
        badge = label.isNotEmpty ? label : null;
      }
      if (badge != null) {
        updated[idx] = item.copyWithCrossSourceBadge(badge);
      }
    }
  }
  return updated == null ? items : List<WorkLibraryItem>.unmodifiable(updated);
}

/// 媒体库海报墙正式入库作品列表（严格排除尚未确认的 `needsReview` / `unmatched` 条目，并仅为跨源重复作品标注来源角标）。
final confirmedLibraryItemsProvider =
    Provider<AsyncValue<List<WorkLibraryItem>>>((ref) {
      final itemsAsync = ref.watch(libraryItemsProvider);
      return itemsAsync.whenData((items) {
        final confirmed = items
            .where(
              (item) =>
                  item.work.scrapeStatus == ScrapeStatus.matched ||
                  item.work.isManualLocked,
            )
            .toList(growable: false);
        return annotateCrossSourceBadges(confirmed);
      });
    });

/// 媒体库海报墙当前实际可见的已确认作品数量 Provider。
final worksCountProvider = FutureProvider<int>((ref) async {
  final items = await ref.watch(libraryItemsProvider.future);
  return items
      .where(
        (item) =>
            item.work.scrapeStatus == ScrapeStatus.matched ||
            item.work.isManualLocked,
      )
      .length;
});

/// 已隐藏作品列表 Provider（通过 `idx_works_hidden` 索引精准查询，避免全表读取）。
final hiddenWorksProvider = FutureProvider<List<Work>>((ref) {
  return ref.watch(libraryRepositoryProvider).getHiddenWorks();
});

/// 按关键词实时过滤并按相关度稳定排序后的正式入库作品列表。
///
/// 支持作品译名、原名、压制组空格分词模糊搜索，以及完整 TMDB / Bangumi ID
/// 或 `tmdb:ID` / `bgm:ID` 精确查询（杜绝短数字子串误召回无关 ID）。
final filteredLibraryItemsProvider =
    Provider<AsyncValue<List<WorkLibraryItem>>>((ref) {
      final itemsAsync = ref.watch(confirmedLibraryItemsProvider);
      final query = ref.watch(librarySearchQueryProvider).trim();
      return itemsAsync.whenData((items) {
        if (query.isEmpty) return items;
        return LibrarySearchMatcher.filterAndRank<WorkLibraryItem>(
          items: items,
          rawQuery: query,
          workOf: (item) => item.work,
          releaseGroupsOf: (item) => item.releaseGroups,
        );
      });
    });

/// 待复核与未匹配队列作品列表。
final needsReviewItemsProvider = Provider<AsyncValue<List<WorkLibraryItem>>>((
  ref,
) {
  final itemsAsync = ref.watch(libraryItemsProvider);
  return itemsAsync.whenData(
    (items) => items
        .where(
          (item) =>
              !item.work.isManualLocked &&
              (item.work.scrapeStatus == ScrapeStatus.needsReview ||
                  item.work.scrapeStatus == ScrapeStatus.unmatched),
        )
        .toList(),
  );
});

/// 查询指定作品的 Top-5 待复核候选列表。
final workScrapeCandidatesProvider =
    FutureProvider.family<List<ScrapeCandidateSummary>, String>((ref, workId) {
      final repo = ref.watch(libraryRepositoryProvider);
      return repo.getScrapeCandidates(workId);
    });

/// 全库系列编组 Provider。
final seriesGroupsProvider = FutureProvider<List<SeriesGroup>>((ref) {
  return ref.watch(libraryRepositoryProvider).getAllSeriesGroups();
});

/// 对未锁定且未绑定 TMDB 分集封面的特典条目执行加载期无感自愈：
/// 1. 拆解历史因宽松编号碰撞而被误合并的同号不同限定词特典（如 `PV01` 与 `Character PV 01`、`Teaser PV 01`、`NCED1a` 与 `NCED1b`）；
/// 2. 修正旧版截断自动生成标题与错分类型，并持久化写回仓储。
Future<({List<Episode> episodes, List<MediaVariant> variants})>
reconcileWorkExtraEpisodes({
  required Work work,
  required List<Episode> episodes,
  required List<MediaVariant> variants,
  required LibraryRepository repo,
}) async {
  if (episodes.isEmpty || variants.isEmpty) {
    return (episodes: episodes, variants: variants);
  }

  final epList = List<Episode>.of(episodes);
  final varList = List<MediaVariant>.of(variants);
  final epIndexById = <String, int>{
    for (var i = 0; i < epList.length; i++) epList[i].id: i,
  };
  final varIndexById = <String, int>{
    for (var i = 0; i < varList.length; i++) varList[i].id: i,
  };

  final variantsByEp = <String, List<MediaVariant>>{};
  final workVideoEntries = <({String fileName, String relativePath})>[];
  for (final v in varList) {
    if (v.assetKind != AssetKind.video) continue;
    workVideoEntries.add((fileName: v.fileName, relativePath: v.relativePath));
    if (v.episodeId != null) {
      variantsByEp.putIfAbsent(v.episodeId!, () => []).add(v);
    }
  }

  var mutated = false;
  for (final ep in episodes) {
    if (ep.category != EpisodeCategory.extra || ep.stillPath != null) {
      continue;
    }
    final epVariants = variantsByEp[ep.id];
    if (epVariants == null || epVariants.isEmpty) continue;
    if (epVariants.any((v) => v.mappingLocked)) continue;

    final groups =
        <String, List<({MediaVariant variant, EpisodeSlotAssignment slot})>>{};
    for (final v in epVariants) {
      final parsed = BdripParser.parseFileName(
        v.fileName,
        relativePath: v.relativePath,
      );
      final slot = ScrapeDomainAdapter.resolveExtraSlotAssignment(
        fileName: v.fileName,
        relativePath: v.relativePath,
        parsed: parsed,
        folderCleanTitle: work.title,
        workVideoEntries: workVideoEntries,
      );
      final canonicalKey =
          slot.unnumberedStemKey ??
          SupplementarySubclassifier.buildExtraCanonicalMergeKey(
            fileName: v.fileName,
            relativePath: v.relativePath,
            extraType: slot.extraType,
            titleHint: slot.extraTitleHint,
            workTitle: work.title,
          );
      groups.putIfAbsent(canonicalKey, () => []).add((variant: v, slot: slot));
    }

    if (groups.isEmpty) continue;

    final entries = groups.entries.toList(growable: true);
    if (entries.length >= 2) {
      // 优先让与现有标题语义最一致的组保留原 episodeId，完整承接播放历史
      final existingCompact = (ep.title ?? '').trim().toLowerCase().replaceAll(
        RegExp(r'\s+'),
        '',
      );
      final matchIdx = entries.indexWhere((e) {
        final hint = (e.value.first.slot.extraTitleHint ?? '')
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), '');
        return hint.isNotEmpty && hint == existingCompact;
      });
      if (matchIdx > 0) {
        final matched = entries.removeAt(matchIdx);
        entries.insert(0, matched);
      }
    }

    for (var i = 0; i < entries.length; i++) {
      final groupKey = entries[i].key;
      final groupItems = entries[i].value;
      final repSlot = groupItems.first.slot;
      final desiredTitle = repSlot.extraTitleHint?.trim() ?? '';
      final desiredType = repSlot.extraType ?? ep.extraType;

      if (i == 0) {
        final shouldFixTitle =
            desiredTitle.isNotEmpty &&
            (entries.length >= 2
                ? desiredTitle != (ep.title?.trim() ?? '') &&
                      _matchExactOrTruncated(ep.title, desiredTitle)
                : SupplementarySubclassifier.isLikelyTruncatedAutoExtraTitle(
                    ep.title,
                    desiredTitle,
                  ));
        final shouldFixType =
            desiredType != null && desiredType != ep.extraType;
        if (shouldFixTitle || shouldFixType) {
          final updatedEp = Episode(
            id: ep.id,
            workId: ep.workId,
            seasonNumber: ep.seasonNumber,
            episodeNumber: repSlot.episodeNumber ?? ep.episodeNumber,
            category: ep.category,
            extraType: shouldFixType ? desiredType : ep.extraType,
            title: shouldFixTitle ? desiredTitle : ep.title,
            overview: ep.overview,
            stillPath: ep.stillPath,
          );
          await repo.upsertEpisode(updatedEp);
          final idx = epIndexById[ep.id];
          if (idx != null) {
            epList[idx] = updatedEp;
          }
          mutated = true;
        }
        continue;
      }

      // 第 1..N-1 组：拆分到独立确定的特典 Episode 槽位并迁移所属 MediaVariant
      final newEpId = ScrapeWorkPersister.deterministicId(
        '${work.id}::extra_reconciled::$groupKey',
      );
      final targetTitle = desiredTitle.isNotEmpty ? desiredTitle : ep.title;
      final newEp = Episode(
        id: newEpId,
        workId: work.id,
        seasonNumber: 0,
        episodeNumber: repSlot.episodeNumber,
        category: EpisodeCategory.extra,
        extraType: desiredType ?? ExtraKind.sp,
        title: targetTitle,
        overview: null,
        stillPath: null,
      );
      await repo.upsertEpisode(newEp);
      final existingIdx = epIndexById[newEpId];
      if (existingIdx != null) {
        epList[existingIdx] = newEp;
      } else {
        epIndexById[newEpId] = epList.length;
        epList.add(newEp);
      }

      for (final item in groupItems) {
        final updatedVariant = item.variant.copyWith(episodeId: newEpId);
        await repo.upsertMediaVariant(updatedVariant);
        final vIdx = varIndexById[updatedVariant.id];
        if (vIdx != null) {
          varList[vIdx] = updatedVariant;
        }
      }
      mutated = true;
    }
  }

  if (mutated) {
    await repo.deleteOrphanEpisodes(work.id);
  }
  return (episodes: epList, variants: varList);
}

bool _matchExactOrTruncated(String? existingTitle, String resolvedTitle) {
  final existing = existingTitle?.trim() ?? '';
  if (existing.isEmpty) return true;
  if (existing == resolvedTitle) return false;
  return SupplementarySubclassifier.isLikelyTruncatedAutoExtraTitle(
    existingTitle,
    resolvedTitle,
  );
}

/// 记录因合并或文件全部拆出而被清理的 `sourceWorkId -> targetWorkId` 重定向表，
/// 使详情页或历史跳转在遇到旧 ID 时能够无缝切入存活目标作品。
final workRedirectMapProvider =
    NotifierProvider<KonataValueNotifier<Map<String, String>>, Map<String, String>>(
      () => KonataValueNotifier<Map<String, String>>.value(const {}),
    );

/// 登记旧作品被合并或迁移至目标存活作品的重定向关系。
void recordWorkRedirect(Ref ref, String sourceWorkId, String targetWorkId) {
  if (sourceWorkId.isEmpty ||
      targetWorkId.isEmpty ||
      sourceWorkId == targetWorkId) {
    return;
  }
  final current = ref.read(workRedirectMapProvider);
  if (current[sourceWorkId] == targetWorkId) return;
  ref.read(workRedirectMapProvider.notifier).state = <String, String>{
    ...current,
    sourceWorkId: targetWorkId,
  };
}

/// 当某部作品被用户明确删除时，清理指向该作品或从该作品出发的重定向记录。
void clearWorkRedirectsForWork(Ref ref, String workId) {
  final current = ref.read(workRedirectMapProvider);
  if (current.isEmpty) return;
  final next = <String, String>{};
  for (final entry in current.entries) {
    if (entry.key == workId || entry.value == workId) continue;
    next[entry.key] = entry.value;
  }
  if (next.length != current.length) {
    ref.read(workRedirectMapProvider.notifier).state = next;
  }
}

/// 沿合并重定向链查找当前存活作品 ID（内置防环保护）。
String resolveWorkRedirectChain(Map<String, String> map, String workId) {
  var current = workId;
  final visited = <String>{current};
  for (var i = 0; i < 6; i++) {
    final next = map[current];
    if (next == null || next.isEmpty || !visited.add(next)) break;
    current = next;
  }
  return current;
}

/// 作品特典自愈状态签名缓存（由 Riverpod 托管生命周期，防止重复打开详情页反复执行高开销正则解析）。
///
/// 签名覆盖 `work.title`、全部未配剧照特典分集与视频变体关键字段；一旦重扫、改名、
/// 人工编辑或合集拆分引起任意字段变化，签名即失配并自动重新执行自愈，零脏缓存风险。
class ExtraReconcileSignatureCache {
  static const int _maxEntries = 512;
  final Map<String, int> _cleanSignatureByWorkId = <String, int>{};

  /// 计算作品特典自愈输入集的确定性 64 位复合指纹。
  static int computeSignature({
    required Work work,
    required List<Episode> episodes,
    required List<MediaVariant> variants,
  }) {
    var h = work.title.hashCode;
    var hasReconcilableExtra = false;
    for (final ep in episodes) {
      if (ep.category != EpisodeCategory.extra || ep.stillPath != null) {
        continue;
      }
      hasReconcilableExtra = true;
      h = Object.hash(
        h,
        ep.id,
        ep.seasonNumber,
        ep.episodeNumber,
        ep.extraType,
        ep.title,
      );
    }
    if (!hasReconcilableExtra) return 0;
    for (final v in variants) {
      if (v.assetKind != AssetKind.video) continue;
      h = Object.hash(
        h,
        v.id,
        v.episodeId,
        v.fileName,
        v.relativePath,
        v.mappingLocked,
      );
    }
    return h == 0 ? 1 : h;
  }

  /// 判断作品当前特典集是否已与最近一次干净自愈状态完全一致。
  bool isClean(String workId, int signature) {
    if (signature == 0) return true;
    return _cleanSignatureByWorkId[workId] == signature;
  }

  /// 记录作品最新一次自愈完成后的干净状态签名。
  void markClean(String workId, int signature) {
    if (signature == 0) return;
    if (_cleanSignatureByWorkId.length >= _maxEntries &&
        !_cleanSignatureByWorkId.containsKey(workId)) {
      _cleanSignatureByWorkId.remove(_cleanSignatureByWorkId.keys.first);
    }
    _cleanSignatureByWorkId[workId] = signature;
  }

  /// 清理全部签名记录。
  void clear() => _cleanSignatureByWorkId.clear();
}

/// 详情页特典自愈签名缓存 Provider。
final extraReconcileSignatureCacheProvider =
    Provider<ExtraReconcileSignatureCache>((ref) {
      final cache = ExtraReconcileSignatureCache();
      ref.onDispose(cache.clear);
      return cache;
    });

Future<({List<Episode> episodes, List<MediaVariant> variants})>
_reconcileWorkExtraEpisodesCached({
  required Work work,
  required List<Episode> episodes,
  required List<MediaVariant> variants,
  required LibraryRepository repo,
  required ExtraReconcileSignatureCache cache,
}) async {
  final sig = ExtraReconcileSignatureCache.computeSignature(
    work: work,
    episodes: episodes,
    variants: variants,
  );
  if (cache.isClean(work.id, sig)) {
    return (episodes: episodes, variants: variants);
  }
  final reconciled = await reconcileWorkExtraEpisodes(
    work: work,
    episodes: episodes,
    variants: variants,
    repo: repo,
  );
  final postSig = ExtraReconcileSignatureCache.computeSignature(
    work: work,
    episodes: reconciled.episodes,
    variants: reconciled.variants,
  );
  cache.markClean(work.id, postSig);
  return reconciled;
}

/// 查询单部作品详情页所需的完整数据包。
final workDetailBundleProvider =
    FutureProvider.family<WorkDetailBundle?, String>((ref, workId) async {
      final repo = ref.watch(libraryRepositoryProvider);
      final photos = ref.watch(photosStorageProvider);
      final extraCache = ref.watch(extraReconcileSignatureCacheProvider);
      final work = await repo.findWorkById(workId);
      if (work == null) return null;
      photos.cacheWorkTitle(work.id, work.title);

      final hasSeries = work.seriesId != null && work.seriesId!.isNotEmpty;
      final coreFutures = <Future<Object?>>[
        repo.getEpisodesByWork(workId),
        repo.getVariantsByWork(workId),
        repo.getMediaSources(),
        repo.getPlaybacksByWork(workId),
        if (hasSeries) repo.findSeriesGroupById(work.seriesId!),
        if (hasSeries) repo.getWorksBySeries(work.seriesId!),
      ];
      final coreResults = await Future.wait(coreFutures);
      final rawEpisodes = coreResults[0]! as List<Episode>;
      final rawVariants = coreResults[1]! as List<MediaVariant>;
      final sources = coreResults[2]! as List<MediaSource>;
      final allPlaybacks = coreResults[3]! as List<PlaybackRecord>;
      final seriesGroup = hasSeries ? coreResults[4] as SeriesGroup? : null;
      final rawSeriesWorks = hasSeries
          ? coreResults[5]! as List<Work>
          : const <Work>[];

      final reconciled = await _reconcileWorkExtraEpisodesCached(
        work: work,
        episodes: rawEpisodes,
        variants: rawVariants,
        repo: repo,
        cache: extraCache,
      );
      final episodes = reconciled.episodes;
      final variants = reconciled.variants;

      // `allPlaybacks` 已按 `playedAt DESC` 排序，直接单遍提取最新视频续播与分集映射表，省去重复 SQL 往返。
      PlaybackRecord? latestPlayback;
      final playbackByEpisodeId = <String, PlaybackRecord>{};
      for (final record in allPlaybacks) {
        if (latestPlayback == null && !record.episodeId.startsWith('cd::')) {
          latestPlayback = record;
        }
        playbackByEpisodeId.putIfAbsent(record.episodeId, () => record);
      }
      final sourcesById = {for (final s in sources) s.id: s};

      final seriesMembers = hasSeries
          ? SeriesSeasonFormatter.sortSeriesMembers(
              rawSeriesWorks.where((w) => !w.isHidden),
            )
          : const <Work>[];
      final mergedEpisodes = List<Episode>.of(episodes);
      final mergedEpisodeIds = mergedEpisodes.map((e) => e.id).toSet();
      final mergedVariants = List<MediaVariant>.of(variants);
      final seenVariantPaths = <String>{
        for (final v in variants)
          '${v.sourceId}::${v.relativePath.toLowerCase()}',
      };

      final cdList = <MediaVariant>[
        for (final v in variants)
          if (v.assetKind == AssetKind.cdAlbum) v,
      ];
      final scanList = <MediaVariant>[
        for (final v in variants)
          if (v.assetKind == AssetKind.scanGallery) v,
      ];

      final disambiguationMembers = seriesMembers.isNotEmpty
          ? seriesMembers
          : <Work>[work];
      final selfIdx = disambiguationMembers.indexWhere((m) => m.id == work.id);
      final selfLabel = SeriesSeasonFormatter.formatMemberLabel(
        work,
        disambiguationMembers,
        seriesGroup: seriesGroup,
        fallbackOrder: selfIdx >= 0 ? selfIdx + 1 : 1,
      );

      final workEpById = {for (final e in episodes) e.id: e};
      final editableItems = <SupplementaryEditableItem>[
        for (final v in variants)
          if (v.assetKind == AssetKind.cdAlbum ||
              v.assetKind == AssetKind.scanGallery ||
              (v.assetKind == AssetKind.video &&
                  v.episodeId != null &&
                  workEpById[v.episodeId]?.category == EpisodeCategory.extra))
            SupplementaryEditableItem(
              variant: v,
              episode: v.episodeId != null ? workEpById[v.episodeId] : null,
              ownerWorkId: work.id,
              ownerLabel: selfLabel,
            ),
      ];

      // 筛选需要读取附属条目的其他系列成员，合并为 2 次批量查询取代 2M 次串行往返。
      final otherMembers = <({int index, Work work})>[];
      for (var i = 0; i < seriesMembers.length; i++) {
        final member = seriesMembers[i];
        photos.cacheWorkTitle(member.id, member.title);
        if (member.id == work.id) continue;
        final isDuplicateSameInstallment =
            work.tmdbId != null &&
            member.tmdbId == work.tmdbId &&
            member.tmdbMediaType == work.tmdbMediaType &&
            member.matchedSeason == work.matchedSeason;
        if (isDuplicateSameInstallment) continue;
        otherMembers.add((index: i, work: member));
      }

      if (otherMembers.isNotEmpty) {
        final otherIds = [for (final item in otherMembers) item.work.id];
        final batchResults = await Future.wait<Object>([
          repo.getEpisodesByWorkIds(otherIds),
          repo.getVariantsByWorkIds(otherIds),
        ]);
        final batchEpisodes = batchResults[0] as List<Episode>;
        final batchVariants = batchResults[1] as List<MediaVariant>;

        final episodesByMemberId = <String, List<Episode>>{};
        for (final ep in batchEpisodes) {
          episodesByMemberId.putIfAbsent(ep.workId, () => <Episode>[]).add(ep);
        }
        final variantsByMemberId = <String, List<MediaVariant>>{};
        for (final v in batchVariants) {
          variantsByMemberId
              .putIfAbsent(v.workId, () => <MediaVariant>[])
              .add(v);
        }

        for (final entry in otherMembers) {
          final member = entry.work;
          final mRawEpisodes = Episode.sortMainFirst(
            episodesByMemberId[member.id] ?? const <Episode>[],
          );
          final mRawVariants =
              variantsByMemberId[member.id] ?? const <MediaVariant>[];
          final mReconciled = await _reconcileWorkExtraEpisodesCached(
            work: member,
            episodes: mRawEpisodes,
            variants: mRawVariants,
            repo: repo,
            cache: extraCache,
          );
          final mEpisodes = mReconciled.episodes;
          final mVariants = mReconciled.variants;
          final mEpById = {for (final e in mEpisodes) e.id: e};
          final mLabel = SeriesSeasonFormatter.formatMemberLabel(
            member,
            seriesMembers,
            seriesGroup: seriesGroup,
            fallbackOrder: entry.index + 1,
          );

          for (final mv in mVariants) {
            final ep = mv.episodeId != null ? mEpById[mv.episodeId] : null;
            final isSupp =
                mv.assetKind == AssetKind.cdAlbum ||
                mv.assetKind == AssetKind.scanGallery ||
                (mv.assetKind == AssetKind.video &&
                    ep?.category == EpisodeCategory.extra);
            if (!isSupp) continue;

            editableItems.add(
              SupplementaryEditableItem(
                variant: mv,
                episode: ep,
                ownerWorkId: member.id,
                ownerLabel: mLabel,
              ),
            );

            if (mv.assetScope != SupplementaryAssetScope.seriesShared) {
              continue;
            }
            final pathKey = '${mv.sourceId}::${mv.relativePath.toLowerCase()}';
            if (!seenVariantPaths.add(pathKey)) continue;

            if (mv.assetKind == AssetKind.cdAlbum) {
              cdList.add(mv);
            } else if (mv.assetKind == AssetKind.scanGallery) {
              scanList.add(mv);
            } else if (ep != null) {
              mergedVariants.add(mv);
              if (mergedEpisodeIds.add(ep.id)) {
                mergedEpisodes.add(ep);
              }
            }
          }
        }
      }

      cdList.sort((a, b) {
        final aOwn = a.workId == work.id;
        final bOwn = b.workId == work.id;
        if (aOwn != bOwn) return aOwn ? -1 : 1;
        return a.relativePath.toLowerCase().compareTo(
          b.relativePath.toLowerCase(),
        );
      });
      scanList.sort((a, b) {
        final aOwn = a.workId == work.id;
        final bOwn = b.workId == work.id;
        if (aOwn != bOwn) return aOwn ? -1 : 1;
        return a.relativePath.toLowerCase().compareTo(
          b.relativePath.toLowerCase(),
        );
      });

      final variantsByEpisodeId = <String, List<MediaVariant>>{};
      for (final v in mergedVariants) {
        final epId = v.episodeId;
        if (epId != null) {
          variantsByEpisodeId
              .putIfAbsent(epId, () => <MediaVariant>[])
              .add(v);
        }
      }

      return WorkDetailBundle(
        work: work,
        episodes: mergedEpisodes,
        variants: mergedVariants,
        sourcesById: sourcesById,
        latestPlayback: latestPlayback,
        playbackByEpisodeId: Map.unmodifiable(playbackByEpisodeId),
        seriesGroup: seriesGroup,
        seriesMembers: seriesMembers,
        cdVariants: cdList,
        scanVariants: scanList,
        editableSupplementaryItems: editableItems,
        variantsByEpisodeId: Map.unmodifiable({
          for (final e in variantsByEpisodeId.entries)
            e.key: List<MediaVariant>.unmodifiable(e.value),
        }),
      );
    });

/// 全部媒体源列表 Provider。
final mediaSourcesProvider = FutureProvider<List<MediaSource>>((ref) {
  return ref.watch(libraryRepositoryProvider).getMediaSources();
});

/// 全局播放历史时间轴 Provider。
final playbackHistoryProvider = FutureProvider<List<PlaybackRecord>>((ref) {
  return ref.watch(libraryRepositoryProvider).getPlaybackHistory();
});

/// 全站 `photos/` 图片存储全局汇总与按作品明细快照 Provider。
final photosStorageSnapshotProvider = FutureProvider<PhotosStorageSnapshot>((
  ref,
) async {
  final photos = ref.watch(photosStorageProvider);
  final repo = ref.watch(libraryRepositoryProvider);
  final works = await repo.getAllWorks();
  return photos.computeSnapshot(knownWorks: works);
});
