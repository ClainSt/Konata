import 'dart:developer' as developer;

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';

import '../data/detail_edit_models.dart';
import '../data/detail_work_actions.dart';
import 'detail_supplementary_view_data.dart';

/// 作品详情页聚合数据包与扩展贡献点动态解析加载器（零 Riverpod）。
abstract final class DetailBundleLoader {
  /// 加载并构建指定作品的完整 [WorkDetailBundle]。
  static Future<WorkDetailBundle?> loadBundle({
    required WorkId workId,
    required LibraryRepository repository,
    required KonataPlatform platform,
    required List<DetailTabContribution> detailTabs,
    required List<DetailActionContribution> detailActions,
    required bool Function() isCancelled,
  }) async {
    final work = await repository.findWorkById(workId.value);
    if (isCancelled() || work == null) return null;

    final hasSeries = work.seriesId != null && work.seriesId!.isNotEmpty;
    final coreResults = await Future.wait<Object?>([
      repository.getEpisodesByWork(work.id),
      repository.getVariantsByWork(work.id),
      repository.getMediaSources(),
      repository.getPlaybacksByWork(work.id),
      repository.getScrapeCandidates(work.id),
      if (hasSeries) repository.findSeriesGroupById(work.seriesId!),
      if (hasSeries) repository.getWorksBySeries(work.seriesId!),
    ]);
    if (isCancelled()) return null;

    final episodes = Episode.sortMainFirst(coreResults[0]! as List<Episode>);
    final variants = coreResults[1]! as List<MediaVariant>;
    final sources = coreResults[2]! as List<MediaSource>;
    final allPlaybacks = coreResults[3]! as List<PlaybackRecord>;
    final candidates = coreResults[4]! as List<ScrapeCandidateSummary>;
    final seriesGroup = hasSeries ? coreResults[5] as SeriesGroup? : null;
    final rawSeriesWorks = hasSeries
        ? coreResults[6]! as List<Work>
        : const <Work>[];

    PlaybackRecord? latestPlayback;
    final playbackByEpisodeId = <String, PlaybackRecord>{};
    for (final record in allPlaybacks) {
      if (latestPlayback == null && !record.episodeId.startsWith('cd::')) {
        latestPlayback = record;
      }
      playbackByEpisodeId.putIfAbsent(record.episodeId, () => record);
    }
    final sourcesById = <String, MediaSource>{for (final s in sources) s.id: s};
    final seriesMembers = hasSeries
        ? SeriesSeasonFormatter.sortSeriesMembers(rawSeriesWorks)
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
    final workEpById = <String, Episode>{for (final e in episodes) e.id: e};
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
            ownerWorkTitle: selfLabel,
          ),
    ];

    final otherMembers = <({int index, Work work})>[];
    for (var i = 0; i < seriesMembers.length; i++) {
      final member = seriesMembers[i];
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
        repository.getEpisodesByWorkIds(otherIds),
        repository.getVariantsByWorkIds(otherIds),
      ]);
      if (isCancelled()) return null;
      final batchEpisodes = batchResults[0] as List<Episode>;
      final batchVariants = batchResults[1] as List<MediaVariant>;
      final episodesByMemberId = <String, List<Episode>>{};
      for (final ep in batchEpisodes) {
        episodesByMemberId.putIfAbsent(ep.workId, () => <Episode>[]).add(ep);
      }
      final variantsByMemberId = <String, List<MediaVariant>>{};
      for (final v in batchVariants) {
        variantsByMemberId.putIfAbsent(v.workId, () => <MediaVariant>[]).add(v);
      }

      for (final entry in otherMembers) {
        final member = entry.work;
        final mEpisodes = Episode.sortMainFirst(
          episodesByMemberId[member.id] ?? const <Episode>[],
        );
        final mVariants =
            variantsByMemberId[member.id] ?? const <MediaVariant>[];
        final mEpById = <String, Episode>{for (final e in mEpisodes) e.id: e};
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
              ownerWorkTitle: mLabel,
            ),
          );
          if (mv.assetScope != SupplementaryAssetScope.seriesShared) {
            continue;
          }
          final pathKey = '${mv.sourceId}::${mv.relativePath.toLowerCase()}';
          if (!seenVariantPaths.add(pathKey)) continue;
          if (mv.assetKind == AssetKind.cdAlbum) {
            cdList.add(mv);
          } else if (mv.assetKind == AssetKind.video && ep != null) {
            mergedVariants.add(mv);
            if (mergedEpisodeIds.add(ep.id)) {
              mergedEpisodes.add(ep);
            }
          }
        }
      }
    }

    // 共享卡片按逻辑分集归属读取历史；其他季度的正片、独享资源与 CD 不参与当前续播。
    final sharedEpisodeOwners = <String, String>{
      for (final ep in mergedEpisodes)
        if (ep.workId != work.id && ep.category == EpisodeCategory.extra)
          ep.id: ep.workId,
    };
    if (sharedEpisodeOwners.isNotEmpty) {
      final ownerIds = sharedEpisodeOwners.values.toSet().toList();
      final histories = await Future.wait(
        ownerIds.map(repository.getPlaybacksByWork),
      );
      if (isCancelled()) return null;
      // 旧错误归属记录不能遮蔽资源所属作品的实际进度。
      for (final id in sharedEpisodeOwners.keys) {
        playbackByEpisodeId.remove(id);
      }
      for (var i = 0; i < ownerIds.length; i++) {
        for (final record in histories[i]) {
          if (!record.isAudioRecord &&
              record.workId == ownerIds[i] &&
              sharedEpisodeOwners[record.episodeId] == record.workId) {
            playbackByEpisodeId.putIfAbsent(record.episodeId, () => record);
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

    final sortedMergedEpisodes = Episode.sortMainFirst(mergedEpisodes);
    final variantsByEpisodeId = <String, List<MediaVariant>>{};
    for (final v in mergedVariants) {
      final epId = v.episodeId;
      if (epId != null) {
        variantsByEpisodeId.putIfAbsent(epId, () => <MediaVariant>[]).add(v);
      }
    }

    final resolvedTabs = await resolveVisibleTabs(
      workId: workId,
      platform: platform,
      detailTabs: detailTabs,
    );
    final resolvedActions = await resolveAvailableActions(
      workId: workId,
      platform: platform,
      detailActions: detailActions,
    );
    if (isCancelled()) return null;

    final resumePlan = PlaybackResumeResolver.resolve(
      episodes: [
        for (final ep in sortedMergedEpisodes)
          DetailSupplementaryHelper.toEpisodeSummaryView(ep),
      ],
      latestPlayback: latestPlayback == null
          ? null
          : DetailSupplementaryHelper.toPlaybackResumeView(latestPlayback),
      playbackByEpisodeId: <EpisodeId, PlaybackResumeView>{
        for (final entry in playbackByEpisodeId.entries)
          EpisodeId.trusted(entry.key):
              DetailSupplementaryHelper.toPlaybackResumeView(entry.value),
      },
      workTitle: work.title,
      workMediaType: work.tmdbMediaType,
    );

    final folderPath = variants.isEmpty
        ? null
        : DetailWorkActionsService.deriveFolderPath(
            variants.first.relativePath,
          );

    return WorkDetailBundle(
      work: work,
      episodes: sortedMergedEpisodes,
      variants: mergedVariants,
      sourcesById: sourcesById,
      latestPlayback: latestPlayback,
      playbackByEpisodeId: playbackByEpisodeId,
      seriesGroup: seriesGroup,
      seriesMembers: seriesMembers,
      cdVariants: cdList,
      editableSupplementaryItems: editableItems,
      variantsByEpisodeId: variantsByEpisodeId,
      scrapeCandidates: candidates,
      folderPath: (folderPath != null && folderPath.isNotEmpty)
          ? folderPath
          : null,
      visibleTabs: resolvedTabs,
      primaryBarActions: resolvedActions.primaryBar,
      gearMenuActions: resolvedActions.gearMenu,
      resumePlan: resumePlan,
    );
  }

  /// 过滤并返回当前作品及运行平台支持展示的外部扩展标签页贡献列表。
  static Future<List<DetailTabContribution>> resolveVisibleTabs({
    required WorkId workId,
    required KonataPlatform platform,
    required List<DetailTabContribution> detailTabs,
  }) async {
    final visible = <DetailTabContribution>[];
    for (final tab in detailTabs) {
      if (!tab.isSupportedOn(platform)) continue;
      var show = true;
      final checker = tab.isVisibleForWork;
      if (checker != null) {
        try {
          show = await checker(workId);
        } catch (error) {
          developer.log(
            '评估详情页扩展标签可见性失败: ${tab.id}',
            name: 'konata.detail_bundle_loader',
            error: error,
          );
          show = false;
        }
      }
      if (show) visible.add(tab);
    }
    visible.sort((a, b) => a.order.compareTo(b.order));
    return List<DetailTabContribution>.unmodifiable(visible);
  }

  /// 过滤并返回当前作品及运行平台可用的外部扩展动作列表。
  static Future<
    ({
      List<DetailActionContribution> primaryBar,
      List<DetailActionContribution> gearMenu,
    })
  >
  resolveAvailableActions({
    required WorkId workId,
    required KonataPlatform platform,
    required List<DetailActionContribution> detailActions,
  }) async {
    final primaryBar = <DetailActionContribution>[];
    final gearMenu = <DetailActionContribution>[];
    for (final action in detailActions) {
      if (!action.isSupportedOn(platform)) continue;
      var enabled = true;
      final checker = action.isEnabledForWork;
      if (checker != null) {
        try {
          enabled = await checker(workId);
        } catch (error) {
          developer.log(
            '评估详情页扩展动作可用性失败: ${action.id}',
            name: 'konata.detail_bundle_loader',
            error: error,
          );
          enabled = false;
        }
      }
      if (!enabled) continue;
      switch (action.placement) {
        case DetailActionPlacement.primaryBar:
          primaryBar.add(action);
        case DetailActionPlacement.gearMenu:
          gearMenu.add(action);
      }
    }
    primaryBar.sort((a, b) => a.order.compareTo(b.order));
    gearMenu.sort((a, b) => a.order.compareTo(b.order));
    return (
      primaryBar: List<DetailActionContribution>.unmodifiable(primaryBar),
      gearMenu: List<DetailActionContribution>.unmodifiable(gearMenu),
    );
  }
}
