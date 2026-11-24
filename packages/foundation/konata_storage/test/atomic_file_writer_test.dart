import 'dart:io';

import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('AtomicFileWriter 支持首次原子发布与覆写既有目标文件', () async {
    final dir = await Directory.systemTemp.createTemp('konata_atomic_writer_');
    addTearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });

    final target = File(p.join(dir.path, 'cache.bin'));
    final part1 = File(p.join(dir.path, 'cache.bin.part1'));
    await part1.writeAsString('v1-content');
    await AtomicFileWriter.replaceFile(part1, target);

    expect(target.existsSync(), isTrue);
    expect(part1.existsSync(), isFalse);
    expect(await target.readAsString(), 'v1-content');

    final part2 = File(p.join(dir.path, 'cache.bin.part2'));
    await part2.writeAsString('v2-updated-content');
    await AtomicFileWriter.replaceFile(part2, target);

    expect(await target.readAsString(), 'v2-updated-content');
    expect(part2.existsSync(), isFalse);
  });
}
