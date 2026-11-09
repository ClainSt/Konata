import 'dart:io';
import 'dart:convert';
import 'package:ccplayer/ui/managed_image.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
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

  test('batch removal keeps unselected resume data and all media', () async {
    final db = await fixture();
    addTearDown(db.close);
    await db.insert('progress', {'asset_id': 'keep', 'position_ms': 9000});
    await PlaybackHistory(db).removeMany(['a', 'b', 'a']);
    expect((await db.query('progress')).single['asset_id'], 'keep');
    expect((await db.query('progress')).single['position_ms'], 9000);
    expect(await db.query('assets'), hasLength(2));
    expect(await db.query('works'), hasLength(1));
    expect(await db.query('sources'), hasLength(1));
  });

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
          theme: NipaPlayStyle.theme(Brightness.light),
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
      expect(find.byTooltip('SP 2 · 特别篇标题'), findsOneWidget);
      expect(find.text('SP 2'), findsOneWidget);
      expect(find.text('b.mkv'), findsNothing);
      expect(find.textContaining('测试媒体源'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('history-progress-b')),
      );
      expect(bar.value, closeTo(12345 / 120000, .000001));
      expect(bar.backgroundColor, isNot(bar.color));
      expect(
        tester.getSize(find.byKey(const ValueKey('history-card-b'))).width,
        closeTo(390 - 48, 1),
      );
      expect(
        tester.getSize(find.byType(ManagedImage)).aspectRatio,
        closeTo(16 / 9, .01),
      );
      expect(
        tester.widget<ManagedImage>(find.byType(ManagedImage)).url,
        'https://example.invalid/episode-two.jpg',
      );
      await tester.tap(find.byKey(const ValueKey('history-play-b')));
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
      'records settings no longer duplicate history navigation, wide=$wide',
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
        expect(find.text('播放记录'), findsNothing);
        expect(find.byType(PlaybackHistoryPage), findsNothing);
        expect(
          find.byKey(const ValueKey('library-backup-inspect')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('history rows fill the available width after every resize', (
    tester,
  ) async {
    final db = (await tester.runAsync(() async {
      final db = await fixture();
      for (var i = 0; i < 18; i++) {
        await db.insert('assets', {
          'id': 'extra-$i',
          'work_id': 'w',
          'source_id': 's',
          'name': '$i.mkv',
        });
        await db.insert('progress', {
          'asset_id': 'extra-$i',
          'position_ms': 15000,
          'duration_ms': 1421000,
        });
      }
      return db;
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(home: PlaybackHistoryPage(history: PlaybackHistory(db))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    for (final width in [
      320.0,
      390.0,
      600.0,
      768.0,
      1024.0,
      1440.0,
      3840.0,
      420.0,
    ]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpAndSettle();
      final cards = find.byWidgetPredicate(
        (w) =>
            w is InkWell &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('history-card-'),
      );
      final rects = tester
          .elementList(cards)
          .map((e) => tester.getRect(find.byWidget(e.widget)))
          .toList();
      final top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      final right = rects
          .where((r) => (r.top - top).abs() < 1)
          .map((r) => r.right)
          .reduce((a, b) => a > b ? a : b);
      expect(
        right,
        closeTo(width - 24, 1),
        reason: 'No unused right-hand strip at $width',
      );
      expect(tester.takeException(), isNull);
    }
  });

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
      await tester.tap(find.byKey(const ValueKey('history-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-card-b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标记为已看'));
      await settleDb();
      expect(find.byTooltip(RegExp('^已看 ·')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await settleDb();
      expect(find.text('测试作品'), findsNWidgets(2));
      // Cancel keeps both records; deselect one to verify selective deletion.
      await tester.tap(find.byKey(const ValueKey('history-select-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await settleDb();
      expect(find.text('测试作品'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await settleDb();
      expect(find.text('暂无播放记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
