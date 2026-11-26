import 'dart:convert';

import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  const remoteId = '9876543210987654321';
  const sourceId = SourceId.trusted('cloud-source');
  const workId = WorkId.trusted('work-cloud');
  const variantId = VariantId.trusted('variant-cloud');

  test('云盘文件标识经同步导出、合并、落库与再导出保持精确', () async {
    final a = KonataDatabaseBundle.openInMemory();
    final b = KonataDatabaseBundle.openInMemory();
    addTearDown(a.close);
    addTearDown(b.close);
    for (final db in [a, b]) {
      db.library.mediaSources.upsert(
        const MediaSourceRecord(
          id: sourceId,
          kind: MediaSourceKind.cloudDrive,
          label: '云盘',
          location: 'guangyapan://account_fixture/123',
          username: 'device-local-fixture',
        ),
      );
      db.library.works.upsert(const WorkRecord(id: workId, title: '86'));
      db.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: variantId,
          workId: workId,
          sourceId: sourceId,
          relativePath: '86/01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
          remoteFileId: identical(db, a) ? remoteId : null,
        ),
      );
    }
    final sa = LibraryCatalogSyncSlice(libraryDb: a.library);
    final sb = LibraryCatalogSyncSlice(libraryDb: b.library);
    final payload = await sa.exportSlice(localDeviceId: 'a');
    final encoded = jsonEncode(payload.toJson());
    expect(encoded, contains(remoteId));
    expect(encoded, isNot(contains('device-local-fixture')));
    final plan = sb.planMerge(
      local: await sb.exportSlice(localDeviceId: 'b'),
      remote: payload,
    );
    b.library.engine.runTransaction(
      (tx) => sb.applyMergePlan(
        DatabaseBundleSyncTransactionContext(
          localDeviceId: 'b',
          appliedAtMs: 5000,
          libraryTx: tx,
        ),
        plan,
      ),
    );
    expect(
      b.library.mediaVariants.listBySource(sourceId).single.remoteFileId,
      remoteId,
    );
    expect(
      jsonEncode((await sb.exportSlice(localDeviceId: 'b')).toJson()),
      contains(remoteId),
    );
    final old = SyncSlicePayload(
      sliceId: payload.sliceId,
      schemaVersion: payload.schemaVersion,
      exportedAtMs: payload.exportedAtMs,
      sourceDeviceId: payload.sourceDeviceId,
      data: {
        ...payload.data,
        'variants': [
          {
            ...SyncSanitizer.coerceStringKeyMap(
              (payload.data['variants'] as List).single,
            ),
          }..remove('remoteFileId'),
        ],
      },
    );
    final oldPlan = sb.planMerge(
      local: await sb.exportSlice(localDeviceId: 'b'),
      remote: old,
    );
    expect(
      oldPlan.planData.variantsToUpsert.every(
        (v) => v.remoteFileId == remoteId,
      ),
      isTrue,
    );
    final conflict = SyncSlicePayload(
      sliceId: payload.sliceId,
      schemaVersion: payload.schemaVersion,
      exportedAtMs: payload.exportedAtMs,
      sourceDeviceId: payload.sourceDeviceId,
      data: {
        ...payload.data,
        'variants': [
          {
            ...SyncSanitizer.coerceStringKeyMap(
              (payload.data['variants'] as List).single,
            ),
            'remoteFileId': 'different-file',
          },
        ],
      },
    );
    final local = await sb.exportSlice(localDeviceId: 'b');
    expect(
      () => sb.planMerge(local: local, remote: conflict),
      throwsFormatException,
    );
    expect(
      b.library.mediaVariants.listBySource(sourceId).single.remoteFileId,
      remoteId,
    );
  });

  test('未知媒体源与携带凭据的云盘地址拒绝解析', () {
    final source = <String, Object?>{
      'id': 'source',
      'kind': 'futureProvider',
      'location': 'future://account',
    };
    expect(
      () => SyncLibrarySourceItem.tryFromJson(source),
      throwsFormatException,
    );
    for (final location in [
      'guangyapan://account_fixture/123?token=fixture',
      'guangyapan://user:secret@account_fixture/123',
    ]) {
      expect(
        () => SyncLibrarySourceItem.tryFromJson({
          ...source,
          'kind': 'cloudDrive',
          'location': location,
        }),
        throwsFormatException,
      );
    }
  });
}
