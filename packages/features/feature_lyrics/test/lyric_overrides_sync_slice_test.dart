import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

class _TestSyncTx implements SyncTransactionContext {
  _TestSyncTx(this._handle);

  final Object _handle;

  @override
  int get appliedAtMs => 0;

  @override
  String get localDeviceId => 'dev_a';

  @override
  Object? rawHandleFor(String databaseName) =>
      databaseName == 'user_state' ? _handle : null;
}

void main() {
  group('LyricOverridesSyncSlice 增量合并与墓碑同步', () {
    test('exportSlice 导出含软删除墓碑在内的全部用户覆盖且不触发 cache.db 打开', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);

      final dao = bundle.userState.lyricUserOverrides;
      dao.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::song_a',
          scope: LyricOverrideScope.track,
          trackKey: 'song_a',
          lrcContent: '[00:10.00]手工歌词',
          offsetMillis: 250,
          userOffsetLocked: true,
          userEdited: true,
          updatedAtMs: 1000,
          sourceDeviceId: 'dev_a',
        ),
      );
      dao.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'album::alb_1',
          scope: LyricOverrideScope.album,
          albumKey: 'alb_1',
          offsetMillis: -400,
          userOffsetLocked: true,
          updatedAtMs: 1500,
          sourceDeviceId: 'dev_a',
        ),
      );
      dao.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::song_deleted',
          scope: LyricOverrideScope.track,
          trackKey: 'song_deleted',
          offsetMillis: 120,
          userOffsetLocked: true,
          updatedAtMs: 1800,
          sourceDeviceId: 'dev_a',
        ),
      );
      dao.softDelete(
        'track::song_deleted',
        deletedAtMs: 2000,
        sourceDeviceId: 'dev_a',
      );

      final slice = LyricOverridesSyncSlice(
        userStateDb: bundle.userState,
        now: () => DateTime.utc(2026, 7, 1, 10, 0),
      );

      expect(slice.sliceId, 'lyric_overrides_slice');
      expect(slice.schemaVersion, 1);

      final exported = await slice.exportSlice(localDeviceId: 'dev_a');
      expect(bundle.isCacheOpen, isFalse);
      expect(exported.sliceId, 'lyric_overrides_slice');

      final rawList = exported.data['overrides'] as List<Object?>;
      expect(rawList.length, 3);
      final map = LyricOverridesSyncSlice.decodeSliceMap(exported);
      expect(map['track::song_a']?.lrcContent, '[00:10.00]手工歌词');
      expect(map['album::alb_1']?.offsetMillis, -400);
      expect(map['track::song_deleted']?.isDeleted, isTrue);
      expect(map['track::song_deleted']?.deletedAtMs, 2000);
    });

    test('歌词切片缺少事务时拒绝，第二条SQL写入失败同步回滚第一条', () async {
      final bundle = KonataDatabaseBundle.openInMemory();
      addTearDown(bundle.close);
      final slice = LyricOverridesSyncSlice(userStateDb: bundle.userState);
      final plan = SyncMergePlan<LyricOverrideMergePlan>(
        sliceId: slice.sliceId,
        insertCount: 2,
        updateCount: 0,
        deleteCount: 0,
        skippedCount: 0,
        planData: const LyricOverrideMergePlan(
          upserts: [
            LyricUserOverrideRecord(
              overrideKey: 'track::first',
              scope: LyricOverrideScope.track,
              trackKey: 'first',
            ),
            LyricUserOverrideRecord(
              overrideKey: 'track::second',
              scope: LyricOverrideScope.track,
              trackKey: 'second',
            ),
          ],
        ),
      );
      final engine = bundle.userState.engine;
      expect(
        () => slice.applyMergePlan(_TestSyncTx(engine), plan),
        throwsStateError,
      );
      expect(bundle.userState.lyricUserOverrides.listAll(), isEmpty);
      engine.runTransaction((tx) {
        tx.execute(
          "CREATE TRIGGER audit_fail_second BEFORE INSERT ON lyric_user_overrides WHEN NEW.override_key = 'track::second' BEGIN SELECT RAISE(ABORT, 'audit second write'); END;",
        );
      });
      expect(
        () => engine.runTransaction(
          (tx) => slice.applyMergePlan(_TestSyncTx(tx), plan),
        ),
        throwsA(
          predicate<Object>((e) => e.toString().contains('audit second write')),
        ),
      );
      expect(
        bundle.userState.lyricUserOverrides.listAll(includeDeleted: true),
        isEmpty,
      );
      engine.runTransaction(
        (tx) => tx.execute('DROP TRIGGER audit_fail_second;'),
      );
      expect(
        engine.runTransaction(
          (tx) => slice.applyMergePlan(_TestSyncTx(tx), plan),
        ),
        SyncApplyCompletion.completed,
      );
      expect(bundle.userState.lyricUserOverrides.listAll(), hasLength(2));
    });
    test('planMerge 与 applyMergePlan 按最后写入胜出原则仲裁并原子提交', () async {
      final localBundle = KonataDatabaseBundle.openInMemory();
      final remoteBundle = KonataDatabaseBundle.openInMemory();
      addTearDown(localBundle.close);
      addTearDown(remoteBundle.close);

      // 本地：一条较旧，一条较新，一条将与远端发生同毫秒不同设备冲突，一条与远端完全相同。
      localBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::older_local',
          scope: LyricOverrideScope.track,
          trackKey: 'older_local',
          lrcContent: '[00:05.00]旧本地',
          offsetMillis: 100,
          userOffsetLocked: true,
          userEdited: true,
          updatedAtMs: 1000,
          sourceDeviceId: 'dev_local',
        ),
      );
      localBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::newer_local',
          scope: LyricOverrideScope.track,
          trackKey: 'newer_local',
          lrcContent: '[00:05.00]新本地保留',
          offsetMillis: -150,
          userOffsetLocked: true,
          userEdited: true,
          updatedAtMs: 5000,
          sourceDeviceId: 'dev_local',
        ),
      );
      localBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'album::tie_break',
          scope: LyricOverrideScope.album,
          albumKey: 'tie_break',
          offsetMillis: 100,
          userOffsetLocked: true,
          updatedAtMs: 3000,
          sourceDeviceId: 'dev_a',
        ),
      );
      localBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::same',
          scope: LyricOverrideScope.track,
          trackKey: 'same',
          offsetMillis: 50,
          userOffsetLocked: true,
          updatedAtMs: 1200,
          sourceDeviceId: 'dev_a',
        ),
      );

      // 远端：更新 older_local、过时的 newer_local、同时间戳设备字典序更高的 tie_break、新增 tomb、相同 same。
      remoteBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::older_local',
          scope: LyricOverrideScope.track,
          trackKey: 'older_local',
          lrcContent: '[00:05.00]远端胜出',
          offsetMillis: 300,
          userOffsetLocked: true,
          userEdited: true,
          updatedAtMs: 2500,
          sourceDeviceId: 'dev_z',
        ),
      );
      remoteBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::newer_local',
          scope: LyricOverrideScope.track,
          trackKey: 'newer_local',
          lrcContent: '[00:05.00]过时远端',
          offsetMillis: 900,
          userOffsetLocked: true,
          userEdited: true,
          updatedAtMs: 2000,
          sourceDeviceId: 'dev_z',
        ),
      );
      remoteBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'album::tie_break',
          scope: LyricOverrideScope.album,
          albumKey: 'tie_break',
          offsetMillis: -500,
          userOffsetLocked: true,
          updatedAtMs: 3000,
          sourceDeviceId: 'dev_z',
        ),
      );
      remoteBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::same',
          scope: LyricOverrideScope.track,
          trackKey: 'same',
          offsetMillis: 50,
          userOffsetLocked: true,
          updatedAtMs: 1200,
          sourceDeviceId: 'dev_a',
        ),
      );
      remoteBundle.userState.lyricUserOverrides.upsert(
        const LyricUserOverrideRecord(
          overrideKey: 'track::remote_deleted',
          scope: LyricOverrideScope.track,
          trackKey: 'remote_deleted',
          updatedAtMs: 3500,
          sourceDeviceId: 'dev_z',
        ),
      );
      remoteBundle.userState.lyricUserOverrides.softDelete(
        'track::remote_deleted',
        deletedAtMs: 4000,
        sourceDeviceId: 'dev_z',
      );

      final localSlice = LyricOverridesSyncSlice(
        userStateDb: localBundle.userState,
      );
      final remoteSlice = LyricOverridesSyncSlice(
        userStateDb: remoteBundle.userState,
      );

      final localPayload = await localSlice.exportSlice(localDeviceId: 'dev_a');
      final remotePayload = await remoteSlice.exportSlice(
        localDeviceId: 'dev_z',
      );

      final plan = localSlice.planMerge(
        local: localPayload,
        remote: remotePayload,
      );
      expect(plan.updateCount, 2); // older_local + tie_break
      expect(plan.deleteCount, 1); // remote_deleted 墓碑新增
      expect(plan.skippedCount, 2); // newer_local + same

      localBundle.userState.engine.runTransaction((tx) {
        localSlice.applyMergePlan(_TestSyncTx(tx), plan);
      });

      final allAfter = localBundle.userState.lyricUserOverrides.listAll(
        includeDeleted: true,
      );
      final byKey = {for (final r in allAfter) r.overrideKey: r};

      expect(byKey['track::older_local']?.lrcContent, '[00:05.00]远端胜出');
      expect(byKey['track::older_local']?.offsetMillis, 300);
      expect(byKey['track::newer_local']?.lrcContent, '[00:05.00]新本地保留');
      expect(byKey['album::tie_break']?.offsetMillis, -500);
      expect(byKey['track::remote_deleted']?.isDeleted, isTrue);
      expect(localBundle.isCacheOpen, isFalse);
    });
  });
}
