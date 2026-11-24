import 'package:engine_scraping/engine_scraping.dart';

import 'detail_edit_models.dart';

/// 系列编组配置与附属资源（特典 / CD / Scan）作用域持久化执行助手（零 Riverpod）。
abstract final class DetailWorkSeriesActionsHelper {
  /// 创建或更新系列编组、调整成员顺序/角色标签并人工锁定；返回受影响的全部作品 ID。
  static Future<Set<String>> saveSeriesGroupConfig({
    required LibraryRepository repository,
    String? seriesId,
    required String title,
    required List<SeriesMemberEdit> members,
    int? tmdbCollectionId,
  }) async {
    final allWorks = await repository.getAllWorks();
    final workById = <String, Work>{for (final w in allWorks) w.id: w};
    final affected = <String>{};
    final normalizedTitle = title.trim().isEmpty ? '未命名系列' : title.trim();

    final validMembers = [
      for (final m in members)
        if (workById.containsKey(m.workId)) m,
    ];
    final targetIds = validMembers.map((m) => m.workId).toSet();

    final resolvedSeriesId = (seriesId != null && seriesId.trim().isNotEmpty)
        ? seriesId.trim()
        : ScrapeWorkPersister.deterministicId(
            'manual_series::${validMembers.isNotEmpty ? validMembers.first.workId : DateTime.now().microsecondsSinceEpoch}',
          );

    final existingGroup = await repository.findSeriesGroupById(
      resolvedSeriesId,
    );
    for (final w in allWorks) {
      if (w.seriesId == resolvedSeriesId && !targetIds.contains(w.id)) {
        await repository.upsertWork(
          w.copyWith(clearSeries: true, seriesLocked: true),
        );
        affected.add(w.id);
      }
    }

    if (validMembers.isEmpty) {
      if (existingGroup != null) {
        await repository.deleteSeriesGroup(resolvedSeriesId);
      }
      return affected;
    }

    final now = DateTime.now();
    await repository.upsertSeriesGroup(
      SeriesGroup(
        id: resolvedSeriesId,
        title: normalizedTitle,
        tmdbCollectionId: tmdbCollectionId ?? existingGroup?.tmdbCollectionId,
        createdAt: existingGroup?.createdAt ?? now,
        updatedAt: now,
      ),
    );

    for (var i = 0; i < validMembers.length; i++) {
      final edit = validMembers[i];
      final current = workById[edit.workId]!;
      final previousSeriesId = current.seriesId;
      final cleanLabel = edit.label.trim().isEmpty
          ? current.title
          : edit.label.trim();
      await repository.upsertWork(
        current.copyWith(
          seriesId: resolvedSeriesId,
          seriesOrder: edit.order > 0 ? edit.order : (i + 1),
          seriesLabel: cleanLabel,
          seriesLocked: true,
        ),
      );
      affected.add(current.id);
      if (previousSeriesId != null &&
          previousSeriesId != resolvedSeriesId &&
          previousSeriesId.isNotEmpty) {
        final stillInOld = allWorks
            .where((w) => w.seriesId == previousSeriesId && w.id != current.id)
            .toList();
        if (stillInOld.isEmpty) {
          await repository.deleteSeriesGroup(previousSeriesId);
        } else {
          for (final sibling in stillInOld) {
            affected.add(sibling.id);
          }
        }
      }
    }

    for (final w in allWorks) {
      if (w.seriesId == resolvedSeriesId) {
        affected.add(w.id);
      }
    }
    return affected;
  }

  /// 保存附属资源（特典 / CD / Scan）的共享或单作独享作用域，并永久写入 `scopeLocked`。
  static Future<Set<String>> updateSupplementaryScopes({
    required LibraryRepository repository,
    required List<SupplementaryScopeEdit> edits,
  }) async {
    if (edits.isEmpty) return const <String>{};
    final editByVariantId = <String, SupplementaryScopeEdit>{
      for (final e in edits) e.variantId: e,
    };
    final allWorks = await repository.getAllWorks();
    final workById = <String, Work>{for (final w in allWorks) w.id: w};
    final affected = <String>{};
    final worksWithMovedEpisodes = <String>{};

    final variantLocations =
        <String, ({MediaVariant variant, Episode? episode})>{};
    for (final work in allWorks) {
      final variants = await repository.getVariantsByWork(work.id);
      if (!variants.any((v) => editByVariantId.containsKey(v.id))) continue;
      final eps = await repository.getEpisodesByWork(work.id);
      final epById = <String, Episode>{for (final e in eps) e.id: e};
      for (final v in variants) {
        if (editByVariantId.containsKey(v.id)) {
          variantLocations[v.id] = (
            variant: v,
            episode: v.episodeId != null ? epById[v.episodeId] : null,
          );
        }
      }
    }

    for (final edit in edits) {
      final loc = variantLocations[edit.variantId];
      if (loc == null) continue;
      final variant = loc.variant;
      final oldWorkId = variant.workId;
      final desiredWorkId =
          (edit.scope == SupplementaryAssetScope.workExclusive &&
              workById.containsKey(edit.targetWorkId))
          ? edit.targetWorkId
          : oldWorkId;

      String? resolvedEpisodeId = variant.episodeId;
      if (desiredWorkId != oldWorkId &&
          variant.assetKind == AssetKind.video &&
          loc.episode != null) {
        final oldEp = loc.episode!;
        final newEpId = ScrapeWorkPersister.deterministicId(
          '$desiredWorkId::scope_extra:${variant.id}',
        );
        await repository.upsertEpisode(
          Episode(
            id: newEpId,
            workId: desiredWorkId,
            seasonNumber: oldEp.seasonNumber,
            episodeNumber: oldEp.episodeNumber,
            category: oldEp.category,
            extraType: oldEp.extraType,
            title: oldEp.title,
            overview: oldEp.overview,
            stillPath: oldEp.stillPath,
          ),
        );
        resolvedEpisodeId = newEpId;
        worksWithMovedEpisodes.add(oldWorkId);
      }

      await repository.upsertMediaVariant(
        variant.copyWith(
          workId: desiredWorkId,
          episodeId: resolvedEpisodeId,
          assetScope: edit.scope,
          scopeLocked: true,
        ),
      );
      affected.add(oldWorkId);
      affected.add(desiredWorkId);

      final seriesId =
          workById[oldWorkId]?.seriesId ?? workById[desiredWorkId]?.seriesId;
      if (seriesId != null && seriesId.isNotEmpty) {
        for (final m in allWorks) {
          if (m.seriesId == seriesId) affected.add(m.id);
        }
      }
    }

    for (final wId in worksWithMovedEpisodes) {
      await repository.deleteOrphanEpisodes(wId);
    }
    return affected;
  }
}
