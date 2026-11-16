import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/parsing/bdrip_parser.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/scraping/scrape_domain_adapter.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../../infrastructure/database/drift_library_repository.dart';
import '../../infrastructure/database/konata_database.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../scraping/scrape_work_persister.dart';

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

/// 作品列表项聚合视图模型（含版本数与主力压制组摘要，供海报卡片与搜索过滤使用）。
class WorkLibraryItem {
  /// 创建媒体库列表项。
  const WorkLibraryItem({
    required this.work,
    required this.variants,
    required this.episodeCount,
    required this.releaseGroups,
    this.maxEpisodeVariantCount = 1,
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

  /// 是否包含同一正片剧集的真实多版本压制文件。
  bool get hasMultiVariants => maxEpisodeVariantCount > 1;
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

  /// 取得指定逻辑分集的物理文件变体。
  List<MediaVariant> variantsForEpisode(String episodeId) =>
      variants.where((v) => v.episodeId == episodeId).toList();
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
final selectedNavSectionProvider = StateProvider<KonataNavSection>(
  (ref) => KonataNavSection.library,
);

/// 媒体库实时搜索关键词。
final librarySearchQueryProvider = StateProvider<String>((ref) => '');

/// 媒体库全量作品列表（默认自动过滤已隐藏作品，含版本与压制组摘要）。
final libraryItemsProvider = FutureProvider<List<WorkLibraryItem>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  final photos = ref.watch(photosStorageProvider);
  final works = await repo.getAllWorks();
  final items = <WorkLibraryItem>[];
  for (final work in works) {
    photos.cacheWorkTitle(work.id, work.title);
    if (work.isHidden) continue;
    final variants = await repo.getVariantsByWork(work.id);
    final episodes = await repo.getEpisodesByWork(work.id);
    final mainEpisodes = episodes
        .where((e) => e.category == EpisodeCategory.main)
        .toList(growable: false);
    final mainEpisodeIds = {for (final ep in mainEpisodes) ep.id};
    final countByEpisode = <String, int>{};
    for (final v in variants) {
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

    final groups = <String>{
      for (final v in variants)
        if (v.releaseGroup != null && v.releaseGroup!.isNotEmpty)
          v.releaseGroup!,
    };
    items.add(
      WorkLibraryItem(
        work: work,
        variants: variants,
        episodeCount: mainEpisodes.length,
        maxEpisodeVariantCount: maxVariantCount,
        releaseGroups: groups.toList(growable: false),
      ),
    );
  }
  return items;
});

/// 媒体库海报墙正式入库作品列表（严格排除尚未确认的 `needsReview` / `unmatched` 条目）。
final confirmedLibraryItemsProvider =
    Provider<AsyncValue<List<WorkLibraryItem>>>((ref) {
      final itemsAsync = ref.watch(libraryItemsProvider);
      return itemsAsync.whenData(
        (items) => items
            .where(
              (item) =>
                  item.work.scrapeStatus == ScrapeStatus.matched ||
                  item.work.isManualLocked,
            )
            .toList(growable: false),
      );
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

/// 已隐藏作品列表 Provider（供设置页管理并恢复显示）。
final hiddenWorksProvider = FutureProvider<List<Work>>((ref) async {
  final works = await ref.watch(libraryRepositoryProvider).getAllWorks();
  return works.where((w) => w.isHidden).toList(growable: false);
});

/// 按关键词实时过滤后的正式入库作品列表（支持作品名、原名、压制组、TMDB ID）。
final filteredLibraryItemsProvider =
    Provider<AsyncValue<List<WorkLibraryItem>>>((ref) {
      final itemsAsync = ref.watch(confirmedLibraryItemsProvider);
      final query = ref.watch(librarySearchQueryProvider).trim().toLowerCase();
      return itemsAsync.whenData((items) {
        if (query.isEmpty) return items;
        return items.where((item) {
          final w = item.work;
          if (w.title.toLowerCase().contains(query)) return true;
          if ((w.originalTitle ?? '').toLowerCase().contains(query)) {
            return true;
          }
          if (w.tmdbId != null && w.tmdbId.toString().contains(query)) {
            return true;
          }
          return item.releaseGroups.any(
            (g) => g.toLowerCase().contains(query),
          );
        }).toList();
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
      groups
          .putIfAbsent(canonicalKey, () => [])
          .add((variant: v, slot: slot));
    }

    if (groups.isEmpty) continue;

    final entries = groups.entries.toList(growable: true);
    if (entries.length >= 2) {
      // 优先让与现有标题语义最一致的组保留原 episodeId，完整承接播放历史
      final existingCompact = (ep.title ?? '')
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), '');
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
        final shouldFixType = desiredType != null && desiredType != ep.extraType;
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

/// 查询单部作品详情页所需的完整数据包。
final workDetailBundleProvider =
    FutureProvider.family<WorkDetailBundle?, String>((ref, workId) async {
      final repo = ref.watch(libraryRepositoryProvider);
      final photos = ref.watch(photosStorageProvider);
      final work = await repo.findWorkById(workId);
      if (work == null) return null;
      photos.cacheWorkTitle(work.id, work.title);
      final rawEpisodes = await repo.getEpisodesByWork(workId);
      final rawVariants = await repo.getVariantsByWork(workId);
      final reconciled = await reconcileWorkExtraEpisodes(
        work: work,
        episodes: rawEpisodes,
        variants: rawVariants,
        repo: repo,
      );
      final episodes = reconciled.episodes;
      final variants = reconciled.variants;
      final sources = await repo.getMediaSources();
      final latestPlayback = await repo.getLatestPlaybackForWork(workId);
      final allPlaybacks = await repo.getPlaybacksByWork(workId);
      final playbackByEpisodeId = <String, PlaybackRecord>{};
      for (final record in allPlaybacks) {
        playbackByEpisodeId.putIfAbsent(record.episodeId, () => record);
      }
      final sourcesById = {for (final s in sources) s.id: s};

      SeriesGroup? seriesGroup;
      var seriesMembers = const <Work>[];
      final mergedEpisodes = List<Episode>.of(episodes);
      final mergedEpisodeIds = mergedEpisodes.map((e) => e.id).toSet();
      final mergedVariants = List<MediaVariant>.of(variants);
      final seenVariantPaths = <String>{
        for (final v in variants) '${v.sourceId}::${v.relativePath.toLowerCase()}',
      };

      final cdList = <MediaVariant>[
        for (final v in variants)
          if (v.assetKind == AssetKind.cdAlbum) v,
      ];
      final scanList = <MediaVariant>[
        for (final v in variants)
          if (v.assetKind == AssetKind.scanGallery) v,
      ];

      if (work.seriesId != null && work.seriesId!.isNotEmpty) {
        seriesGroup = await repo.findSeriesGroupById(work.seriesId!);
        final allWorks = await repo.getAllWorks();
        seriesMembers =
            allWorks
                .where((w) => w.seriesId == work.seriesId && !w.isHidden)
                .toList()
              ..sort((a, b) {
                final o = (a.seriesOrder ?? 9999).compareTo(
                  b.seriesOrder ?? 9999,
                );
                if (o != 0) return o;
                return a.title.toLowerCase().compareTo(b.title.toLowerCase());
              });
      }

      final disambiguationMembers = seriesMembers.isNotEmpty
          ? seriesMembers
          : <Work>[work];
      final selfIdx = disambiguationMembers.indexWhere((m) => m.id == work.id);
      final selfLabel = SeriesLabelPresets.formatDisambiguatedMemberLabel(
        work,
        disambiguationMembers,
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

      for (var i = 0; i < seriesMembers.length; i++) {
        final member = seriesMembers[i];
        photos.cacheWorkTitle(member.id, member.title);
        if (member.id == work.id) continue;
        final mRawEpisodes = await repo.getEpisodesByWork(member.id);
        final mRawVariants = await repo.getVariantsByWork(member.id);
        final mReconciled = await reconcileWorkExtraEpisodes(
          work: member,
          episodes: mRawEpisodes,
          variants: mRawVariants,
          repo: repo,
        );
        final mEpisodes = mReconciled.episodes;
        final mVariants = mReconciled.variants;
        final mEpById = {for (final e in mEpisodes) e.id: e};
        final mLabel = SeriesLabelPresets.formatDisambiguatedMemberLabel(
          member,
          seriesMembers,
          fallbackOrder: i + 1,
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

      cdList.sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
          b.relativePath.toLowerCase(),
        ),
      );
      scanList.sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
          b.relativePath.toLowerCase(),
        ),
      );

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

/// 外部播放器配置列表 Provider。
final externalPlayersProvider = FutureProvider<List<ExternalPlayerConfig>>((
  ref,
) {
  return ref.watch(libraryRepositoryProvider).getExternalPlayers();
});

/// 待复核抽屉展开状态 Provider。
final reviewDrawerOpenProvider = StateProvider<bool>((ref) => false);
