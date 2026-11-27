import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import 'support/detail_test_fixtures.dart';

final class _FakeVideoRelay implements DesktopRelayGateway {
  bool configured = false;
  bool succeeds = true;
  int calls = 0;
  int? start;
  String? target;
  VariantId? variant;
  PlaybackProgressCallback? progress;

  @override
  Future<List<RelayTargetDescriptor>> listVideoTargets() async => configured
      ? [
          const RelayTargetDescriptor(
            id: 'other',
            name: '其他',
            kindKey: 'mpv',
            isDefault: false,
            configured: true,
          ),
          const RelayTargetDescriptor(
            id: 'default',
            name: '默认',
            kindKey: 'mpv',
            isDefault: true,
            configured: true,
          ),
        ]
      : [];

  @override
  Future<LaunchPlaybackResult> launchVideo({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    String? preferredKindKey,
    int startSeconds = 0,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  }) async {
    calls++;
    start = startSeconds;
    target = targetId;
    this.variant = variant.id;
    progress = onProgressUpdate;
    return LaunchPlaybackResult(
      launched: succeeds,
      message: succeeds ? '已启动外部播放器' : '播放器启动失败',
    );
  }

  @override
  Future<LaunchPlaybackResult> launchAudio({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    int startSeconds = 0,
    double? exactStartSeconds,
    PlaybackProgressCallback? onProgressUpdate,
  }) async => throw StateError('不应调用外部音频');

  @override
  Future<LaunchPlaybackResult> launchAudioAlbum(
    ExternalAudioAlbumRelayRequest request, {
    ExternalAudioProgressCallback? onTrackProgress,
  }) async => throw StateError('不应调用外部音频专辑');

  @override
  Future<FoobarComponentStatusSnapshot> probeAudioPlayerStatus({
    int beefwebPort = 8880,
  }) async => throw StateError('不应探测音频组件');

  @override
  Future<void> stopActiveExternalAudioSession({int beefwebPort = 8880}) async =>
      throw StateError('不应直接停止外部音频');
}

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
      overview: '繁华的人类文明毁灭之后，两位少女驾驶履带摩托在废墟都市之间缓缓穿行，寻找着微光与希望。',
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

    testWidgets('选集右键接力默认外部播放器并持久化真实进度', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final relay = _FakeVideoRelay();
      var prepares = 0;
      await harness.repository.recordPlayback(
        PlaybackRecord(
          id: 'w_ui_1::ep_ui_1',
          workId: 'w_ui_1',
          episodeId: 'ep_ui_1',
          variantId: 'var_ui_1',
          playedAt: DateTime.utc(2025),
          positionSeconds: 320,
          durationSeconds: 1450,
          sourceType: MediaSourceKind.local,
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第一集',
        ),
      );
      await tester.pumpWidget(
        wrapDetailTestApp(
          dependencies: harness.buildDependencies(
            desktopRelayGateway: relay,
            prepareExternalVideo: () async {
              prepares++;
            },
          ),
          child: WorkDetailPage(
            workId: const WorkId.trusted('w_ui_1'),
            controllerOverride: ctrl,
            imageLoaderOverride: createStubImageLoader(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail_tab_episodes')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('episode_card_ep_ui_1'));
      Future<void> clickExternal() async {
        await tester.tapAt(
          tester.getCenter(card),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('episode_menu_external_play')),
        );
        await tester.pumpAndSettle();
      }

      await clickExternal();
      expect(relay.calls, 0);
      expect(prepares, 0);
      relay.configured = true;
      await clickExternal();
      expect(relay.calls, 1);
      expect(prepares, 1);
      expect(relay.target, 'default');
      expect(relay.start, 320);
      expect(relay.variant?.value, 'var_ui_1');
      expect(harness.navigator.videoPlayerCalls, isEmpty);
      await relay.progress!(500, 1450, isFinal: false);
      await tester.pumpAndSettle();
      final saved = await harness.repository.getPlaybacksByWork('w_ui_1');
      expect(saved.single.positionSeconds, 500);
      expect(saved.single.isCompleted, isFalse);
      await relay.progress!(1400, 1450, isFinal: true);
      await tester.pumpAndSettle();
      expect(
        (await harness.repository.getPlaybacksByWork(
          'w_ui_1',
        )).single.isCompleted,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    test('标记单集保留既有播放记录与实际版本且不修改其他集', () async {
      final ep = (await harness.repository.getEpisodesByWork(
        'w_ui_1',
      )).firstWhere((e) => e.id == 'ep_ui_2');
      await harness.repository.recordPlayback(
        PlaybackRecord(
          id: 'existing-record',
          workId: 'w_ui_1',
          episodeId: ep.id,
          variantId: 'var_ui_2',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '第二集',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime.utc(2025),
          positionSeconds: 320,
          durationSeconds: 1450,
        ),
      );
      final completion = harness.domainEventBus
          .on<EpisodeCompletionChangedEvent>()
          .first;
      final marked = await ctrl.markEpisodeWatched(ep);
      final event = await completion;
      expect(event.workId.value, 'w_ui_1');
      expect(event.episodeId.value, ep.id);
      expect(event.completed, isTrue);
      expect(marked.id, 'existing-record');
      expect(marked.positionSeconds, 320);
      expect(marked.durationSeconds, 1450);
      expect(marked.isCompleted, isTrue);
      final again = await ctrl.markEpisodeWatched(ep);
      expect(again.id, marked.id);
      expect(again.playedAt, marked.playedAt);
      final saved = await harness.repository.getPlaybacksByWork('w_ui_1');
      expect(saved.length, 1);
      expect(saved.single.episodeId, ep.id);
      expect(saved.single.isCompleted, isTrue);
      expect(saved.single.durationSeconds, 1450);
    });

    test('批量已看保留实际版本与断点，跳过未映射分集和特典', () async {
      await harness.repository.upsertEpisode(
        const Episode(
          id: 'ep_unmapped',
          workId: 'w_ui_1',
          seasonNumber: 1,
          episodeNumber: 4,
          category: EpisodeCategory.main,
        ),
      );
      await harness.repository.upsertMediaVariant(
        const MediaVariant(
          id: 'var_ui_2_alt',
          workId: 'w_ui_1',
          episodeId: 'ep_ui_2',
          sourceId: 'src_ui',
          relativePath: 'Main/Alt/02.mkv',
          fileName: '02.mkv',
          fileSize: 1024,
        ),
      );
      final previouslyCompleted = await ctrl.markEpisodeWatched(
        (await harness.repository.getEpisodesByWork(
          'w_ui_1',
        )).firstWhere((episode) => episode.id == 'ep_ui_3'),
      );
      await harness.repository.recordPlayback(
        PlaybackRecord(
          id: 'real-alt-history',
          workId: 'w_ui_1',
          episodeId: 'ep_ui_2',
          variantId: 'var_ui_2_alt',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '第二集',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime.utc(2025),
          positionSeconds: 320,
          durationSeconds: 1450,
        ),
      );
      final completions = <EpisodeCompletionChangedEvent>[];
      final subscription = harness.domainEventBus
          .on<EpisodeCompletionChangedEvent>()
          .listen(completions.add);
      addTearDown(subscription.cancel);

      await ctrl.markAllMainEpisodesWatched();
      await Future<void>.delayed(Duration.zero);
      final records = {
        for (final record in await harness.repository.getPlaybacksByWork(
          'w_ui_1',
        ))
          record.episodeId: record,
      };
      expect(records.keys, unorderedEquals(['ep_ui_1', 'ep_ui_2', 'ep_ui_3']));
      expect(records.values.every((record) => record.isCompleted), isTrue);
      final first = records['ep_ui_1']!;
      expect(first.id, 'w_ui_1::ep_ui_1');
      expect(first.variantId, 'var_ui_1');
      expect((first.positionSeconds, first.durationSeconds), (0, 0));
      final second = records['ep_ui_2']!;
      expect(second.id, 'real-alt-history');
      expect(second.variantId, 'var_ui_2_alt');
      expect((second.positionSeconds, second.durationSeconds), (320, 1450));
      expect(records['ep_ui_3']!.playedAt, previouslyCompleted.playedAt);
      expect(
        completions.map(
          (event) =>
              (event.workId.value, event.episodeId.value, event.completed),
        ),
        unorderedEquals([
          ('w_ui_1', 'ep_ui_1', true),
          ('w_ui_1', 'ep_ui_2', true),
        ]),
      );

      await ctrl.markAllMainEpisodesWatched();
      await Future<void>.delayed(Duration.zero);
      expect(completions, hasLength(2));
      final afterRetry = await harness.repository.getPlaybacksByWork('w_ui_1');
      expect(afterRetry, hasLength(3));
      for (final record in afterRetry) {
        expect(record.playedAt, records[record.episodeId]!.playedAt);
      }
    });

    testWidgets('分集菜单调整季集号后保存真实映射且仅修改目标文件', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        wrapDetailTestApp(
          dependencies: harness.buildDependencies(),
          child: WorkDetailPage(
            workId: const WorkId.trusted('w_ui_1'),
            controllerOverride: ctrl,
            imageLoaderOverride: createStubImageLoader(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail_tab_episodes')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('episode_card_ep_ui_1'));
      await tester.tapAt(
        tester.getCenter(card),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('episode_menu_adjust_mapping')),
      );
      await tester.pumpAndSettle();
      final panel = tester.widget<FileMappingPanel>(
        find.byType(FileMappingPanel),
      );
      expect(panel.selectedVariantIds, {'var_ui_1'});
      Finder field(String hint) => find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is KonataSoftTextField && w.hintText == hint,
        ),
        matching: find.byType(EditableText),
      );
      await tester.enterText(field('季'), '2');
      await tester.enterText(field('起始集'), '8');
      await tester.tap(find.text('顺延编号'));
      await tester.pumpAndSettle();
      final row = panel.rows.firstWhere((r) => r.variant.id == 'var_ui_1');
      expect(row.seasonNumber, 2);
      expect(row.episodeNumber, 8);
      expect(row.isModified, isTrue);
      await tester.tap(find.text('保存并锁定变更'));
      await tester.pumpAndSettle();
      expect(find.byType(FileMappingPanel), findsNothing);
      final variants = await harness.repository.getVariantsByWork('w_ui_1');
      final changed = variants.firstWhere((v) => v.id == 'var_ui_1');
      expect(changed.mappingLocked, isTrue);
      final episodes = await harness.repository.getEpisodesByWork('w_ui_1');
      final target = episodes.firstWhere((e) => e.id == changed.episodeId);
      expect(target.seasonNumber, 2);
      expect(target.episodeNumber, 8);
      expect(
        variants.firstWhere((v) => v.id == 'var_ui_2').episodeId,
        'ep_ui_2',
      );
      expect(harness.navigator.videoPlayerCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '动态挂载模拟 DetailTabContribution 与 DetailActionContribution 并完整响应点击路由',
      (tester) async {
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
          find.byKey(
            const ValueKey<String>('detail_ext_primary_mock_primary_action'),
          ),
          findsNothing,
        );

        // 1. 打开唯一齿轮菜单触发已收口的外部扩展动作，并确认仅保留封面与横版背景入口
        await tester.tap(find.byKey(const Key('detail_gear_menu_button')));
        await tester.pumpAndSettle();
        expect(find.text('编辑竖版原画'), findsNothing);
        expect(find.text('编辑封面海报'), findsOneWidget);
        expect(find.text('编辑横版背景'), findsOneWidget);
        const expectedLabels = [
          '重新抓取数据',
          '手动编辑信息',
          '手动精确匹配',
          '管理系列编组',
          '并入其他作品',
          '编辑封面海报',
          '编辑横版背景',
          '编辑标题徽标',
          '移除这部作品',
        ];
        Finder menuLabel(String label) => find.descendant(
          of: find.byType(KonataPopoverOptionTile),
          matching: find.text(label),
        );
        for (final label in expectedLabels) {
          expect(menuLabel(label), findsOneWidget);
        }
        for (var i = 1; i < expectedLabels.length; i++) {
          expect(
            tester.getTopLeft(menuLabel(expectedLabels[i])).dy,
            greaterThan(tester.getTopLeft(menuLabel(expectedLabels[i - 1])).dy),
          );
        }
        for (final label in ['刷新源目录变更', '全剧标为已看完', '清空观看进度', '从主媒体库隐藏']) {
          expect(menuLabel(label), findsNothing);
        }
        expect(
          find.byKey(
            const ValueKey<String>('detail_ext_gear_mock_primary_action'),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(
            const ValueKey<String>('detail_ext_gear_mock_primary_action'),
          ),
        );
        await tester.pumpAndSettle();
        expect(invokedActionWorkIds, <WorkId>[const WorkId.trusted('w_ui_1')]);

        final primaryPlay = find.byKey(const Key('detail_primary_play_button'));
        expect(
          find.descendant(of: primaryPlay, matching: find.text('开始播放')),
          findsOneWidget,
        );

        // 取消移除必须保留作品及其资源关系。
        await tester.tap(find.byKey(const Key('detail_gear_menu_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除这部作品'));
        await tester.pumpAndSettle();
        expect(find.text('确认移出'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(WorkDetailPage), findsOneWidget);
        expect(await harness.repository.findWorkById('w_ui_1'), isNotNull);
        expect(
          await harness.repository.getVariantsByWork('w_ui_1'),
          hasLength(5),
        );

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
        await tester.tap(
          find.byKey(const ValueKey<String>('episode_card_ep_ui_1')),
        );
        await tester.pump();
        expect(harness.navigator.videoPlayerCalls.length, 1);
        expect(
          harness.navigator.videoPlayerCalls.single.episodeId?.value,
          'ep_ui_1',
        );

        // 4. 切换至 CD 标签并点击专辑，验证路由至音频播放器
        await tester.tap(find.byKey(const ValueKey<String>('detail_tab_cd')));
        await tester.pump(const Duration(milliseconds: 50));
        final cdCard = find.byKey(const ValueKey<String>('cd_card_var_ui_cd1'));
        expect(
          find.descendant(of: cdCard, matching: find.text('OST_Disc1')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: cdCard, matching: find.text('420 MB')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: cdCard, matching: find.text('OST_Disc1.flac')),
          findsNothing,
        );
        await tester.tap(cdCard);
        await tester.pump();
        expect(harness.navigator.audioPlayerCalls.length, 1);
        expect(
          harness.navigator.audioPlayerCalls.single.variantId?.value,
          'var_ui_cd1',
        );

        // 5. 切回正片后点击主播放按钮，先按 Esc 收起抽屉（不直接退出），再次按 Esc 返回
        await tester.tap(
          find.byKey(const ValueKey<String>('detail_tab_episodes')),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byKey(const Key('detail_primary_play_button')));
        await tester.pump();
        expect(harness.navigator.videoPlayerCalls.length, 2);

        await tester.tap(
          find.byKey(const ValueKey<String>('detail_back_button')),
        );
        await tester.pump();
        expect(harness.navigator.popCount, 1);
      },
    );
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
        kind: DetailTabKind.scan,
        iconKey: 'scan',
        order: 40,
        isVisibleForWork: (_) async => true,
        viewBuilder: (_) => const SizedBox.shrink(),
      );
      ctrl = harness.createController(
        const WorkId.trusted('w_ui_1'),
        platform: KonataPlatform.windows,
        detailTabs: <DetailTabContribution>[
          scanTab,
          DetailTabContribution(
            id: 'supplement_index',
            label: 'Scan 制作资料',
            iconKey: 'scan',
            order: 50,
            viewBuilder: (_) => const Text('制作资料索引'),
          ),
        ],
      );
      await ctrl.load();
    });

    testWidgets('续播按钮只显示继续播放，目标剧集及原断点保持不变', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      harness.databases.userState.playbackRecords.upsert(
        const PlaybackRecordEntity(
          id: 'resume-ui',
          workId: WorkId.trusted('w_ui_1'),
          episodeId: EpisodeId.trusted('ep_ui_2'),
          variantId: VariantId.trusted('var_ui_2'),
          playedAtMs: 1000,
          updatedAtMs: 1000,
          episodeNumber: 2,
          positionSeconds: 245,
          durationSeconds: 1440,
        ),
      );
      await tester.runAsync(ctrl.load);
      expect(ctrl.bundle!.resumePlan!.startSeconds, 245);
      await tester.pumpWidget(
        wrapDetailTestApp(
          dependencies: harness.buildDependencies(),
          child: WorkDetailPage(
            workId: const WorkId.trusted('w_ui_1'),
            controllerOverride: ctrl,
            imageLoaderOverride: createStubImageLoader(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('detail_primary_play_button'));
      expect(
        find.descendant(of: button, matching: find.text('继续播放')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: button, matching: find.byType(Text)),
        findsOneWidget,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        harness.navigator.videoPlayerCalls.single.episodeId?.value,
        'ep_ui_2',
      );
      expect(
        harness.navigator.videoPlayerCalls.single.variantId?.value,
        'var_ui_2',
      );
      expect(ctrl.bundle!.resumePlan!.startSeconds, 245);
    });
    testWidgets('正片卡片保持标准与紧凑剧照尺寸和字体层级', (tester) async {
      final bundle = ctrl.bundle!;
      for (final (compact, width, titleSize, fileSize, lines) in [
        (false, 244.0, 14.0, 12.0, 3),
        (true, 208.0, 13.0, 11.5, 2),
      ]) {
        for (final dpr in [1.0, 2.0]) {
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = Size(390 * dpr, 780 * dpr);
          await tester.pumpWidget(
            wrapDetailTestApp(
              child: Align(
                alignment: Alignment.topCenter,
                child: DetailBottomDrawer(
                  bundle: bundle,
                  imageLoader: createStubImageLoader(),
                  displayPreferences: const DetailDisplayPreferences(),
                  expanded: true,
                  compact: compact,
                  onTapEpisode: (_) {},
                  onTapCdVariant: (_) {},
                  onInspectEpisodeInfo: (_) {},
                  onOpenFullList: (_) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final card = find.byKey(const ValueKey('episode_card_ep_ui_1'));
          expect(card, findsOneWidget);
          expect(tester.widget<EpisodeDrawerCard>(card).compactMeta, compact);
          final still = find
              .descendant(of: card, matching: find.byType(AspectRatio))
              .first;
          final rect = tester.getSize(still);
          expect(rect.width, closeTo(width, 3));
          expect(rect.width / rect.height, closeTo(16 / 9, 0.02));
          final metadata = tester
              .widgetList<EllipsisTextWithTooltip>(
                find.descendant(
                  of: card,
                  matching: find.byType(EllipsisTextWithTooltip),
                ),
              )
              .toList();
          expect(metadata[0].style.fontSize, titleSize);
          expect(metadata[0].maxLines, 1);
          expect(metadata[1].style.fontSize, fileSize);
          expect(metadata[1].maxLines, lines);
          expect(tester.takeException(), isNull);
        }
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
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

      // 正常进入详情时默认收起，只有点击分类后才显示资源。
      expect(
        find.byKey(const Key('detail_drawer_collapsed_body')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('detail_drawer_expanded_body')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('detail_drawer_view_all_button')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('detail_tab_episodes')));
      await tester.pumpAndSettle();

      // 展开态右端可见 `⊞`，且彻底不存在独立 `⌄` 收起按钮
      expect(find.byKey(const Key('detail_category_capsule')), findsOneWidget);
      expect(
        find.byKey(const Key('detail_drawer_view_all_button')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
      expect(
        find.byKey(const Key('detail_drawer_expanded_body')),
        findsOneWidget,
      );

      expect(find.byType(Scrollbar), findsNothing);
      final infoItem = find.byKey(const ValueKey('episode_menu_media_info'));
      Future<void> checkMediaInfo(Finder card) async {
        await tester.tapAt(
          tester.getCenter(card),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(infoItem, findsOneWidget);
        expect(harness.navigator.videoPlayerCalls, isEmpty);
        await tester.tap(infoItem);
        await tester.pumpAndSettle();
        final mediaInfo = find.byType(EpisodeMediaInfoDialog);
        expect(mediaInfo, findsOneWidget);
        expect(
          find.descendant(of: mediaInfo, matching: find.text('[Subs] 01.mkv')),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: mediaInfo, matching: find.text('关闭')),
        );
        await tester.pumpAndSettle();
        expect(mediaInfo, findsNothing);
        expect(card, findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      final drawerCard = find.byKey(const ValueKey('episode_card_ep_ui_1'));
      await checkMediaInfo(drawerCard);
      await tester.tapAt(
        tester.getCenter(drawerCard),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('episode_menu_adjust_mapping')),
      );
      await tester.pumpAndSettle();
      final mapping = find.byType(FileMappingPanel);
      expect(mapping, findsOneWidget);
      final panel = tester.widget<FileMappingPanel>(mapping);
      expect(panel.selectedVariantIds, {'var_ui_1'});
      expect(panel.rows.first.variant.id, 'var_ui_1');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(mapping, findsNothing);
      expect(harness.navigator.videoPlayerCalls, isEmpty);
      await tester.tap(find.byKey(const Key('detail_drawer_view_all_button')));
      await tester.pumpAndSettle();
      expect(find.text('少女终末旅行 · 完整列表'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('full_list_episode_ep_ui_1')),
        findsOneWidget,
      );
      await checkMediaInfo(
        find.byKey(const ValueKey('full_list_episode_ep_ui_1')),
      );
      final card = find.byKey(const ValueKey('full_list_episode_ep_ui_1'));
      final mark = find.byKey(const ValueKey('episode_menu_mark_watched'));
      await tester.tapAt(
        tester.getCenter(card),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(mark, findsOneWidget);
      await tester.tap(mark);
      await tester.pumpAndSettle();
      final records = await harness.repository.getPlaybacksByWork('w_ui_1');
      expect(records.length, 1);
      expect(records.single.episodeId, 'ep_ui_1');
      expect(records.single.id, 'w_ui_1::ep_ui_1');
      expect(records.single.variantId, 'var_ui_1');
      expect(records.single.isCompleted, isTrue);
      expect(records.single.durationSeconds, 0);
      expect(
        tester.widget<EpisodeDrawerCard>(card).playback?.isCompleted,
        isTrue,
      );
      expect(harness.navigator.videoPlayerCalls, isEmpty);
      await tester.tapAt(
        tester.getCenter(card),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(mark, findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      final dialog = find.byType(KonataGlassDialog);

      final list = find.byKey(const ValueKey('detail_full_list_episodes'));
      final bar = find.descendant(
        of: dialog,
        matching: find.byType(KonataDraggableScrollbar),
      );
      expect((tester.widget<ListView>(list).padding! as EdgeInsets).right, 0);
      expect(
        tester.getRect(bar).right - tester.getRect(list).right,
        greaterThanOrEqualTo(
          KonataTheme.scrollbarMaxThickness + KonataTheme.scrollbarContentGap,
        ),
      );
      final initialDialog = tester.widget<KonataGlassDialog>(dialog);
      expect(initialDialog.width, closeTo(1280 * 0.84, 0.01));
      expect(initialDialog.height, closeTo(800 * 0.82, 0.01));
      final resizeHandle = find.byKey(
        const ValueKey('detail_full_list_resize_handle'),
      );
      expect(resizeHandle, findsOneWidget);
      await tester.drag(resizeHandle, const Offset(-60, -40));
      await tester.pumpAndSettle();
      final resizedDialog = tester.widget<KonataGlassDialog>(dialog);
      expect(resizedDialog.width, lessThan(initialDialog.width));
      expect(resizedDialog.height, lessThan(initialDialog.height!));
      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.byKey(const ValueKey('detail_tab_extras')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('full_list_episode_ep_ui_sp1')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.byKey(const ValueKey('detail_tab_cd')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('full_list_cd_var_ui_cd1')),
        findsOneWidget,
      );
      final fullCdCard = find.byKey(const ValueKey('full_list_cd_var_ui_cd1'));
      expect(
        find.descendant(of: fullCdCard, matching: find.text('420 MB')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: fullCdCard, matching: find.text('OST_Disc1.flac')),
        findsNothing,
      );
      await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(EditableText)),
        '不存在的文件',
      );
      await tester.pumpAndSettle();
      expect(find.text('没有符合当前筛选条件的文件'), findsOneWidget);
      Navigator.of(tester.element(dialog)).pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('detail_drawer_view_all_button')),
        findsOneWidget,
      );

      final capsule = find.byKey(const Key('detail_category_capsule'));
      final initialTop = tester.getTopLeft(capsule).dy;
      final initialHeight = tester.getSize(capsule).height;
      for (final tab in ['extras', 'cd', 'scan_viewer', 'episodes']) {
        await tester.tap(find.byKey(ValueKey('detail_tab_$tab')));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(capsule).dy, closeTo(initialTop, 0.01));
        expect(tester.getSize(capsule).height, closeTo(initialHeight, 0.01));
      }

      // 再次点击当前高亮「正片」分类 -> 收起抽屉并收回 `⊞`
      await tester.tap(
        find.byKey(const ValueKey<String>('detail_tab_episodes')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(
        find.byKey(const Key('detail_drawer_collapsed_body')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('detail_drawer_view_all_button')),
        findsNothing,
      );

      // 重新点击「正片」展开 -> `⊞` 再次弹出
      await tester.tap(
        find.byKey(const ValueKey<String>('detail_tab_episodes')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(
        find.byKey(const Key('detail_drawer_view_all_button')),
        findsOneWidget,
      );

      // 桌面点击背景空白区 -> 收起抽屉
      await tester.tapAt(const Offset(900, 180));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(
        find.byKey(const Key('detail_drawer_collapsed_body')),
        findsOneWidget,
      );

      // 再次展开后按 Esc：首按先收起抽屉不退页，再按才退回媒体库
      await tester.tap(
        find.byKey(const ValueKey<String>('detail_tab_episodes')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(
        find.byKey(const Key('detail_drawer_collapsed_body')),
        findsOneWidget,
      );
      expect(harness.navigator.popCount, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(harness.navigator.popCount, 1);

      // 验证 `feature_detail.display` 共享开关实时生效（隐藏 CD/Scan 与简介）
      expect(
        find.byKey(const ValueKey<String>('detail_tab_cd')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('detail_tab_scan_viewer')),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await ctrl.setShowCdTab(false);
        await ctrl.setShowScanTab(false);
        await ctrl.setShowOverview(false);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey<String>('detail_tab_cd')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('detail_tab_scan_viewer')),
        findsNothing,
      );
      expect(find.textContaining('繁华的人类文明毁灭之后'), findsNothing);
      const supplementTab = ValueKey<String>('detail_tab_supplement_index');
      expect(find.byKey(supplementTab), findsOneWidget);
      await tester.tap(find.byKey(supplementTab));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.tap(find.byKey(const Key('detail_drawer_view_all_button')));
      await tester.pumpAndSettle();
      expect(find.text('少女终末旅行 · 完整列表'), findsOneWidget);
      expect(find.byKey(supplementTab), findsWidgets);
      expect(
        find.byKey(const ValueKey<String>('detail_tab_scan_viewer')),
        findsNothing,
      );
      expect(find.text('制作资料索引'), findsWidgets);
    });
  });

  group('WorkDetailPage 系列选择器与竖屏 portraitBackdropRef 溶底验证', () {
    Future<DetailTestHarness> seedBigSeries({
      bool withPortraitArt = true,
    }) async {
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
          portraitBackdropPath: withPortraitArt
              ? '/portrait_textless_g01.jpg'
              : null,
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
            title: i == 5 ? '机动战士高达 0080 口袋里的战争 OVA' : '机动战士高达 衍生篇 $i',
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

    testWidgets('桌面宽窗弹出居中毛玻璃系列弹窗并支持 TV/剧场版/OVA 筛选与实时搜索切换', (tester) async {
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

      expect(
        find.byKey(const Key('series_selector_glass_dialog')),
        findsOneWidget,
      );
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
      expect(
        find.byKey(const ValueKey<String>('series_member_item_g_02')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('series_member_item_g_02')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        desktopHarness.navigator.workDetailCalls.map((c) => c.workId),
        contains(const WorkId.trusted('g_02')),
      );
    });

    testWidgets(
      'Android 手机竖屏展示 portraitBackdropRef 溶底、横向选集卡与底部系列抽屉，空时回退海报绝不强裁 16:9 横图',
      (tester) async {
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

        expect(
          find.byKey(const ValueKey<String>('detail_portrait_hero_artwork')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('detail_portrait_synopsis_section')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('detail_drawer_collapsed_body')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('episode_card_ep_g1')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('detail_tab_episodes')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey<String>('episode_card_ep_g1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('detail_gear_menu_button')),
          findsOneWidget,
        );

        // 手机端点击系列胶囊弹出底部全宽毛玻璃抽屉
        await tester.tap(find.byKey(const Key('series_switcher_capsule')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        expect(
          find.byKey(const Key('series_selector_bottom_sheet')),
          findsOneWidget,
        );
        Navigator.of(
          tester.element(find.byKey(const Key('series_selector_bottom_sheet'))),
        ).pop();
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
          find.byKey(
            const ValueKey<String>('detail_portrait_hero_poster_fallback'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('detail_wide_backdrop_stage')),
          findsNothing,
        );
      },
    );
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

          Rect? previousCapsule;
          Rect? previousPlay;
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
            expect(find.text('2017 · 3 话 · Bangumi 8.8'), findsOneWidget);
            expect(find.text('3 集正片'), findsNothing);
            expect(find.text('1 项特典'), findsNothing);
            expect(find.text('1 张 CD'), findsNothing);
            expect(
              find.byKey(const ValueKey('detail_tab_episodes')),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('detail_tab_cd')), findsOneWidget);
            expect(
              find.byKey(const Key('detail_drawer_expanded_body')),
              findsNothing,
            );
            final capsule = find.byKey(const Key('detail_category_capsule'));
            final play = find.byKey(const Key('detail_primary_play_button'));
            if (vp.platform == KonataPlatform.windows &&
                vp.size.width >= 760 &&
                vp.size.height >= 540) {
              expect(tester.element(capsule).palette.isDark, isTrue);
              expect(
                tester.element(play).palette.primaryButtonFg,
                const Color(0xFF20242C),
              );
              final capsuleRect = tester.getRect(capsule);
              final playRect = tester.getRect(play);
              if (previousCapsule != null) {
                expect(capsuleRect, previousCapsule);
                expect(playRect, previousPlay);
              }
              previousCapsule = capsuleRect;
              previousPlay = playRect;
            }
          }
        });
      });
    }
  });
}
