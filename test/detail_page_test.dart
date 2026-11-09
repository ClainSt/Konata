import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/artwork_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      'poster': 'test-poster.png',
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
        'id': 'ep1-alt',
        'work_id': 'work-one',
        'episode': 1,
        'category': 'main',
        'relative_path': 'Work/alternate/01.mkv',
        'name': '[VCB-Studio] 测试动画 [01][1080p].mkv',
      },
      {
        'id': 'sp1',
        'work_id': 'work-one',
        'episode': null,
        'category': 'extra',
        'relative_path': 'Work/SP.mkv',
        'name': 'SP.mkv',
      },
      {
        'id': 'unknown-extra',
        'work_id': 'work-one',
        'category': 'extra',
        'extra_type': '其他',
        'relative_path': 'Work/制作访谈幕后记录.mkv',
        'name': '制作访谈幕后记录.mkv',
      },
    ];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => db.close());
    });
    await tester.binding.setSurfaceSize(const Size(1350, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var metadataCount = 0, coverCount = 0, backCount = 0, deleteCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NipaPlayStyle.theme(Brightness.light),
        home: NipaPlayDetailPage(
          work: work,
          assets: assets,
          onBack: () => backCount++,
          onEditMetadata: () => metadataCount++,
          onEditCover: () => coverCount++,
          onDelete: () => deleteCount++,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('测试动画'), findsOneWidget);
    final backdrop = find.byKey(const ValueKey('detail-backdrop'));
    for (final (size, visible) in [
      (const Size(1350, 860), true),
      (const Size(1024, 700), true),
      (const Size(850, 390), false),
      (const Size(390, 850), false),
      (const Size(600, 750), false),
      (const Size(1350, 860), true),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pump();
      expect(
        backdrop,
        visible ? findsOneWidget : findsNothing,
        reason: '$size',
      );
      final cover = find.byKey(const ValueKey('detail-portrait-cover'));
      if (size.width < 650 && size.height > size.width) {
        expect(tester.getSize(cover).width, size.width);
      } else {
        expect(cover, findsNothing);
      }
      expect(tester.takeException(), isNull);
    }
    expect(find.text('关联管理'), findsNothing);
    SharedPreferences.setMockInitialValues({});
    await ArtworkSettings.instance.setBackdrop(false);
    await tester.pump();
    expect(backdrop, findsNothing);
    await ArtworkSettings.instance.setBackdrop(true);
    await tester.pump();
    expect(backdrop, findsOneWidget);
    expect(find.byKey(const ValueKey('detail-manage-button')), findsNothing);
    expect(find.byKey(const ValueKey('detail-more-button')), findsOneWidget);
    expect(find.text('开始播放'), findsOneWidget);
    expect(find.text('从头播放'), findsNothing);
    expect(find.byTooltip('刷新详情资料'), findsNothing);
    expect(find.text('正片  1'), findsOneWidget);
    expect(find.text('特典  2'), findsOneWidget);
    expect(find.text('未看'), findsOneWidget);
    expect(find.text('0%'), findsNothing);

    // The primary play button must offer versions too, before opening a player.
    await tester.tap(find.text('开始播放'));
    await tester.pumpAndSettle();
    expect(find.text('选择播放版本'), findsOneWidget);
    expect(find.textContaining('VCB-Studio'), findsWidgets);
    await tester.tap(find.byTooltip('关闭版本选择'));
    await tester.pumpAndSettle();
    expect(find.text('选择播放版本'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('detail-more-button')));
    await tester.pumpAndSettle();
    expect(find.text('编辑元数据'), findsOneWidget);
    expect(find.text('编辑封面'), findsOneWidget);
    expect(find.text('删除该作品'), findsOneWidget);
    expect(find.text('关联管理'), findsNothing);
    await tester.tap(find.text('编辑元数据'));
    await tester.pumpAndSettle();
    expect(metadataCount, 1);
    await tester.tap(find.byKey(const ValueKey('detail-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑封面'));
    await tester.pumpAndSettle();
    expect(coverCount, 1);
    await tester.tap(find.byKey(const ValueKey('detail-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除该作品'));
    await tester.pumpAndSettle();
    expect(deleteCount, 1);

    await tester.tap(find.text('特典  2'));
    await tester.pump();
    expect(find.text('SP 01'), findsOneWidget);
    expect(find.text('特别篇 01'), findsOneWidget);
    expect(find.text('制作访谈幕后记录'), findsOneWidget);
    expect(find.text('其他 01'), findsNothing);
    final clearToolbar = tester.widget<Container>(
      find.byKey(const ValueKey('detail-fixed-toolbar')),
    );
    expect(clearToolbar.color, Colors.transparent);
    expect(
      find.byKey(const ValueKey('detail-episode:Work/SP.mkv')),
      findsOneWidget,
    );

    await tester.binding.setSurfaceSize(const Size(1350, 420));
    await tester.pumpAndSettle();
    final toolbar = find.byKey(const ValueKey('detail-fixed-toolbar'));
    final topBefore = tester.getTopLeft(toolbar);
    await tester.drag(
      find.byKey(const ValueKey('detail-content-scroll')),
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
    await tester.binding.setSurfaceSize(const Size(1350, 860));
    await tester.pumpWidget(
      MaterialApp(
        theme: NipaPlayStyle.theme(Brightness.light),
        home: NipaPlayDetailPage(
          key: const ValueKey('movie-title-regression'),
          work: {...work, 'tmdb_type': 'movie'},
          assets: [
            {
              ...assets.first,
              'episode': null,
              'name': '[VCB-Studio] Movie [1080p x265].mkv',
            },
          ],
          onBack: () {},
          onEditMetadata: () {},
          onEditCover: () {},
          onDelete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试动画'), findsNWidgets(2));
    expect(find.text('[VCB-Studio] Movie [1080p x265].mkv'), findsNothing);
    expect(find.byTooltip('测试动画'), findsOneWidget);
  });
}
