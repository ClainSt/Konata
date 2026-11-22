import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/work_management_provider.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/cache/artwork_cache.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';

void main() {
  group('PhotosStorage 懒创建与作品重命名/合并/删除生命周期测试', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;
    late PhotosStorage photosStorage;
    late ProviderContainer container;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_photos_test_');
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
      photosStorage = PhotosStorage(overrideRoot: tempRoot);
      // 确保 tempRoot 尚未创建（由我们测试“初始无 photos 目录”先删除它）
      await tempRoot.delete(recursive: true);

      container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          photosStorageProvider.overrideWithValue(photosStorage),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('未写入图片前不预建空目录，搜索预览(ownerWorkId == null)仅驻留内存不落盘', () async {
      final cache = ArtworkCache.photos(photosStorage);
      final previewBytes = Uint8List.fromList([10, 20, 30, 40, 50]);

      // 只做路径计算与标题登记，绝不触发 mkdir
      await photosStorage.registerWorkTitle('tmdb::tv::100', '狼与香辛料:重制版');
      await photosStorage.resolveWorkDirectory(
        'tmdb::tv::100',
        title: '狼与香辛料:重制版',
      );
      expect(
        await photosStorage.readArtwork(
          workId: 'tmdb::tv::100',
          title: '狼与香辛料:重制版',
          subfolder: PhotoSubfolder.posters,
          fileKey: 'k1',
        ),
        isNull,
      );
      expect(await tempRoot.exists(), isFalse);

      // ownerWorkId == null 的搜索预览图仅进内存 LRU
      await cache.write(
        'w500_/search_preview_1.jpg',
        previewBytes,
        owner: null,
        subfolder: PhotoSubfolder.posters,
      );
      final cachedPreview = await cache.read(
        'w500_/search_preview_1.jpg',
        owner: null,
        subfolder: PhotoSubfolder.posters,
      );
      expect(cachedPreview, equals(previewBytes));
      expect(await tempRoot.exists(), isFalse);

      // 当传入具体 ownerWorkId 时才按需懒创建对应作品目录及子目录落盘
      await cache.write(
        'original_/real_backdrop_1.jpg',
        Uint8List.fromList([1, 2, 3, 4]),
        owner: 'tmdb::tv::100',
        subfolder: PhotoSubfolder.backdrops,
      );
      expect(await tempRoot.exists(), isTrue);
      final workDir = await photosStorage.resolveWorkDirectory(
        'tmdb::tv::100',
        title: '狼与香辛料:重制版',
      );
      // 验证非法 Windows 字符（冒号）已被清洗替换
      expect(p.basename(workDir.path).contains(':'), isFalse);
      final bdDir = Directory(p.join(workDir.path, 'backdrops'));
      expect(await bdDir.exists(), isTrue);
      // 未写入的其它子目录（posters/logos/thumbnails/scans）不得创建空目录
      expect(await Directory(p.join(workDir.path, 'scans')).exists(), isFalse);
      expect(
        await Directory(p.join(workDir.path, 'thumbnails')).exists(),
        isFalse,
      );
    });

    test('重命名作品同步更名 photos 目录、合并作品迁移合并资产、删除作品自动清理文件夹', () async {
      const srcId = 'work::source::1';
      const dstId = 'work::target::2';
      await repo.upsertWork(
        const Work(id: srcId, title: '旧番剧名', scrapeStatus: ScrapeStatus.matched),
      );
      await repo.upsertWork(
        const Work(id: dstId, title: '目标正片作品', scrapeStatus: ScrapeStatus.matched),
      );
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_local',
          kind: MediaSourceKind.local,
          label: '本地测试源',
          location: 'D:/Anime',
        ),
      );

      await repo.upsertEpisode(
        const Episode(
          id: 'ep_src_1',
          workId: srcId,
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '第 1 话',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_src_1',
          workId: srcId,
          episodeId: 'ep_src_1',
          sourceId: 'src_local',
          relativePath: 'Old/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
        ),
      );

      // 分别为 src 写入封面、为 dst 写入背景图
      await photosStorage.writeArtwork(
        workId: srcId,
        title: '旧番剧名',
        subfolder: PhotoSubfolder.posters,
        fileKey: 'poster_src.jpg',
        bytes: Uint8List.fromList([7, 8, 9]),
      );
      await photosStorage.writeArtwork(
        workId: dstId,
        title: '目标正片作品',
        subfolder: PhotoSubfolder.backdrops,
        fileKey: 'backdrop_dst.jpg',
        bytes: Uint8List.fromList([11, 12, 13]),
      );

      // 1. 重命名源作品 -> 验证 photos 目录名同步改名，原图保留
      final actions = container.read(workManagementProvider);
      await actions.updateWorkManualMetadata(
        workId: srcId,
        title: '新番剧名/第一季',
      );
      final renamedDir = await photosStorage.resolveWorkDirectory(
        srcId,
        title: '新番剧名/第一季',
      );
      expect(await renamedDir.exists(), isTrue);
      expect(
        p.basename(renamedDir.path).startsWith('新番剧名 第一季'),
        isTrue,
      );
      final statsAfterRename = await photosStorage.computeStats();
      expect(statsAfterRename.workFolderCount, 2);

      // 2. 将 src 合并进 dst -> 验证 src 目录清理、posters 迁移到 dst、变体全部迁移、src 从库中删除
      final mergeOutcome = await actions.mergeWorkIntoExisting(
        sourceWorkId: srcId,
        targetWorkId: dstId,
      );
      expect(mergeOutcome.movedVariantCount, 1);
      expect(await repo.findWorkById(srcId), isNull);
      expect(await renamedDir.exists(), isFalse);

      final dstDir = await photosStorage.resolveWorkDirectory(
        dstId,
        title: '目标正片作品',
      );
      expect(await Directory(p.join(dstDir.path, 'posters')).exists(), isTrue);
      expect(
        await Directory(p.join(dstDir.path, 'backdrops')).exists(),
        isTrue,
      );
      final statsAfterMerge = await photosStorage.computeStats();
      expect(statsAfterMerge.workFolderCount, 1);
      expect(statsAfterMerge.totalFiles, 2);

      // 3. 删除目标作品 -> 验证数据库与 photos 对应作品目录同步移除
      await actions.deleteWorkFromLibrary(dstId);
      expect(await repo.findWorkById(dstId), isNull);
      expect(await dstDir.exists(), isFalse);
      final statsAfterDelete = await photosStorage.computeStats();
      expect(statsAfterDelete.workFolderCount, 0);
      expect(statsAfterDelete.totalFiles, 0);
    });
  });
}
