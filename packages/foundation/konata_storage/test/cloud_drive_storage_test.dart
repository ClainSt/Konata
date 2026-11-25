import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

void main() {
  test('历史库迁移保留原记录，云盘文件 ID 可空且可更新', () async {
    final root = Directory.systemTemp.createTempSync('konata-cloud-migration-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/library.db';
    final old = KonataSqliteEngine.openFile(
      filePath: path,
      databaseName: 'library',
      migrations: LibraryMigrations.steps
          .where((s) => s.targetVersion <= 2)
          .toList(),
    );
    old.execute('ALTER TABLE media_variants DROP COLUMN remote_file_id;');
    old.execute(
      "INSERT INTO media_sources (id,kind,label,location) VALUES ('source','webdav','旧源','https://example.invalid/dav');",
    );
    old.execute("INSERT INTO works (id,title) VALUES ('work','旧作品');");
    old.execute(
      "INSERT INTO media_variants (id,work_id,source_id,relative_path,file_name,file_size) VALUES ('variant','work','source','01.mkv','01.mkv',100);",
    );
    await old.close();

    final db = LibraryDatabase.openFile(path);
    addTearDown(db.close);
    final id = VariantId('variant');
    expect(db.engine.select('PRAGMA user_version;').single.values.first, 4);
    expect(db.mediaVariants.findById(id)?.fileSize, 100);
    expect(db.mediaVariants.findById(id)?.remoteFileId, isNull);
    db.mediaVariants.upsert(
      MediaVariantRecord(
        id: id,
        workId: WorkId('work'),
        sourceId: SourceId('source'),
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 100,
        remoteFileId: '9876543210987654321',
      ),
    );
    expect(db.mediaVariants.findById(id)?.remoteFileId, '9876543210987654321');
    expect(
      db.mediaVariants.listBySource(SourceId('source')).single.remoteFileId,
      '9876543210987654321',
    );
  });

  test('云盘目录快照按源隔离并原子替换，缓存仍惰性打开', () async {
    final bundle = KonataDatabaseBundle.openInMemory();
    addTearDown(bundle.close);
    expect(bundle.isCacheOpen, isFalse);
    final a = SourceId('cloud-a');
    final b = SourceId('cloud-b');
    CloudDriveEntryRecord entry(SourceId source, String name) =>
        CloudDriveEntryRecord(
          sourceId: source,
          fileId: 'same-id',
          parentId: 'root',
          name: name,
          isDirectory: false,
          size: 10,
          listedAtMs: 1,
        );
    final dao = bundle.cache.cloudDriveEntries;
    expect(bundle.isCacheOpen, isTrue);
    dao.replaceDirectory(a, 'root', [entry(a, 'a.mkv')]);
    dao.replaceDirectory(b, 'root', [entry(b, 'b.mkv')]);
    expect(dao.find(a, 'same-id')?.name, 'a.mkv');
    expect(dao.find(b, 'same-id')?.name, 'b.mkv');
    expect(
      () => dao.replaceDirectory(a, 'root', [entry(b, 'wrong.mkv')]),
      throwsArgumentError,
    );
    expect(dao.listDirectory(a, 'root').single.name, 'a.mkv');
    dao.replaceDirectory(a, 'root', []);
    expect(dao.find(a, 'same-id'), isNull);
    expect(dao.find(b, 'same-id')?.name, 'b.mkv');
    dao.clearSource(b);
    expect(dao.find(b, 'same-id'), isNull);
  });
}
