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

    final cleared = await storage.clearCategories(const <PhotoStorageCategory>{
      PhotoStorageCategory.scans,
    });
    expect(cleared, 1);
    expect(evicted, hasLength(1));
  });

  test('分类统计清理与新图片写入拒绝受管目录内的链接重定向', () async {
    final temp = await Directory.systemTemp.createTemp(
      'konata_photo_link_guard_',
    );
    final root = Directory('${temp.path}/photos')..createSync();
    final external = Directory('${temp.path}/external')..createSync();
    final protected = File('${external.path}/original.png')
      ..writeAsStringSync('外部文件');
    final storage = PhotosStorage(overrideRoot: root);
    final work = await storage.resolveWorkDirectory('w_link', title: '测试');
    work.createSync(recursive: true);
    final link = Link('${work.path}/thumbnails');
    if (Platform.isWindows) {
      final result = await Process.run('cmd.exe', [
        '/c',
        'mklink',
        '/J',
        link.path.replaceAll('/', r'\'),
        external.path.replaceAll('/', r'\'),
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
    } else {
      await link.create(external.path);
    }
    try {
      expect(
        await storage.listManagedCategoryFiles(
          workDirKey: work.uri.pathSegments.where((s) => s.isNotEmpty).last,
          category: PhotoStorageCategory.thumbnails,
        ),
        isEmpty,
      );
      expect((await storage.computeStats()).totalFiles, 0);
      final removed = await storage.clearSelectedCategories({
        PhotoStorageCategory.thumbnails,
      });
      expect(removed.removedFiles, 0);
      expect(removed.freedBytes, 0);
      await expectLater(
        storage.saveCustomArtwork(
          workId: 'w_link',
          subfolder: PhotoSubfolder.thumbnails,
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(protected.readAsStringSync(), '外部文件');
      expect(external.listSync(), hasLength(1));
    } finally {
      if (Platform.isWindows) {
        await Process.run('cmd.exe', [
          '/c',
          'rmdir',
          link.path.replaceAll('/', r'\'),
        ]);
      } else {
        await link.delete();
      }
      await temp.delete(recursive: true);
    }
  });
  test('精准清理仅允许当前作品受管子目录内的图片，保护外部与其他作品', () async {
    final temp = await Directory.systemTemp.createTemp('konata_photo_guard_');
    addTearDown(() => temp.delete(recursive: true));
    final root = Directory('${temp.path}/photos')..createSync();
    final storage = PhotosStorage(overrideRoot: root);
    final own = await storage.resolveSubfolderDirectory(
      'w1',
      PhotoSubfolder.thumbnails,
      title: '作品甲',
    );
    final other = await storage.resolveSubfolderDirectory(
      'w2',
      PhotoSubfolder.thumbnails,
      title: '作品乙',
    );
    final wrongSlot = await storage.resolveSubfolderDirectory(
      'w1',
      PhotoSubfolder.backdrops,
    );
    for (final dir in [own, other, wrongSlot]) {
      dir.createSync(recursive: true);
    }
    final external = File('${temp.path}/video_still_legacy.png')
      ..writeAsStringSync('原始图片');
    final sibling = File('${other.path}/video_still_legacy.png')
      ..writeAsStringSync('其他作品');
    final backdrop = File('${wrongSlot.path}/video_still_legacy.png')
      ..writeAsStringSync('其他槽位');
    final owned = File('${own.path}/video_still_legacy.png')
      ..writeAsStringSync('可清理缓存');
    Future<bool> remove(String path) => storage.deleteManagedArtworkFile(
      workId: 'w1',
      subfolder: PhotoSubfolder.thumbnails,
      path: path,
    );
    expect(await remove(external.path), isFalse);
    expect(await remove(sibling.path), isFalse);
    expect(await remove(backdrop.path), isFalse);
    expect(await remove('video_still_legacy.png'), isFalse);
    expect(
      await remove('${own.path}/../../../video_still_legacy.png'),
      isFalse,
    );
    expect(await remove(owned.path), isTrue);
    expect(await remove(owned.path), isFalse);
    expect(external.readAsStringSync(), '原始图片');
    expect(sibling.readAsStringSync(), '其他作品');
    expect(backdrop.readAsStringSync(), '其他槽位');
    expect(owned.existsSync(), isFalse);
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
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x01,
      0x02,
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
