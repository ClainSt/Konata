import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';

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
      expect(find.text('扩展动作'), findsOneWidget);

      // 1. 点击外部扩展按钮
      await tester.tap(
        find.byKey(const ValueKey<String>('detail_ext_primary_mock_primary_action')),
      );
      await tester.pump();
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

      // 5. 点击主播放按钮与返回按钮，验证主舞台操作路由闭环
      await tester.tap(find.byKey(const Key('detail_primary_play_button')));
      await tester.pump();
      expect(harness.navigator.videoPlayerCalls.length, 2);

      await tester.tap(find.byKey(const ValueKey<String>('detail_back_button')));
      await tester.pump();
      expect(harness.navigator.popCount, 1);
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
        name: '平板横屏 1024x700',
        size: Size(1024, 700),
        platform: KonataPlatform.androidTablet,
      ),
      (
        name: '手机竖屏 390x780',
        size: Size(390, 780),
        platform: KonataPlatform.androidPhone,
      ),
      (
        name: '手机横屏 844x390',
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
          }
        });
      });
    }
  });
}
