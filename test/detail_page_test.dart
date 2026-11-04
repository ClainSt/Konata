import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/ui/nipaplay_detail_page.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());
  testWidgets('NipaPlay detail has only more menu and fixed back navigation', (
    tester,
  ) async {
    final db = (await tester.runAsync(() async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      await database.execute(
        'CREATE TABLE work_details (work_id TEXT PRIMARY KEY, identity TEXT NOT NULL, payload TEXT NOT NULL, fetched_at TEXT NOT NULL)',
      );
      await database.execute(
        'CREATE TABLE assets (id TEXT PRIMARY KEY, work_id TEXT, episode INTEGER, category TEXT, relative_path TEXT, name TEXT)',
      );
      await database.execute(
        'CREATE TABLE progress (asset_id TEXT PRIMARY KEY, position_ms INTEGER, duration_ms INTEGER, completed INTEGER, updated_at TEXT)',
      );
      return database;
    }))!;
    Catalog.instance.db = db;
    final work = <String, Object?>{
      'id': 'work-one',
      'title': '测试动画',
      'year': 2023,
      'tmdb_id': null,
      'bangumi_id': null,
      'poster': null,
      'overview': '短简介',
    };
    final assets = <Map<String, Object?>>[
      {
        'id': 'ep1',
        'work_id': 'work-one',
        'episode': 1,
        'category': 'main',
        'relative_path': 'Work/01.mkv',
        'name': '01.mkv',
      },
      {
        'id': 'sp1',
        'work_id': 'work-one',
        'episode': null,
        'category': 'extra',
        'relative_path': 'Work/SP.mkv',
        'name': 'SP.mkv',
      },
    ];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => db.close());
    });
    await tester.binding.setSurfaceSize(const Size(1350, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var metadataCount = 0, coverCount = 0, backCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NipaPlayStyle.theme(Brightness.light),
        home: NipaPlayDetailPage(
          work: work,
          assets: assets,
          onBack: () => backCount++,
          onEditMetadata: () => metadataCount++,
          onEditCover: () => coverCount++,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('测试动画'), findsOneWidget);
    expect(find.text('关联管理'), findsNothing);
    expect(find.byKey(const ValueKey('detail-manage-button')), findsNothing);
    expect(find.byKey(const ValueKey('detail-more-button')), findsOneWidget);
    expect(find.text('开始播放'), findsOneWidget);
    expect(find.text('从头播放'), findsNothing);
    expect(find.byTooltip('刷新详情资料'), findsNothing);
    expect(find.text('正片  1'), findsOneWidget);
    expect(find.text('特典  1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('detail-more-button')));
    await tester.pumpAndSettle();
    expect(find.text('编辑元数据'), findsOneWidget);
    expect(find.text('编辑封面'), findsOneWidget);
    expect(find.text('关联管理'), findsNothing);
    await tester.tap(find.text('编辑元数据'));
    await tester.pumpAndSettle();
    expect(metadataCount, 1);
    await tester.tap(find.byKey(const ValueKey('detail-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑封面'));
    await tester.pumpAndSettle();
    expect(coverCount, 1);

    await tester.tap(find.text('特典  1'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('detail-episode:Work/SP.mkv')),
      findsOneWidget,
    );

    await tester.binding.setSurfaceSize(const Size(1350, 420));
    await tester.pumpAndSettle();
    final toolbar = find.byKey(const ValueKey('detail-fixed-toolbar'));
    final topBefore = tester.getTopLeft(toolbar);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -460),
    );
    await tester.pumpAndSettle();
    final topAfter = tester.getTopLeft(toolbar);
    expect((topBefore.dy - topAfter.dy).abs(), lessThan(1));
    await tester.tap(find.byKey(const ValueKey('detail-back-button')));
    expect(backCount, 1);
    await tester.tap(find.byKey(const ValueKey('detail-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑元数据'));
    await tester.pumpAndSettle();
    expect(metadataCount, 2);
  });
}
