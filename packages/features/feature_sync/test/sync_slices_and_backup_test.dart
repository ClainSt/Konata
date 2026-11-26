import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 模拟外部业务模块动态挂载的“歌词人工修正”同步切片。
final class _FakeLyricOverridesSlice
    implements SyncSliceContributor<List<Map<String, Object?>>> {
  _FakeLyricOverridesSlice({this.throwOnApply = false});

  final bool throwOnApply;
  final Map<String, Map<String, Object?>> records =
      <String, Map<String, Object?>>{};

  @override
  String get sliceId => 'lyric_overrides_slice';

  @override
  String get displayName => '歌词人工修正';

  @override
  int get schemaVersion => 1;

  @override
  Future<SyncSlicePayload> exportSlice({required String localDeviceId}) async {
    final items = records.values.toList(growable: false)
      ..sort(
        (a, b) => a['trackKey'].toString().compareTo(b['trackKey'].toString()),
      );
    return SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      exportedAtMs: 1700000000000,
      sourceDeviceId: localDeviceId,
      data: <String, Object?>{'items': items},
    );
  }

  @override
  SyncMergePlan<List<Map<String, Object?>>> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final localItems = _coerceItems(local.data['items']);
    final remoteItems = _coerceItems(remote.data['items']);
    final localByKey = <String, Map<String, Object?>>{
      for (final item in localItems) item['trackKey'].toString(): item,
    };
    final toApply = <Map<String, Object?>>[];
    var inserts = 0;
    var updates = 0;
    var skipped = 0;

    for (final remoteItem in remoteItems) {
      final key = remoteItem['trackKey'].toString();
      final localItem = localByKey[key];
      if (localItem == null) {
        inserts++;
        toApply.add(remoteItem);
        continue;
      }
      final remoteTs = (remoteItem['updatedAtMs'] as num?)?.toInt() ?? 0;
      final localTs = (localItem['updatedAtMs'] as num?)?.toInt() ?? 0;
      if (remoteTs > localTs) {
        updates++;
        toApply.add(remoteItem);
      } else {
        skipped++;
      }
    }

    return SyncMergePlan<List<Map<String, Object?>>>(
      sliceId: sliceId,
      insertCount: inserts,
      updateCount: updates,
      deleteCount: 0,
      skippedCount: skipped,
      planData: List<Map<String, Object?>>.unmodifiable(toApply),
      summaryLines: <String>['歌词修正：新增 $inserts 项，更新 $updates 项'],
    );
  }

  @override
  SyncApplyCompletion applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<List<Map<String, Object?>>> plan,
  ) {
    if (throwOnApply) {
      final handle = tx.rawHandleFor('user_state')! as SqliteTransaction;
      handle.execute(
        "INSERT INTO lyric_user_overrides(override_key) VALUES ('audit-first')",
      );
      // 模拟扩展切片已写入一条后第二条违反唯一约束。
      handle.execute(
        "INSERT INTO lyric_user_overrides(override_key) VALUES ('audit-first')",
      );
    }
    for (final item in plan.planData) {
      records[item['trackKey'].toString()] = Map<String, Object?>.of(item);
    }
    return SyncApplyCompletion.completed;
  }

  static List<Map<String, Object?>> _coerceItems(Object? raw) {
    if (raw is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final item in raw)
        if (item is Map) SyncSanitizer.coerceStringKeyMap(item),
    ];
  }
}

void main() {
  group('PrefsSyncSlice 白名单过滤、敏感凭据隔离与合并策略', () {
    late KonataDatabaseBundle db;
    late ScopedPrefsStore prefs;
    late PrefsSyncSlice slice;

    setUp(() {
      db = KonataDatabaseBundle.openInMemory();
      prefs = ScopedPrefsStore(db.userState);
      slice = PrefsSyncSlice(
        userStateDb: db.userState,
        scopedPrefs: prefs,
        nowMs: () => 5000,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('严格剔除 deviceLocal 命名空间、WebDAV 密码及本机绝对路径键值', () async {
      const appearanceSlice = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'appearance',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );
      const webDavLocalSlice = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'sync_webdav',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.deviceLocal,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );
      const blockedSecretsSlice = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'secrets',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );

      prefs.write(appearanceSlice, <String, Object?>{
        'themeMode': 'dark',
        'cardDensity': 'compact',
        'api_key': 'secret-tmdb-key-should-strip',
        'pat': 'ghp_1234567890',
        'mpv_path': r'C:\Tools\mpv\mpv.exe',
        'custom_cover_path': '/Users/alice/Pictures/cover.jpg',
        'extra_url': 'https://alice:hunter2@dav.example.com/dav',
      }, sourceDeviceId: 'dev-a');

      prefs.write(webDavLocalSlice, <String, Object?>{
        'baseUrl': 'https://dav.example.com',
        'password': 'top-secret-password',
      }, sourceDeviceId: 'dev-a');

      prefs.write(blockedSecretsSlice, <String, Object?>{
        'token': 'should-never-export',
      }, sourceDeviceId: 'dev-a');

      final exported = await slice.exportSlice(localDeviceId: 'dev-a');
      final encoded = jsonEncode(exported.toJson());

      expect(encoded, contains('themeMode'));
      expect(encoded, contains('compact'));
      expect(encoded, isNot(contains('secret-tmdb-key-should-strip')));
      expect(encoded, isNot(contains('ghp_1234567890')));
      expect(encoded, isNot(contains(r'mpv.exe')));
      expect(encoded, isNot(contains('/Users/alice/Pictures/cover.jpg')));
      expect(encoded, isNot(contains('hunter2')));
      expect(encoded, isNot(contains('sync_webdav')));
      expect(encoded, isNot(contains('top-secret-password')));
      expect(encoded, isNot(contains('should-never-export')));
    });

    test('按 LWW 合并可同步命名空间并绝不覆写本机 deviceLocal 配置', () async {
      const localOnlyNs = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'feature_detail.display',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.deviceLocal,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );
      const portableNs = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'appearance',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );

      prefs.write(localOnlyNs, <String, Object?>{'showBitrate': false});
      prefs.write(portableNs, <String, Object?>{'themeMode': 'light'});

      final localPayload = await slice.exportSlice(localDeviceId: 'dev-local');
      const remotePayload = SyncSlicePayload(
        sliceId: PrefsSyncSlice.id,
        schemaVersion: 1,
        exportedAtMs: 9999999999999,
        sourceDeviceId: 'dev-remote',
        data: <String, Object?>{
          'entries': <Map<String, Object?>>[
            <String, Object?>{
              'namespace': 'feature_detail.display',
              'schemaVersion': 1,
              'payload': <String, Object?>{'showBitrate': true},
              'updatedAtMs': 9999999999999,
              'sourceDeviceId': 'dev-remote',
            },
            <String, Object?>{
              'namespace': 'appearance',
              'schemaVersion': 1,
              'payload': <String, Object?>{
                'themeMode': 'dark',
                'password': 'leaked',
              },
              'updatedAtMs': 9999999999999,
              'sourceDeviceId': 'dev-remote',
            },
          ],
        },
      );

      final plan = slice.planMerge(local: localPayload, remote: remotePayload);
      db.userState.engine.runTransaction((tx) {
        slice.applyMergePlan(
          DatabaseBundleSyncTransactionContext(
            localDeviceId: 'dev-local',
            appliedAtMs: 6000,
            userStateTx: tx,
          ),
          plan,
        );
      });

      expect(prefs.read(portableNs)['themeMode'], 'dark');
      expect(prefs.read(portableNs).containsKey('password'), isFalse);
      expect(prefs.read(localOnlyNs)['showBitrate'], isFalse);
    });
  });

  group('PlaybackHistorySyncSlice 跨源聚类、完播态与墓碑规则', () {
    late KonataDatabaseBundle dbA;
    late KonataDatabaseBundle dbB;
    late PlaybackHistorySyncSlice sliceA;
    late PlaybackHistorySyncSlice sliceB;

    setUp(() {
      dbA = KonataDatabaseBundle.openInMemory();
      dbB = KonataDatabaseBundle.openInMemory();
      sliceA = PlaybackHistorySyncSlice(databases: dbA, nowMs: () => 5000);
      sliceB = PlaybackHistorySyncSlice(databases: dbB, nowMs: () => 5000);
    });

    tearDown(() async {
      await dbA.close();
      await dbB.close();
    });

    test('跨数据源等价作品合流保留完播态、最大观看进度并遵守软删除墓碑裁决', () async {
      // 设备 A 以 TMDB 主体保存第 1 集（已完播）与第 2 集（观看 90 秒后软删除）。
      final srcA = SourceId('src-a');
      final workA = WorkId('work-a');
      final epA1 = EpisodeId('ep-a-1');
      final epA2 = EpisodeId('ep-a-2');
      final varA1 = VariantId('var-a-1');
      final varA2 = VariantId('var-a-2');

      dbA.library.mediaSources.upsert(
        MediaSourceRecord(
          id: srcA,
          kind: MediaSourceKind.local,
          label: '本地 A',
          location: r'D:\AnimeA',
        ),
      );
      dbA.library.works.upsert(
        WorkRecord(
          id: workA,
          tmdbId: 95479,
          tmdbMediaType: TmdbMediaType.tv,
          bangumiId: 425998,
          matchedSeason: 1,
          title: '葬送的芙莉莲',
          updatedAtMs: 1000,
        ),
      );
      dbA.library.episodes.upsert(
        EpisodeRecord(
          id: epA1,
          workId: workA,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '冒险的终结',
        ),
      );
      dbA.library.episodes.upsert(
        EpisodeRecord(
          id: epA2,
          workId: workA,
          seasonNumber: 1,
          episodeNumber: 2,
          title: '倒也不必是魔法',
        ),
      );
      dbA.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: '${workA.value}::${epA1.value}',
          canonicalKey: 'tmdb:tv:95479:s1::s1::e1',
          workId: workA,
          episodeId: epA1,
          variantId: varA1,
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '冒险的终结',
          sourceKind: MediaSourceKind.local,
          playedAtMs: 1500,
          positionSeconds: 1380,
          durationSeconds: 1440,
          isCompleted: true,
          updatedAtMs: 1500,
          sourceDeviceId: 'dev-a',
        ),
      );
      dbA.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: '${workA.value}::${epA2.value}',
          canonicalKey: 'tmdb:tv:95479:s1::s1::e2',
          workId: workA,
          episodeId: epA2,
          variantId: varA2,
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '倒也不必是魔法',
          sourceKind: MediaSourceKind.local,
          playedAtMs: 1600,
          positionSeconds: 90,
          durationSeconds: 1440,
          isCompleted: false,
          updatedAtMs: 1600,
          sourceDeviceId: 'dev-a',
        ),
      );
      dbA.userState.playbackRecords.softDelete(
        '${workA.value}::${epA2.value}',
        deletedAtMs: 3000,
        sourceDeviceId: 'dev-a',
      );

      // 设备 B 同作品通过 Bangumi 身份存储第 1 集（更新时间戳但未完播且进度较小）与第 2 集旧进度。
      final workB = WorkId('work-b');
      final epB1 = EpisodeId('ep-b-1');
      final epB2 = EpisodeId('ep-b-2');
      final varB1 = VariantId('var-b-1');
      final varB2 = VariantId('var-b-2');

      dbB.library.works.upsert(
        WorkRecord(
          id: workB,
          bangumiId: 425998,
          title: '葬送のフリーレン',
          updatedAtMs: 2000,
        ),
      );
      dbB.library.episodes.upsert(
        EpisodeRecord(
          id: epB1,
          workId: workB,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '冒险的终结',
        ),
      );
      dbB.library.episodes.upsert(
        EpisodeRecord(
          id: epB2,
          workId: workB,
          seasonNumber: 1,
          episodeNumber: 2,
          title: '倒也不必是魔法',
        ),
      );
      dbB.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: '${workB.value}::${epB1.value}',
          canonicalKey: 'bgm:425998::s1::e1',
          workId: workB,
          episodeId: epB1,
          variantId: varB1,
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '冒险的终结',
          sourceKind: MediaSourceKind.webdav,
          playedAtMs: 2800,
          positionSeconds: 320,
          durationSeconds: 1440,
          isCompleted: false,
          updatedAtMs: 2800,
          sourceDeviceId: 'dev-b',
        ),
      );
      dbB.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: '${workB.value}::${epB2.value}',
          canonicalKey: 'bgm:425998::s1::e2',
          workId: workB,
          episodeId: epB2,
          variantId: varB2,
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '倒也不必是魔法',
          sourceKind: MediaSourceKind.webdav,
          playedAtMs: 2000,
          positionSeconds: 200,
          durationSeconds: 1440,
          isCompleted: false,
          updatedAtMs: 2000,
          sourceDeviceId: 'dev-b',
        ),
      );

      final remoteA = await sliceA.exportSlice(localDeviceId: 'dev-a');
      final localB = await sliceB.exportSlice(localDeviceId: 'dev-b');
      final plan = sliceB.planMerge(local: localB, remote: remoteA);

      dbB.userState.engine.runTransaction((tx) {
        sliceB.applyMergePlan(
          DatabaseBundleSyncTransactionContext(
            localDeviceId: 'dev-b',
            appliedAtMs: 5000,
            userStateTx: tx,
          ),
          plan,
        );
      });

      final activeB = dbB.userState.playbackRecords
          .listAllWithTombstones()
          .where((r) => !r.isDeleted)
          .toList();
      expect(activeB, hasLength(1));
      expect(activeB.single.episodeId, epB1);
      expect(activeB.single.isCompleted, isTrue);
      expect(activeB.single.positionSeconds, 1380);

      final allWithTombstonesB = dbB.userState.playbackRecords
          .listAllWithTombstones();
      final deletedEp2 = allWithTombstonesB.firstWhere(
        (r) => r.episodeId == epB2,
      );
      expect(deletedEp2.deletedAtMs, 3000);
    });
  });

  group('LibraryCatalogSyncSlice 媒体库完整同步与 ArtworkRef 安全铁律', () {
    late KonataDatabaseBundle dbA;
    late KonataDatabaseBundle dbB;
    late LibraryCatalogSyncSlice sliceA;
    late LibraryCatalogSyncSlice sliceB;

    setUp(() {
      dbA = KonataDatabaseBundle.openInMemory();
      dbB = KonataDatabaseBundle.openInMemory();
      sliceA = LibraryCatalogSyncSlice(
        libraryDb: dbA.library,
        nowMs: () => 5000,
      );
      sliceB = LibraryCatalogSyncSlice(
        libraryDb: dbB.library,
        nowMs: () => 5000,
      );
    });

    tearDown(() async {
      await dbA.close();
      await dbB.close();
    });

    test('旧端仅发送作品墓碑时收敛本机子关系并保持同系列其他作品', () async {
      const work = WorkId.trusted('deleted-parent');
      const sibling = WorkId.trusted('kept-parent');
      const source = SourceId.trusted('same-source');
      const series = SeriesGroupId.trusted('same-series');
      const ep = EpisodeId.trusted('deleted-episode');
      const variant = VariantId.trusted('deleted-variant');
      const moved = VariantId.trusted('moved-variant');
      for (final db in [dbA.library, dbB.library]) {
        db.mediaSources.upsert(
          const MediaSourceRecord(
            id: source,
            kind: MediaSourceKind.local,
            label: '测试',
            location: 'D:/readonly',
          ),
        );
        db.seriesGroups.upsert(
          const SeriesGroupRecord(id: series, title: '系列'),
        );
        db.works.upsert(
          const WorkRecord(
            id: work,
            title: '移除',
            seriesId: series,
            updatedAtMs: 1000,
          ),
        );
        db.works.upsert(
          const WorkRecord(
            id: sibling,
            title: '保留',
            seriesId: series,
            updatedAtMs: 1000,
          ),
        );
      }
      dbB.library.episodes.upsert(
        const EpisodeRecord(
          id: ep,
          workId: work,
          seasonNumber: 1,
          episodeNumber: 1,
          updatedAtMs: 1100,
        ),
      );
      dbB.library.mediaVariants.upsert(
        const MediaVariantRecord(
          id: variant,
          workId: work,
          episodeId: ep,
          sourceId: source,
          relativePath: 'A/01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
          updatedAtMs: 1100,
        ),
      );
      dbB.library.mediaVariants.upsert(
        const MediaVariantRecord(
          id: moved,
          workId: sibling,
          sourceId: source,
          relativePath: 'B/02.mkv',
          fileName: '02.mkv',
          fileSize: 100,
          updatedAtMs: 1500,
        ),
      );
      dbA.library.works.softDelete(
        work,
        deletedAtMs: 2000,
        sourceDeviceId: 'dev-a',
      );
      final remote = await sliceA.exportSlice(localDeviceId: 'dev-a');
      final local = await sliceB.exportSlice(localDeviceId: 'dev-b');
      final plan = sliceB.planMerge(local: local, remote: remote);
      expect(plan.deleteCount, 3);
      dbB.library.engine.runTransaction((tx) {
        sliceB.applyMergePlan(
          DatabaseBundleSyncTransactionContext(
            localDeviceId: 'dev-b',
            appliedAtMs: 5000,
            libraryTx: tx,
          ),
          plan,
        );
      });
      expect(dbB.library.works.findById(work), isNull);
      expect(dbB.library.episodes.listByWork(work), isEmpty);
      expect(dbB.library.mediaVariants.listByWork(work), isEmpty);
      expect(dbB.library.mediaVariants.listBySource(source).single.id, moved);
      expect(dbB.library.works.listBySeries(series).single.id, sibling);
      expect(
        dbB.library.mediaVariants
            .findById(variant, includeDeleted: true)
            ?.deletedAtMs,
        2000,
      );
      // 远端后来补发旧归属的文件墓碑，本机已转移的文件仍必须保留。
      dbA.library.mediaVariants.upsert(
        const MediaVariantRecord(
          id: moved,
          workId: work,
          sourceId: source,
          relativePath: 'B/02.mkv',
          fileName: '02.mkv',
          fileSize: 100,
          updatedAtMs: 3000,
          deletedAtMs: 3000,
          sourceDeviceId: 'dev-a',
        ),
      );
      final late = await sliceA.exportSlice(localDeviceId: 'dev-a');
      final after = await sliceB.exportSlice(localDeviceId: 'dev-b');
      final latePlan = sliceB.planMerge(local: after, remote: late);
      dbB.library.engine.runTransaction((tx) {
        sliceB.applyMergePlan(
          DatabaseBundleSyncTransactionContext(
            localDeviceId: 'dev-b',
            appliedAtMs: 5000,
            libraryTx: tx,
          ),
          latePlan,
        );
      });
      expect(dbB.library.mediaVariants.findById(moved)?.workId, sibling);
      expect(
        sliceB.planMerge(local: after, remote: remote).hasChanges,
        isFalse,
      );
    });
    test('旧版目录切片隐藏标记不再参与合并或重新导出', () async {
      dbA.library.works.upsert(
        const WorkRecord(
          id: WorkId.trusted('legacy-work'),
          title: '历史作品',
          scrapeStatus: ScrapeStatus.matched,
          updatedAtMs: 100,
        ),
      );
      final exported = await sliceA.exportSlice(localDeviceId: 'dev-a');
      final oldWork = SyncSanitizer.coerceStringKeyMap(
        (exported.data['works'] as List).single,
      );
      final legacy = SyncSlicePayload(
        sliceId: exported.sliceId,
        schemaVersion: exported.schemaVersion,
        exportedAtMs: exported.exportedAtMs,
        sourceDeviceId: exported.sourceDeviceId,
        data: {
          ...exported.data,
          'works': [
            {...oldWork, 'isHidden': true, 'keepHidden': true},
          ],
        },
      );
      final local = await sliceB.exportSlice(localDeviceId: 'dev-b');
      final plan = sliceB.planMerge(local: local, remote: legacy);
      dbB.library.engine.runTransaction((tx) {
        sliceB.applyMergePlan(
          DatabaseBundleSyncTransactionContext(
            localDeviceId: 'dev-b',
            appliedAtMs: 5000,
            libraryTx: tx,
          ),
          plan,
        );
      });
      expect(dbB.library.works.listVisible().single.id.value, 'legacy-work');
      final reexported = await sliceB.exportSlice(localDeviceId: 'dev-b');
      final item = SyncSanitizer.coerceStringKeyMap(
        (reexported.data['works'] as List).single,
      );
      expect(item.containsKey('isHidden'), isFalse);
      expect(item.containsKey('keepHidden'), isFalse);
    });
    test('ArtworkRef.localCustom 序列化严格输出 null，同时保留远程海报与人工锁定态', () async {
      final srcId = SourceId('src-webdav-a');
      final seriesId = SeriesGroupId('series-monogatari');
      final workId = WorkId('work-bakemonogatari');
      final epId = EpisodeId('ep-1');
      final varId = VariantId('var-1');

      dbA.library.mediaSources.upsert(
        MediaSourceRecord(
          id: srcId,
          kind: MediaSourceKind.webdav,
          label: '主力 NAS',
          location: 'https://user:secret-inline-pass@nas.example.com/anime',
          username: 'alice',
          updatedAtMs: 1000,
          sourceDeviceId: 'dev-a',
        ),
      );
      dbA.library.seriesGroups.upsert(
        SeriesGroupRecord(
          id: seriesId,
          canonicalKey: 'tmdb:col:9001',
          title: '物语系列',
          tmdbCollectionId: 9001,
          updatedAtMs: 1000,
          sourceDeviceId: 'dev-a',
        ),
      );
      dbA.library.works.upsert(
        WorkRecord(
          id: workId,
          canonicalKey: 'tmdb:tv:46195:s1',
          tmdbId: 46195,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          title: '化物语',
          year: 2009,
          posterRef: const ArtworkRef.localCustom(
            localPath: 'photos/custom_poster_secret.jpg',
            locked: true,
          ),
          backdropRef: const ArtworkRef.localCustom(
            localPath: r'C:\Users\alice\Pictures\local_backdrop.png',
            locked: true,
          ),
          logoRef: const ArtworkRef.remote(
            source: ArtworkSource.fanart,
            uri: 'https://assets.fanart.tv/bakemonogatari_logo.png',
            locked: true,
          ),
          bangumiPosterPath: 'https://lain.bgm.tv/pic/cover/l/12/34/1671.jpg',
          folderTmdbHint: 46195,
          isManualLocked: true,
          metadataLocked: true,
          scrapeStatus: ScrapeStatus.matched,
          seriesId: seriesId,
          seriesOrder: 1,
          seriesLabel: '第 1 作',
          seriesLocked: true,
          updatedAtMs: 2000,
          sourceDeviceId: 'dev-a',
        ),
      );
      dbA.library.episodes.upsert(
        EpisodeRecord(
          id: epId,
          workId: workId,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '黑仪螃蟹 其壹',
          stillPath: '/tmdb_still_1.jpg',
          updatedAtMs: 2000,
          sourceDeviceId: 'dev-a',
        ),
      );
      dbA.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: varId,
          workId: workId,
          episodeId: epId,
          sourceId: srcId,
          relativePath: 'Monogatari/01.mkv',
          fileName: '01.mkv',
          fileSize: 987654321,
          mappingLocked: true,
          workLocked: true,
          scopeLocked: true,
          externalSubtitles: const <String>['Monogatari/01.sc.ass'],
          updatedAtMs: 2000,
          sourceDeviceId: 'dev-a',
        ),
      );

      final exported = await sliceA.exportSlice(localDeviceId: 'dev-a');
      final jsonStr = jsonEncode(exported.toJson());

      expect(jsonStr, isNot(contains('custom_poster_secret.jpg')));
      expect(jsonStr, isNot(contains('local_backdrop.png')));
      expect(jsonStr, isNot(contains('secret-inline-pass')));
      expect(jsonStr, contains('bakemonogatari_logo.png'));

      final worksList = exported.data['works']! as List<Object?>;
      final exportedWork = SyncSanitizer.coerceStringKeyMap(worksList.single);
      expect(exportedWork['posterRef'], isNull);
      expect(exportedWork['backdropRef'], isNull);
      expect(exportedWork['logoRef'], isA<Map<Object?, Object?>>());

      // 设备 B 本机预先存在同址 WebDAV 媒体源（本地 ID 不同），合并后必须复用本地 sourceId 保留凭据绑定。
      final localSrcB = SourceId('local-src-b-99');
      dbB.library.mediaSources.upsert(
        MediaSourceRecord(
          id: localSrcB,
          kind: MediaSourceKind.webdav,
          label: '旧标签',
          location: 'https://nas.example.com/anime/',
          createdAtMs: 500,
          updatedAtMs: 500,
          sourceDeviceId: 'dev-b',
        ),
      );

      final localB = await sliceB.exportSlice(localDeviceId: 'dev-b');
      final plan = sliceB.planMerge(local: localB, remote: exported);

      dbB.library.engine.runTransaction((libTx) {
        sliceB.applyMergePlan(
          DatabaseBundleSyncTransactionContext(
            localDeviceId: 'dev-b',
            appliedAtMs: 5000,
            libraryTx: libTx,
          ),
          plan,
        );
      });

      final mergedWorks = dbB.library.works.listVisible();
      expect(mergedWorks, hasLength(1));
      final wB = mergedWorks.single;
      expect(wB.title, '化物语');
      expect(wB.posterRef, isNull);
      expect(wB.backdropRef, isNull);
      expect((wB.logoRef! as RemoteArtworkRef).locked, isTrue);
      expect(wB.isManualLocked, isTrue);
      expect(wB.metadataLocked, isTrue);
      expect(wB.seriesLocked, isTrue);
      expect(wB.seriesLabel, '第 1 作');

      final variantsB = dbB.library.mediaVariants.listByWork(wB.id);
      expect(variantsB, hasLength(1));
      expect(variantsB.single.sourceId, localSrcB);
      expect(variantsB.single.mappingLocked, isTrue);
      expect(variantsB.single.workLocked, isTrue);
      expect(variantsB.single.scopeLocked, isTrue);
    });

    test('portraitBackdropRef 支持远程同步往返、本地自定义图脱敏剔除与旧版 JSON 兼容', () async {
      final remoteWorkId = WorkId('work-portrait-remote');
      final localWorkId = WorkId('work-portrait-local');

      dbA.library.works.upsert(
        WorkRecord(
          id: remoteWorkId,
          canonicalKey: 'tmdb:tv:1001:s1',
          tmdbId: 1001,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          title: '远程竖版原画作品',
          portraitBackdropRef: const ArtworkRef.remote(
            source: ArtworkSource.tmdb,
            uri: '/textless_portrait_2k.jpg',
            locked: true,
          ),
          scrapeStatus: ScrapeStatus.matched,
          updatedAtMs: 3000,
          sourceDeviceId: 'dev-a',
        ),
      );
      dbA.library.works.upsert(
        WorkRecord(
          id: localWorkId,
          canonicalKey: 'tmdb:tv:1002:s1',
          tmdbId: 1002,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          title: '本地自定义竖版原画作品',
          portraitBackdropRef: const ArtworkRef.localCustom(
            localPath: 'photos/secret_portrait_custom.jpg',
            locked: true,
          ),
          scrapeStatus: ScrapeStatus.matched,
          updatedAtMs: 3000,
          sourceDeviceId: 'dev-a',
        ),
      );

      final exported = await sliceA.exportSlice(localDeviceId: 'dev-a');
      final encoded = jsonEncode(exported.toJson());
      expect(encoded, contains('/textless_portrait_2k.jpg'));
      expect(encoded, isNot(contains('secret_portrait_custom.jpg')));

      final localB = await sliceB.exportSlice(localDeviceId: 'dev-b');
      final plan = sliceB.planMerge(local: localB, remote: exported);
      dbB.library.engine.runTransaction((libTx) {
        sliceB.applyMergePlan(
          DatabaseBundleSyncTransactionContext(
            localDeviceId: 'dev-b',
            appliedAtMs: 5000,
            libraryTx: libTx,
          ),
          plan,
        );
      });

      final remoteMerged = dbB.library.works.findById(remoteWorkId);
      expect(remoteMerged, isNotNull);
      expect(remoteMerged!.portraitBackdropRef, isA<RemoteArtworkRef>());
      final remoteRef = remoteMerged.portraitBackdropRef! as RemoteArtworkRef;
      expect(remoteRef.uri, '/textless_portrait_2k.jpg');
      expect(remoteRef.locked, isTrue);

      final localMerged = dbB.library.works.findById(localWorkId);
      expect(localMerged, isNotNull);
      expect(localMerged!.portraitBackdropRef, isNull);

      // 兼容旧版未包含 portraitBackdropRef 字段的同步载荷。
      const legacyPayload = SyncSlicePayload(
        sliceId: LibraryCatalogSyncSlice.id,
        schemaVersion: 1,
        exportedAtMs: 6000,
        sourceDeviceId: 'dev-legacy',
        data: <String, Object?>{
          'sources': <Object?>[],
          'seriesGroups': <Object?>[],
          'works': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'work-legacy-no-portrait',
              'canonicalKey': 'tmdb:tv:1003:s1',
              'tmdbId': 1003,
              'tmdbMediaType': 'tv',
              'title': '旧版载荷作品',
              'scrapeStatus': 'matched',
              'updatedAtMs': 6000,
            },
          ],
          'episodes': <Object?>[],
          'variants': <Object?>[],
        },
      );
      final localBeforeLegacy = await sliceB.exportSlice(
        localDeviceId: 'dev-b',
      );
      final legacyPlan = sliceB.planMerge(
        local: localBeforeLegacy,
        remote: legacyPayload,
      );
      dbB.library.engine.runTransaction((libTx) {
        sliceB.applyMergePlan(
          DatabaseBundleSyncTransactionContext(
            localDeviceId: 'dev-b',
            appliedAtMs: 7000,
            libraryTx: libTx,
          ),
          legacyPlan,
        );
      });
      final legacyWork = dbB.library.works.findById(
        WorkId('work-legacy-no-portrait'),
      );
      expect(legacyWork, isNotNull);
      expect(legacyWork!.portraitBackdropRef, isNull);
    });
  });

  group('KonataBackupService .konata 选择性导出、干跑预览、原子事务与扩展切片', () {
    late KonataDatabaseBundle dbA;
    late KonataDatabaseBundle dbB;
    late ScopedPrefsStore prefsA;
    late ScopedPrefsStore prefsB;
    late InMemoryDomainEventBus eventBusB;

    setUp(() {
      dbA = KonataDatabaseBundle.openInMemory();
      dbB = KonataDatabaseBundle.openInMemory();
      prefsA = ScopedPrefsStore(dbA.userState);
      prefsB = ScopedPrefsStore(dbB.userState);
      eventBusB = InMemoryDomainEventBus();
    });

    tearDown(() async {
      await eventBusB.dispose();
      await dbA.close();
      await dbB.close();
    });

    test('文件大小、流式解压及未来切片版本拒绝，目标库保持不变', () async {
      final service = KonataBackupService(
        databases: dbB,
        scopedPrefs: prefsB,
        deviceStore: SyncDeviceStore(dbB.userState.syncMeta),
      );
      const work = WorkId.trusted('protected-work');
      dbB.library.works.upsert(const WorkRecord(id: work, title: '原有收藏'));
      final dir = await Directory.systemTemp.createTemp('backup-size-');
      addTearDown(() => dir.delete(recursive: true));
      final oversized = File('${dir.path}/oversized.konata');
      final handle = await oversized.open(mode: FileMode.write);
      try {
        await handle.truncate(KonataBackupService.maxArchiveBytes + 1);
      } finally {
        await handle.close();
      }
      await expectLater(
        KonataBackupService.readArchiveFile(oversized.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('32 MiB'),
          ),
        ),
      );
      await expectLater(
        service.decodeAndVerifyArchiveBytes(
          Uint8List(KonataBackupService.maxArchiveBytes + 1),
        ),
        throwsFormatException,
      );
      final encoded = _TestByteSink();
      final compressor = gzip.encoder.startChunkedConversion(encoded);
      final block = Uint8List(1024 * 1024);
      for (
        var i = 0;
        i <= KonataBackupService.maxDecodedArchiveBytes ~/ block.length;
        i++
      ) {
        compressor.add(block);
      }
      compressor.close();
      await expectLater(
        service.decodeAndVerifyArchiveBytes(encoded.bytes.takeBytes()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('128 MiB'),
          ),
        ),
      );
      final futureArchive = KonataBackupArchive.create(
        exportedAtMs: 1000,
        deviceId: 'future',
        deviceName: 'fixture',
        platform: 'android',
        appVersion: 'future',
        slicePayloads: [
          const SyncSlicePayload(
            sliceId: 'library_catalog_slice',
            schemaVersion: 99,
            exportedAtMs: 1000,
            sourceDeviceId: 'future',
            data: {},
          ),
        ],
      );
      final futureBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(futureArchive.toJson())),
      );
      for (final mode in KonataRestoreMode.values) {
        await expectLater(
          service.previewRestore(futureBytes, mode: mode),
          throwsFormatException,
        );
        await expectLater(
          service.restoreFromArchiveBytes(futureBytes, mode: mode),
          throwsFormatException,
        );
      }
      expect(dbB.library.works.listVisible().single.id, work);
      expect(dbB.library.works.listVisible().single.title, '原有收藏');
    });

    test('校验和正确但内外切片标识不一致时拒绝，格式版本必须是整数', () async {
      final source = KonataBackupService(
        databases: dbA,
        scopedPrefs: prefsA,
        deviceStore: SyncDeviceStore(dbA.userState.syncMeta),
      );
      final bytes = await source.exportArchiveBytes(compressGzip: false);
      final original = SyncSanitizer.coerceStringKeyMap(
        jsonDecode(utf8.decode(bytes)) as Map,
      );
      final slices = SyncSanitizer.coerceStringKeyMap(original['slices']);
      final item = SyncSanitizer.coerceStringKeyMap(
        slices['library_catalog_slice'],
      );
      item['sliceId'] = 'playback_history_slice';
      slices['library_catalog_slice'] = item;
      final mismatched = {
        ...original,
        'slices': slices,
        'payloadSha256': SyncSanitizer.computeMapSha256(slices),
      };
      expect(
        () => KonataBackupArchive.parseAndVerify(jsonEncode(mismatched)),
        throwsFormatException,
      );
      for (final invalid in [3.5, '3', 0, -1]) {
        expect(
          () => KonataBackupArchive.parseAndVerify(
            jsonEncode({...original, 'schemaVersion': invalid}),
          ),
          throwsFormatException,
        );
      }
    });

    test('支持选择性切片导出、SHA-256 篡改拒绝、干跑预览不改库、原子应用与发布 SyncCompletedEvent', () async {
      final extraA = _FakeLyricOverridesSlice();
      extraA.records['track::clannad::op'] = <String, Object?>{
        'trackKey': 'track::clannad::op',
        'offsetMs': -250,
        'updatedAtMs': 4000,
      };
      final extraB = _FakeLyricOverridesSlice();

      const appearanceSlice = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'appearance',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );
      prefsA.write(appearanceSlice, <String, Object?>{'themeMode': 'dark'});
      dbA.library.works.upsert(
        WorkRecord(
          id: WorkId('w-clannad'),
          title: 'CLANNAD',
          updatedAtMs: 4000,
        ),
      );

      final serviceA = KonataBackupService(
        databases: dbA,
        scopedPrefs: prefsA,
        deviceStore: SyncDeviceStore(dbA.userState.syncMeta, nowMs: () => 4000),
        extraSlices: <SyncSliceContributor<Object?>>[extraA],
        nowMs: () => 4000,
      );
      final serviceB = KonataBackupService(
        databases: dbB,
        scopedPrefs: prefsB,
        deviceStore: SyncDeviceStore(dbB.userState.syncMeta, nowMs: () => 5000),
        extraSlices: <SyncSliceContributor<Object?>>[extraB],
        nowMs: () => 5000,
        eventBus: eventBusB,
      );

      // 仅导出 prefs_slice 与外部自定义切片 lyric_overrides_slice，跳过 library_catalog_slice。
      final gzipBytes = await serviceA.exportArchiveBytes(
        sliceIds: const <String>{'prefs_slice', 'lyric_overrides_slice'},
      );
      expect(gzipBytes.sublist(0, 2), equals(<int>[0x1f, 0x8b]));

      final decodedJson = utf8.decode(gzip.decode(gzipBytes));
      final archive = KonataBackupArchive.parseAndVerify(decodedJson);
      expect(
        archive.sliceIds,
        equals(<String>['prefs_slice', 'lyric_overrides_slice']),
      );
      expect(archive.slices.containsKey('library_catalog_slice'), isFalse);

      // 篡改归档内容应立即触发 SHA-256 完整性校验失败。
      final tamperedMap = archive.toJson();
      final tamperedSlices = SyncSanitizer.coerceStringKeyMap(
        tamperedMap['slices'],
      );
      final tamperedLyric = SyncSanitizer.coerceStringKeyMap(
        tamperedSlices['lyric_overrides_slice'],
      );
      tamperedLyric['schemaVersion'] = 99;
      tamperedSlices['lyric_overrides_slice'] = tamperedLyric;
      tamperedMap['slices'] = tamperedSlices;
      final tamperedBytes = Uint8List.fromList(
        gzip.encode(utf8.encode(jsonEncode(tamperedMap))),
      );
      await expectLater(
        () => serviceB.previewRestore(tamperedBytes),
        throwsA(isA<FormatException>()),
      );

      // 干跑预览阶段应准确返回各切片变更数且绝不修改目标数据库与外部切片内存。
      final preview = await serviceB.previewRestore(gzipBytes);
      expect(preview.totalInserts, 2);
      expect(
        preview.slicePreviews
            .firstWhere((s) => s.sliceId == 'library_catalog_slice')
            .remoteAvailable,
        isFalse,
      );
      expect(prefsB.read(appearanceSlice), isEmpty);
      expect(extraB.records, isEmpty);

      // 确认恢复后原子写入并触发 SyncCompletedEvent。
      final events = <DomainEvent>[];
      final sub = eventBusB.stream.listen(events.add);
      addTearDown(() => sub.cancel());

      final outcome = await serviceB.restoreFromArchiveBytes(
        gzipBytes,
        selectedSliceIds: const <String>{
          'prefs_slice',
          'lyric_overrides_slice',
        },
      );
      await Future<void>.delayed(Duration.zero);

      expect(outcome.channel, SyncChannelIds.localBackup);
      expect(
        outcome.updatedSliceIds,
        equals(<String>{'prefs_slice', 'lyric_overrides_slice'}),
      );
      expect(prefsB.read(appearanceSlice)['themeMode'], 'dark');
      expect(extraB.records['track::clannad::op']?['offsetMs'], -250);
      expect(dbB.library.works.listVisible(), isEmpty);

      final syncEvents = events.whereType<SyncCompletedEvent>().toList();
      expect(syncEvents, hasLength(1));
      expect(syncEvents.single.channel, SyncChannelIds.localBackup);
      expect(
        syncEvents.single.updatedSliceIds,
        equals(<String>{'prefs_slice', 'lyric_overrides_slice'}),
      );
    });

    test('统一写事务内若外部切片抛出异常，内置表改动必须同步回滚保持原子性', () async {
      const appearanceSlice = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'appearance',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );
      prefsA.write(appearanceSlice, <String, Object?>{'themeMode': 'dark'});
      final extraA = _FakeLyricOverridesSlice();
      extraA.records['track::rollback'] = <String, Object?>{
        'trackKey': 'track::rollback',
        'offsetMs': 120,
        'updatedAtMs': 4000,
      };

      final serviceA = KonataBackupService(
        databases: dbA,
        scopedPrefs: prefsA,
        deviceStore: SyncDeviceStore(dbA.userState.syncMeta, nowMs: () => 4000),
        extraSlices: <SyncSliceContributor<Object?>>[extraA],
      );
      final archiveBytes = await serviceA.exportArchiveBytes();

      final failingExtraB = _FakeLyricOverridesSlice(throwOnApply: true);
      final serviceB = KonataBackupService(
        databases: dbB,
        scopedPrefs: prefsB,
        deviceStore: SyncDeviceStore(dbB.userState.syncMeta, nowMs: () => 5000),
        extraSlices: <SyncSliceContributor<Object?>>[failingExtraB],
      );

      await expectLater(
        () => serviceB.restoreFromArchiveBytes(archiveBytes),
        throwsA(
          predicate<Object>(
            (e) => e.toString().contains('UNIQUE constraint failed'),
          ),
        ),
      );
      expect(prefsB.read(appearanceSlice), isEmpty);
      expect(
        dbB.userState.lyricUserOverrides.listAll(includeDeleted: true),
        isEmpty,
      );
    });

    test('扩展切片同步失败不得留下已提交的双库内置表', () async {
      const appearanceSlice = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'appearance',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );
      prefsA.write(appearanceSlice, <String, Object?>{'themeMode': 'dark'});
      dbA.library.works.upsert(
        const WorkRecord(id: WorkId.trusted('rollback-work'), title: '隔离作品'),
      );
      final extraA = _FakeLyricOverridesSlice();
      extraA.records['track::rollback'] = <String, Object?>{
        'trackKey': 'track::rollback',
        'offsetMs': 120,
        'updatedAtMs': 4000,
      };

      final serviceA = KonataBackupService(
        databases: dbA,
        scopedPrefs: prefsA,
        deviceStore: SyncDeviceStore(dbA.userState.syncMeta, nowMs: () => 4000),
        extraSlices: <SyncSliceContributor<Object?>>[extraA],
      );
      final archiveBytes = await serviceA.exportArchiveBytes();

      final failingExtraB = _FakeLyricOverridesSlice(throwOnApply: true);
      final serviceB = KonataBackupService(
        databases: dbB,
        scopedPrefs: prefsB,
        deviceStore: SyncDeviceStore(dbB.userState.syncMeta, nowMs: () => 5000),
        extraSlices: <SyncSliceContributor<Object?>>[failingExtraB],
      );

      await expectLater(
        () => serviceB.restoreFromArchiveBytes(archiveBytes),
        throwsA(
          predicate<Object>(
            (e) => e.toString().contains('UNIQUE constraint failed'),
          ),
        ),
      );
      expect(prefsB.read(appearanceSlice), isEmpty);
      expect(
        dbB.userState.lyricUserOverrides.listAll(includeDeleted: true),
        isEmpty,
      );
      expect(dbB.library.works.listVisible(), isEmpty);
      expect(
        dbB.userState.syncMeta.get(SyncDeviceStore.metaKeyLocalBackupLastAtMs),
        isNull,
      );
    });

    test('覆盖还原模式会重建所选切片数据，但保留同址媒体源 ID 且不动本机 deviceLocal 配置', () async {
      const webDavSlice = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'sync_webdav',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.deviceLocal,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );
      prefsB.write(webDavSlice, <String, Object?>{
        'baseUrl': 'https://keep.me',
      });
      dbB.library.works.upsert(
        WorkRecord(
          id: WorkId('w-old-local'),
          title: '旧本地作品',
          updatedAtMs: 9000,
        ),
      );

      dbA.library.works.upsert(
        WorkRecord(id: WorkId('w-snap'), title: '快照作品', updatedAtMs: 1000),
      );
      final serviceA = KonataBackupService(
        databases: dbA,
        scopedPrefs: prefsA,
        deviceStore: SyncDeviceStore(dbA.userState.syncMeta),
      );
      final serviceB = KonataBackupService(
        databases: dbB,
        scopedPrefs: prefsB,
        deviceStore: SyncDeviceStore(dbB.userState.syncMeta),
      );

      final snapBytes = await serviceA.exportArchiveBytes(
        sliceIds: const <String>{'library_catalog_slice', 'prefs_slice'},
      );
      await serviceB.restoreFromArchiveBytes(
        snapBytes,
        mode: KonataRestoreMode.overwrite,
      );

      final visibleB = dbB.library.works.listVisible();
      expect(visibleB.map((w) => w.title), equals(<String>['快照作品']));
      expect(prefsB.read(webDavSlice)['baseUrl'], 'https://keep.me');
    });
  });
}

Map<String, Object?> _identityEncode(Map<String, Object?> value) => value;
Map<String, Object?> _identityDecode(
  Map<String, Object?> json,
  int schemaVersion,
) => json;

final class _TestByteSink implements Sink<List<int>> {
  final BytesBuilder bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) => bytes.add(data);
  @override
  void close() {}
}
