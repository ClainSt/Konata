import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_foundation.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_inspector.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/watch_event_store.dart';
import 'package:ccplayer/core/watched_timeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cat = Catalog.instance;
  late Directory root;
  late String assetId, workId;
  const key = 'tmdb:tv:42:s1:e1';
  Future<void> reopen({bool enabled = true}) async {
    await cat.db.close();
    await cat.initialize(dataDirectory: root, enableFoundation: enabled);
  }

  Future<void> watch() => cat.progress(
    assetId,
    90000,
    100000,
    watchedRanges: [const WatchedRange(0, 90000)],
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('konata-foundation-');
    await cat.initialize(dataDirectory: root);
    await cat.db.insert('sources', {
      'id': 's',
      'kind': 'local',
      'label': 'Fixture',
      'location': 'synthetic',
    });
    await cat.indexVideo('s', 'Series/01.mkv', 100, workFolder: 'Series');
    final asset = (await cat.db.query('assets')).single;
    assetId = asset['id'] as String;
    workId = asset['work_id'] as String;
    await cat.db.update(
      'works',
      {'tmdb_id': 42, 'tmdb_type': 'tv'},
      where: 'id=?',
      whereArgs: [workId],
    );
    await cat.logicalEpisodes.confirm(assetId, key);
    await watch();
    expect((await WatchEventStore(cat.db).uploadCandidate(key)).ready, isTrue);
  });
  tearDown(() async {
    if (cat.db.isOpen) await cat.db.close();
    await root.delete(recursive: true);
  });
  Future<Map<String, List<Map<String, Object?>>>> snapshot() async => {
    for (final t in LibraryBackupExporter.tablesForSchema(
      await cat.db.getVersion(),
    ))
      t: await cat.db.query(t),
  };
  test(
    '18 to 19 preserves IDs, references, events and unknown whole-work lock',
    () async {
      await cat.db.update(
        'works',
        {'manual_lock': 1, 'manual_cover_url': 'artwork:custom'},
        where: 'id=?',
        whereArgs: [workId],
      );
      final before = await snapshot();
      await reopen();
      expect(await cat.db.getVersion(), 19);
      for (final t in before.keys) {
        expect(await cat.db.query(t), before[t], reason: t);
      }
      final protection = (await cat.db.query('library_work_protection')).single;
      expect(protection['legacy_lock'], 1);
      expect(protection['identity_locked'], 1);
      final cover = await LibraryFoundation(
        cat.db,
      ).field(workId, 'manual_cover_url');
      expect(cover['mode'], 'manual');
      expect(jsonDecode(cover['manual_json'] as String), 'artwork:custom');
      await cat.indexVideo('s', 'Series/01.mkv', 100, workFolder: 'Series');
      expect(
        (await WatchEventStore(cat.db).uploadCandidate(key)).ready,
        isTrue,
      );
      expect(await cat.resumePosition(assetId), 90000);
      await reopen();
      expect(
        (await cat.db.query('library_work_protection')).single,
        protection,
      );
      await expectLater(
        LibraryFoundation(cat.db).writeField(
          workId,
          'overview',
          expectedScope: cover['scope'] as String,
          expectedBindingRevision: 0,
          expectedRevision: 0,
          mode: 'auto',
          value: 'automatic',
          automatic: true,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'new IDs are opaque; same path and normalization reuse, case remains distinct',
    () async {
      await reopen();
      await cat.indexVideo('s', 'New/01.mkv', 100, workFolder: 'New');
      final first = (await cat.db.query(
        'assets',
        where: 'relative_path=?',
        whereArgs: ['New/01.mkv'],
      )).single;
      expect(first['id'], startsWith('asset:s:id-'));
      expect(first['work_id'], startsWith('work:s:id-'));
      await cat.indexVideo('s', r'New\01.mkv', 100, workFolder: 'New');
      expect(await cat.db.query('assets'), hasLength(2));
      await cat.indexVideo('s', 'new/01.mkv', 100, workFolder: 'new');
      expect(await cat.db.query('assets'), hasLength(3));
    },
  );
  test(
    'reviewed directory move, stale scan rejection, old path reuse and reversible move',
    () async {
      await reopen();
      final f = LibraryFoundation(cat.db);
      await f.relocate(
        's',
        {assetId: 'Renamed/renamed.mkv'},
        expectedRevision: 0,
        workId: workId,
        workPath: 'Renamed',
      );
      await cat.indexVideo(
        's',
        'Renamed/renamed.mkv',
        100,
        workFolder: 'Renamed',
      );
      expect((await cat.db.query('assets')).single['id'], assetId);
      expect((await cat.db.query('assets')).single['episode'], 1);
      expect(
        (await WatchEventStore(cat.db).uploadCandidate(key)).ready,
        isTrue,
      );
      await expectLater(
        cat.indexVideos('s', [
          (
            relative: 'Series/01.mkv',
            size: 100,
            folder: 'Series',
            review: true,
          ),
        ], expectedLocationRevision: 0),
        throwsStateError,
      );
      expect(await cat.db.query('assets'), hasLength(1));
      await expectLater(
        cat.indexVideo(
          's',
          'Series/01.mkv',
          100,
          workFolder: 'Series',
          expectedLocationRevision: 0,
        ),
        throwsStateError,
      );
      await f.relocate(
        's',
        {assetId: 'Series/01.mkv'},
        expectedRevision: 1,
        workId: workId,
        workPath: 'Series',
      );
      expect(await cat.resumePosition(assetId), 90000);
      await f.relocate(
        's',
        {assetId: 'Renamed/renamed.mkv'},
        expectedRevision: 2,
        workId: workId,
        workPath: 'Renamed',
      );
      await cat.indexVideos('s', [
        (relative: 'Series/01.mkv', size: 200, folder: 'Series', review: true),
      ], expectedLocationRevision: 3);
      final added = (await cat.db.query(
        'assets',
        where: 'relative_path=?',
        whereArgs: ['Series/01.mkv'],
      )).single;
      expect(added['id'], isNot(assetId));
      expect(await cat.resumePosition(added['id'] as String), 0);
      await reopen();
      expect(await cat.db.query('library_location_history'), hasLength(6));
    },
  );
  test('move collision rolls back all paths and revisions', () async {
    await reopen();
    await cat.indexVideo('s', 'Other/01.mkv', 100, workFolder: 'Other');
    final before = await snapshot();
    await expectLater(
      LibraryFoundation(cat.db).relocate(
        's',
        {assetId: 'Other/01.mkv'},
        expectedRevision: 0,
        workId: workId,
        workPath: 'Other',
      ),
      throwsA(anything),
    );
    expect(await snapshot(), before);
  });
  test(
    'size changes quarantine new progress without deleting old proof; same-content resolution',
    () async {
      await reopen();
      final before = await cat.db.query('watch_events');
      await cat.indexVideo('s', 'Series/01.mkv', 200, workFolder: 'Series');
      expect(await cat.resumePosition(assetId), 0);
      await cat.progress(
        assetId,
        10000,
        200000,
        watchedRanges: [const WatchedRange(0, 10000)],
      );
      expect((await cat.db.query('progress')).single['position_ms'], 90000);
      expect(await cat.db.query('watch_events'), before);
      await reopen();
      expect(await cat.resumePosition(assetId), 0);
      final row = (await cat.db.query('library_content')).single;
      expect(row['pending_progress'], isNotNull);
      await LibraryFoundation(
        cat.db,
      ).confirmSameContent(assetId, row['revision'] as int);
      expect(await cat.resumePosition(assetId), 90000);
      expect((await cat.db.query('assets')).single['size'], 200);
      expect(
        (await WatchEventStore(cat.db).uploadCandidate(key)).ready,
        isTrue,
      );
      expect(
        (await cat.db.query(
          'library_content_history',
        )).single['pending_progress'],
        row['pending_progress'],
      );
    },
  );
  test(
    'field override, explicit blank, automatic draft, stale previews and old identity scope',
    () async {
      await reopen();
      final f = LibraryFoundation(cat.db);
      Future<void> write(
        String name,
        String mode,
        Object? value, {
        bool automatic = false,
      }) async {
        final field = await f.field(workId, name);
        await f.writeField(
          workId,
          name,
          expectedScope: field['scope'] as String,
          expectedBindingRevision: field['binding_revision'] as int,
          expectedRevision:
              field[automatic ? 'automatic_revision' : 'revision'] as int,
          mode: mode,
          value: value,
          automatic: automatic,
        );
      }

      await write('title', 'manual', 'My title');
      await write('overview', 'auto', 'Fetched synopsis', automatic: true);
      expect((await cat.db.query('works')).single['manual_lock'], 0);
      expect((await cat.db.query('works')).single['title'], 'My title');
      await write('overview', 'empty', null);
      final stale = await f.field(workId, 'overview');
      await write(
        'overview',
        'auto',
        'New automatic synopsis',
        automatic: true,
      );
      expect((await cat.db.query('works')).single['overview'], isNull);
      await write('overview', 'manual', 'Later edit');
      await expectLater(
        f.writeField(
          workId,
          'overview',
          expectedScope: stale['scope'] as String,
          expectedBindingRevision: stale['binding_revision'] as int,
          expectedRevision: stale['revision'] as int,
          mode: 'auto',
        ),
        throwsStateError,
      );
      await write('overview', 'auto', null);
      expect(
        (await cat.db.query('works')).single['overview'],
        'New automatic synopsis',
      );
      expect((await cat.db.query('works')).single['title'], 'My title');
      final title = await f.field(workId, 'title');
      await cat.db.update(
        'works',
        {'tmdb_id': 99},
        where: 'id=?',
        whereArgs: [workId],
      );
      await cat.db.update(
        'works',
        {'tmdb_id': 42},
        where: 'id=?',
        whereArgs: [workId],
      );
      await expectLater(
        f.writeField(
          workId,
          'title',
          expectedScope: title['scope'] as String,
          expectedBindingRevision: title['binding_revision'] as int,
          expectedRevision: title['revision'] as int,
          mode: 'manual',
          value: 'Stale',
        ),
        throwsStateError,
      );
      await reopen();
      expect(
        (await LibraryFoundation(cat.db).field(workId, 'title'))['mode'],
        'manual',
      );
    },
  );
  test(
    'schema 19 roundtrip includes new data; schema 18 target refuses newer backup',
    () async {
      await reopen();
      final f = LibraryFoundation(cat.db);
      final field = await f.field(workId, 'overview');
      await f.writeField(
        workId,
        'overview',
        expectedScope: field['scope'] as String,
        expectedBindingRevision: 0,
        expectedRevision: 0,
        mode: 'empty',
      );
      await cat.indexVideo('s', 'Series/01.mkv', 200, workFolder: 'Series');
      await cat.progress(
        assetId,
        1000,
        10000,
        watchedRanges: [const WatchedRange(0, 1000)],
      );
      final before = await snapshot();
      final prefs = await SharedPreferences.getInstance();
      final art = await Directory('${root.path}/artwork').create();
      final zip = File('${root.path}/new.zip');
      await LibraryBackupExporter(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      ).export(zip);
      final data = await LibraryBackupInspector.read(zip);
      expect(
        (data.manifest['tables'] as Map).keys.toSet(),
        before.keys.toSet(),
      );
      final restorer = LibraryBackupRestorer(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      );
      final prepared = await restorer.prepare(zip);
      try {
        await restorer.restore(prepared);
      } finally {
        await prepared.dispose();
      }
      expect(await snapshot(), before);
      await reopen();
      expect(await snapshot(), before);
      await cat.db.close();
      final old = await Directory('${root.path}/old').create();
      await cat.initialize(dataDirectory: old);
      final oldRestorer = LibraryBackupRestorer(
        database: cat.db,
        artworkDirectory: Directory('${old.path}/artwork'),
        preferences: prefs,
      );
      final newer = await oldRestorer.prepare(zip);
      try {
        await expectLater(oldRestorer.restore(newer), throwsFormatException);
      } finally {
        await newer.dispose();
      }
      expect(await cat.db.query('works'), isEmpty);
      expect(await oldRestorer.recoveryBackups(), isEmpty);
    },
  );
  test(
    'existing metadata editor protects only changed fields; scraper cannot rebind',
    () async {
      await reopen();
      await cat.updateWorkMetadata(
        workId,
        title: 'User title',
        overview: '',
        year: null,
      );
      expect((await cat.db.query('works')).single['manual_lock'], 0);
      expect(
        await cat.applyScrapedWork(
          workId,
          const ScrapedWork(
            title: 'Automatic title',
            provider: 'tmdb',
            tmdbId: 42,
            tmdbType: 'tv',
            overview: 'Automatic synopsis',
          ),
        ),
        isTrue,
      );
      final row = (await cat.db.query('works')).single;
      expect(row['title'], 'User title');
      expect(row['overview'], 'Automatic synopsis');
      expect(
        await cat.applyScrapedWork(
          workId,
          const ScrapedWork(
            title: 'Wrong work',
            provider: 'tmdb',
            tmdbId: 99,
            tmdbType: 'tv',
          ),
        ),
        isFalse,
      );
      expect((await cat.db.query('works')).single['tmdb_id'], 42);
      expect(
        (await WatchEventStore(cat.db).uploadCandidate(key)).ready,
        isTrue,
      );
    },
  );
  test(
    'older portable backup restores and seeds foundation without rewriting evidence',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final art = await Directory('${root.path}/artwork').create();
      final zip = File('${root.path}/old.zip');
      final old = await snapshot();
      await LibraryBackupExporter(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      ).export(zip);
      await reopen();
      final restorer = LibraryBackupRestorer(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      );
      final prepared = await restorer.prepare(zip);
      try {
        await restorer.restore(prepared);
      } finally {
        await prepared.dispose();
      }
      for (final table in old.keys) {
        expect(await cat.db.query(table), old[table], reason: table);
      }
      final newer = File('${root.path}/seeded.zip');
      await LibraryBackupExporter(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      ).export(newer);
      expect((await LibraryBackupInspector.inspect(newer)).assets, 1);
      await reopen();
      expect((await cat.db.query('assets')).single['id'], assetId);
    },
  );
  test(
    'migration failure rolls back schema and data; retry succeeds',
    () async {
      final before = await snapshot();
      await cat.db.execute('CREATE TABLE library_fields (conflict TEXT)');
      await cat.db.close();
      await expectLater(
        cat.initialize(dataDirectory: root, enableFoundation: true),
        throwsA(anything),
      );
      await cat.initialize(dataDirectory: root);
      expect(await cat.db.getVersion(), 18);
      expect(await snapshot(), before);
      expect(
        await cat.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='library_locations'",
        ),
        isEmpty,
      );
      await cat.db.execute('DROP TABLE library_fields');
      await reopen();
      expect(await cat.db.getVersion(), 19);
      expect(
        (await WatchEventStore(cat.db).uploadCandidate(key)).ready,
        isTrue,
      );
    },
  );
  test(
    'confirmed identity protects only binding and keeps old scoped overrides for undo',
    () async {
      await reopen();
      await cat.updateWorkMetadata(
        workId,
        title: 'Old manual title',
        overview: 'Old manual summary',
      );
      await cat.setManualCover(
        workId,
        source: 'tmdb',
        url: 'https://example.test/manual.png',
      );
      final oldScope = LibraryFoundation.scope(
        (await cat.db.query('works')).single,
      );
      await cat.bind(
        workId,
        provider: 'tmdb',
        providerId: 99,
        title: 'New identity',
      );
      final work = (await cat.db.query('works')).single;
      expect(work['title'], 'New identity');
      expect(work['overview'], isNull);
      expect(work['manual_cover_url'], isNull);
      expect(work['manual_lock'], 0);
      expect(
        (await cat.db.query(
          'library_work_protection',
        )).single['identity_locked'],
        1,
      );
      final oldFields = await cat.db.query(
        'library_fields',
        where: 'work_id=? AND scope=?',
        whereArgs: [workId, oldScope],
      );
      expect(
        oldFields
            .where((r) => r['field'] == 'manual_cover_url')
            .single['manual_json'],
        jsonEncode('https://example.test/manual.png'),
      );
      expect(
        oldFields.where((r) => r['field'] == 'title').single['manual_json'],
        jsonEncode('Old manual title'),
      );
      expect(
        await cat.applyScrapedWork(
          workId,
          const ScrapedWork(
            title: 'Updated title',
            provider: 'tmdb',
            tmdbId: 99,
            tmdbType: 'tv',
            overview: 'New automatic synopsis',
          ),
        ),
        isTrue,
      );
      expect(
        (await cat.db.query('works')).single['overview'],
        'New automatic synopsis',
      );
      expect(
        (await WatchEventStore(cat.db).uploadCandidate(key)).ready,
        isFalse,
      );
    },
  );
  test(
    'snapshot rejects orphaned locations and malformed field states',
    () async {
      await reopen();
      final data =
          jsonDecode(jsonEncode(await snapshot())) as Map<String, dynamic>;
      data['library_locations'][0]['entity_id'] = 'missing';
      expect(
        () => LibraryFoundation.validateSnapshot(data),
        throwsFormatException,
      );
      final fields =
          jsonDecode(jsonEncode(await snapshot())) as Map<String, dynamic>;
      fields['library_fields'][0]['mode'] = 'manual';
      fields['library_fields'][0]['manual_json'] = null;
      expect(
        () => LibraryFoundation.validateSnapshot(fields),
        throwsFormatException,
      );
    },
  );
  test(
    'schema 19 restore failure rolls back new tables and default open refuses downgrade',
    () async {
      await reopen();
      final prefs = await SharedPreferences.getInstance();
      final art = await Directory('${root.path}/artwork').create();
      final zip = File('${root.path}/checkpoint.zip');
      await LibraryBackupExporter(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      ).export(zip);
      await cat.updateWorkMetadata(
        workId,
        title: 'Keep after failed restore',
        overview: 'Manual',
      );
      final before = await snapshot();
      await cat.db.execute(
        "CREATE TRIGGER fail_fields BEFORE INSERT ON library_fields BEGIN SELECT RAISE(ABORT,'injected phase1 restore failure'); END",
      );
      final restorer = LibraryBackupRestorer(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      );
      final prepared = await restorer.prepare(zip);
      try {
        await expectLater(restorer.restore(prepared), throwsA(anything));
      } finally {
        await prepared.dispose();
      }
      expect(await snapshot(), before);
      await cat.db.execute('DROP TRIGGER fail_fields');
      await cat.db.close();
      await expectLater(cat.initialize(dataDirectory: root), throwsA(anything));
      await cat.initialize(dataDirectory: root, enableFoundation: true);
      expect(await snapshot(), before);
    },
  );
  test(
    'content history capacity stops mixing without deleting stored evidence',
    () async {
      await reopen();
      await cat.indexVideo('s', 'Series/01.mkv', 200, workFolder: 'Series');
      await cat.progress(
        assetId,
        1000,
        10000,
        watchedRanges: [const WatchedRange(0, 1000)],
      );
      for (var i = 0; i < 32; i++) {
        await cat.db.insert('library_content_history', {
          'id': 'h$i',
          'asset_id': assetId,
          'revision': i,
          'decision': 'same',
          'pending_progress': null,
        });
      }
      final old = (await cat.db.query('library_content')).single;
      await cat.indexVideo('s', 'Series/01.mkv', 300, workFolder: 'Series');
      expect(
        (await cat.db.query('library_content')).single['state'],
        'blocked',
      );
      await expectLater(cat.progress(assetId, 2000, 10000), throwsStateError);
      expect(
        (await cat.db.query('library_content')).single['pending_progress'],
        old['pending_progress'],
      );
      expect(await cat.resumePosition(assetId), 0);
      expect((await cat.db.query('progress')).single['position_ms'], 90000);
    },
  );
}
