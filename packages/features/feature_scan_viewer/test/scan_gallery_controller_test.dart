import 'dart:io';

import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  group('ScanGalleryController 与 DetailTabContribution 声明测试', () {
    late KonataDatabaseBundle databases;
    late ScopedPrefsStore prefsStore;
    late Directory tempPhotos;
    late ScanThumbnailScheduler scheduler;

    setUp(() async {
      databases = KonataDatabaseBundle.openInMemory();
      prefsStore = ScopedPrefsStore(databases.userState);
      tempPhotos = await Directory.systemTemp.createTemp('konata_ctrl_test_');
      scheduler = ScanThumbnailScheduler(
        photosStorage: PhotosStorage(overrideRoot: tempPhotos),
      );
    });

    tearDown(() async {
      scheduler.dispose();
      await databases.close();
      if (tempPhotos.existsSync()) {
        await tempPhotos.delete(recursive: true);
      }
    });

    test('查询作品自身扫图与同系列 seriesShared 扫图，并排除他作独占扫图', () async {
      final srcLocal = MediaSourceRecord(
        id: SourceId('src_1'),
        kind: MediaSourceKind.local,
        label: '本地测试源',
        location: tempPhotos.path,
      );
      databases.library.mediaSources.upsert(srcLocal);

      databases.library.seriesGroups.upsert(
        SeriesGroupRecord(id: SeriesGroupId('series_1'), title: '测试系列'),
      );

      final workA = WorkRecord(
        id: WorkId('work_a'),
        title: '第一季',
        seriesId: SeriesGroupId('series_1'),
        seriesOrder: 1,
        tmdbId: 1001,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      final workB = WorkRecord(
        id: WorkId('work_b'),
        title: '第二季',
        seriesId: SeriesGroupId('series_1'),
        seriesOrder: 2,
        tmdbId: 1001,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 2,
      );
      final workOther = WorkRecord(id: WorkId('work_other'), title: '无关作品');
      databases.library.works.upsert(workA);
      databases.library.works.upsert(workB);
      databases.library.works.upsert(workOther);

      databases.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId('v_a1'),
          workId: workA.id,
          sourceId: srcLocal.id,
          relativePath: 'Season1/Scans/Vol.1/01.png',
          fileName: '01.png',
          fileSize: 1024,
          assetKind: AssetKind.scanGallery,
        ),
      );
      databases.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId('v_a2'),
          workId: workA.id,
          sourceId: srcLocal.id,
          relativePath: 'Season1/Scans/Vol.2/02.png',
          fileName: '02.png',
          fileSize: 2048,
          assetKind: AssetKind.scanGallery,
        ),
      );
      // 非扫图视频文件必须被过滤。
      databases.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId('v_video'),
          workId: workA.id,
          sourceId: srcLocal.id,
          relativePath: 'Season1/EP01.mkv',
          fileName: 'EP01.mkv',
          fileSize: 4096,
          assetKind: AssetKind.video,
        ),
      );
      // 同系列作品 B 的系列共用扫图应纳入，独享扫图应过滤。
      databases.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId('v_b_shared'),
          workId: workB.id,
          sourceId: srcLocal.id,
          relativePath: 'Season2/Scans/Box/booklet.png',
          fileName: 'booklet.png',
          fileSize: 3072,
          assetKind: AssetKind.scanGallery,
          assetScope: SupplementaryAssetScope.seriesShared,
        ),
      );
      databases.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: VariantId('v_b_exclusive'),
          workId: workB.id,
          sourceId: srcLocal.id,
          relativePath: 'Season2/Scans/Vol.1/b_only.png',
          fileName: 'b_only.png',
          fileSize: 3072,
          assetKind: AssetKind.scanGallery,
          assetScope: SupplementaryAssetScope.workExclusive,
        ),
      );

      final controller = ScanGalleryController(
        databases: databases,
        scopedPrefs: prefsStore,
        scheduler: scheduler,
        photosStorage: PhotosStorage(overrideRoot: tempPhotos),
      );
      addTearDown(controller.dispose);

      await controller.loadWork(workA.id, prewarmAspectRatios: false);

      expect(controller.state.workTitle, '第一季');
      expect(controller.state.showSeriesSharedBadge, isTrue);
      expect(controller.state.allScans.map((v) => v.id).toList(), [
        'v_a1',
        'v_a2',
        'v_b_shared',
      ]);
      expect(controller.state.sourcesById.containsKey('src_1'), isTrue);
      expect(controller.state.scanSummary.chips.length, 3);

      // 切换二级分卷筛选并核验过滤结果。
      final firstChipKey = controller.state.scanSummary.chips.first.key;
      controller.selectVolume(firstChipKey);
      expect(controller.state.selectedVolumeKey, firstChipKey);
      expect(controller.state.visibleScans.length, 1);

      // 验证静态可用性判定方法与动态清单扩展点。
      expect(
        ScanViewerAvailability.hasScansForWork(databases, workA.id),
        isTrue,
      );
      expect(ScanViewerAvailability.countScansForWork(databases, workA.id), 3);
      expect(
        ScanViewerAvailability.hasScansForWork(databases, workOther.id),
        isFalse,
      );

      final dynamicManifest = createFeatureScanViewerManifest(
        databases: databases,
      );
      final tab = dynamicManifest.detailTabs.single;
      expect(tab.id, 'scan_viewer');
      expect(tab.label, 'Scan');
      expect(tab.iconKey, 'scan_viewer');
      expect(tab.order, 40);
      expect(await tab.isVisibleForWork!(workA.id), isTrue);
      expect(await tab.isVisibleForWork!(workOther.id), isFalse);

      // 共享范围仅修改数据库索引，当前已打开的画廊必须即时刷新。
      Future<void> settle() async {
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }

      await settle();
      final sharedKey =
          controller.state.scanSummary.byVariantId['v_b_shared']!.volumeKey;
      controller.selectVolume(sharedKey);
      void writeShared(SupplementaryAssetScope scope) {
        databases.library.mediaVariants.upsert(
          MediaVariantRecord(
            id: VariantId('v_b_shared'),
            workId: workB.id,
            sourceId: srcLocal.id,
            relativePath: 'Season2/Scans/Box/booklet.png',
            fileName: 'booklet.png',
            fileSize: 3072,
            assetKind: AssetKind.scanGallery,
            assetScope: scope,
            scopeLocked: true,
          ),
        );
      }

      writeShared(SupplementaryAssetScope.workExclusive);
      await settle();
      expect(controller.state.allScans.map((v) => v.id), ['v_a1', 'v_a2']);
      expect(controller.state.selectedVolumeKey, isNull);
      expect(controller.state.visibleScans.length, 2);
      expect(ScanViewerAvailability.countScansForWork(databases, workA.id), 2);
      writeShared(SupplementaryAssetScope.seriesShared);
      await settle();
      expect(controller.state.allScans.length, 3);
      expect(controller.state.selectedVolumeKey, isNull);

      // 仅修改系列编组，不写 media_variants；旧画廊不能保留已脱离系列的资源。
      databases.library.works.upsert(
        WorkRecord(
          id: workB.id,
          title: workB.title,
          tmdbId: workB.tmdbId,
          tmdbMediaType: workB.tmdbMediaType,
          matchedSeason: workB.matchedSeason,
        ),
      );
      await settle();
      expect(controller.state.allScans.map((v) => v.id), [
        'v_a1',
        'v_a2',
      ], reason: '作品脱离系列后画廊应即时移除共享资源');
      expect(controller.state.showSeriesSharedBadge, isFalse);
      expect(ScanViewerAvailability.countScansForWork(databases, workA.id), 2);
      databases.library.works.upsert(workB);
      await settle();
      expect(controller.state.allScans.length, 3);
      expect(controller.state.showSeriesSharedBadge, isTrue);
      await controller.loadWork(workB.id, prewarmAspectRatios: false);
      expect(controller.state.allScans.map((v) => v.id), [
        'v_b_shared',
        'v_b_exclusive',
      ]);
      writeShared(SupplementaryAssetScope.workExclusive);
      await settle();
      expect(controller.state.allScans.length, 2);
      expect(controller.state.workId, workB.id);

      final manual = ScanGalleryController(
        databases: databases,
        scopedPrefs: prefsStore,
        scheduler: scheduler,
        autoWatchDatabase: false,
      );
      addTearDown(manual.dispose);
      await manual.loadWork(workA.id, prewarmAspectRatios: false);
      expect(manual.state.allScans.length, 2);
      writeShared(SupplementaryAssetScope.seriesShared);
      await settle();
      expect(manual.state.allScans.length, 2);
      await manual.reload(prewarmAspectRatios: false);
      expect(manual.state.allScans.length, 3);
    });

    test('画廊双模式与密度偏好持久化至 ScopedPrefsStore 并在重建后恢复', () async {
      final controller1 = ScanGalleryController(
        databases: databases,
        scopedPrefs: prefsStore,
        scheduler: scheduler,
      );
      expect(controller1.state.mode, ScanGalleryMode.uniformFrame);
      expect(controller1.state.density, ScanGalleryDensity.standard);

      controller1.setMode(ScanGalleryMode.justified);
      controller1.setDensity(ScanGalleryDensity.large);
      expect(controller1.state.mode, ScanGalleryMode.justified);
      expect(controller1.state.density, ScanGalleryDensity.large);
      controller1.dispose();

      // 重建控制器验证偏好已从数据库恢复。
      final controller2 = ScanGalleryController(
        databases: databases,
        scopedPrefs: prefsStore,
        scheduler: scheduler,
      );
      addTearDown(controller2.dispose);
      expect(controller2.state.mode, ScanGalleryMode.justified);
      expect(controller2.state.density, ScanGalleryDensity.large);
      expect(
        prefsStore.read(scanGalleryPrefsSlice),
        const ScanGalleryPrefs(
          mode: ScanGalleryMode.justified,
          density: ScanGalleryDensity.large,
        ),
      );
    });
  });
}
