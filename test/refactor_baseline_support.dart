import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Isolated synthetic data only; never opens the application's normal database.
Future<void> openBaselineCatalog(Directory root) async {
  SharedPreferences.setMockInitialValues({});
  await Catalog.instance.initialize(
    dataDirectory: root,
    enableFoundation: true,
    enableTasks: true,
    enableMappings: true,
    enableRecognition: true,
    enableScopedArtwork: true,
    enableChapterRelations: true,
    enableLibraryMerge: true,
  );
}

Future<void> closeBaselineCatalog() async {
  final catalog = Catalog.instance;
  catalog.taskStore?.dispose();
  catalog.taskStore = null;
  catalog.mappingStore = null;
  await catalog.db.close();
}

Future<void> seedBaselineCatalog(int count) async {
  final db = Catalog.instance.db;
  await db.transaction((tx) async {
    await tx.insert('sources', {
      'id': 'baseline-source',
      'kind': 'local',
      'label': 'Synthetic fixture',
      'location': 'Z:/nonexistent-konata-baseline',
    });
    final batch = tx.batch();
    for (var i = 0; i < count; i++) {
      batch.insert('works', {'id': 'w$i', 'title': 'Fixture $i'});
      batch.insert('assets', {
        'id': 'a$i',
        'work_id': 'w$i',
        'source_id': 'baseline-source',
        'relative_path': 'Series$i/E01.mkv',
        'name': 'E01.mkv',
        'category': 'main',
        'episode': 1,
        'size': 1024,
      });
      batch.insert('progress', {
        'asset_id': 'a$i',
        'position_ms': 1000,
        'duration_ms': 24000,
        'completed': 0,
        'updated_at': '2026-01-01T00:00:00Z',
        'watched_ranges': '[[0,1000]]',
      });
    }
    await batch.commit(noResult: true);
    await LibraryFoundation.seed(tx);
  });
}
