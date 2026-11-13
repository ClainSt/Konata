import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/artwork_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ccplayer/ui/nipaplay_detail_page.dart';
import 'package:ccplayer/ui/managed_image.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';

Future<Database> openDetailFixture() async {
  final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
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
}

void main() {
  setUpAll(() => sqfliteFfiInit());
  testWidgets('unnumbered films have their own list in a television detail', (tester) async {
    final db = (await tester.runAsync(openDetailFixture))!;
    Catalog.instance.db = db;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
    });
    const work = <String, Object?>{'id': 'mixed', 'title': 'Mixed', 'tmdb_type': 'tv'};
    const assets = <Map<String, Object?>>[
      {'id': 'tv', 'episode': 1, 'category': 'main',
        'name': 'Title.S01E01.mkv', 'relative_path': 'Mixed/Title.S01E01.mkv'},
      {'id': 'film1', 'category': 'main',
        'name': 'Title.Movie.1.2017.mkv', 'relative_path': 'Mixed/Title.Movie.1.2017.mkv'},
      {'id': 'film2', 'category': 'main',
        'name': 'Title.Movie.2.2018.mkv', 'relative_path': 'Mixed/Title.Movie.2.2018.mkv'},
    ];
    await tester.pumpWidget(MaterialApp(home: NipaPlayDetailPage(
      work: work, assets: assets,
      onBack: () {}, onEditMetadata: () {}, onEditCover: () {}, onDelete: () {},
    )));
    final film = find.byKey(const ValueKey('detail-episode:Mixed/Title.Movie.1.2017.mkv'));
    expect(film, findsNothing);
    await tester.tap(find.text('Films  2'));
    await tester.pumpAndSettle();
    expect(film, findsOneWidget);
    expect(find.byKey(const ValueKey('detail-episode:Mixed/Title.S01E01.mkv')), findsNothing);
  });

  testWidgets('NipaPlay detail has only more menu and fixed back navigation', (
    tester,
  ) async {
    final db = (await tester.runAsync(openDetailFixture))!;
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
      final backButton = tester.widget<IconButton>(
        find.byKey(const ValueKey('detail-back-button')),
      );
      final moreButton = tester.widget<PopupMenuButton<String>>(
        find.byKey(const ValueKey('detail-more-button')),
      );
      if (size.width < 650 && size.height > size.width) {
        expect(tester.getSize(cover).width, size.width);
        expect(
          backButton.style?.backgroundColor?.resolve({}),
          Colors.transparent,
        );
        expect(
          moreButton.style?.backgroundColor?.resolve({}),
          Colors.transparent,
        );
        expect((backButton.icon as Icon).color, Colors.white);
        expect((moreButton.icon as Icon).color, Colors.white);
        expect((backButton.icon as Icon).shadows, isNotEmpty);
        expect(
          find.byKey(const ValueKey('detail-navigation-scrim')),
          findsOneWidget,
        );
      } else {
        expect(cover, findsNothing);
        expect(
          find.byKey(const ValueKey('detail-navigation-scrim')),
          findsNothing,
        );
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
    final mainPlaceholder = find.byKey(
      const ValueKey('detail-episode-placeholder:Work/01.mkv'),
    );
    expect(mainPlaceholder, findsOneWidget);
    expect(
      find.descendant(of: mainPlaceholder, matching: find.byType(FittedBox)),
      findsOneWidget,
    );

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
    await tester.runAsync(
      () => db.insert('work_details', {
        'work_id': work['id'],
        'identity': Catalog.detailIdentity(work),
        'payload': jsonEncode({
          'specialAssets': {
            'Work/11-ova.mkv': {
              'name': '『其他作品 第二季』OAD「单集标题」',
              'special_number': 1,
            },
            'Work/02-ova.mkv': {
              'name': 'OVA 2: Another Title',
              'special_number': 2,
            },
          },
        }),
        'fetched_at': DateTime.now().toIso8601String(),
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NipaPlayStyle.theme(Brightness.light),
        home: NipaPlayDetailPage(
          key: const ValueKey('special-title-regression'),
          work: work,
          assets: [
            for (final (path, number, type) in [
              ('Work/01-cm.mkv', 1, 'CM'),
              ('Work/11-ova.mkv', 11, 'OVA'),
              ('Work/02-ova.mkv', 2, 'OVA'),
            ])
              {
                'id': path,
                'name': path.split('/').last,
                'relative_path': path,
                'category': 'extra',
                'extra_type': type,
                'episode': number,
              },
          ],
          onBack: () {},
          onEditMetadata: () {},
          onEditCover: () {},
          onDelete: () {},
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('特典  3'));
    await tester.pumpAndSettle();
    final chips = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .toList();
    expect(chips.map((chip) => (chip.label as Text).data), [
      '全部',
      'OVA',
      'OAD',
      'CM',
    ]);
    final oad = find.byKey(const ValueKey('detail-episode:Work/11-ova.mkv'));
    final ova = find.byKey(const ValueKey('detail-episode:Work/02-ova.mkv'));
    final cm = find.byKey(const ValueKey('detail-episode:Work/01-cm.mkv'));
    expect(tester.getTopLeft(oad).dx, lessThan(tester.getTopLeft(ova).dx));
    expect(tester.getTopLeft(ova).dx, lessThan(tester.getTopLeft(cm).dx));
    expect(
      find.descendant(of: oad, matching: find.text('OAD')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: oad, matching: find.text('单集标题')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: ova, matching: find.text('Another Title')),
      findsOneWidget,
    );
    expect(find.text('OVA 11'), findsNothing);

    final movie = {...work, 'tmdb_type': 'movie'};
    await tester.runAsync(
      () => db.update(
        'work_details',
        {
          'identity': Catalog.detailIdentity(movie),
          'payload': jsonEncode({'movieStill': 'test-movie-still.jpg'}),
        },
        where: 'work_id=?',
        whereArgs: [work['id']],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NipaPlayStyle.theme(Brightness.light),
        home: NipaPlayDetailPage(
          key: const ValueKey('movie-title-regression'),
          work: movie,
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试动画'), findsNWidgets(2));
    expect(find.text('[VCB-Studio] Movie [1080p x265].mkv'), findsNothing);
    expect(find.byTooltip('测试动画'), findsOneWidget);
    final movieCard = find.byKey(const ValueKey('detail-episode:Work/01.mkv'));
    expect(
      tester
          .widgetList<ManagedImage>(
            find.descendant(of: movieCard, matching: find.byType(ManagedImage)),
          )
          .map((image) => image.url),
      contains('test-movie-still.jpg'),
    );
    expect(
      find.descendant(of: movieCard, matching: find.text('正片')),
      findsNothing,
    );
    expect(
      find.descendant(of: movieCard, matching: find.text('未看')),
      findsOneWidget,
    );
  });

  testWidgets(
    'synopsis controls follow wrapping after width and font changes',
    (tester) async {
      final db = (await tester.runAsync(openDetailFixture))!;
      Catalog.instance.db = db;
      final scale = ValueNotifier(1.0);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        scale.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(db.close);
      });

      Future<void> show(String overview) async {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => ValueListenableBuilder<double>(
              valueListenable: scale,
              builder: (_, factor, _) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(factor)),
                child: child!,
              ),
            ),
            home: NipaPlayDetailPage(
              key: ValueKey(overview),
              work: {'id': 'synopsis', 'title': 'Title', 'overview': overview},
              assets: const [],
              onBack: () {},
              onEditMetadata: () {},
              onEditCover: () {},
              onDelete: () {},
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }

      final expand = find.text('展开简介');
      final collapse = find.text('收起简介');
      const wide = Size(1350, 900);
      await tester.binding.setSurfaceSize(wide);
      await show(List.filled(42, 'wide').join(' '));
      expect(expand, findsNothing);

      await show(List.filled(27, 'word').join(' '));
      expect(expand, findsNothing);
      await tester.binding.setSurfaceSize(const Size(390, 850));
      await tester.pumpAndSettle();
      expect(expand, findsOneWidget);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(collapse, findsOneWidget);

      await tester.binding.setSurfaceSize(wide);
      await tester.pumpAndSettle();
      expect(expand, findsNothing);
      expect(collapse, findsNothing);

      scale.value = 3;
      await tester.pumpAndSettle();
      expect(collapse, findsOneWidget);
      await tester.ensureVisible(collapse);
      await tester.pumpAndSettle();
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      expect(expand, findsOneWidget);
      scale.value = 1;
      await tester.pumpAndSettle();
      expect(expand, findsNothing);
      expect(collapse, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
