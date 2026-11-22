import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/presentation/detail/work_detail_page.dart';
import 'package:konata/presentation/history/playback_history_page.dart';
import 'package:konata/presentation/theme/konata_palette.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Uint8List _tinyPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget _wrapTimelineApp(
  Widget child, {
  List<dynamic> overrides = const [],
  ThemeData? theme,
}) {
  return ProviderScope(
    overrides: overrides.cast(),
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: theme ?? KonataTheme.darkTheme(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('新版播放记录日记时间轴、原地展开与滚动保持回归测试', () {
    testWidgets('视频按 YYYY.MM.DD 日记分组，点击卡片无单独按钮原地展开当日多集剧照与进度条，音频展示 1:1 专辑封面', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_1',
          kind: MediaSourceKind.local,
          label: '本地',
          location: 'D:/Anime',
        ),
      );
      const work = Work(
        id: 'w_86',
        title: '86 -不存在的战区-',
        posterPath: '/poster_86.jpg',
        backdropPath: '/backdrop_86.jpg',
        tmdbMediaType: TmdbMediaType.tv,
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(work);
      await repo.upsertEpisodesBatch(const [
        Episode(
          id: 'ep_86_1',
          workId: 'w_86',
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '送葬者',
          stillPath: '/still_86_1.jpg',
        ),
        Episode(
          id: 'ep_86_2',
          workId: 'w_86',
          seasonNumber: 1,
          episodeNumber: 2,
          category: EpisodeCategory.main,
          title: '先锋战队',
          stillPath: '/still_86_2.jpg',
        ),
        Episode(
          id: 'ep_86_3',
          workId: 'w_86',
          seasonNumber: 1,
          episodeNumber: 3,
          category: EpisodeCategory.main,
          title: '我不想死',
          stillPath: '/still_86_3.jpg',
        ),
      ]);
      await repo.upsertMediaVariantsBatch(const [
        MediaVariant(
          id: 'v_86_1',
          workId: 'w_86',
          episodeId: 'ep_86_1',
          sourceId: 'src_1',
          relativePath: '86/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
          assetKind: AssetKind.video,
        ),
        MediaVariant(
          id: 'v_cd_1',
          workId: 'w_86',
          sourceId: 'src_1',
          relativePath: '86/CD/01.flac',
          fileName: '01.flac',
          fileSize: 512,
          assetKind: AssetKind.cdAlbum,
        ),
      ]);

      // 10 月 23 日看了第 2、3 集；10 月 21 日看了第 1 集
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'rec_3',
          workId: 'w_86',
          episodeId: 'ep_86_3',
          variantId: 'v_86_1',
          seasonNumber: 1,
          episodeNumber: 3,
          episodeTitle: '我不想死',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 10, 23, 22, 15),
          positionSeconds: 720,
          durationSeconds: 1440,
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'rec_2',
          workId: 'w_86',
          episodeId: 'ep_86_2',
          variantId: 'v_86_1',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '先锋战队',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 10, 23, 21, 40),
          positionSeconds: 1440,
          durationSeconds: 1440,
          isCompleted: true,
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'rec_1',
          workId: 'w_86',
          episodeId: 'ep_86_1',
          variantId: 'v_86_1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '送葬者',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 10, 21, 9, 5),
          positionSeconds: 1440,
          durationSeconds: 1440,
          isCompleted: true,
        ),
      );
      // 音频同日听了两首
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'cd_r2',
          workId: 'w_86',
          episodeId: '${PlaybackRecord.audioEpisodePrefix}v_cd_1::track_02',
          variantId: 'v_cd_1',
          seasonNumber: 0,
          episodeNumber: 2,
          episodeTitle: '02. Voices of the Chord.flac',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 10, 23, 23, 5),
          positionSeconds: 90,
          durationSeconds: 240,
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'cd_r1',
          workId: 'w_86',
          episodeId: '${PlaybackRecord.audioEpisodePrefix}v_cd_1::track_01',
          variantId: 'v_cd_1',
          seasonNumber: 0,
          episodeNumber: 1,
          episodeTitle: '01. Avid.flac',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 10, 23, 22, 58),
          positionSeconds: 250,
          durationSeconds: 250,
          isCompleted: true,
        ),
      );

      final loadedPaths = <String>[];
      await tester.pumpWidget(
        _wrapTimelineApp(
          const PlaybackHistoryPage(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbImageLoaderProvider.overrideWithValue((
              path, {
              targetWidth,
              imageSize,
            }) async {
              loadedPaths.add(path);
              return _tinyPng;
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 左侧小圆点 + YYYY.MM.DD 日期头（日记风格分两天）
      expect(find.byKey(const ValueKey('history_day_dot_2026-10-23')), findsOneWidget);
      expect(find.text('2026.10.23'), findsOneWidget);
      expect(find.byKey(const ValueKey('history_day_dot_2026-10-21')), findsOneWidget);
      expect(find.text('2026.10.21'), findsOneWidget);

      // 收起态展示最后观看集数、24 小时制时间与共看集数；无单独展开箭头按钮，未展开前隐藏子集剧照
      expect(find.text('第 3 集 - 22:15 · 共 2 集'), findsOneWidget);
      expect(find.text('第 1 集 - 09:05'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
      expect(find.byKey(const ValueKey('history_video_still_rec_3')), findsNothing);

      // 点击 10.23 卡片主体直接原地展开当天 2 集（剧照、标题与进度条全展示）
      await tester.tap(
        find.byKey(const ValueKey('history_work_card_2026-10-23::w_86')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history_video_still_rec_3')), findsOneWidget);
      expect(find.byKey(const ValueKey('history_video_still_rec_2')), findsOneWidget);
      expect(find.text('03 · 我不想死'), findsOneWidget);
      expect(find.text('02 · 先锋战队'), findsOneWidget);
      expect(find.text('12:00 / 24:00'), findsOneWidget);
      expect(find.text('已看完'), findsOneWidget);
      expect(loadedPaths, contains('/still_86_3.jpg'));
      expect(loadedPaths, contains('/still_86_2.jpg'));
      // 10.21 的卡片未展开，不会展示第 1 集明细
      expect(find.byKey(const ValueKey('history_video_still_rec_1')), findsNothing);

      // 再次点击卡片收起
      await tester.tap(
        find.byKey(const ValueKey('history_work_card_2026-10-23::w_86')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history_video_still_rec_3')), findsNothing);

      // 切至音频页签，点击卡片原地展开 2 首曲目与 1:1 专辑封面
      await tester.tap(find.text('音频'));
      await tester.pumpAndSettle();
      expect(find.text('Voices of the Chord - 23:05 · 共 2 首'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('history_work_card_2026-10-23::w_86')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history_audio_cover_cd_r2')), findsOneWidget);
      expect(find.byKey(const ValueKey('history_audio_cover_cd_r1')), findsOneWidget);
      expect(find.text('Voices of the Chord'), findsOneWidget);
      expect(find.text('Avid'), findsOneWidget);
      expect(find.text('01:30 / 04:00'), findsOneWidget);
      expect(find.text('已听完'), findsOneWidget);
    });

    testWidgets('点击作品封面进入详情页，退出返回播放记录时精确停留在原滚动位置且保留展开状态', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      for (var i = 1; i <= 16; i++) {
        final workId = 'w_scroll_$i';
        await repo.upsertWork(
          Work(
            id: workId,
            title: '测试滚动作品 $i',
            posterPath: '/p_$i.jpg',
            tmdbMediaType: TmdbMediaType.tv,
            scrapeStatus: ScrapeStatus.matched,
          ),
        );
        await repo.recordPlayback(
          PlaybackRecord(
            id: 'rec_scroll_$i',
            workId: workId,
            episodeId: 'ep_scroll_$i',
            variantId: 'var_scroll_$i',
            seasonNumber: 1,
            episodeNumber: i,
            episodeTitle: '第 $i 话标题',
            sourceType: MediaSourceKind.local,
            playedAt: DateTime(2026, 10, i, 20, 0),
            positionSeconds: 300,
            durationSeconds: 1440,
          ),
        );
      }

      await tester.pumpWidget(
        _wrapTimelineApp(
          const PlaybackHistoryPage(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _tinyPng,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 向下滚动列表至中间位置
      final scrollableState = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scrollableState.position.jumpTo(450.0);
      await tester.pumpAndSettle();
      final offsetBeforeNav = scrollableState.position.pixels;
      expect(offsetBeforeNav, greaterThan(400.0));

      // 挑选完全位于当前视口中央（y 在 200..560 之间）的真实可见作品卡片，先展开再点封面进详情
      final visibleCover = find.byWidgetPredicate((w) {
        if (w.key is! ValueKey<String>) return false;
        final keyVal = (w.key! as ValueKey<String>).value;
        return keyVal.startsWith('history_work_cover_');
      });
      String? targetCoverKey;
      for (final elem in visibleCover.evaluate()) {
        final box = elem.renderObject as RenderBox?;
        if (box == null || !box.hasSize) continue;
        final centerY = box.localToGlobal(box.size.center(Offset.zero)).dy;
        if (centerY >= 200.0 && centerY <= 560.0) {
          targetCoverKey = (elem.widget.key! as ValueKey<String>).value;
          break;
        }
      }
      expect(targetCoverKey, isNotNull);
      final groupKey = targetCoverKey!.substring('history_work_cover_'.length);

      await tester.tap(find.byKey(ValueKey('history_work_card_$groupKey')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('history_expanded_$groupKey')), findsOneWidget);

      final offsetAfterExpand = scrollableState.position.pixels;

      await tester.tap(find.byKey(ValueKey(targetCoverKey)));
      await tester.pumpAndSettle();
      expect(find.byType(WorkDetailPage), findsOneWidget);

      // 退出详情页返回播放记录页
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      expect(find.byType(WorkDetailPage), findsNothing);
      expect(find.byType(PlaybackHistoryPage), findsOneWidget);
      // 滚动位置必须停在离开前的精确位置（绝不回顶 0.0），且展开状态保持
      final returnedOffset = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      expect(returnedOffset, closeTo(offsetAfterExpand, 1.0));
      expect(find.byKey(ValueKey('history_expanded_$groupKey')), findsOneWidget);
    });

    testWidgets(
      '播放记录左对齐铺开，宽屏单日一行双作品、窄屏退化单列，展开多集单行横向排列可左右拖动且不纵向堆积',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);

        await repo.upsertMediaSource(
          const MediaSource(
            id: 'src_1',
            kind: MediaSourceKind.local,
            label: '本地',
            location: 'D:/Anime',
          ),
        );
        await repo.upsertWork(
          const Work(
            id: 'w_multi',
            title: '弹丸论破3 绝望篇',
            posterPath: '/p_multi.jpg',
            tmdbMediaType: TmdbMediaType.tv,
            scrapeStatus: ScrapeStatus.matched,
          ),
        );
        await repo.upsertWork(
          const Work(
            id: 'w_second',
            title: '超级弹丸论破2.5',
            posterPath: '/p_second.jpg',
            tmdbMediaType: TmdbMediaType.movie,
            scrapeStatus: ScrapeStatus.matched,
          ),
        );
        final eps = <Episode>[
          for (var i = 1; i <= 5; i++)
            Episode(
              id: 'ep_m_$i',
              workId: 'w_multi',
              seasonNumber: 1,
              episodeNumber: i,
              category: EpisodeCategory.main,
              title: '绝望第 $i 话',
              stillPath: '/still_m_$i.jpg',
            ),
        ];
        await repo.upsertEpisodesBatch(eps);

        for (var i = 1; i <= 5; i++) {
          await repo.recordPlayback(
            PlaybackRecord(
              id: 'rec_m_$i',
              workId: 'w_multi',
              episodeId: 'ep_m_$i',
              variantId: 'v_m_$i',
              seasonNumber: 1,
              episodeNumber: i,
              episodeTitle: '绝望第 $i 话',
              sourceType: MediaSourceKind.local,
              playedAt: DateTime(2026, 11, 23, 7, i),
              positionSeconds: 120 * i,
              durationSeconds: 1420,
            ),
          );
        }
        await repo.recordPlayback(
          PlaybackRecord(
            id: 'rec_s_1',
            workId: 'w_second',
            episodeId: 'ep_s_1',
            variantId: 'v_s_1',
            seasonNumber: 1,
            episodeNumber: 1,
            episodeTitle: '正片',
            sourceType: MediaSourceKind.local,
            playedAt: DateTime(2026, 11, 23, 6, 54),
            positionSeconds: 300,
            durationSeconds: 1500,
          ),
        );

        await tester.pumpWidget(
          _wrapTimelineApp(
            const PlaybackHistoryPage(),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _tinyPng,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // 1. 左对齐铺开：时间轴圆点紧贴页面标准左边距，不再居中缩窄
        final dotRect = tester.getRect(
          find.byKey(const ValueKey('history_day_dot_2026-11-23')),
        );
        expect(
          dotRect.left,
          lessThan(KonataTheme.pageHorizontalPadding + 20.0),
        );

        // 2. 宽屏单日双列：同日两部作品并排处于同一水平行
        final cardMultiRect = tester.getRect(
          find.byKey(const ValueKey('history_work_card_2026-11-23::w_multi')),
        );
        final cardSecondRect = tester.getRect(
          find.byKey(const ValueKey('history_work_card_2026-11-23::w_second')),
        );
        expect((cardMultiRect.top - cardSecondRect.top).abs(), lessThan(1.0));
        expect(cardSecondRect.left, greaterThan(cardMultiRect.right));

        // 3. 展开 5 集作品卡：单行横向排布，总高度紧凑不纵向累积，左右拖动可滑出最早一集
        await tester.tap(
          find.byKey(const ValueKey('history_work_card_2026-11-23::w_multi')),
        );
        await tester.pumpAndSettle();

        final expandedRect = tester.getRect(
          find.byKey(const ValueKey('history_expanded_2026-11-23::w_multi')),
        );
        expect(expandedRect.height, lessThan(140.0));

        final ep5Rect = tester.getRect(
          find.byKey(const ValueKey('history_entry_rec_m_5')),
        );
        final ep4Rect = tester.getRect(
          find.byKey(const ValueKey('history_entry_rec_m_4')),
        );
        expect((ep5Rect.top - ep4Rect.top).abs(), lessThan(1.0));
        expect(ep4Rect.left, greaterThan(ep5Rect.right));

        final railFinder = find.byKey(
          const ValueKey('history_expanded_rail_2026-11-23::w_multi'),
        );
        expect(railFinder, findsOneWidget);
        await tester.drag(railFinder, const Offset(-900, 0));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('history_video_still_rec_m_1')),
          findsOneWidget,
        );

        // 4. 窄屏（手机竖屏 390x844）自动切为单列，同时保持展开单行横向紧凑
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final narrowMultiRect = tester.getRect(
          find.byKey(const ValueKey('history_work_card_2026-11-23::w_multi')),
        );
        final narrowSecondRect = tester.getRect(
          find.byKey(const ValueKey('history_work_card_2026-11-23::w_second')),
        );
        expect(narrowSecondRect.top, greaterThan(narrowMultiRect.bottom));
      },
    );

    testWidgets('播放记录展开剧集子卡片在深色与浅色模式下分别复用对应主题 surface 令牌，杜绝深色泛白割裂', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      await repo.upsertWork(
        const Work(
          id: 'w_theme',
          title: '配色验收番剧',
          posterPath: '/p_theme.jpg',
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'rec_theme_1',
          workId: 'w_theme',
          episodeId: 'ep_theme_1',
          variantId: 'v_theme_1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第 1 话',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 23, 7, 10),
          positionSeconds: 120,
          durationSeconds: 1420,
        ),
      );

      for (final (isDark, theme, expectedSurface) in [
        (true, KonataTheme.darkTheme(), KonataPalette.dark.surface),
        (false, KonataTheme.lightTheme(), KonataPalette.light.surface),
      ]) {
        await tester.pumpWidget(
          _wrapTimelineApp(
            const PlaybackHistoryPage(),
            theme: theme,
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _tinyPng,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('history_work_card_2026-11-23::w_theme')),
        );
        await tester.pumpAndSettle();

        final entryContainer = tester.widget<Container>(
          find.byKey(const ValueKey('history_entry_surface_rec_theme_1')),
        );
        final decoration = entryContainer.decoration! as BoxDecoration;
        expect(
          decoration.color,
          equals(expectedSurface),
          reason: isDark ? '深色模式子卡片应复用通透暗色 surface 而非高不透明泛白底色' : '浅色模式应复用亮色 surface',
        );
        if (isDark) {
          expect(decoration.color!.a, lessThan(0.15));
        }

        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}
