import 'dart:async';
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

void main() {
  group('user_state.db 全部 5 个 DAO 与 ScopedPrefsStore（:memory:）', () {
    late UserStateDatabase db;

    setUp(() {
      db = UserStateDatabase.openInMemory();
    });

    tearDown(() async {
      await db.close();
    });

    test('PlaybackRecordDao 支持续播查询、响应式时间轴、软删除与只读端口', () async {
      final counts = <int>[];
      final sub = db.playbackRecords.watchRecent().listen((rows) {
        counts.add(rows.length);
      });
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      final workId = WorkId('w-1');
      final epId = EpisodeId('ep-1');
      final varId = VariantId('var-1');
      db.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: 'rec-1',
          canonicalKey: 'tmdb:tv:1:s1:e1',
          workId: workId,
          episodeId: epId,
          variantId: varId,
          playedAtMs: 1000,
          positionSeconds: 420,
          durationSeconds: 1440,
          updatedAtMs: 1000,
          sourceDeviceId: 'win-1',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(counts, equals(<int>[0, 1]));

      final readPort = db.createPlaybackReadPort();
      final resume = await readPort.findLatestForWork(workId);
      expect(resume?.positionSeconds, 420);
      expect(resume?.completed, isFalse);

      db.playbackRecords.softDelete(
        'rec-1',
        deletedAtMs: 2000,
        sourceDeviceId: 'win-1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(counts, equals(<int>[0, 1, 0]));
      expect(await readPort.findLatestForEpisode(epId), isNull);
    });

    test('ScopedPrefsStore 严格隔离 portable 与 deviceLocal 配置切片并支持合并', () async {
      final store = ScopedPrefsStore(db, nowMs: () => 5000);

      final portableSlice = TypedPrefsSlice<int>(
        namespace: 'feature_library.grid_columns',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: 5,
        encode: (value) => <String, Object?>{'columns': value},
        decode: (json, _) => json['columns'] as int? ?? 5,
      );
      final localSlice = TypedPrefsSlice<String>(
        namespace: 'feature_player_video.desktop_hwdec',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.deviceLocal,
        defaultValue: 'd3d11va',
        encode: (value) => <String, Object?>{'hwdec': value},
        decode: (json, _) => json['hwdec'] as String? ?? 'd3d11va',
      );

      final watchedCols = <int>[];
      final sub = store.watch(portableSlice).listen(watchedCols.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(watchedCols, equals(<int>[5]));

      store.write(portableSlice, 6, sourceDeviceId: 'win-1', updatedAtMs: 1000);
      store.write(
        localSlice,
        'd3d11va-copy',
        sourceDeviceId: 'win-1',
        updatedAtMs: 1000,
      );
      await Future<void>.delayed(Duration.zero);
      expect(watchedCols, equals(<int>[5, 6]));

      // 导出便携切片必须彻底过滤掉 deviceLocal 配置。
      final exported = store.exportPortableEntries();
      expect(exported.map((e) => e.namespace), equals(<String>[
        'feature_library.grid_columns',
      ]));

      // 模拟远端推送更新的 portable 切片与企图覆盖 deviceLocal 的脏切片。
      final plan = store.planPortableMerge(
        localPortable: exported,
        remotePortable: const <PortablePrefEntry>[
          PortablePrefEntry(
            namespace: 'feature_library.grid_columns',
            schemaVersion: 1,
            payload: <String, Object?>{'columns': 7},
            updatedAtMs: 2000,
            sourceDeviceId: 'android-1',
          ),
          PortablePrefEntry(
            namespace: 'feature_player_video.desktop_hwdec',
            schemaVersion: 1,
            payload: <String, Object?>{'hwdec': 'mediacodec'},
            updatedAtMs: 9999,
            sourceDeviceId: 'android-1',
          ),
        ],
      );
      store.applyPortableMergePlan(plan);

      expect(store.read(portableSlice), 7);
      // 二次守卫确保本机 deviceLocal 配置绝不被远端同步覆写。
      expect(store.read(localSlice), 'd3d11va-copy');
    });

    test('LyricUserOverrideDao、SyncMetaDao 与多平台 TrackerSyncQueueDao 运转正常', () {
      db.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'album::w1::cd1',
          scope: LyricOverrideScope.album,
          albumKey: 'w1::cd1',
          offsetMillis: -350,
          userOffsetLocked: true,
          updatedAtMs: 100,
        ),
      );
      expect(
        db.lyricUserOverrides.findByKey('album::w1::cd1')?.offsetMillis,
        -350,
      );

      db.syncMeta.put('device_id', 'win-station-1', updatedAtMs: 100);
      expect(db.syncMeta.get('device_id')?.value, 'win-station-1');

      db.trackerSyncQueue.enqueue(
        const TrackerSyncQueueItem(
          queueKey: 'bangumi::1424::s1::e1',
          trackerId: 'bangumi',
          externalSubjectId: '1424',
          seasonNumber: 1,
          episodeNumber: 1,
          targetStatus: 2,
          enqueuedAtMs: 100,
          nextRetryAtMs: 100,
        ),
      );
      db.trackerSyncQueue.enqueue(
        const TrackerSyncQueueItem(
          queueKey: 'anilist::5680::s1::e1',
          trackerId: 'anilist',
          externalSubjectId: '5680',
          seasonNumber: 1,
          episodeNumber: 1,
          targetStatus: 1,
          enqueuedAtMs: 120,
          nextRetryAtMs: 500,
        ),
      );

      expect(
        db.trackerSyncQueue.listDueForTracker('bangumi', nowMs: 200),
        hasLength(1),
      );
      expect(
        db.trackerSyncQueue.listDueForTracker('anilist', nowMs: 200),
        isEmpty,
      );

      db.trackerSyncQueue.markRetryFailed(
        'bangumi::1424::s1::e1',
        retryCount: 1,
        nextRetryAtMs: 600,
        lastError: '网络超时',
      );
      expect(
        db.trackerSyncQueue.listDueForTracker('bangumi', nowMs: 200),
        isEmpty,
      );
      expect(
        db.trackerSyncQueue.listDueForTracker('bangumi', nowMs: 700).single.retryCount,
        1,
      );
    });
  });

  group('cache.db 惰性打开与三库物理分治删库重建', () {
    test('冷启动不打开 cache.db，按需打开后可一键删库重建且不影响另外两库', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_bundle_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final storageRoot = PortableStorageRootService(
        overrideRootPath: tempDir.path,
      );
      final bundle = await KonataDatabaseBundle.openFromStorageRoot(
        storageRoot,
      );
      addTearDown(bundle.close);

      // 冷启动阶段严禁提前打开 cache.db，物理文件也不应生成。
      expect(bundle.isCacheOpen, isFalse);
      final cachePath = await storageRoot.resolveDatabaseFilePath(
        StoragePathNames.cacheDbFile,
      );
      expect(File(cachePath).existsSync(), isFalse);

      // 写入 library.db 与 user_state.db 持久数据。
      final workId = WorkId('w-persist');
      bundle.library.works.upsert(WorkRecord(id: workId, title: '幸运星'));
      bundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::op1',
          scope: LyricOverrideScope.track,
          trackKey: 'op1',
          offsetMillis: 250,
          userOffsetLocked: true,
        ),
      );

      // 首次访问 cache 属性才惰性打开 cache.db 并写入三张缓存表。
      final cacheDb = bundle.cache;
      expect(bundle.isCacheOpen, isTrue);
      expect(File(cachePath).existsSync(), isTrue);

      cacheDb.scrapeCandidates.replaceForWork(
        workId,
        <ScrapeCandidateRecord>[
          ScrapeCandidateRecord(
            workId: workId,
            rank: 1,
            tmdbId: 30983,
            mediaType: TmdbMediaType.tv,
            title: '幸运星',
            score: 98.5,
            reasons: const <String>['exact_title', 'year_match'],
          ),
        ],
      );
      cacheDb.lyricCache.upsert(
        const LyricCacheEntryRecord(
          trackKey: 'op1',
          songKey: 'motteke_sailor_fuku',
          status: LyricCacheHitStatus.hit,
          source: 'amll',
          lrcContent: '[00:00.00]もってけ！セーラーふく',
          score: 99.0,
          engineVersion: 1,
          updatedAtMs: 1000,
        ),
      );
      cacheDb.artworkNegativeCache.upsert(
        ArtworkNegativeCacheRecord(
          workId: workId,
          slot: ArtworkSlot.logo,
          negativeUntilMs: 9000,
          probedSourceMask: 3,
          updatedAtMs: 1000,
        ),
      );

      expect(cacheDb.scrapeCandidates.listByWork(workId), hasLength(1));
      expect(
        cacheDb.lyricCache.findBestHitBySongKey('motteke_sailor_fuku')?.source,
        'amll',
      );
      expect(
        cacheDb.artworkNegativeCache
            .find(workId, ArtworkSlot.logo)
            ?.isCoolingDownAt(5000),
        isTrue,
      );

      // 一键删库重建：cache.db 物理文件消失并回到惰性状态，另外两库完好无损。
      await bundle.resetCacheDatabase();
      expect(bundle.isCacheOpen, isFalse);
      expect(File(cachePath).existsSync(), isFalse);
      expect(bundle.library.works.findById(workId)?.title, '幸运星');
      expect(
        bundle.userState.lyricUserOverrides.findByKey('track::op1')?.offsetMillis,
        250,
      );

      // 再次访问 cache 自动重建全新空库。
      expect(bundle.cache.scrapeCandidates.listByWork(workId), isEmpty);
      expect(bundle.isCacheOpen, isTrue);
    });
  });
}
