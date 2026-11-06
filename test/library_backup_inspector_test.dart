import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:ccplayer/core/library_backup_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backup reader rejects path traversal and unknown ZIP entries', () async {
    final temp = await Directory.systemTemp.createTemp('ccplayer-bad-zip-');
    try {
      final file = File('${temp.path}/malicious.zip');
      final zip = ZipFileEncoder();
      zip.create(file.path);
      zip.addArchiveFile(ArchiveFile.bytes('../outside.json', [1, 2]));
      zip.addArchiveFile(ArchiveFile.string('manifest.json', '{}'));
      await zip.close();
      await expectLater(
        LibraryBackupInspector.inspect(file),
        throwsA(isA<FormatException>()),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('backup reader rejects malformed schema and never extracts files', () async {
    final temp = await Directory.systemTemp.createTemp('ccplayer-bad-schema-');
    try {
      final file = File('${temp.path}/incompatible.zip');
      final zip = ZipFileEncoder();
      zip.create(file.path);
      zip.addArchiveFile(ArchiveFile.string('manifest.json', '{"format":"unknown"}'));
      await zip.close();
      await expectLater(
        LibraryBackupInspector.inspect(file),
        throwsA(isA<FormatException>()),
      );
      expect(await temp.list().length, 1);
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
