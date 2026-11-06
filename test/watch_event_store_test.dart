import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/playback_history.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_inspector.dart';
import 'package:ccplayer/core/watch_event_store.dart';
import 'package:ccplayer/core/watched_timeline.dart';
import 'package:ccplayer/ui/playback_history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

const episode = 'tmdb:tv:42:s1:e1';
const a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
Map<String, Object?> manual(
  String device,
  int seq,
  bool value, {
  List<String> parents = const [],
}) => {
  'event_id': '$device:$seq',
  'device_id': device,
  'episode_key': episode,
  'kind': 'manual',
  'parents_json': jsonEncode(parents),
  'payload_json': jsonEncode({'completed': value}),
  'version': 1,
  'created_at': '2026-11-06T00:00:00Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  Future<Database> fixture() async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await WatchEventStore.createSchema(db);
    addTearDown(db.close);
    return db;
  }

  test(
    'offline conflicting manual changes converge without timestamp overwrite',
    () async {
      final left = await fixture(), right = await fixture();
      final l = WatchEventStore(left), r = WatchEventStore(right);
      final first = manual(a, 1, true);
      final second = {
        ...manual(b, 1, false),
        'created_at': '2099-01-01T00:00:00Z',
      };
      await l.importEvents([first, second]);
      await r.importEvents([second, first]);
      expect((await l.state(episode)).conflict, isTrue);
      expect((await r.state(episode)).completed, isNull);
      expect(await l.importEvents([second, first]), 0);
      await left.transaction(
        (tx) => WatchEventStore.recordManual(tx, episode, false),
      );
      final merged = await left.query('watch_events');
      await r.importEvents(merged);
      expect((await r.state(episode)).conflict, isFalse);
      expect((await r.state(episode)).completed, isFalse);
      final count = merged.length;
      await left.transaction(
        (tx) => WatchEventStore.recordManual(tx, episode, false),
      );
      expect((await left.query('watch_events')).length, count);
    },
  );

  test(
    'invalid batches, collisions, missing parents and cycles roll back',
    () async {
      final db = await fixture();
      final store = WatchEventStore(db);
      final first = manual(a, 1, true);
      await store.importEvents([first]);
      await expectLater(
        store.importEvents([manual(b, 1, false), manual(a, 1, false)]),
        throwsFormatException,
      );
      expect((await db.query('watch_events')).length, 1);
      await expectLater(
        store.importEvents([
          manual(b, 1, false, parents: ['$a:99']),
        ]),
        throwsFormatException,
      );
      await expectLater(
        store.importEvents([
          manual(b, 1, true, parents: ['$b:2']),
          manual(b, 2, false, parents: ['$b:1']),
        ]),
        throwsFormatException,
      );
      await expectLater(
        store.importEvents([
          {...manual(b, 1, false), 'version': 2},
        ]),
        throwsFormatException,
      );
      await expectLater(
        store.importEvents([
          {...manual(b, 1, false), 'episode_key': 'unknown'},
        ]),
        throwsFormatException,
      );
      expect((await store.state(episode)).completed, isTrue);
    },
  );

  test(
    'coverage stays on each physical timeline; manual unwatched wins',
    () async {
      final db = await fixture();
      final store = WatchEventStore(db);
      final half = WatchedTimeline([const WatchedRange(0, 50000)]);
      await db.transaction((tx) async {
        await WatchEventStore.recordCoverage(
          tx,
          episode,
          'BD',
          half,
          100000,
          90,
        );
        await WatchEventStore.recordCoverage(
          tx,
          episode,
          'BD',
          half,
          100000,
          90,
        );
        await WatchEventStore.recordCoverage(
          tx,
          episode,
          'WEB',
          WatchedTimeline([const WatchedRange(50000, 110000)]),
          110000,
          90,
        );
      });
      expect((await db.query('watch_events')).length, 2);
      expect((await store.state(episode)).completed, isFalse);
      await db.transaction(
        (tx) => WatchEventStore.recordCoverage(
          tx,
          episode,
          'BD',
          WatchedTimeline([const WatchedRange(50000, 90000)]),
          100000,
          90,
        ),
      );
      expect((await store.state(episode)).completed, isTrue);
      const changedDuration = 'tmdb:tv:42:s1:e2';
      await db.transaction((tx) async {
        await WatchEventStore.recordCoverage(
          tx,
          changedDuration,
          'same-file',
          half,
          100000,
          90,
        );
        await WatchEventStore.recordCoverage(
          tx,
          changedDuration,
          'same-file',
          WatchedTimeline([const WatchedRange(50000, 110000)]),
          110000,
          90,
        );
      });
      expect((await store.state(changedDuration)).completed, isFalse);
      await db.transaction(
        (tx) => WatchEventStore.recordCoverage(
          tx,
          episode,
          'BD',
          WatchedTimeline([const WatchedRange(0, 90000)]),
          100000,
          90,
        ),
      );
      expect((await store.state(episode)).completed, isTrue);
      await db.transaction(
        (tx) => WatchEventStore.recordManual(tx, episode, false),
      );
      await db.transaction(
        (tx) => WatchEventStore.recordCoverage(
          tx,
          episode,
          'BD',
          WatchedTimeline([const WatchedRange(0, 100000)]),
          100000,
          90,
        ),
      );
      expect((await store.state(episode)).completed, isFalse);
      final exported = await db.query('watch_events');
      final other = await fixture();
      final remote = WatchEventStore(other);
      expect(
        await remote.importEvents(exported.reversed.toList()),
        exported.length,
      );
      expect((await remote.state(episode)).completed, isFalse);
      final damaged = {
        ...exported.first,
        'event_id': '$a:9',
        'device_id': a,
        'payload_json': jsonEncode({
          'stream': '0' * 64,
          'duration': 100,
          'percent': 90,
          'ranges': [
            [0, 101],
          ],
        }),
      };
      await expectLater(remote.importEvents([damaged]), throwsFormatException);
    },
  );

  Future<Directory> library() async {
    final dir = await Directory.systemTemp.createTemp('ccplayer-events-');
    final cat = Catalog.instance;
    await cat.initialize(dataDirectory: dir);
    await cat.db.insert('sources', {
      'id': 's',
      'kind': 'local',
      'label': 'local',
      'location': dir.path,
    });
    await cat.db.insert('works', {
      'id': 'w',
      'title': '测试作品',
      'tmdb_id': 42,
      'tmdb_type': 'tv',
    });
    await cat.db.insert('assets', {
      'id': 'file',
      'work_id': 'w',
      'source_id': 's',
      'name': '01.mkv',
      'relative_path': '01.mkv',
      'category': 'main',
      'season': 1,
      'episode': 1,
    });
    return dir;
  }

  test(
    'real save path is atomic, persists and does not backfill seek positions',
    () async {
      final dir = await library();
      final cat = Catalog.instance;
      try {
        await cat.progress('file', 5000, 100000);
        final legacy = await cat.db.query('progress');
        await cat.db.execute('DROP TABLE watch_events');
        await cat.db.execute('DROP TABLE watch_event_local');
        await cat.db.setVersion(16);
        await cat.db.close();
        await cat.initialize(dataDirectory: dir);
        expect(await cat.db.getVersion(), 18);
        expect(await cat.db.query('progress'), legacy);
        await cat.logicalEpisodes.confirm('file', episode);
        await cat.progress('file', 99000, 100000);
        expect((await cat.db.query('watch_events')), isEmpty);
        await cat.progress(
          'file',
          90000,
          100000,
          watchedRanges: [const WatchedRange(0, 90000)],
        );
        expect(
          (await WatchEventStore(cat.db).state(episode)).completed,
          isTrue,
        );
        await PlaybackHistory(cat.db).setCompleted('file', false);
        await cat.progress(
          'file',
          100000,
          100000,
          watchedRanges: [const WatchedRange(0, 100000)],
        );
        expect(
          (await WatchEventStore(cat.db).state(episode)).completed,
          isFalse,
        );
        SharedPreferences.setMockInitialValues({});
        final backup = await LibraryBackupExporter(
          database: cat.db,
          artworkDirectory: Directory('${dir.path}/artwork'),
          preferences: await SharedPreferences.getInstance(),
        ).export(File('${dir.path}/events.zip'));
        await LibraryBackupInspector.inspect(backup);
        final zipContents = ZipDecoder().decodeBytes(
          await backup.readAsBytes(),
        );
        final manifest =
            jsonDecode(
                  utf8.decode(
                    zipContents.findFile('manifest.json')!.readBytes()!,
                  ),
                )
                as Map<String, dynamic>;
        final tables = manifest['tables'] as Map;
        expect((tables['watch_events'] as List).length, greaterThan(1));
        expect(tables.containsKey('watch_event_local'), isFalse);
        ((tables['watch_events'] as List).first as Map)['version'] = 2;
        final bad = ZipFileEncoder()..create('${dir.path}/invalid-events.zip');
        bad.addArchiveFile(
          ArchiveFile.string('manifest.json', jsonEncode(manifest)),
        );
        await bad.close();
        await expectLater(
          LibraryBackupInspector.inspect(
            File('${dir.path}/invalid-events.zip'),
          ),
          throwsFormatException,
        );
        final before = await cat.db.query('progress');
        await cat.db.execute(
          "CREATE TRIGGER reject_event BEFORE INSERT ON watch_events BEGIN SELECT RAISE(ABORT, 'test'); END",
        );
        await expectLater(
          PlaybackHistory(cat.db).setCompleted('file', true),
          throwsA(isA<DatabaseException>()),
        );
        expect(await cat.db.query('progress'), before);
        await cat.db.close();
        await cat.initialize(dataDirectory: dir);
        expect(
          (await WatchEventStore(cat.db).state(episode)).completed,
          isFalse,
        );
        expect(await cat.db.query('progress'), before);
        expect(await cat.resumePosition('file'), 0);
      } finally {
        await cat.db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'history confirms and revokes an episode; conflict offers both decisions',
    (tester) async {
      final dir = (await tester.runAsync(library))!;
      final cat = Catalog.instance;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await cat.db.close();
          await dir.delete(recursive: true);
        });
      });
      await tester.runAsync(() => cat.progress('file', 50000, 100000));
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: PlaybackHistoryPage(history: PlaybackHistory(cat.db)),
        ),
      );
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();
      }

      await settle();
      await tester.tap(find.byTooltip('管理播放记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认剧集身份'));
      await tester.pumpAndSettle();
      expect(find.textContaining('TMDB 42 · S1 · E1'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '确认剧集身份'));
      await settle();
      expect(
        await tester.runAsync(() => cat.logicalEpisodes.resolve('file')),
        episode,
      );
      await tester.tap(find.byTooltip('管理播放记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销身份确认'));
      await settle();
      expect(
        await tester.runAsync(() => cat.logicalEpisodes.resolve('file')),
        isNull,
      );
      await tester.runAsync(() async {
        await cat.logicalEpisodes.confirm('file', episode);
        await WatchEventStore(
          cat.db,
        ).importEvents([manual(a, 1, true), manual(b, 1, false)]);
      });
      await tester.tap(find.byTooltip('刷新播放记录'));
      await settle();
      expect(find.textContaining('观看状态有冲突'), findsOneWidget);
      await tester.tap(find.byTooltip('管理播放记录'));
      await tester.pumpAndSettle();
      expect(find.text('标记为已看'), findsOneWidget);
      expect(find.text('标记为未看'), findsOneWidget);
      await tester.tap(find.text('标记为未看'));
      await settle();
      expect(find.textContaining('观看状态有冲突'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
