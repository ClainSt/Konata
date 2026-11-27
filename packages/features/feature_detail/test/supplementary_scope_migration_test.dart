import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'support/detail_test_fixtures.dart';

void main() {
  const sourceWork = 'season-one';
  const targetWork = 'season-two';
  const sourceEpisode = 'logical-sp';
  const firstVariant = 'sp-v1';
  const secondVariant = 'sp-v2';

  late DetailTestHarness harness;
  late WorkDetailController controller;

  setUp(() async {
    harness = await DetailTestHarness.create();
    final repository = harness.repository;
    await repository.upsertMediaSource(
      const MediaSource(
        id: 'fixture',
        kind: MediaSourceKind.local,
        label: '隔离夹具',
        location: 'D:/AuditOnly',
      ),
    );
    await repository.upsertSeriesGroup(
      SeriesGroup(
        id: 'fixture-series',
        title: '隔离系列',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
      ),
    );
    for (final id in [sourceWork, targetWork]) {
      final season = id == sourceWork ? 1 : 2;
      await repository.upsertWork(
        Work(
          id: id,
          title: id,
          seriesId: 'fixture-series',
          seriesOrder: season,
          tmdbId: 90001,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: season,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repository.upsertEpisode(
        Episode(
          id: id == sourceWork ? sourceEpisode : 'unrelated-sp',
          workId: id,
          seasonNumber: 0,
          episodeNumber: 1,
          category: EpisodeCategory.extra,
          extraType: ExtraKind.sp,
          title: 'SP 1',
          overview: '特典简介',
        ),
      );
    }
    for (final (id, owner, episode) in [
      (firstVariant, sourceWork, sourceEpisode),
      (secondVariant, sourceWork, sourceEpisode),
      ('unrelated-v1', targetWork, 'unrelated-sp'),
    ]) {
      await repository.upsertMediaVariant(
        MediaVariant(
          id: id,
          workId: owner,
          episodeId: episode,
          sourceId: 'fixture',
          relativePath: '$owner/$id.mkv',
          fileName: '$id.mkv',
          fileSize: 1024,
          assetScope: SupplementaryAssetScope.seriesShared,
        ),
      );
    }
    controller = harness.createController(const WorkId.trusted(sourceWork));
  });

  Future<void> moveToTarget(List<String> ids) =>
      controller.updateSupplementaryScopes([
        for (final id in ids)
          SupplementaryScopeEdit(
            variantId: id,
            scope: SupplementaryAssetScope.workExclusive,
            targetWorkId: targetWork,
          ),
      ]);

  Future<String> expectGroupedAtTarget({String overview = '特典简介'}) async {
    final repository = harness.repository;
    final variants = await repository.getVariantsByWork(targetWork);
    final byId = {for (final variant in variants) variant.id: variant};
    final movedEpisodeId = byId[firstVariant]!.episodeId;
    expect(movedEpisodeId, isNotNull);
    expect(byId[secondVariant]!.episodeId, movedEpisodeId);
    expect(byId['unrelated-v1']!.episodeId, 'unrelated-sp');
    expect(movedEpisodeId, isNot('unrelated-sp'));
    for (final id in [firstVariant, secondVariant]) {
      expect(byId[id]!.relativePath, '$sourceWork/$id.mkv');
      expect(byId[id]!.assetScope, SupplementaryAssetScope.workExclusive);
      expect(byId[id]!.scopeLocked, isTrue);
    }

    final episodes = await repository.getEpisodesByWork(targetWork);
    expect(
      episodes.map((episode) => episode.id),
      unorderedEquals(['unrelated-sp', movedEpisodeId]),
    );
    expect(
      episodes.singleWhere((episode) => episode.id == movedEpisodeId).overview,
      overview,
    );
    expect(await repository.getEpisodesByWork(sourceWork), isEmpty);
    expect(await repository.getVariantsByWork(sourceWork), isEmpty);
    return movedEpisodeId!;
  }

  test('同批迁移的双版本特典共用目标分集，同名同编号特典仍独立', () async {
    await moveToTarget([firstVariant, secondVariant]);
    final movedEpisodeId = await expectGroupedAtTarget();
    expect(controller.bundle!.variantsForEpisode(movedEpisodeId), isEmpty);

    await controller.updateSupplementaryScopes([
      for (final id in [firstVariant, secondVariant])
        SupplementaryScopeEdit(
          variantId: id,
          scope: SupplementaryAssetScope.seriesShared,
          targetWorkId: sourceWork,
        ),
    ]);
    final sharedVariants = controller.bundle!.variantsForEpisode(
      movedEpisodeId,
    );
    expect(
      sharedVariants.map((variant) => variant.id),
      unorderedEquals([firstVariant, secondVariant]),
    );
    expect(
      sharedVariants.map((variant) => variant.workId),
      everyElement(targetWork),
    );
  });

  test('分两次移入的版本复用由原分集生成的目标分集', () async {
    await moveToTarget([firstVariant]);
    final kept = await harness.repository.getVariantsByWork(sourceWork);
    expect(kept.single.id, secondVariant);
    expect(kept.single.episodeId, sourceEpisode);
    expect(
      (await harness.repository.getEpisodesByWork(sourceWork)).single.id,
      sourceEpisode,
    );
    final repository = harness.repository;
    final moved = (await repository.getVariantsByWork(
      targetWork,
    )).singleWhere((variant) => variant.id == firstVariant);
    final movedEpisode = (await repository.getEpisodesByWork(
      targetWork,
    )).singleWhere((episode) => episode.id == moved.episodeId);
    await repository.upsertEpisode(movedEpisode.copyWith(overview: '目标侧简介'));
    await moveToTarget([secondVariant]);
    await expectGroupedAtTarget(overview: '目标侧简介');
  });

  test('第二个版本写入失败时回滚本批迁移和新建分集', () async {
    harness.databases.library.engine.execute("""
CREATE TRIGGER fail_second_scope_edit BEFORE UPDATE ON media_variants
WHEN NEW.id = 'sp-v2' AND NEW.work_id = 'season-two'
BEGIN SELECT RAISE(ABORT, 'audit second scope edit'); END;
""");
    await expectLater(
      moveToTarget([firstVariant, secondVariant]),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('audit second scope edit'),
        ),
      ),
    );
    final source = await harness.repository.getVariantsByWork(sourceWork);
    expect(
      source.map((variant) => variant.id),
      unorderedEquals([firstVariant, secondVariant]),
    );
    expect(
      source.map((variant) => variant.episodeId),
      everyElement(sourceEpisode),
    );
    expect(source.map((variant) => variant.scopeLocked), everyElement(isFalse));
    final target = await harness.repository.getEpisodesByWork(targetWork);
    expect(target.single.id, 'unrelated-sp');

    harness.databases.library.engine.execute(
      'DROP TRIGGER fail_second_scope_edit;',
    );
    await moveToTarget([firstVariant, secondVariant]);
    await expectGroupedAtTarget();
  });
}
