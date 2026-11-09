import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_inspector.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'export preserves media indexes and progress but excludes credentials',
    () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': 'dark',
        'watched_completion_percent': 87,
        'detail_backdrop_enabled': false,
        'debug_logs': true,
        'metadata_server_0': 'https://private.example/token',
      });
      final dir = await Directory.systemTemp.createTemp('ccplayer-export-');
      final artwork = Directory('${dir.path}/artwork');
      final destination = File('${dir.path}/snapshot.zip');
      final catalog = Catalog.instance;
      try {
        await catalog.initialize(dataDirectory: dir);
        await catalog.db.insert('sources', {
          'id': 's',
          'kind': 'webdav',
          'label': 'Cloud',
          'location':
              'https://alice:secret@example.com/dav?token=hidden&mode=readonly',
          'username': 'alice',
          'password': 'legacy-secret',
        });
        await catalog.db.insert('works', {'id': 'w', 'title': 'Anime'});
        await catalog.db.insert('assets', {
          'id': 'a',
          'source_id': 's',
          'work_id': 'w',
          'relative_path': '01.mkv',
          'name': '01.mkv',
          'category': 'main',
        });
        await catalog.db.insert('progress', {
          'asset_id': 'a',
          'position_ms': 12000,
          'duration_ms': 23000,
          'completed': 0,
          'updated_at': '2026-11-06T00:00:00Z',
          'watched_ranges': '[[0,12000]]',
        });
        await artwork.create();
        const fakeImage = [1, 2, 3, 4, 5];
        final digest = sha256.convert(fakeImage).toString();
        final filename = 'crop_$digest.png';
        await File('${artwork.path}/$filename').writeAsBytes(fakeImage);
        await File('${artwork.path}/cache_ignored').writeAsString('cached');
        final exporter = LibraryBackupExporter(
          database: catalog.db,
          artworkDirectory: artwork,
          preferences: await SharedPreferences.getInstance(),
        );
        await exporter.export(destination);
        final preview = await LibraryBackupInspector.inspect(destination);
        expect(preview.works, 1);
        expect(preview.assets, 1);
        expect(preview.sources, 1);
        expect(preview.history, 1);
        expect(preview.artwork, 1);
        final archive = ZipDecoder().decodeBytes(
          await destination.readAsBytes(),
        );
        expect(
          archive.files.map((f) => f.name),
          containsAll(['manifest.json', 'artwork/$filename']),
        );
        expect(archive.files.length, 2);
        final manifest =
            jsonDecode(
                  utf8.decode(
                    archive.files
                        .firstWhere((f) => f.name == 'manifest.json')
                        .content,
                  ),
                )
                as Map<String, dynamic>;
        final tables = manifest['tables'] as Map<String, dynamic>;
        final sources = (tables['sources'] as List).single as Map;
        expect(sources['location'], 'https://example.com/dav?mode=readonly');
        expect(sources['password'], isNull);
        expect(sources['username'], isNull);
        expect(
          (tables['progress'] as List).single['watched_ranges'],
          '[[0,12000]]',
        );
        expect(manifest['preferences'], {
          'theme_mode': 'dark',
          'watched_completion_percent': 87,
          'detail_backdrop_enabled': false,
        });
        expect(jsonEncode(manifest), isNot(contains('secret')));
        expect(jsonEncode(manifest), isNot(contains('token=hidden')));
        expect(jsonEncode(manifest), isNot(contains('metadata_server_0')));
        await expectLater(exporter.export(destination), throwsStateError);
      } finally {
        try {
          await catalog.db.close();
        } catch (_) {}
        await dir.delete(recursive: true);
      }
    },
  );

  test('redacts URL password and sensitive query keys', () {
    expect(
      LibraryBackupExporter.redactLocation(
        'https://user:pass@example.com/dav?api_key=a&folder=media&access_token=b',
      ),
      'https://example.com/dav?folder=media',
    );
  });

  test(
    'removes a query containing only secrets and preserves safe URL parts',
    () {
      expect(
        LibraryBackupExporter.redactLocation(
          'https://user:pass@example.com:8443/dav%20folder?TOKEN=secret&token=second&api_key=key#section',
        ),
        'https://example.com:8443/dav%20folder#section',
      );
      expect(
        LibraryBackupExporter.redactLocation('https://example.com/dav'),
        'https://example.com/dav',
      );
      expect(
        LibraryBackupExporter.redactLocation('D:/Media/Anime'),
        'D:/Media/Anime',
      );
    },
  );

  test(
    'keeps repeated non-sensitive query values when removing credentials',
    () {
      expect(
        LibraryBackupExporter.redactLocation(
          'https://example.com/dav?folder=one&token=secret&folder=two',
        ),
        'https://example.com/dav?folder=one&folder=two',
      );
    },
  );
}
