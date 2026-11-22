import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/presentation/detail/detail_bottom_drawer.dart';
import 'package:konata/presentation/theme/konata_theme.dart';

Future<Uint8List> _mockLoader(
  String path, {
  int? targetWidth,
  TmdbImageSize? imageSize,
}) async =>
    Uint8List(0);

void main() {
  WorkDetailBundle buildTestBundle() {
    const work = Work(
      id: 'w_detail',
      title: '86 -不存在的战区-',
      scrapeStatus: ScrapeStatus.matched,
    );
    final episodes = [
      for (var i = 1; i <= 10; i++)
        Episode(
          id: 'ep_$i',
          workId: work.id,
          seasonNumber: 1,
          episodeNumber: i,
          category: EpisodeCategory.main,
          title: '第 $i 话',
        ),
      const Episode(
        id: 'sp_1',
        workId: 'w_detail',
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.ncop,
        title: 'NCOP 01',
      ),
    ];
    final variants = [
      for (var i = 1; i <= 10; i++)
        MediaVariant(
          id: 'v_$i',
          workId: work.id,
          episodeId: 'ep_$i',
          sourceId: 's1',
          relativePath: '86/Ep_$i.mkv',
          fileName:
              '[VCB-Studio] 86 -Eighty Six- [${i.toString().padLeft(2, '0')}][Ma10p_1080p][x265_flac][CHS].mkv',
          fileSize: 500 * 1024 * 1024,
        ),
      const MediaVariant(
        id: 'v_sp1',
        workId: 'w_detail',
        episodeId: 'sp_1',
        sourceId: 's1',
        relativePath: '86/SPs/NCOP1.mkv',
        fileName: '[VCB-Studio] 86 [NCOP1].mkv',
        fileSize: 80 * 1024 * 1024,
      ),
      const MediaVariant(
        id: 'v_cd1',
        workId: 'w_detail',
        sourceId: 's1',
        relativePath: '86/CD/track01.flac',
        fileName: 'track01.flac',
        fileSize: 20 * 1024 * 1024,
        assetKind: AssetKind.cdAlbum,
      ),
      const MediaVariant(
        id: 'v_scan1',
        workId: 'w_detail',
        sourceId: 's1',
        relativePath: '86/Scans/book.webp',
        fileName: 'book.webp',
        fileSize: 2 * 1024 * 1024,
        assetKind: AssetKind.scanGallery,
      ),
    ];
    final cdVariants = [
      for (final v in variants)
        if (v.assetKind == AssetKind.cdAlbum) v,
    ];
    final scanVariants = [
      for (final v in variants)
        if (v.assetKind == AssetKind.scanGallery) v,
    ];
    return WorkDetailBundle(
      work: work,
      episodes: episodes,
      variants: variants,
      cdVariants: cdVariants,
      scanVariants: scanVariants,
      sourcesById: const {
        's1': MediaSource(
          id: 's1',
          kind: MediaSourceKind.local,
          label: 'Anime',
          location: 'D:/Anime',
        ),
      },
      latestPlayback: null,
    );
  }

  testWidgets('底部抽屉按需展示正片/特典/CD/Scan与管理菜单，无CD/Scan时保持隐藏', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bundle = buildTestBundle();
    DetailDrawerTab? tab = DetailDrawerTab.main;

    await tester.pumpWidget(
      MaterialApp(
        theme: KonataTheme.darkTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Align(
                alignment: Alignment.bottomCenter,
                child: DetailBottomDrawer(
                  bundle: bundle,
                  activeTab: tab,
                  imageLoader: _mockLoader,
                  onToggleTab: (next) => setState(() => tab = next),
                  onCollapse: () => setState(() => tab = null),
                  onEpisodeTap: (_) {},
                  onEpisodeAdjustSlot: (_) {},
                  onOpenManualMatch: () {},
                  onOpenManualEdit: () {},
                  onOpenPosterPicker: () {},
                  onOpenBackdropPicker: () {},
                  onHideWork: () {},
                  onDeleteWork: () {},
                  onRescrape: () {},
                  onOpenLocalDir: () {},
                  onOpenSeriesManage: () {},
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 存在 CD 与 Scan 时动态显示 CD (1) / Scan (1)，并与正片/特典统一成无框胶囊，三端均不显示左右翻页箭头
    expect(find.text('正片 (10)'), findsOneWidget);
    expect(find.text('特典 (1)'), findsOneWidget);
    expect(find.text('CD (1)'), findsOneWidget);
    expect(find.text('Scan (1)'), findsOneWidget);
    expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    expect(find.byIcon(Icons.settings_rounded), findsOneWidget);

    // 2. 文件名 Text 允许自动多行折行（不再 maxLines == 1）
    final fileNameTextFinder = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          (w.data ?? '').contains('VCB-Studio') &&
          (w.maxLines ?? 1) > 1,
    );
    expect(fileNameTextFinder, findsWidgets);

    // 3. 发送垂直滚轮 PointerScrollEvent，验证横向 ListView 产生向右滚动偏移
    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);
    final scrollableState = tester.state<ScrollableState>(
      find.descendant(of: listFinder, matching: find.byType(Scrollable)),
    );
    expect(scrollableState.position.pixels, 0.0);

    final listCenter = tester.getCenter(listFinder);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(listCenter));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 180)));
    await tester.pumpAndSettle();
    expect(scrollableState.position.pixels, greaterThan(0.0));

    // 收起后右下角应隐藏 < / > / ⌄，仅保留齿轮图标
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    expect(find.byIcon(Icons.settings_rounded), findsOneWidget);

    // 4. 点击齿轮，验证向上悬浮玻璃菜单包含管理系列编组与全部 6 个作品管理项
    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pumpAndSettle();
    expect(find.text('绑定元数据'), findsOneWidget);
    expect(find.text('手动编辑'), findsOneWidget);
    expect(find.text('编辑封面'), findsOneWidget);
    expect(find.text('编辑背景图'), findsOneWidget);
    expect(find.text('管理系列编组'), findsOneWidget);
    expect(find.text('隐藏作品'), findsOneWidget);
    expect(find.text('删除作品'), findsOneWidget);

    // 5. 无 CD 与 Scan 资源时绝不展示空的 CD / Scan 标签
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    final emptyExtrasBundle = WorkDetailBundle(
      work: bundle.work,
      episodes: bundle.episodes,
      variants: bundle.variants
          .where((v) => v.assetKind == AssetKind.video)
          .toList(),
      sourcesById: bundle.sourcesById,
      latestPlayback: null,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: KonataTheme.darkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: DetailBottomDrawer(
              bundle: emptyExtrasBundle,
              activeTab: DetailDrawerTab.main,
              imageLoader: _mockLoader,
              onToggleTab: (_) {},
              onCollapse: () {},
              onEpisodeTap: (_) {},
              onEpisodeAdjustSlot: (_) {},
              onOpenManualMatch: () {},
              onOpenManualEdit: () {},
              onOpenPosterPicker: () {},
              onOpenBackdropPicker: () {},
              onHideWork: () {},
              onDeleteWork: () {},
              onRescrape: () {},
              onOpenLocalDir: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('正片 (10)'), findsOneWidget);
    expect(find.text('特典 (1)'), findsOneWidget);
    expect(find.textContaining('CD'), findsNothing);
    expect(find.textContaining('Scan'), findsNothing);
  });
}
