import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/playback_history.dart';
import 'package:ccplayer/core/watch_event_store.dart';
import 'package:ccplayer/core/watched_timeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const key = 'tmdb:tv:42:s1:e1';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final cat = Catalog.instance;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ccplayer-origin-');
    await cat.initialize(dataDirectory: dir);
    await cat.db.insert('sources', {
      'id': 's',
      'kind': 'local',
      'label': 'Test',
      'location': dir.path,
    });
    await cat.db.insert('works', {
      'id': 'w',
      'title': 'Test',
      'tmdb_id': 42,
      'tmdb_type': 'tv',
    });
    for (final id in ['a', 'b']) {
      await cat.db.insert('assets', {
        'id': id,
        'source_id': 's',
        'work_id': 'w',
        'name': '$id.mkv',
        'relative_path': '$id.mkv',
        'category': 'main',
        'season': 1,
        'episode': 1,
      });
      await cat.logicalEpisodes.confirm(id, key);
    }
  });
  tearDown(() async {
    await cat.db.close();
    await dir.delete(recursive: true);
  });
  Future<void> watch(String id) => cat.progress(
    id,
    90000,
    100000,
    watchedRanges: [const WatchedRange(0, 90000)],
  );

  test(
    'rename is stable; identity change-back and reconfirm never resurrect old evidence',
    () async {
      final store = WatchEventStore(cat.db);
      await watch('a');
      expect((await store.uploadCandidate(key)).ready, isTrue);
      await cat.db.update(
        'assets',
        {'name': 'new.mkv', 'relative_path': 'new/location.mkv'},
        where: 'id=?',
        whereArgs: ['a'],
      );
      expect((await store.uploadCandidate(key)).ready, isTrue);
      await cat.db.update(
        'assets',
        {'episode': 2},
        where: 'id=?',
        whereArgs: ['a'],
      );
      await cat.db.update(
        'assets',
        {'episode': 1},
        where: 'id=?',
        whereArgs: ['a'],
      );
      expect((await store.uploadCandidate(key)).ready, isFalse);
      expect((await store.state(key)).completed, isNull);
      final events = await store.exportEvents();
      expect(events.where((e) => e['kind'] == 'retract').length, 1);
      expect(
        events.first['kind'],
        'coverage',
      ); // Audit evidence remains unchanged.
      await cat.logicalEpisodes.revoke('a');
      await cat.logicalEpisodes.confirm('a', key);
      expect((await store.uploadCandidate(key)).ready, isFalse);
      await cat.progress(
        'a',
        50000,
        100000,
        watchedRanges: [const WatchedRange(0, 50000)],
      );
      expect((await store.uploadCandidate(key)).reason, 'incomplete');
      await cat.progress(
        'a',
        90000,
        100000,
        watchedRanges: [const WatchedRange(50000, 90000)],
      );
      expect((await store.uploadCandidate(key)).ready, isTrue);
      final after = await store.exportEvents();
      await store.exportEvents();
      expect((await cat.db.query('watch_events')).length, after.length);
      await cat.db.close();
      await cat.initialize(dataDirectory: dir);
      expect(
        (await WatchEventStore(cat.db).uploadCandidate(key)).ready,
        isTrue,
      );
    },
  );

  test(
    'retractions replicate, survive reverse delivery, and cannot revoke another device',
    () async {
      final store = WatchEventStore(cat.db);
      await watch('a');
      final first = await store.exportEvents();
      final remoteDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await WatchEventStore.createSchema(remoteDb);
        final remote = WatchEventStore(remoteDb);
        await remote.importEvents(first);
        expect((await remote.state(key)).completed, isTrue);
        await cat.logicalEpisodes.revoke('a');
        final changed = await store.exportEvents();
        expect(await remote.importEvents(changed.reversed.toList()), 1);
        expect((await remote.state(key)).completed, isNull);
        expect(await remote.importEvents(changed), 0);
        final invalid = {
          ...changed.last,
          'device_id': 'f' * 32,
          'event_id': '${'f' * 32}:1',
        };
        await expectLater(
          remote.importEvents([invalid]),
          throwsFormatException,
        );
        final missing = {
          ...changed.last,
          'event_id': '${changed.last['device_id']}:999',
          'parents_json': jsonEncode(['${changed.last['device_id']}:998']),
        };
        await expectLater(
          remote.importEvents([missing]),
          throwsFormatException,
        );
      } finally {
        await remoteDb.close();
      }
    },
  );

  test(
    'one bad version does not revoke independent evidence; manual unwatched is eligible',
    () async {
      final store = WatchEventStore(cat.db);
      await watch('a');
      await watch('b');
      await cat.logicalEpisodes.revoke('a');
      final candidate = await store.uploadCandidate(key);
      expect(candidate.ready, isTrue);
      expect(candidate.eventIds.length, 1);
      await PlaybackHistory(cat.db).setCompleted('b', false);
      expect((await store.uploadCandidate(key)).completed, isFalse);
      await cat.db.update(
        'works',
        {'tmdb_id': 99},
        where: 'id=?',
        whereArgs: ['w'],
      );
      expect((await store.uploadCandidate(key)).ready, isFalse);
      expect((await store.state(key)).completed, isNull);
    },
  );

  test(
    'manual binding change, deletion and transaction rollback invalidate precisely',
    () async {
      final store = WatchEventStore(cat.db);
      await watch('a');
      await expectLater(
        cat.db.transaction((tx) async {
          await tx.update(
            'assets',
            {'season': 2},
            where: 'id=?',
            whereArgs: ['a'],
          );
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect((await store.uploadCandidate(key)).ready, isTrue);
      await cat.db.insert('asset_overrides', {
        'asset_id': 'a',
        'work_id': 'w',
        'category': 'extra',
        'season': 0,
        'episode': 1,
        'extra_type': 'SP',
      });
      expect((await store.uploadCandidate(key)).ready, isFalse);
      await cat.db.delete(
        'asset_overrides',
        where: 'asset_id=?',
        whereArgs: ['a'],
      );
      expect((await store.uploadCandidate(key)).ready, isFalse);
      await watch('a');
      expect((await store.uploadCandidate(key)).ready, isTrue);
      await cat.db.delete('assets', where: 'id=?', whereArgs: ['a']);
      expect((await store.uploadCandidate(key)).ready, isFalse);
    },
  );

  test(
    '17 upgrade preserves legacy events but never guesses provenance',
    () async {
      final store = WatchEventStore(cat.db);
      await watch('a');
      await PlaybackHistory(cat.db).setCompleted('a', true);
      final before = await store.exportEvents();
      final triggers = await cat.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'watch_%'",
      );
      for (final t in triggers) {
        await cat.db.execute('DROP TRIGGER ${t['name']}');
      }
      await cat.db.execute('DROP TABLE watch_event_origins');
      await cat.db.execute('DROP TABLE watch_identity_epochs');
      await cat.db.setVersion(17);
      await cat.db.close();
      await cat.initialize(dataDirectory: dir);
      final migrated = WatchEventStore(cat.db);
      expect(await cat.db.getVersion(), 18);
      expect(await migrated.exportEvents(), before);
      expect((await migrated.uploadCandidate(key)).reason, 'unproven_origin');
      await PlaybackHistory(cat.db).setCompleted('a', true);
      expect((await migrated.uploadCandidate(key)).ready, isTrue);
      // A new installation identity must not reuse another device's proofs
      // or issue a retraction pretending to be that device.
      await cat.db.delete('watch_event_local');
      expect((await migrated.uploadCandidate(key)).ready, isFalse);
      await cat.logicalEpisodes.revoke('a');
      WatchEventStore.validateGraph(await migrated.exportEvents());
    },
  );
}
