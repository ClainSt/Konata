import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import 'support/detail_test_fixtures.dart';

Future<void> _seedRichWork(DetailTestHarness harness) async {
  await harness.repository.upsertSeriesGroup(
    SeriesGroup(
      id: 'ser_ui',
      title: '测试系列大合集',
      createdAt: DateTime.utc(2025, 1, 1),
      updatedAt: DateTime.utc(2025, 1, 1),
    ),
  );
  await harness.repository.upsertMediaSource(
    const MediaSource(
      id: 'src_ui',
      kind: MediaSourceKind.local,
      label: '本地测试盘',
      location: 'D:/Anime/Test',
    ),
  );
  await harness.repository.upsertWork(
    const Work(
      id: 'w_ui_1',
      seriesId: 'ser_ui',
      seriesOrder: 1,
      seriesLabel: '第 1 季',
      title: '少女终末旅行',
      originalTitle: '少女終末旅行',
      year: 2017,
      overview:
          '繁华的人类文明毁灭之后，两位少女驾驶履带摩托在废墟都市之间缓缓穿行，寻找着微光与希望。',
      bangumiScore: 8.8,
      matchedSeason: 1,
      scrapeStatus: ScrapeStatus.needsReview,
      reviewReason: '模拟待复核提示信息',
    ),
  );
  await harness.repository.upsertWork(
    const Work(
      id: 'w_ui_2',
      seriesId: 'ser_ui',
      seriesOrder: 2,
      seriesLabel: '剧场篇',
      title: '少女终末旅行 · 特别纪念篇',
      year: 2018,
      scrapeStatus: ScrapeStatus.matched,
    ),
  );

  for (var i = 1; i <= 3; i++) {
    final epId = 'ep_ui_$i';
    await harness.repository.upsertEpisode(
      Episode(
        id: epId,
        workId: 'w_ui_1',
        seasonNumber: 1,
        episodeNumber: i,
        category: EpisodeCategory.main,
        title: '第 $i 话 · 废墟旅途',
        overview: '分集 $i 剧情简介内容。',
      ),
    );
    await harness.repository.upsertMediaVariant(
      MediaVariant(
        id: 'var_ui_$i',
        workId: 'w_ui_1',
        episodeId: epId,
        sourceId: 'src_ui',
        relativePath: 'Main/0$i.mkv',
        fileName: '[Subs] 0$i.mkv',
        fileSize: 1200 * 1024 * 1024,
        releaseGroup: 'TestSub',
        resolution: '1080p',
        videoCodec: 'HEVC',
        bitDepth: '10bit',
      ),
    );
  }

  await harness.repository.upsertEpisode(
    const Episode(
      id: 'ep_ui_sp1',
      workId: 'w_ui_1',
      seasonNumber: 0,
      episodeNumber: 1,
      category: EpisodeCategory.extra,
      extraType: ExtraKind.ncop,
      title: 'NCOP01',
    ),
  );
  await harness.repository.upsertMediaVariant(
    const MediaVariant(
      id: 'var_ui_sp1',
      workId: 'w_ui_1',
      episodeId: 'ep_ui_sp1',
      sourceId: 'src_ui',
      relativePath: 'SPs/NCOP01.mkv',
      fileName: 'NCOP01.mkv',
      fileSize: 240 * 1024 * 1024,
    ),
  );
  await harness.repository.upsertMediaVariant(
    const MediaVariant(
      id: 'var_ui_cd1',
      workId: 'w_ui_1',
      sourceId: 'src_ui',
      relativePath: 'CD/OST_Disc1.flac',
      fileName: 'OST_Disc1.flac',
      fileSize: 420 * 1024 * 1024,
      assetKind: AssetKind.cdAlbum,
    ),
  );
}

void main() {
  group('WorkDetailPage 动态扩展挂载与交互路由', () {
    late DetailTestHarness harness;
    late WorkDetailController ctrl;
    final invokedActionWorkIds = <WorkId>[];
    final builtTabWorkIds = <WorkId>[];
    late DetailTabContribution visibleTab;
    late DetailTabContribution hiddenTab;
    late DetailActionContribution primaryAction;

    setUp(() async {
      invokedActionWorkIds.clear();
      builtTabWorkIds.clear();
      harness = await DetailTestHarness.create();
      await _seedRichWork(harness);

      visibleTab = DetailTabContribution(
        id: 'mock_scan_viewer',
        label: '模拟扫图',
        iconKey: 'scan_viewer',
        order: 40,
        isVisibleForWork: (workId) async => workId.value == 'w_ui_1',
        viewBuilder: (slotCtx) {
          final resolvedId = slotCtx.workId!;
          builtTabWorkIds.add(resolvedId);
          return Center(
            key: const ValueKey<String>('mock_scan_tab_body'),
            child: Text('外部挂载扫图视图 · ${resolvedId.value}'),
          );
        },
      );
      hiddenTab = DetailTabContribution(
        id: 'mock_hidden_tab',
        label: '隐藏扩展页',
        iconKey: 'folder',
        order: 50,
        isVisibleForWork: (_) async => false,
        viewBuilder: (_) => const SizedBox.shrink(),
      );
      primaryAction = DetailActionContribution(
        id: 'mock_primary_action',
        label: '扩展动作',
        iconKey: 'external',
        placement: DetailActionPlacement.primaryBar,
        order: 10,
        isEnabledForWork: (workId) async => workId.value == 'w_ui_1',
        onInvoke: (slotCtx) async {
          invokedActionWorkIds.add(slotCtx.workId!);
        },
      );

      ctrl = harness.createController(
        const WorkId.trusted('w_ui_1'),
        detailTabs: <DetailTabContribution>[visibleTab, hiddenTab],
        detailActions: <DetailActionContribution>[primaryAction],
      );
      await ctrl.load();
    });

    testWidgets('动态挂载模拟 DetailTabContribution 与 DetailActionContribution 并完整响应点击路由', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrapDetailTestApp(
          dependencies: harness.buildDependencies(
            detailTabs: <DetailTabContribution>[visibleTab, hiddenTab],
            detailActions: <DetailActionContribution>[primaryAction],
          ),
          child: WorkDetailPage(
            workId: const WorkId.trusted('w_ui_1'),
            controllerOverride: ctrl,
            imageLoaderOverride: createStubImageLoader(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.text('少女终末旅行'), findsOneWidget);
      expect(find.text('模拟扫图'), findsOneWidget);
      expect(find.text('隐藏扩展页'), findsNothing);
      // 冗余「刷新元数据」与外露扩展动作按钮均已从主操作行彻底移除，统一收口进唯一 `⚙`
      expect(find.byKey(const Key('detail_rescrape_button')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('detail_ext_primary_mock_primary_action')),
        findsNothing,
      );

      // 1. 打开唯一齿轮菜单触发已收口的外部扩展动作，并确认包含「编辑竖版原画」入口
      await tester.tap(find.byKey(const Key('detail_gear_menu_button')));
      await tester.pumpAndSettle();
      expect(find.text('编辑竖版原画'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('detail_ext_gear_mock_primary_action')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('detail_ext_gear_mock_primary_action')),
      );
      await tester.pumpAndSettle();
      expect(invokedActionWorkIds, <WorkId>[const WorkId.trusted('w_ui_1')]);

      // 2. 点击动态扩展标签并校验 viewBuilder 被调用
      await tester.tap(
        find.byKey(const ValueKey<String>('detail_tab_mock_scan_viewer')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const ValueKey<String>('mock_scan_tab_body')),
        findsOneWidget,
      );
      expect(builtTabWorkIds, <WorkId>[const WorkId.trusted('w_ui_1')]);

      // 3. 切回正片标签并点击第一集卡片，验证路由至视频播放器
      await tester.tap(
        find.byKey(const ValueKey<String>('detail_tab_episodes')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey<String>('episode_card_ep_ui_1')));
      await tester.pump();
      expect(harness.navigator.videoPlayerCalls.length, 1);
      expect(harness.navigator.videoPlayerCalls.single.episodeId?.value, 'ep_ui_1');

      // 4. 切换至 CD 标签并点击专辑，验证路由至音频播放器
      await tester.tap(find.byKey(const ValueKey<String>('detail_tab_cd')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey<String>('cd_card_var_ui_cd1')));
      await tester.pump();
      expect(harness.navigator.audioPlayerCalls.length, 1);
      expect(harness.navigator.audioPlayerCalls.single.variantId?.value, 'var_ui_cd1');

      // 5. 切回正片后点击主播放按钮，先按 Esc 收起抽屉（不直接退出），再次按 Esc 返回
      await tester.tap(
        find.byKey(const ValueKey<String>('detail_tab_episodes')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('detail_primary_play_button')));
      await tester.pump();
      expect(harness.navigator.videoPlayerCalls.length, 2);

      await tester.tap(find.byKey(const ValueKey<String>('detail_back_button')));
      await tester.pump();
      expect(harness.navigator.popCount, 1);
    });
  });

  group('WorkDetailPage 分类胶囊 ⊞ 弹性伸展、无 ⌄、Esc 与偏好显隐', () {
    late DetailTestHarness harness;
    late WorkDetailController ctrl;
    late DetailTabContribution scanTab;

    setUp(() async {
      harness = await DetailTestHarness.create();
      await _seedRichWork(harness);
      scanTab = DetailTabContribution(
        id: 'scan_viewer',
        label: 'Scan',
        iconKey: 'scan',
        order: 40,
        isVisibleForWork: (_) async => true,
        viewBuilder: (_) => const SizedBox.shrink(),
      );
      ctrl = harness.createController(
        const WorkId.trusted('w_ui_1'),
        platform: KonataPlatform.windows,
        detailTabs: <DetailTabContribution>[scanTab],
      );
      await ctrl.load();
    });

    testWidgets('点击高亮分类弹出/收回 ⊞，支持点击背景/Esc 收起且实时响应 shared prefs', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrapDetailTestApp(
          dependencies: harness.buildDependencies(
            detailTabs: <DetailTabContribution>[scanTab],
          ),
          child: WorkDetailPage(
            workId: const WorkId.trusted('w_ui_1'),
            controllerOverride: ctrl,
            imageLoaderOverride: createStubImageLoader(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      // 展开态右端可见 `⊞`，且彻底不存在独立 `⌄` 收起按钮
      expect(find.byKey(const Key('detail_category_capsule')), findsOneWidget);
      expect(find.byKey(const Key('detail_drawer_view_all_button')), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
      expect(find.byKey(const Key('detail_drawer_expanded_body')), findsOneWidget);

      // 再次点击当前高亮「正片」分类 -> 收起抽屉并收回 `⊞`
      await tester.tap(find.byKey(const ValueKey<String>('detail_tab_episodes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.byKey(const Key('detail_drawer_collapsed_body')), findsOneWidget);
      expect(find.byKey(const Key('detail_drawer_view_all_button')), findsNothing);

      // 重新点击「正片」展开 -> `⊞` 再次弹出
      await tester.tap(find.byKey(const ValueKey<String>('detail_tab_episodes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.byKey(const Key('detail_drawer_view_all_button')), findsOneWidget);

      // 桌面点击背景空白区 -> 收起抽屉
      await tester.tapAt(const Offset(900, 180));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.byKey(const Key('detail_drawer_collapsed_body')), findsOneWidget);

      // 再次展开后按 Esc：首按先收起抽屉不退页，再按才退回媒体库
      await tester.tap(find.byKey(const ValueKey<String>('detail_tab_episodes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.byKey(const Key('detail_drawer_collapsed_body')), findsOneWidget);
      expect(harness.navigator.popCount, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(harness.navigator.popCount, 1);

      // 验证 `feature_detail.display` 共享开关实时生效（隐藏 CD/Scan 与简介）
      expect(find.byKey(const ValueKey<String>('detail_tab_cd')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('detail_tab_scan_viewer')), findsOneWidget);
      await tester.runAsync(() async {
        await ctrl.setShowCdTab(false);
        await ctrl.setShowScanTab(false);
        await ctrl.setShowOverview(false);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey<String>('detail_tab_cd')), findsNothing);
      expect(find.byKey(const ValueKey<String>('detail_tab_scan_viewer')), findsNothing);
      expect(find.textContaining('繁华的人类文明毁灭之后'), findsNothing);
    });
  });

  group('WorkDetailPage 系列选择器与竖屏 portraitBackdropRef 溶底验证', () {
    Future<DetailTestHarness> seedBigSeries({bool withPortraitArt = true}) async {
      final harness = await DetailTestHarness.create();
      await harness.repository.upsertSeriesGroup(
        SeriesGroup(
          id: 'ser_gundam',
          title: '高达系列',
          createdAt: DateTime.utc(2025, 1, 1),
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
      );
      await harness.repository.upsertMediaSource(
        const MediaSource(
          id: 'src_g',
          kind: MediaSourceKind.local,
          label: '本地盘',
          location: 'D:/Gundam',
        ),
      );
      await harness.repository.upsertWork(
        Work(
          id: 'g_01',
          tmdbId: 8001,
          tmdbMediaType: TmdbMediaType.tv,
          seriesId: 'ser_gundam',
          seriesOrder: 1,
          title: '机动战士高达 0079',
          overview: '一年战争史诗巨著简介正文。',
          year: 1979,
          posterPath: '/poster_g01.jpg',
          backdropPath: '/wide_backdrop_g01.jpg',
          portraitBackdropPath: withPortraitArt ? '/portrait_textless_g01.jpg' : null,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await harness.repository.upsertWork(
        const Work(
          id: 'g_02',
          tmdbId: 8002,
          tmdbMediaType: TmdbMediaType.movie,
          seriesId: 'ser_gundam',
          seriesOrder: 2,
          title: '机动战士高达 逆袭的夏亚',
          year: 1988,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      for (var i = 3; i <= 26; i++) {
        await harness.repository.upsertWork(
          Work(
            id: 'g_$i',
            tmdbId: 8000 + i,
            tmdbMediaType: TmdbMediaType.tv,
            seriesId: 'ser_gundam',
            seriesOrder: i,
            title: i == 5
                ? '机动战士高达 0080 口袋里的战争 OVA'
                : '机动战士高达 衍生篇 $i',
            year: 1980 + i,
            scrapeStatus: ScrapeStatus.matched,
          ),
        );
      }
      await harness.repository.upsertEpisode(
        const Episode(
          id: 'ep_g1',
          workId: 'g_01',
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '高达站立在大地上',
        ),
      );
      await harness.repository.upsertMediaVariant(
        const MediaVariant(
          id: 'var_g1',
          workId: 'g_01',
          episodeId: 'ep_g1',
          sourceId: 'src_g',
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: 1000,
        ),
      );
      return harness;
    }

    late DetailTestHarness desktopHarness;
    late WorkDetailController desktopCtrl;
    late DetailTestHarness phoneArtHarness;
    late WorkDetailController phoneArtCtrl;
    late DetailTestHarness tabletNoArtHarness;
    late WorkDetailController tabletNoArtCtrl;

    setUp(() async {
      desktopHarness = await seedBigSeries(withPortraitArt: true);
      desktopCtrl = desktopHarness.createController(
        const WorkId.trusted('g_01'),
        platform: KonataPlatform.windows,
      );
      await desktopCtrl.load();

      phoneArtHarness = await seedBigSeries(withPortraitArt: true);
      phoneArtCtrl = phoneArtHarness.createController(
        const WorkId.trusted('g_01'),
        platform: KonataPlatform.androidPhone,
      );
      await phoneArtCtrl.load();

      tabletNoArtHarness = await seedBigSeries(withPortraitArt: false);
      tabletNoArtCtrl = tabletNoArtHarness.createController(
        const WorkId.trusted('g_01'),
        platform: KonataPlatform.androidTablet,
      );
      await tabletNoArtCtrl.load();
    });

    testWidgets('桌面宽窗弹出居中毛玻璃系列弹窗并支持 TV/剧场版/OVA 筛选与实时搜索切换', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrapDetailTestApp(
          dependencies: desktopHarness.buildDependencies(
            platform: KonataPlatform.windows,
          ),
          child: WorkDetailPage(
            workId: const WorkId.trusted('g_01'),
            controllerOverride: desktopCtrl,
            imageLoaderOverride: createStubImageLoader(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(find.text('高达系列 · 26 部'), findsOneWidget);
      await tester.tap(find.byKey(const Key('series_switcher_capsule')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(find.byKey(const Key('series_selector_glass_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('series_filter_ova')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.textContaining('口袋里的战争'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('series_filter_all')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('series_selector_search_field')),
        '逆袭的夏亚',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey<String>('series_member_item_g_02')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('series_member_item_g_02')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        desktopHarness.navigator.workDetailCalls.map((c) => c.workId),
        contains(const WorkId.trusted('g_02')),
      );
    });

    testWidgets('Android 手机竖屏展示 portraitBackdropRef 溶底、横向选集卡与底部系列抽屉，空时回退海报绝不强裁 16:9 横图', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrapDetailTestApp(
          dark: false,
          dependencies: phoneArtHarness.buildDependencies(
            platform: KonataPlatform.androidPhone,
          ),
          child: WorkDetailPage(
            workId: const WorkId.trusted('g_01'),
            controllerOverride: phoneArtCtrl,
            imageLoaderOverride: createStubImageLoader(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(find.byKey(const ValueKey<String>('detail_portrait_hero_artwork')), findsOneWidget);
      expect(find.byKey(const Key('detail_portrait_synopsis_section')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('episode_card_ep_g1')), findsOneWidget);
      expect(find.byKey(const Key('detail_gear_menu_button')), findsOneWidget);

      // 手机端点击系列胶囊弹出底部全宽毛玻璃抽屉
      await tester.tap(find.byKey(const Key('series_switcher_capsule')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.byKey(const Key('series_selector_bottom_sheet')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const Key('series_selector_bottom_sheet')))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      // 验证 portraitBackdropPath 为空时回退常规竖版海报，绝不强裁 16:9 横版原画
      tester.view.physicalSize = const Size(768, 1024);
      await tester.pumpWidget(
        wrapDetailTestApp(
          dark: true,
          dependencies: tabletNoArtHarness.buildDependencies(
            platform: KonataPlatform.androidTablet,
          ),
          child: WorkDetailPage(
            workId: const WorkId.trusted('g_01'),
            controllerOverride: tabletNoArtCtrl,
            imageLoaderOverride: createStubImageLoader(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(
        find.byKey(const ValueKey<String>('detail_portrait_hero_poster_fallback')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('detail_wide_backdrop_stage')), findsNothing);
    });
  });

  group('WorkDetailPage 桌面 / 平板 / 手机横竖屏四视口零溢出', () {
    const viewports = <({String name, Size size, KonataPlatform platform})>[
      (
        name: '桌面宽屏 1440x900',
        size: Size(1440, 900),
        platform: KonataPlatform.windows,
      ),
      (
        name: '平板横屏 1280x800',
        size: Size(1280, 800),
        platform: KonataPlatform.androidTablet,
      ),
      (
        name: '平板竖屏 768x1024',
        size: Size(768, 1024),
        platform: KonataPlatform.androidTablet,
      ),
      (
        name: '平板小横屏 1024x700',
        size: Size(1024, 700),
        platform: KonataPlatform.androidTablet,
      ),
      (
        name: '手机竖屏 390x844',
        size: Size(390, 844),
        platform: KonataPlatform.androidPhone,
      ),
      (
        name: '手机紧凑竖屏 390x780',
        size: Size(390, 780),
        platform: KonataPlatform.androidPhone,
      ),
      (
        name: '手机窄宽安全兜底 844x390',
        size: Size(844, 390),
        platform: KonataPlatform.androidPhone,
      ),
    ];

    for (final vp in viewports) {
      group(vp.name, () {
        late DetailTestHarness harness;
        late WorkDetailController ctrl;

        setUp(() async {
          harness = await DetailTestHarness.create();
          await _seedRichWork(harness);
          ctrl = harness.createController(
            const WorkId.trusted('w_ui_1'),
            platform: vp.platform,
          );
          await ctrl.load();
        });

        testWidgets('明暗双主题渲染零异常零溢出', (tester) async {
          tester.view.physicalSize = vp.size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          for (final dark in const <bool>[true, false]) {
            await tester.pumpWidget(
              wrapDetailTestApp(
                dark: dark,
                dependencies: harness.buildDependencies(platform: vp.platform),
                child: WorkDetailPage(
                  workId: const WorkId.trusted('w_ui_1'),
                  controllerOverride: ctrl,
                  imageLoaderOverride: createStubImageLoader(),
                ),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 80));

            expect(
              tester.takeException(),
              isNull,
              reason: '${vp.name} (dark=$dark) 出现布局或溢出异常',
            );
            expect(find.text('少女终末旅行'), findsOneWidget);
            expect(find.text('2017 · Bangumi 8.8'), findsOneWidget);
            expect(find.text('3 集正片'), findsNothing);
            expect(find.text('1 项特典'), findsNothing);
            expect(find.text('1 张 CD'), findsNothing);
            expect(
              find.byKey(const ValueKey('detail_tab_episodes')),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('detail_tab_cd')), findsOneWidget);
          }
        });
      });
    }
  });
}
