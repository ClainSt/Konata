import 'dart:io';
import 'dart:convert';
import 'package:ccplayer/ui/managed_image.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/playback_history.dart';
import 'package:ccplayer/ui/playback_history_page.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RouteObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<Database> fixture() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT)');
    await db.execute('CREATE TABLE sources (id TEXT PRIMARY KEY, label TEXT)');
    await db.execute(
      'CREATE TABLE assets (id TEXT PRIMARY KEY, work_id TEXT, source_id TEXT, name TEXT, relative_path TEXT)',
    );
    await db.execute(
      'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER,duration_ms INTEGER,completed INTEGER,updated_at TEXT,manual_completed INTEGER,watched_ranges TEXT)',
    );
    await db.insert('works', {'id': 'w', 'title': '测试作品'});
    await db.insert('sources', {'id': 's', 'label': '测试媒体源'});
    for (final id in ['a', 'b']) {
      await db.insert('assets', {
        'id': id,
        'work_id': 'w',
        'source_id': 's',
        'name': '$id.mkv',
        'relative_path': '$id.mkv',
      });
      await db.insert('progress', {
        'asset_id': id,
        'position_ms': 12345,
        'duration_ms': 120000,
        'completed': 0,
        'updated_at': id == 'a'
            ? '2026-11-01T00:00:00Z'
            : '2026-11-02T00:00:00Z',
      });
    }
    return db;
  }

  test(
    'resume skips a saved final frame but preserves the history row',
    () async {
      final db = await fixture();
      addTearDown(db.close);
      final catalog = Catalog.instance..db = db;
      for (final (position, duration, start) in [
        (1421056, 1421098, 0),
        (1421098, 1421098, 0),
        (1422000, 1421098, 0),
        (1420098, 1421098, 1420098),
        (100, 200, 100),
        (4200, 0, 4200),
      ]) {
        await db.update(
          'progress',
          {'position_ms': position, 'duration_ms': duration},
          where: 'asset_id=?',
          whereArgs: ['a'],
        );
        expect(await catalog.resumePosition('a'), start);
        final row = (await db.query(
          'progress',
          where: 'asset_id=?',
          whereArgs: ['a'],
        )).single;
        expect(row['position_ms'], position);
        expect(row['completed'], 0);
      }
    },
  );

  testWidgets(
    'history uses shared episode title and still while playing original file',
    (tester) async {
      final db = (await tester.runAsync(() async {
        final db = await fixture();
        for (final column in [
          'episode INTEGER',
          'season INTEGER',
          'category TEXT',
          'extra_type TEXT',
        ]) {
          await db.execute('ALTER TABLE assets ADD COLUMN $column');
        }
        await db.update(
          'assets',
          {'episode': 2, 'season': 0, 'category': 'extra', 'extra_type': 'SP'},
          where: 'id=?',
          whereArgs: ['b'],
        );
        await db.execute(
          'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY)',
        );
        await db.insert('asset_overrides', {'asset_id': 'b'});
        await db.execute(
          'CREATE TABLE work_details (work_id TEXT PRIMARY KEY, identity TEXT, payload TEXT)',
        );
        await db.insert('work_details', {
          'work_id': 'w',
          'identity': Catalog.detailIdentity({'id': 'w', 'title': '测试作品'}),
          'payload': jsonEncode({
            'specials': {
              '2': {
                'name': '特别篇标题',
                'still': 'https://example.invalid/episode-two.jpg',
              },
            },
          }),
        });
        return db;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(db.close);
        await tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(390, 844));
      Map<String, Object?>? played;
      await tester.pumpWidget(
        MaterialApp(
          home: PlaybackHistoryPage(
            history: PlaybackHistory(db),
            onPlay: (row) async => played = row,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('SP 2 · 特别篇标题'), findsOneWidget);
      expect(find.text('b.mkv'), findsNothing);
      expect(find.textContaining('测试媒体源'), findsNothing);
      final recordTile = find.ancestor(
        of: find.text('SP 2 · 特别篇标题'),
        matching: find.byType(ListTile),
      );
      expect(
        tester.getSize(find.byType(ManagedImage)).height,
        tester.getSize(recordTile).height,
      );
      expect(
        tester.widget<ManagedImage>(find.byType(ManagedImage)).url,
        'https://example.invalid/episode-two.jpg',
      );
      await tester.tap(
        find.ancestor(
          of: find.text('SP 2 · 特别篇标题'),
          matching: find.byType(ListTile),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(played?['name'], 'b.mkv');
      expect(played?['position_ms'], 12345);
      expect(tester.takeException(), isNull);
    },
  );

  for (final wide in [true, false]) {
    testWidgets(
      'history stays in settings content with no app route push, wide=$wide',
      (tester) async {
        final db = (await tester.runAsync(fixture))!;
        Catalog.instance.db = db;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(db.close);
        });
        await tester.binding.setSurfaceSize(
          wide ? const Size(1100, 800) : const Size(390, 844),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final observer = _RouteObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            theme: ThemeData(
              platform: wide ? TargetPlatform.windows : TargetPlatform.android,
            ),
            home: const Scaffold(body: SettingsPage(embedded: true)),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('settings-category-3')));
        await tester.pumpAndSettle();
        final before = observer.pushes;
        await tester.tap(find.text('播放记录'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(observer.pushes, before);
        expect(find.byType(PlaybackHistoryPage), findsOneWidget);
        expect(find.text('测试作品'), findsNWidgets(2));
        if (wide) {
          final menu = find.byKey(const ValueKey('settings-category-3'));
          expect(menu, findsOneWidget);
          expect(
            tester.getRect(find.byType(PlaybackHistoryPage)).left,
            greaterThanOrEqualTo(tester.getRect(menu).right),
          );
        }
        await tester.tap(find.byKey(const ValueKey('history-back')));
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackHistoryPage), findsNothing);
        expect(find.text('播放记录'), findsOneWidget);
        expect(observer.pushes, before);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'history orders by recent play, preserves manual state during saves, removes only records',
    () async {
      final db = await fixture();
      addTearDown(db.close);
      final history = PlaybackHistory(db);
      Catalog.instance.db = db;
      expect((await history.entries()).map((r) => r['id']), ['b', 'a']);
      await history.setCompleted('a', true);
      await Catalog.instance.progress('a', 1000, 120000);
      expect(
        (await db.query(
          'progress',
          where: 'asset_id=?',
          whereArgs: ['a'],
        )).single['completed'],
        1,
      );
      await history.setCompleted('a', false);
      await Catalog.instance.progress('a', 119000, 120000);
      expect(
        (await db.query(
          'progress',
          where: 'asset_id=?',
          whereArgs: ['a'],
        )).single['completed'],
        0,
      );
      expect(await Catalog.instance.resumePosition('a'), 119000);
      await history.remove('a');
      expect((await history.entries()).length, 1);
      await history.clear();
      expect(await history.entries(), isEmpty);
      expect(await db.query('assets'), hasLength(2));
      expect(await db.query('works'), hasLength(1));
      expect(await db.query('sources'), hasLength(1));
    },
  );

  test(
    'v13 progress migrates and manual state persists across reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('ccplayer-history-');
      addTearDown(() => dir.delete(recursive: true));
      await Catalog.instance.initialize(dataDirectory: dir);
      var db = Catalog.instance.db;
      await db.execute('ALTER TABLE progress DROP COLUMN manual_completed');
      await db.setVersion(13);
      await db.insert('progress', {
        'asset_id': 'saved',
        'position_ms': 4321,
        'duration_ms': 10000,
        'completed': 1,
        'updated_at': '2026-11-01T00:00:00Z',
      });
      await db.close();
      await Catalog.instance.initialize(dataDirectory: dir);
      db = Catalog.instance.db;
      expect(await db.getVersion(), 18);
      expect((await db.query('progress')).single['position_ms'], 4321);
      await PlaybackHistory(db).setCompleted('saved', false);
      await db.close();
      await Catalog.instance.initialize(dataDirectory: dir);
      db = Catalog.instance.db;
      try {
        await Catalog.instance.progress('saved', 9999, 10000);
        final row = (await db.query('progress')).single;
        expect(row['completed'], 0);
        expect(row['manual_completed'], 0);
      } finally {
        await db.close();
      }
    },
  );

  testWidgets(
    'history opens resume callback and confirms deletion at phone width',
    (tester) async {
      final db = (await tester.runAsync(fixture))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(db.close);
      });
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? played;
      await tester.pumpWidget(
        MaterialApp(
          home: PlaybackHistoryPage(
            history: PlaybackHistory(db),
            onPlay: (row) async {
              played = row['id'].toString();
            },
          ),
        ),
      );
      Future<void> settleDb() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }

      await settleDb();
      await tester.tap(find.text('测试作品').first);
      await settleDb();
      expect(played, 'b');
      await tester.tap(find.byTooltip('管理播放记录').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('标记为已看'));
      await settleDb();
      expect(find.textContaining('已看 ·'), findsOneWidget);
      await tester.tap(find.byTooltip('清空播放记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await settleDb();
      expect(find.text('测试作品'), findsNWidgets(2));
      await tester.tap(find.byTooltip('清空播放记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await settleDb();
      expect(find.text('暂无播放记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
