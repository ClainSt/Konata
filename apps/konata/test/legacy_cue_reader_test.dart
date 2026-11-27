import 'dart:io';

import 'package:engine_sources/engine_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/feature_registry.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  test('宿主从已索引本机清单读取真实 CUE，拒绝文件变化和越权引用', () async {
    final root = await Directory.systemTemp.createTemp('konata_legacy_cue_');
    addTearDown(() => root.delete(recursive: true));
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final gateway = MediaSourceGatewayFactory();
    const source = SourceId.trusted('audit-source');
    const work = WorkId.trusted('audit-work');
    const id = VariantId.trusted('audit-cue');
    db.library.mediaSources.upsert(
      MediaSourceRecord(
        id: source,
        kind: MediaSourceKind.local,
        label: '隔离测试',
        location: root.path,
      ),
    );
    db.library.works.upsert(const WorkRecord(id: work, title: '隔离作品'));
    final file = File('${root.path}/album.cue');
    Future<void> write(String content) async {
      await file.writeAsString(content);
      db.library.mediaVariants.upsert(
        MediaVariantRecord(
          id: id,
          workId: work,
          sourceId: source,
          relativePath: 'album.cue',
          fileName: 'album.cue',
          fileSize: await file.length(),
          assetKind: AssetKind.cdAlbum,
        ),
      );
    }

    const cue = '''
FILE "album.flac" WAVE
  TRACK 01 AUDIO
    TITLE "First"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Second"
    INDEX 01 00:30:00
''';
    Future<List<({int number, String title, String fileName})>?> read(
      String value,
    ) => readIndexedLegacyCue(db, gateway, value);
    await write(cue);
    expect(await read('unknown'), isNull);
    final tracks = await read(id.value);
    expect(tracks, [
      (number: 1, title: 'First', fileName: 'album.flac'),
      (number: 2, title: 'Second', fileName: 'album.flac'),
    ]);
    await file.writeAsString('$cue\nREM modified');
    expect(await read(id.value), isNull);
    await write(cue.replaceAll('album.flac', '../album.flac'));
    expect(await read(id.value), isNull);
    await write(cue.replaceAll('INDEX 01 00:30:00', 'REM no index'));
    expect(await read(id.value), isNull);
  });
}
