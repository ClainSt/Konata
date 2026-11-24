import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

void main() {
  test('PhotosStorage 懒创建作品目录、读写扫图与统计清理', () async {
    final tempDir = await Directory.systemTemp.createTemp('konata_photos_');
    addTearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    final evicted = <String>[];
    final storage = PhotosStorage(
      overrideRoot: tempDir,
      onEvictImageFile: (file) async => evicted.add(file.path),
    );
    storage.cacheWorkTitle('work::86', '86 -不存在的战区-');

    // 纯只读未命中时绝不建空目录。
    final miss = await storage.readScanThumbnail(
      workId: 'work::86',
      variantId: 'v1',
      relativePath: 'Booklet/01.png',
      fileSize: 1024,
    );
    expect(miss, isNull);
    expect(tempDir.listSync(), isEmpty);

    // 编码一张合法 WebP 并落盘。
    final rgba = Uint8List(4 * 4 * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 0x20;
      rgba[i + 1] = 0x80;
      rgba[i + 2] = 0xE0;
      rgba[i + 3] = 0xFF;
    }
    final webp = CompactWebpEncoder.encodeRgba(rgba: rgba, width: 4, height: 4);
    expect(webp.length, greaterThan(12));
    expect(String.fromCharCodes(webp.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(webp.sublist(8, 12)), 'WEBP');

    await storage.writeScanThumbnail(
      workId: 'work::86',
      variantId: 'v1',
      relativePath: 'Booklet/01.png',
      fileSize: 1024,
      webpBytes: webp,
    );

    final hit = await storage.readScanThumbnail(
      workId: 'work::86',
      variantId: 'v1',
      relativePath: 'Booklet/01.png',
      fileSize: 1024,
    );
    expect(hit, webp);

    final stats = await storage.computeStats();
    expect(stats.workFolderCount, 1);
    expect(stats.regenerableFiles, 1);

    final cleared = await storage.clearCategories(
      const <PhotoStorageCategory>{PhotoStorageCategory.scans},
    );
    expect(cleared, 1);
    expect(evicted, hasLength(1));
  });

  test('ArtworkDiskCache 区分有归属持久化与无归属纯内存 LRU', () async {
    final tempDir = await Directory.systemTemp.createTemp('konata_artcache_');
    addTearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    final storage = PhotosStorage(overrideRoot: tempDir);
    final cache = ArtworkDiskCache(photosStorage: storage);
    final pngHeader = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02,
    ]);

    await cache.write('preview_1', pngHeader, quality: 1);
    expect(tempDir.listSync(), isEmpty);
    expect(await cache.read('preview_1'), pngHeader);

    await cache.write(
      'w500_/poster.png',
      pngHeader,
      owner: 'work_1',
      subfolder: PhotoSubfolder.posters,
      quality: 2,
    );
    cache.clearMemoryCache();
    expect(
      await cache.read(
        'w500_/poster.png',
        owner: 'work_1',
        subfolder: PhotoSubfolder.posters,
      ),
      pngHeader,
    );
  });
}
