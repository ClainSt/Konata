import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/series_group.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/audio/immersive_audio_page.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/detail/detail_bottom_drawer.dart';
import 'package:ccplayer/presentation/detail/detail_full_list_dialog.dart';
import 'package:ccplayer/presentation/detail/detail_hero_info.dart';
import 'package:ccplayer/presentation/detail/series_switcher_dropdown.dart';
import 'package:ccplayer/presentation/detail/work_detail_page.dart';
import 'package:ccplayer/presentation/dialogs/series_manage_dialog.dart';
import 'package:ccplayer/presentation/dialogs/work_merge_target_dialog.dart';
import 'package:ccplayer/presentation/history/playback_history_page.dart';
import 'package:ccplayer/presentation/sources/source_selected_scope_panel.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';

final Uint8List _sample1x1Png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _Stage1StubVideoController extends VideoPlaybackController {
  _Stage1StubVideoController(super.request)
    : super(
        deferBootstrap: true,
        initialState: VideoPlaybackState(
          isInitializing: false,
          isBuffering: false,
          hasFirstFrame: true,
          isPlaying: true,
          currentWork: request.work,
          currentBundle: request.bundle,
          currentEpisode: request.episode,
          currentVariant: request.variant,
          positionSeconds: 120,
          durationSeconds: 1420,
        ),
      );

  @override
  void togglePlayPause() {
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> closeAndRelease() async {
    state = state.copyWith(isClosing: true);
  }
}

class _Stage1StubAudioNotifier extends AudioPlaybackNotifier {
  _Stage1StubAudioNotifier(AudioPlaybackState initial)
    : super(initialState: initial);

  @override
  Future<void> toggleMute() async {
    state = state.copyWith(isMuted: !state.isMuted);
  }

  @override
  void cycleLoopMode() {}
}

Widget _wrapApp(
  Widget child, {
  ThemeMode themeMode = ThemeMode.dark,
  double textScale = 1.0,
  EdgeInsets padding = EdgeInsets.zero,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: overrides,
    child: MaterialApp(
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: themeMode,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (ctx, inner) {
        final mq = MediaQuery.of(ctx);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: padding,
            viewPadding: padding,
          ),
          child: inner ?? const SizedBox.shrink(),
        );
      },
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    SharedPreferences.setMockInitialValues(const {});
  });

  group('第四轮阶段 1 · 纯界面排版与文案验收回归', () {
    testWidgets(
      '01：播放记录卡片进度行底边与封面底边差值 <= 1px（5 尺寸 × 双主题 × 双字号缩放 × 单双行标题）',
      (tester) async {
        addTearDown(() {
          tester.view.reset();
          debugDefaultTargetPlatformOverride = null;
        });

        const shortWork = Work(
          id: 'w_short',
          title: '加速世界',
          year: 2012,
          posterPath: '/short.jpg',
          scrapeStatus: ScrapeStatus.matched,
        );
        const longWork = Work(
          id: 'w_long',
          title: '16bit的感动 ANOTHER LAYER 超长副标题测试两行折行与截断边界验证',
          year: 2023,
          posterPath: '/long.jpg',
          scrapeStatus: ScrapeStatus.matched,
        );
        final videoRecShort = PlaybackRecord(
          id: 'rec_v_short',
          workId: shortWork.id,
          episodeId: 'ep_1',
          variantId: 'var_v_1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '加速',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 19, 1, 55),
          positionSeconds: 50,
          durationSeconds: 1421,
        );
        final videoRecLong = PlaybackRecord(
          id: 'rec_v_long',
          workId: longWork.id,
          episodeId: 'ep_2',
          variantId: 'var_v_2',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '我穿越了！？',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 19, 1, 58),
          positionSeconds: 1136,
          durationSeconds: 1421,
        );
        final audioRecShort = PlaybackRecord(
          id: 'rec_a_short',
          workId: shortWork.id,
          episodeId: 'cd::var_a_1',
          variantId: 'var_a_1',
          seasonNumber: 0,
          episodeTitle: '65535',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 19, 2, 0),
          positionSeconds: 93,
          durationSeconds: 193,
        );
        final audioRecLong = PlaybackRecord(
          id: 'rec_a_long',
          workId: longWork.id,
          episodeId: 'cd::var_a_2',
          variantId: 'var_a_2',
          seasonNumber: 0,
          episodeTitle: 'リンク～past and future～',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 19, 2, 5),
          positionSeconds: 120,
          durationSeconds: 260,
        );

        const viewports = <(Size, TargetPlatform)>[
          (Size(390, 780), TargetPlatform.android),
          (Size(640, 420), TargetPlatform.android),
          (Size(768, 1024), TargetPlatform.android),
          (Size(1024, 700), TargetPlatform.android),
          (Size(1440, 900), TargetPlatform.windows),
        ];

        for (final (size, platform) in viewports) {
          debugDefaultTargetPlatformOverride = platform;
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;

          for (final themeMode in const [ThemeMode.dark, ThemeMode.light]) {
            for (final scale in const [1.0, 1.15]) {
              await tester.pumpWidget(
                _wrapApp(
                  const PlaybackHistoryPage(),
                  themeMode: themeMode,
                  textScale: scale,
                  overrides: [
                    playbackHistoryProvider.overrideWith(
                      (_) async => [
                        videoRecShort,
                        videoRecLong,
                        audioRecShort,
                        audioRecLong,
                      ],
                    ),
                    libraryItemsProvider.overrideWith(
                      (_) async => const [
                        WorkLibraryItem(
                          work: shortWork,
                          variants: [],
                          episodeCount: 24,
                          releaseGroups: [],
                        ),
                        WorkLibraryItem(
                          work: longWork,
                          variants: [],
                          episodeCount: 13,
                          releaseGroups: [],
                        ),
                      ],
                    ),
                    tmdbImageLoaderProvider.overrideWithValue(
                      (_, {targetWidth, imageSize}) async => _sample1x1Png,
                    ),
                  ],
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(find.byType(IntrinsicHeight), findsNothing);

              for (final id in ['rec_v_short', 'rec_v_long']) {
                final coverBottom = tester
                    .getRect(find.byKey(ValueKey('history_video_cover_$id')))
                    .bottom;
                final rowBottom = tester
                    .getRect(find.byKey(ValueKey('history_progress_row_$id')))
                    .bottom;
                expect(
                  (rowBottom - coverBottom).abs(),
                  lessThanOrEqualTo(1.0),
                  reason:
                      '视频记录贴底失败 viewport=$size theme=$themeMode scale=$scale id=$id',
                );
              }

              await tester.tap(find.textContaining('音频'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);

              for (final id in ['rec_a_short', 'rec_a_long']) {
                final coverBottom = tester
                    .getRect(find.byKey(ValueKey('history_audio_cover_$id')))
                    .bottom;
                final rowBottom = tester
                    .getRect(find.byKey(ValueKey('history_progress_row_$id')))
                    .bottom;
                expect(
                  (rowBottom - coverBottom).abs(),
                  lessThanOrEqualTo(1.0),
                  reason:
                      '音频记录贴底失败 viewport=$size theme=$themeMode scale=$scale id=$id',
                );
              }
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '02 + 13(顺带) + 14：详情页继续播放与系列胶囊严格等高，手机/平板横屏头图从状态栏下沿起绘，简介滑到底完整露出',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() {
          tester.view.reset();
          debugDefaultTargetPlatformOverride = null;
        });

        final db = KonataDatabase(NativeDatabase.memory());
        final repo = DriftLibraryRepository(db);

        final group = SeriesGroup(
          id: 'sg_1',
          title: '加速世界系列',
          createdAt: DateTime(2026, 5, 1),
          updatedAt: DateTime(2026, 5, 1),
        );
        const work1 = Work(
          id: 'w_aw_1',
          title: '加速世界',
          year: 2012,
          overview: '这是一段用于验证详情页底部避让留白与滑到底完整露出的作品简介文本。',
          backdropPath: '/aw_bg.jpg',
          posterPath: '/aw_poster.jpg',
          seriesId: 'sg_1',
          seriesOrder: 1,
          scrapeStatus: ScrapeStatus.matched,
        );
        const work2 = Work(
          id: 'w_aw_2',
          title: '加速世界 INFINITE BURST',
          year: 2016,
          seriesId: 'sg_1',
          seriesOrder: 2,
          scrapeStatus: ScrapeStatus.matched,
        );
        await tester.runAsync(() async {
          await repo.upsertSeriesGroup(group);
          await repo.upsertWork(work1);
          await repo.upsertWork(work2);
          await repo.upsertEpisode(
            const Episode(
              id: 'ep_aw_1',
              workId: 'w_aw_1',
              seasonNumber: 1,
              episodeNumber: 1,
              title: '加速',
            ),
          );
        });

        // 手机横屏（顶部状态栏 28dp，底部小窗避让 96dp）
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          _wrapApp(
            const KonataBottomClearanceScope(
              bottomClearance: 96.0,
              child: WorkDetailPage(workId: 'w_aw_1'),
            ),
            padding: const EdgeInsets.only(top: 28, bottom: 16),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _sample1x1Png,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final playRect = tester.getRect(find.byType(FrostedPlayButton));
        final switcherRect = tester.getRect(
          find.byType(SeriesSwitcherDropdown),
        );
        expect(
          (playRect.height - switcherRect.height).abs(),
          lessThanOrEqualTo(0.5),
        );
        expect(
          (playRect.center.dy - switcherRect.center.dy).abs(),
          lessThanOrEqualTo(1.0),
        );

        // 14：手机横屏头图边到边贴顶延伸至状态栏背后，消除顶部黑边
        final phoneLandscapeHeroRect = tester.getRect(
          find.byKey(const ValueKey('detail_phone_landscape_hero')),
        );
        expect(phoneLandscapeHeroRect.top, closeTo(0.0, 0.5));

        // 13(顺带)：滚动到底后「作品简介」完整位于底部避让线之上
        await tester.drag(
          find.byKey(const ValueKey('detail_phone_landscape_scroll_view')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        final synopsisRect = tester.getRect(find.text('作品简介'));
        expect(synopsisRect.bottom, lessThanOrEqualTo(390.0 - 96.0));

        // 14：平板横屏头图舞台同样从状态栏下沿 (32dp) 起绘
        tester.view.physicalSize = const Size(1200, 800);
        await tester.pumpWidget(
          _wrapApp(
            const WorkDetailPage(workId: 'w_aw_1'),
            padding: const EdgeInsets.only(top: 32, bottom: 16),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _sample1x1Png,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final wideStageRect = tester.getRect(
          find.byKey(const ValueKey('detail_wide_backdrop_stage')),
        );
        expect(wideStageRect.top, closeTo(32.0, 0.5));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(db.close);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '03：视频已暂停提示在视口水平+垂直双居中且不触发整页重建',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const work = Work(id: 'w_v', title: '测试番剧');
        const ep = Episode(
          id: 'ep_v',
          workId: 'w_v',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '第一话',
        );
        const variant = MediaVariant(
          id: 'var_v',
          workId: 'w_v',
          episodeId: 'ep_v',
          sourceId: 'src_1',
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
        );
        const vBundle = WorkDetailBundle(
          work: work,
          episodes: [ep],
          variants: [variant],
          sourcesById: {},
          latestPlayback: null,
          playbackByEpisodeId: {},
        );
        const req = VideoLaunchRequest(
          work: work,
          bundle: vBundle,
          episode: ep,
          variant: variant,
        );

        var outerBuilds = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              videoPlaybackProvider(req).overrideWith(
                () => _Stage1StubVideoController(req),
              ),
            ],
            child: MaterialApp(
              darkTheme: KonataTheme.darkTheme(),
              themeMode: ThemeMode.dark,
              home: Builder(
                builder: (context) {
                  outerBuilds++;
                  return const EmbeddedVideoPage(request: req);
                },
              ),
            ),
          ),
        );
        await tester.pump();
        final buildsBeforePause = outerBuilds;

        // 按下空格键触发暂停
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.pump();

        expect(outerBuilds, equals(buildsBeforePause));
        expect(find.text('已暂停'), findsOneWidget);
        final centerPillRect = tester.getRect(
          find.byKey(const ValueKey('video_center_status_pill')),
        );
        expect(centerPillRect.center.dx, closeTo(640.0, 1.0));
        expect(centerPillRect.center.dy, closeTo(360.0, 1.0));

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '07 + 08 + 09 + 10 + 15：完整列表紧凑行高、归入文案、零占位搜索框、系列编组同行按钮与移除文案',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final db = KonataDatabase(NativeDatabase.memory());
        final repo = DriftLibraryRepository(db);

        final group = SeriesGroup(
          id: 'sg_m',
          title: '测试系列',
          createdAt: DateTime(2026, 5, 1),
          updatedAt: DateTime(2026, 5, 1),
        );
        const workA = Work(
          id: 'w_a',
          title: '作品 A',
          seriesId: 'sg_m',
          seriesOrder: 1,
          scrapeStatus: ScrapeStatus.matched,
        );
        const workB = Work(
          id: 'w_b',
          title: '作品 B',
          seriesId: 'sg_m',
          seriesOrder: 2,
          scrapeStatus: ScrapeStatus.matched,
        );
        await tester.runAsync(() async {
          await repo.upsertSeriesGroup(group);
          await repo.upsertWork(workA);
          await repo.upsertWork(workB);
        });

        const ep1 = Episode(
          id: 'ep_1',
          workId: 'w_a',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '第一话',
        );
        const ep2 = Episode(
          id: 'ep_2',
          workId: 'w_a',
          seasonNumber: 1,
          episodeNumber: 2,
          title: '第二话',
        );
        const ep3 = Episode(
          id: 'ep_3',
          workId: 'w_a',
          seasonNumber: 1,
          episodeNumber: 3,
          title: '第三话',
        );
        const v1 = MediaVariant(
          id: 'v_1',
          workId: 'w_a',
          episodeId: 'ep_1',
          sourceId: 's1',
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
        );
        const v2 = MediaVariant(
          id: 'v_2',
          workId: 'w_a',
          episodeId: 'ep_2',
          sourceId: 's1',
          relativePath: '02.mkv',
          fileName: '02.mkv',
          fileSize: 100,
        );
        const v3 = MediaVariant(
          id: 'v_3',
          workId: 'w_a',
          episodeId: 'ep_3',
          sourceId: 's1',
          relativePath: '03.mkv',
          fileName: '03.mkv',
          fileSize: 100,
        );

        final bundle = WorkDetailBundle(
          work: workA,
          episodes: const [ep1, ep2, ep3],
          variants: const [v1, v2, v3],
          sourcesById: const {},
          latestPlayback: null,
          playbackByEpisodeId: const {},
          seriesGroup: group,
          seriesMembers: const [workA, workB],
        );

        // 07 & 09：完整列表弹窗收紧行距，且搜索框无占位提示词
        await tester.pumpWidget(
          _wrapApp(
            DetailFullListDialog(
              bundle: bundle,
              imageLoader: (_, {targetWidth, imageSize}) async => _sample1x1Png,
              initialTab: DetailDrawerTab.main,
              onEpisodeTap: (_) {},
              onEpisodeAdjustSlot: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        final searchField = tester.widget<TextField>(find.byType(TextField));
        expect(searchField.decoration?.hintText, isNull);
        final cardRow1Rect = tester.getRect(
          find.byKey(const ValueKey('full_list_ep_ep_1')),
        );
        final cardRow2Rect = tester.getRect(
          find.byKey(const ValueKey('full_list_ep_ep_3')),
        );
        expect(cardRow2Rect.top - cardRow1Rect.bottom, lessThanOrEqualTo(16.0));

        // 08 & 09：并入作品弹窗归入方式文案「原分类」「特典」「正片」同行显示且搜索无占位词
        await tester.pumpWidget(
          _wrapApp(
            const WorkMergeTargetDialog(
              sourceWorkId: 'w_a',
              sourceWorkTitle: '作品 A',
            ),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              libraryItemsProvider.overrideWith((_) async => const []),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('原分类'), findsOneWidget);
        expect(find.text('特典'), findsOneWidget);
        expect(find.text('正片'), findsOneWidget);
        final mergeSearch = tester.widget<TextField>(find.byType(TextField));
        expect(mergeSearch.decoration?.hintText, isNull);

        // 10：管理系列编组「成员」「添加」与「脱离为独立系列」同行左右对齐
        await tester.pumpWidget(
          _wrapApp(
            SeriesManageDialog(bundle: bundle),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              seriesGroupsProvider.overrideWith((_) async => [group]),
              libraryItemsProvider.overrideWith((_) async => const []),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final membersTabRect = tester.getRect(find.text('成员'));
        final addTabRect = tester.getRect(find.text('添加'));
        final detachRect = tester.getRect(find.text('脱离为独立系列'));
        expect(
          (membersTabRect.center.dy - addTabRect.center.dy).abs(),
          lessThan(2.0),
        );
        expect(
          (membersTabRect.center.dy - detachRect.center.dy).abs(),
          lessThan(6.0),
        );
        expect(detachRect.left, greaterThan(addTabRect.right));

        // 15：扫描已选目录面板「批量移除」改名「移除」且同排不溢出
        await tester.pumpWidget(
          _wrapApp(
            SizedBox(
              height: 360,
              child: SourceSelectedScopePanel(
                selectedPaths: const ['动画-单作品', '动画-多作品'],
                busy: false,
                onBackToBrowse: () {},
                onRemovePathsBatch: (_) {},
                onShowHelp: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('批量移除'), findsNothing);
        expect(find.text('移除'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(db.close);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '11：手机竖屏全屏音频页封面下方去除重复副标题，最下排依次为循环模式、歌词、队列菜单、音量',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.reset();
          debugDefaultTargetPlatformOverride = null;
        });

        const work = Work(
          id: 'w_cd',
          title: '加速世界',
          scrapeStatus: ScrapeStatus.matched,
        );
        const variant = MediaVariant(
          id: 'var_cd',
          workId: 'w_cd',
          sourceId: 's_1',
          relativePath: 'CD/01.flac',
          fileName: '01.flac',
          fileSize: 30000000,
          assetKind: AssetKind.cdAlbum,
        );
        const item = AudioQueueItem(
          id: 'q_1',
          work: work,
          variant: variant,
          title: 'ハルユキの災難',
          albumTitle: 'スペシャルドラマCD',
        );

        await tester.pumpWidget(
          _wrapApp(
            const ImmersiveAudioPage(),
            overrides: [
              audioPlaybackProvider.overrideWith(
                () => _Stage1StubAudioNotifier(
                  const AudioPlaybackState(
                    isActive: true,
                    isPlaying: true,
                    queue: [item],
                    currentIndex: 0,
                    durationSeconds: 180,
                    positionSeconds: 12,
                    audioCodecLabel: 'FLAC',
                    cover: EmptyAudioCover(),
                  ),
                ),
              ),
            ],
          ),
        );
        await tester.pump();

        // 顶部极简留白不展示作品/专辑副标题，主体保留当前曲目名与音质徽章
        expect(find.text('スペシャルドラマCD'), findsNothing);
        expect(find.text('ハルユキの災難'), findsOneWidget);

        // 底部全圆角单排光学胶囊五键从左到右：循环 < 上一曲 < 播放暂停 < 下一曲 < 队列（去掉静音）
        final loopX = tester
            .getCenter(find.byKey(const ValueKey('portrait_audio_loop_button')))
            .dx;
        final prevX = tester
            .getCenter(find.byKey(const ValueKey('portrait_audio_prev_button')))
            .dx;
        final playX = tester
            .getCenter(find.byKey(const ValueKey('portrait_audio_play_pause')))
            .dx;
        final nextX = tester
            .getCenter(find.byKey(const ValueKey('portrait_audio_next_button')))
            .dx;
        final queueX = tester
            .getCenter(find.byKey(const ValueKey('portrait_open_queue_button')))
            .dx;
        expect(loopX, lessThan(prevX));
        expect(prevX, lessThan(playX));
        expect(playX, lessThan(nextX));
        expect(nextX, lessThan(queueX));
        expect(
          find.byKey(const ValueKey('portrait_audio_mute_button')),
          findsNothing,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}
