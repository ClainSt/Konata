import 'dart:io';
import 'dart:convert';
import 'package:ccplayer/core/metadata.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:path_provider_windows/src/portable_data.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';

class _TestPaths extends PathProviderWindows {
  _TestPaths(this.executablePath, this.legacy);
  @override
  final String executablePath;
  final Directory legacy;
  @override
  Future<String?> getPath(String folderID) async => legacy.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unavailable credentials do not block library startup', () async {
    await Metadata.loadCredentials((key) async {
      if (key == 'tmdb_token') return 'synthetic-token';
      throw const FileSystemException('Synthetic unavailable store');
    });
    expect(Metadata.token, isEmpty);
    expect(Metadata.apiKey, isEmpty);
    expect(Metadata.authMode, 'token');
  });
  if (!Platform.isWindows) return;
  test(
    'a live WAL database is not imported while SQLite holds its locks',
    () async {
      sqfliteFfiInit();
      final root = await (await Directory(
        'build/portable-path-tests',
      ).absolute.create(recursive: true)).createTemp('wal-');
      final legacy = await Directory(p.join(root.path, 'legacy')).create();
      final db = await databaseFactoryFfi.openDatabase(
        p.join(legacy.absolute.path, 'ccplayer.db'),
      );
      try {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute('CREATE TABLE sample (value TEXT)');
        await db.insert('sample', {'value': 'preserved'});
        expect(await File(p.join(legacy.path, 'ccplayer.db')).exists(), true);
        final target = Directory(p.join(root.path, 'userdata'));
        await expectLater(
          preparePortableData(target, legacy),
          throwsA(isA<FileSystemException>()),
        );
        expect(await target.exists(), false);
        await db.close();
        await preparePortableData(target, legacy);
        final migrated = await databaseFactoryFfi.openDatabase(
          p.join(target.absolute.path, 'ccplayer.db'),
        );
        try {
          expect(await migrated.query('sample'), [
            {'value': 'preserved'},
          ]);
        } finally {
          await migrated.close();
        }
      } finally {
        if (db.isOpen) await db.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'unreadable portable ciphertext is retained and can be explicitly replaced',
    () async {
      final root = await (await Directory(
        'build/portable-path-tests',
      ).absolute.create(recursive: true)).createTemp('unreadable-');
      try {
        final original = File(
          p.join(root.path, '${base64Url.encode(utf8.encode('key'))}.bin'),
        );
        await original.writeAsBytes([1, 2, 3]);
        final storage = FlutterSecureStorageWindows(
          directory: root,
          readLegacy: (_) =>
              throw StateError('Must not re-import over unreadable file'),
        );
        expect(await storage.read(key: 'key', options: {}), isNull);
        expect(await original.readAsBytes(), [1, 2, 3]);
        await storage.write(key: 'key', value: 'replacement', options: {});
        expect(await storage.read(key: 'key', options: {}), 'replacement');
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
  test(
    'Windows support and temporary files follow the executable, not cwd or AppData',
    () async {
      final base = await Directory(
        'build/portable-path-tests',
      ).absolute.create(recursive: true);
      final root = await base.createTemp('paths-');
      try {
        final executable = p.join(root.path, 'portable', 'Konata.exe');
        final paths = _TestPaths(
          executable,
          Directory(p.join(root.path, 'legacy')),
        );
        final support = await paths.getApplicationSupportPath();
        final temp = await paths.getTemporaryPath();
        expect(support, p.join(p.dirname(executable), 'userdata'));
        expect(temp, p.join(p.dirname(executable), 'cache', 'tmp'));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'legacy data copies once without overwriting portable data or deleting the original',
    () async {
      final root = await (await Directory(
        'build/portable-path-tests',
      ).absolute.create(recursive: true)).createTemp('migration-');
      try {
        final legacy = await Directory(p.join(root.path, 'legacy')).create();
        await File(
          p.join(legacy.path, 'ccplayer.db'),
        ).writeAsString('existing library');
        await Directory(p.join(legacy.path, 'artwork')).create();
        await File(
          p.join(legacy.path, 'artwork', 'original.png'),
        ).writeAsBytes([1, 2, 3]);
        final target = Directory(p.join(root.path, 'portable', 'userdata'));
        await preparePortableData(target, legacy);
        expect(
          await File(p.join(target.path, 'ccplayer.db')).readAsString(),
          'existing library',
        );
        expect(
          await File(p.join(legacy.path, 'ccplayer.db')).readAsString(),
          'existing library',
        );
        await File(
          p.join(target.path, 'ccplayer.db'),
        ).writeAsString('newer portable library');
        await preparePortableData(target, legacy);
        expect(
          await File(p.join(target.path, 'ccplayer.db')).readAsString(),
          'newer portable library',
        );
        expect(
          await root
              .list(recursive: true)
              .where((e) => p.basename(e.path).startsWith('.konata-import-'))
              .length,
          0,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'portable encrypted credentials survive folder moves and deletion never reimports legacy secrets',
    () async {
      final root = await (await Directory(
        'build/portable-path-tests',
      ).absolute.create(recursive: true)).createTemp('secrets-');
      var legacyReads = 0;
      Future<String?> legacy(String _) async {
        legacyReads++;
        return 'synthetic-secret';
      }

      try {
        final directory = Directory(p.join(root.path, 'secrets'));
        final storage = FlutterSecureStorageWindows(
          directory: directory,
          readLegacy: legacy,
        );
        expect(
          await storage.read(key: 'test-key', options: {}),
          'synthetic-secret',
        );
        await storage.write(
          key: 'test-key',
          value: 'changed-secret',
          options: {},
        );
        expect(
          await storage.read(key: 'test-key', options: {}),
          'changed-secret',
        );
        final bytes = await directory
            .list()
            .where((e) => e is File)
            .cast<File>()
            .first
            .then((f) => f.readAsBytes());
        expect(String.fromCharCodes(bytes), isNot(contains('changed-secret')));
        final moved = await directory.rename(p.join(root.path, 'moved'));
        final reopened = FlutterSecureStorageWindows(
          directory: moved,
          readLegacy: legacy,
        );
        expect(
          await reopened.read(key: 'test-key', options: {}),
          'changed-secret',
        );
        await reopened.delete(key: 'test-key', options: {});
        expect(await reopened.read(key: 'test-key', options: {}), isNull);
        expect(legacyReads, 1);
        await reopened.deleteAll(options: {});
        expect(await reopened.read(key: 'other-key', options: {}), isNull);
        expect(legacyReads, 1);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
  test(
    'a locked legacy database aborts migration without publishing a partial portable library',
    () async {
      final root = await (await Directory(
        'build/portable-path-tests',
      ).absolute.create(recursive: true)).createTemp('locked-');
      final legacy = await Directory(p.join(root.path, 'legacy')).create();
      final db = await File(
        p.join(legacy.path, 'ccplayer.db'),
      ).writeAsString('keep');
      final handle = await db.open();
      try {
        await handle.lock(FileLock.exclusive);
        final target = Directory(p.join(root.path, 'userdata'));
        await expectLater(
          preparePortableData(target, legacy),
          throwsA(isA<FileSystemException>()),
        );
        expect(await target.exists(), false);
      } finally {
        await handle.close();
        expect(await db.readAsString(), 'keep');
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
