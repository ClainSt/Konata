import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

import '../support/test_helpers.dart';

void main() {
  test('云盘正片、CD 与扫图文件标识经过归集、持久化及复制后保持精确', () async {
    final db = openTestScrapeDatabase();
    final repo = db.repository;
    const source = 'cloud-fixture';
    await repo.upsertMediaSource(
      const MediaSource(
        id: source,
        kind: MediaSourceKind.cloudDrive,
        label: '云盘',
        location: 'guangyapan://fixture/',
      ),
    );
    const work = Work(id: 'work-fixture', title: '86');
    await repo.upsertWork(work);
    const files = [
      ScannedFileInput(
        relativePath: '86/86 - 01.mkv',
        fileName: '86 - 01.mkv',
        fileSize: 100,
        assetKind: AssetKind.video,
        remoteFileId: '9876543210987654321',
      ),
      ScannedFileInput(
        relativePath: '86/CDs/01.flac',
        fileName: '01.flac',
        fileSize: 20,
        assetKind: AssetKind.cdAlbum,
        remoteFileId: '9876543210987654322',
      ),
      ScannedFileInput(
        relativePath: '86/Scans/01.webp',
        fileName: '01.webp',
        fileSize: 10,
        assetKind: AssetKind.scanGallery,
        remoteFileId: '9876543210987654323',
      ),
      ScannedFileInput(
        relativePath: '86/86 - 02.mkv',
        fileName: '86 - 02.mkv',
        fileSize: 100,
        assetKind: AssetKind.video,
      ),
    ];
    final group = DirectoryGrouper.groupFiles(
      sourceId: source,
      files: files,
    ).single;
    final expected = {
      for (final file in files) file.relativePath: file.remoteFileId,
    };
    expect({
      for (final v in group.variants) v.relativePath: v.remoteFileId,
    }, expected);
    // 模拟旧库或审计测试库已有非确定性 ID：重扫必须沿用物理文件身份。
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'imported-episode-id',
        sourceId: source,
        workId: 'work-fixture',
        relativePath: '86/86 - 01.mkv',
        fileName: '86 - 01.mkv',
        fileSize: 100,
      ),
    );
    await ScrapeWorkPersister(repo).syncEpisodesAndVariants(
      work: work,
      folder: group,
      tmdbEpisodes: const [],
    );
    final loaded = await repo.getVariantsByWork(work.id);
    expect(loaded.length, files.length);
    expect(
      loaded.singleWhere((v) => v.relativePath == files.first.relativePath).id,
      'imported-episode-id',
    );
    await ScrapeWorkPersister(repo).syncEpisodesAndVariants(
      work: work,
      folder: group,
      tmdbEpisodes: const [],
    );
    expect((await repo.getVariantsByWork(work.id)).length, files.length);
    expect({for (final v in loaded) v.relativePath: v.remoteFileId}, expected);
    final records = db.bundle.library.mediaVariants.listBySource(
      const SourceId.trusted(source),
    );
    expect({for (final v in records) v.relativePath: v.remoteFileId}, expected);
    final copied = loaded.map((v) => v.copyWith(workLocked: true)).toList();
    await repo.upsertMediaVariantsBatch(copied);
    final reloaded = await repo.getVariantsByWork(work.id);
    expect({
      for (final v in reloaded) v.relativePath: v.remoteFileId,
    }, expected);
    expect(reloaded.every((v) => v.workLocked), isTrue);
  });
}
