import 'dart:async';
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

void main() {
  group('library.db 全部 6 个 DAO（:memory:）', () {
    late LibraryDatabase db;

    setUp(() {
      db = LibraryDatabase.openInMemory();
    });

    tearDown(() async {
      await db.close();
    });

    test('MediaSourceDao 支持增删改、响应式监听与软删除墓碑', () async {
      final emitted = <int>[];
      final sub = db.mediaSources.watchAll().listen((rows) {
        emitted.add(rows.length);
      });
      addTearDown(sub.cancel);

      await Future<void>.delayed(Duration.zero);
      expect(emitted, equals(<int>[0]));

      final srcId = SourceId('src-local-1');
      db.mediaSources.upsert(
        MediaSourceRecord(
          id: srcId,
          canonicalKey: 'local::anime',
          kind: MediaSourceKind.local,
          label: '本地番剧库',
          location: r'D:\Anime',
          createdAtMs: 100,
          updatedAtMs: 100,
          sourceDeviceId: 'win-dev',
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(emitted, equals(<int>[0, 1]));
      expect(db.mediaSources.findById(srcId)?.label, '本地番剧库');

      db.mediaSources.softDelete(
        srcId,
        deletedAtMs: 200,
        sourceDeviceId: 'win-dev',
      );

      await Future<void>.delayed(Duration.zero);
      expect(emitted, equals(<int>[0, 1, 0]));
      expect(db.mediaSources.findById(srcId), isNull);
      final tombstone = db.mediaSources.findById(srcId, includeDeleted: true);
      expect(tombstone?.isDeleted, isTrue);
      expect(tombstone?.deletedAtMs, 200);
    });

    test('SeriesGroupDao 与 WorkDao 支持 ArtworkRef 编解码与软删除墓碑', () async {
      final seriesId = SeriesGroupId('ser-k-on');
      db.seriesGroups.upsert(
        SeriesGroupRecord(
          id: seriesId,
          canonicalKey: 'tmdb:col:888',
          title: '轻音少女系列',
          tmdbCollectionId: 888,
          createdAtMs: 100,
          updatedAtMs: 100,
          sourceDeviceId: 'win-dev',
        ),
      );
      expect(db.seriesGroups.findById(seriesId)?.title, '轻音少女系列');

      final visibleCounts = <int>[];
      final sub = db.works.watchVisible().listen((rows) {
        visibleCounts.add(rows.length);
      });
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      final workId = WorkId('work-k-on-s1');
      db.works.upsert(
        WorkRecord(
          id: workId,
          canonicalKey: 'tmdb:tv:31910:s1',
          tmdbId: 31910,
          tmdbMediaType: TmdbMediaType.tv,
          bangumiId: 1424,
          matchedSeason: 1,
          title: '轻音少女',
          originalTitle: 'けいおん！',
          year: 2009,
          posterRef: const ArtworkRef.remote(
            source: ArtworkSource.tmdb,
            uri: '/poster.jpg',
            locked: true,
          ),
          backdropRef: const ArtworkRef.localCustom(
            localPath: 'photos/k_on_bg.png',
          ),
          portraitBackdropRef: const ArtworkRef.remote(
            source: ArtworkSource.tmdb,
            uri: '/portrait_textless.jpg',
            locked: true,
          ),
          logoRef: const ArtworkRef.remote(
            source: ArtworkSource.fanart,
            uri: 'https://assets.fanart.tv/k_on_logo.png',
          ),
          scrapeStatus: ScrapeStatus.matched,
          seriesId: seriesId,
          seriesOrder: 1,
          seriesLabel: '第 1 季',
          updatedAtMs: 1000,
          sourceDeviceId: 'win-dev',
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(visibleCounts, equals(<int>[0, 1]));

      final loaded = db.works.findByCanonicalKey('tmdb:tv:31910:s1');
      expect(loaded, isNotNull);
      expect(loaded!.posterRef, isA<RemoteArtworkRef>());
      expect((loaded.posterRef! as RemoteArtworkRef).locked, isTrue);
      expect(loaded.backdropRef, isA<LocalCustomArtworkRef>());
      expect(loaded.backdropRef!.toSyncJson(), isNull);
      expect(loaded.portraitBackdropRef, isA<RemoteArtworkRef>());
      expect(
        (loaded.portraitBackdropRef! as RemoteArtworkRef).uri,
        '/portrait_textless.jpg',
      );
      expect(
        loaded.toSummaryView().portraitBackdropRef,
        loaded.portraitBackdropRef,
      );
      expect(loaded.seriesId?.value, seriesId.value);

      // 软删除后可见视图过滤，但全量墓碑查询仍保留。
      db.works.softDelete(workId, deletedAtMs: 2000, sourceDeviceId: 'win-dev');
      await Future<void>.delayed(Duration.zero);
      expect(visibleCounts, equals(<int>[0, 1, 0]));
      expect(db.works.listVisible(), isEmpty);
      expect(db.works.listAllWithTombstones().single.deletedAtMs, 2000);
    });

    test('EpisodeDao、MediaVariantDao、IgnoredFolderDao 与外键级联删除正常', () async {
      final srcId = SourceId('src-1');
      final workId = WorkId('work-1');
      final epId = EpisodeId('ep-1');
      final varId = VariantId('var-1');

      db.mediaSources.upsert(
        MediaSourceRecord(
          id: srcId,
          kind: MediaSourceKind.webdav,
          label: 'NAS WebDAV',
          location: 'https://nas.local/anime',
        ),
      );
      db.works.upsert(WorkRecord(id: workId, title: '冰菓'));
      db.episodes.upsert(
        EpisodeRecord(
          id: epId,
          canonicalKey: 'work-1::s1::e1',
          workId: workId,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '传统古典部的再生',
          updatedAtMs: 500,
        ),
      );
      db.mediaVariants.upsert(
        MediaVariantRecord(
          id: varId,
          workId: workId,
          episodeId: epId,
          sourceId: srcId,
          relativePath: 'Hyouka/[VCB-Studio] Hyouka [01].mkv',
          fileName: '[VCB-Studio] Hyouka [01].mkv',
          fileSize: 1024 * 1024 * 800,
          releaseGroup: 'VCB-Studio',
          videoCodec: 'HEVC',
          bitDepth: '10bit',
          externalSubtitles: const <String>['Hyouka/01.sc.ass'],
          mappingLocked: true,
          updatedAtMs: 500,
        ),
      );
      db.ignoredFolders.upsert(
        IgnoredFolderRecord(
          id: 'src-1::TempFolder',
          sourceId: srcId,
          relativePath: 'TempFolder',
          createdAtMs: 500,
          updatedAtMs: 500,
        ),
      );

      // 验证只读端口投影正常。
      final readPort = db.createReadPort();
      expect((await readPort.findWorkSummary(workId))?.title, '冰菓');
      expect((await readPort.listEpisodesForWork(workId)), hasLength(1));
      expect((await readPort.listMediaSources()).single.id, srcId);

      // 校验外挂字幕 JSON 与锁定态读写一致。
      final variant = db.mediaVariants.listByWork(workId).single;
      expect(variant.externalSubtitles, equals(<String>['Hyouka/01.sc.ass']));
      expect(variant.mappingLocked, isTrue);

      // 校验忽略目录软删除。
      expect(db.ignoredFolders.listBySource(srcId), hasLength(1));
      db.ignoredFolders.softDelete('src-1::TempFolder', deletedAtMs: 600);
      expect(db.ignoredFolders.listBySource(srcId), isEmpty);

      // 物理删除作品后，episodes 与 media_variants 应通过外键自动级联清理。
      db.works.hardDelete(workId);
      expect(db.episodes.listByWork(workId, includeDeleted: true), isEmpty);
      expect(
        db.mediaVariants.listByWork(workId, includeDeleted: true),
        isEmpty,
      );
    });

    test('作品墓碑原子收敛有效子关系，保留既有墓碑和其他作品', () {
      final source = SourceId('remove-source');
      final work = WorkId('remove-work');
      final sibling = WorkId('keep-work');
      final series = SeriesGroupId('remove-series');
      final ep = EpisodeId('remove-episode');
      final keepEp = EpisodeId('keep-episode');
      final oldEp = EpisodeId('old-episode');
      final variant = VariantId('remove-variant');
      final keepVariant = VariantId('keep-variant');
      db.mediaSources.upsert(
        MediaSourceRecord(
          id: source,
          kind: MediaSourceKind.local,
          label: '测试',
          location: 'D:/readonly',
        ),
      );
      db.seriesGroups.upsert(SeriesGroupRecord(id: series, title: '系列'));
      db.works.upsert(WorkRecord(id: work, title: '移除', seriesId: series));
      db.works.upsert(WorkRecord(id: sibling, title: '保留', seriesId: series));
      db.episodes.upsert(
        EpisodeRecord(id: ep, workId: work, seasonNumber: 1, updatedAtMs: 800),
      );
      db.episodes.upsert(
        EpisodeRecord(
          id: keepEp,
          workId: sibling,
          seasonNumber: 1,
          updatedAtMs: 800,
        ),
      );
      db.episodes.upsert(
        EpisodeRecord(
          id: oldEp,
          workId: work,
          seasonNumber: 1,
          deletedAtMs: 500,
          updatedAtMs: 500,
          sourceDeviceId: 'old',
        ),
      );
      db.mediaVariants.upsert(
        MediaVariantRecord(
          id: variant,
          workId: work,
          episodeId: ep,
          sourceId: source,
          relativePath: 'A/01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
          updatedAtMs: 2500,
        ),
      );
      db.mediaVariants.upsert(
        MediaVariantRecord(
          id: keepVariant,
          workId: sibling,
          episodeId: keepEp,
          sourceId: source,
          relativePath: 'B/01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
          updatedAtMs: 900,
        ),
      );
      db.works.softDelete(work, deletedAtMs: 2000, sourceDeviceId: 'win');
      expect(db.works.findById(work), isNull);
      expect(db.works.findById(work, includeDeleted: true)?.deletedAtMs, 2000);
      expect(db.episodes.listByWork(work), isEmpty);
      expect(db.mediaVariants.listByWork(work), isEmpty);
      expect(db.mediaVariants.listBySource(source).single.id, keepVariant);
      expect(db.works.listBySeries(series).single.id, sibling);
      expect(
        db.episodes
            .listByWork(work, includeDeleted: true)
            .firstWhere((e) => e.id == oldEp)
            .deletedAtMs,
        500,
      );
      expect(
        db.mediaVariants.findById(variant, includeDeleted: true)?.deletedAtMs,
        2500,
      );
      expect(
        db.mediaVariants.findById(variant, includeDeleted: true)?.relativePath,
        'A/01.mkv',
      );
      db.works.softDelete(work, deletedAtMs: 3000, sourceDeviceId: 'other');
      expect(db.works.findById(work, includeDeleted: true)?.deletedAtMs, 2000);
      expect(
        db.mediaVariants.findById(variant, includeDeleted: true)?.deletedAtMs,
        2500,
      );
      expect(db.mediaVariants.findById(keepVariant), isNotNull);
    });
    test('历史 v3 隐藏标记原位迁移，完整保留作品关系及墓碑', () async {
      final root = Directory.systemTemp.createTempSync(
        'konata_work_migration_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final path = '${root.path}/library.db';
      final old = LibraryDatabase.openFile(path);
      old.seriesGroups.upsert(
        const SeriesGroupRecord(
          id: SeriesGroupId.trusted('series-1'),
          title: '系列',
        ),
      );
      old.mediaSources.upsert(
        const MediaSourceRecord(
          id: SourceId.trusted('source-1'),
          kind: MediaSourceKind.local,
          label: '测试源',
          location: 'D:/test',
        ),
      );
      old.works.upsert(
        const WorkRecord(
          id: WorkId.trusted('work-1'),
          title: '历史收藏',
          seriesId: SeriesGroupId.trusted('series-1'),
          scrapeStatus: ScrapeStatus.matched,
          metadataLocked: true,
          updatedAtMs: 100,
        ),
      );
      old.works.upsert(
        const WorkRecord(
          id: WorkId.trusted('work-2'),
          title: '待复核收藏',
          scrapeStatus: ScrapeStatus.needsReview,
        ),
      );
      old.works.upsert(
        const WorkRecord(
          id: WorkId.trusted('work-3'),
          title: '已删除收藏',
          deletedAtMs: 200,
        ),
      );
      old.episodes.upsert(
        const EpisodeRecord(
          id: EpisodeId.trusted('episode-1'),
          workId: WorkId.trusted('work-1'),
          seasonNumber: 1,
          episodeNumber: 1,
        ),
      );
      old.mediaVariants.upsert(
        const MediaVariantRecord(
          id: VariantId.trusted('variant-1'),
          workId: WorkId.trusted('work-1'),
          episodeId: EpisodeId.trusted('episode-1'),
          sourceId: SourceId.trusted('source-1'),
          relativePath: 'Test/01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
          mappingLocked: true,
        ),
      );
      old.engine.execute('DROP INDEX idx_works_visible;');
      old.engine.execute(
        'ALTER TABLE works ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0;',
      );
      old.engine.execute(
        'ALTER TABLE works ADD COLUMN keep_hidden INTEGER NOT NULL DEFAULT 0;',
      );
      old.engine.execute(
        'CREATE INDEX idx_works_visible ON works (deleted_at_ms, is_hidden);',
      );
      old.engine.execute('UPDATE works SET is_hidden = 1, keep_hidden = 1;');
      old.engine.execute('PRAGMA user_version = 3;');
      await old.close();

      final migrated = LibraryDatabase.openFile(path);
      addTearDown(migrated.close);
      expect(
        migrated.engine.select('PRAGMA user_version;').single.values.first,
        4,
      );
      expect(
        migrated.works.listVisibleIdsInInsertionOrder().map((id) => id.value),
        ['work-1', 'work-2'],
      );
      expect(migrated.works.listNeedsReview().single.id.value, 'work-2');
      expect(
        migrated.works
            .listBySeries(const SeriesGroupId.trusted('series-1'))
            .single
            .id
            .value,
        'work-1',
      );
      final work = migrated.works.findById(const WorkId.trusted('work-1'))!;
      expect(work.metadataLocked, isTrue);
      expect(work.updatedAtMs, 100);
      expect(migrated.works.findById(const WorkId.trusted('work-3')), isNull);
      expect(
        migrated.works
            .findById(const WorkId.trusted('work-3'), includeDeleted: true)
            ?.deletedAtMs,
        200,
      );
      expect(
        migrated.episodes.listByWork(work.id).single.id.value,
        'episode-1',
      );
      final variant = migrated.mediaVariants.listByWork(work.id).single;
      expect(variant.episodeId?.value, 'episode-1');
      expect(variant.mappingLocked, isTrue);
      expect(variant.relativePath, 'Test/01.mkv');
      expect(migrated.engine.select('PRAGMA foreign_key_check;'), isEmpty);
      final columns = migrated.engine
          .select('PRAGMA table_info(works);')
          .map((row) => row['name']);
      expect(columns, isNot(contains('is_hidden')));
      expect(columns, isNot(contains('keep_hidden')));
      final indexColumns = migrated.engine
          .select('PRAGMA index_info(idx_works_visible);')
          .map((row) => row['name']);
      expect(indexColumns, ['deleted_at_ms']);
    });
    test('library.db 支持从 v1 增量迁移至 v2 并补齐 portrait_backdrop_ref_json 列', () async {
      final tempDir = Directory.systemTemp.createTempSync('konata_lib_v1_v2_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final dbPath = '${tempDir.path}${Platform.pathSeparator}library.db';

      final v1Steps = LibraryMigrations.steps
          .where((step) => step.targetVersion == 1)
          .toList(growable: false);
      final v1Engine = KonataSqliteEngine.openFile(
        filePath: dbPath,
        databaseName: 'library_v1_upgrade',
        migrations: v1Steps,
      );

      // 模拟旧版 v1 works 表（不含 portrait_backdrop_ref_json 列）并写入历史作品行。
      v1Engine.execute('PRAGMA foreign_keys = OFF;');
      v1Engine.execute('DROP TABLE ${WorksSchema.table};');
      v1Engine.execute('''
CREATE TABLE ${WorksSchema.table} (
  ${WorksSchema.colId} TEXT NOT NULL PRIMARY KEY,
  ${WorksSchema.colCanonicalKey} TEXT,
  ${WorksSchema.colTmdbId} INTEGER,
  ${WorksSchema.colTmdbMediaType} TEXT,
  ${WorksSchema.colBangumiId} INTEGER,
  ${WorksSchema.colTvdbId} INTEGER,
  ${WorksSchema.colMatchedSeason} INTEGER,
  ${WorksSchema.colTitle} TEXT NOT NULL,
  ${WorksSchema.colOriginalTitle} TEXT,
  ${WorksSchema.colYear} INTEGER,
  ${WorksSchema.colOverview} TEXT,
  ${WorksSchema.colPosterRefJson} TEXT,
  ${WorksSchema.colPosterFallback} TEXT,
  ${WorksSchema.colBangumiPosterPath} TEXT,
  ${WorksSchema.colBackdropRefJson} TEXT,
  ${WorksSchema.colLogoRefJson} TEXT,
  ${WorksSchema.colVoteAverage} REAL,
  ${WorksSchema.colBangumiScore} REAL,
  ${WorksSchema.colFolderTmdbHint} INTEGER,
  ${WorksSchema.colIsManualLocked} INTEGER NOT NULL DEFAULT 0,
  ${WorksSchema.colMetadataLocked} INTEGER NOT NULL DEFAULT 0,
  is_hidden INTEGER NOT NULL DEFAULT 0,
  keep_hidden INTEGER NOT NULL DEFAULT 0,
  ${WorksSchema.colScrapeStatus} TEXT NOT NULL DEFAULT 'unmatched',
  ${WorksSchema.colReviewReason} TEXT,
  ${WorksSchema.colSeriesId} TEXT,
  ${WorksSchema.colSeriesOrder} INTEGER,
  ${WorksSchema.colSeriesLabel} TEXT,
  ${WorksSchema.colSeriesLocked} INTEGER NOT NULL DEFAULT 0,
  ${WorksSchema.colUpdatedAtMs} INTEGER NOT NULL DEFAULT 0,
  ${WorksSchema.colSourceDeviceId} TEXT NOT NULL DEFAULT '',
  ${WorksSchema.colDeletedAtMs} INTEGER
);
''');
      v1Engine.execute(
        "INSERT INTO ${WorksSchema.table} (${WorksSchema.colId}, ${WorksSchema.colTitle}, is_hidden, keep_hidden) VALUES ('legacy-1', '旧版作品', 1, 1);",
      );
      v1Engine.execute('PRAGMA user_version = 1;');
      await v1Engine.close();

      // 重新以生产路径打开 library.db，自动触发 v1 -> v2 增量迁移。
      final upgradedDb = LibraryDatabase.openFile(dbPath);
      addTearDown(upgradedDb.close);

      final versionRows = upgradedDb.engine.select('PRAGMA user_version;');
      expect(versionRows.single.values.first, LibraryMigrations.currentVersion);

      final legacy = upgradedDb.works.findById(
        const WorkId.trusted('legacy-1'),
      );
      expect(legacy, isNotNull);
      expect(legacy!.title, '旧版作品');
      expect(upgradedDb.works.listVisible().single.id.value, 'legacy-1');
      final columnNames = upgradedDb.engine
          .select('PRAGMA table_info(works);')
          .map((row) => row['name']);
      expect(columnNames, isNot(contains('is_hidden')));
      expect(columnNames, isNot(contains('keep_hidden')));
      expect(legacy.portraitBackdropRef, isNull);

      upgradedDb.works.upsert(
        const WorkRecord(
          id: WorkId.trusted('legacy-1'),
          title: '旧版作品',
          portraitBackdropRef: ArtworkRef.remote(
            source: ArtworkSource.tmdb,
            uri: '/v2_portrait.jpg',
          ),
        ),
      );
      final updated = upgradedDb.works.findById(
        const WorkId.trusted('legacy-1'),
      );
      expect(
        updated?.portraitBackdropRef,
        const ArtworkRef.remote(
          source: ArtworkSource.tmdb,
          uri: '/v2_portrait.jpg',
        ),
      );
    });
  });
}
