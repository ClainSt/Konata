import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/artwork_palette_service.dart';
import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/formatting/clear_logo_legibility.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/cache/scan_thumbnail_scheduler.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/presentation/audio/smart_cover_framing.dart';
import 'package:konata/presentation/detail/detail_bottom_drawer.dart';
import 'package:konata/presentation/detail/detail_full_list_dialog.dart';
import 'package:konata/presentation/detail/detail_hero_info.dart';
import 'package:konata/presentation/detail/episode_drawer_card.dart';
import 'package:konata/presentation/detail/episode_media_info_dialog.dart';
import 'package:konata/presentation/detail/supplementary_asset_cards.dart';
import 'package:konata/presentation/detail/work_detail_page.dart';
import 'package:konata/presentation/detail/work_detail_sub_views.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/managed_image.dart';

final Uint8List _sample1x1Png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Widget _wrapApp(
  Widget child, {
  List<Override> overrides = const [],
  ThemeMode themeMode = ThemeMode.dark,
  EdgeInsets padding = EdgeInsets.zero,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: themeMode,
      builder: (ctx, inner) {
        final mq = MediaQuery.of(ctx);
        return MediaQuery(
          data: mq.copyWith(padding: padding, viewPadding: padding),
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

  group('阶段 4 · 详情页方案 P1、MediaInfo、1:1 CD、Scan 双模式画廊与灯箱验收', () {
    testWidgets('手机竖屏渲染全幅竖版封面沉浸头图（方案 P1）且不溢出，单集长按可打开媒体信息弹窗', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(() async => tester.runAsync(db.close));
      final repo = DriftLibraryRepository(db);

      const source = MediaSource(
        id: 'src_p1',
        label: '本地番剧库',
        kind: MediaSourceKind.local,
        location: r'D:\Anime',
        createdAt: null,
      );
      const work = Work(
        id: 'w_p1',
        title: '葬送的芙莉莲',
        year: 2023,
        bangumiScore: 8.6,
        posterPath: '/poster_vertical.jpg',
        backdropPath: '/backdrop_wide.jpg',
        logoPath: '/logo_clear.png',
        overview: '打倒魔王之后勇者一行人的余生旅途。',
        scrapeStatus: ScrapeStatus.matched,
      );
      const ep1 = Episode(
        id: 'ep_p1_1',
        workId: 'w_p1',
        seasonNumber: 1,
        episodeNumber: 1,
        title: '冒险的终点',
      );
      const variant1 = MediaVariant(
        id: 'v_p1_1',
        workId: 'w_p1',
        episodeId: 'ep_p1_1',
        sourceId: 'src_p1',
        relativePath: 'Frieren/[VCB-Studio] Frieren [01][Ma10p_1080p].mkv',
        fileName: '[VCB-Studio] Frieren [01][Ma10p_1080p].mkv',
        fileSize: 1850 * 1024 * 1024,
        releaseGroup: 'VCB-Studio',
        subtitleGroup: '诸神字幕组',
        resolution: '1080p',
        videoCodec: 'HEVC',
        bitDepth: '10bit',
        audioCodec: 'FLAC',
        externalSubtitles: ['Frieren/01.sc.ass'],
      );

      await tester.runAsync(() async {
        await repo.upsertMediaSource(
          MediaSource(
            id: source.id,
            label: source.label,
            kind: source.kind,
            location: source.location,
            createdAt: DateTime(2026),
          ),
        );
        await repo.upsertWork(work);
        await repo.upsertEpisode(ep1);
        await repo.upsertMediaVariant(variant1);
      });

      await tester.pumpWidget(
        _wrapApp(
          const WorkDetailPage(workId: 'w_p1'),
          padding: const EdgeInsets.only(top: 44, bottom: 24),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _sample1x1Png,
            ),
          ],
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();

      // 1. 手机竖屏启用方案 P1 全幅竖版封面沉浸头图（高度约 52% 视口）
      final heroFinder = find.byKey(
        const ValueKey('detail_portrait_hero_header'),
      );
      expect(heroFinder, findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail_phone_vertical_poster_hero')),
        findsOneWidget,
      );
      final heroRect = tester.getRect(heroFinder);
      expect(heroRect.top, closeTo(0.0, 0.5));
      expect(heroRect.height, greaterThan(360.0));
      expect(heroRect.height, lessThanOrEqualTo(460.0));

      // 2. 长按单集卡片弹出菜单，验证「查看媒体信息」入口并成功展示规格详情
      await tester.ensureVisible(find.byType(EpisodeDrawerCard).first);
      await tester.longPress(find.byType(EpisodeDrawerCard).first);
      await tester.pumpAndSettle();
      expect(find.text('查看媒体信息'), findsOneWidget);

      await tester.tap(find.text('查看媒体信息'));
      await tester.pumpAndSettle();
      expect(find.byType(EpisodeMediaInfoDialog), findsOneWidget);
      expect(find.text('VCB-Studio'), findsOneWidget);
      expect(find.text('诸神字幕组'), findsOneWidget);
      expect(find.text('Frieren/01.sc.ass'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('CD 卡片采用 1:1 专辑封面比例，Scan 双模式画廊与内置高清灯箱支持分卷范围、胶片条与远程暂停', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tempRoot = await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_stage4_scan_'),
      );
      final tempPhotos = await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_stage4_photos_'),
      );
      addTearDown(() async {
        await tester.runAsync(() async {
          if (tempRoot != null && await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
          if (tempPhotos != null && await tempPhotos.exists()) {
            await tempPhotos.delete(recursive: true);
          }
        });
      });

      await tester.runAsync(() async {
        final vol1 = Directory(p.join(tempRoot!.path, 'Scans', 'Vol.01'));
        final vol2 = Directory(p.join(tempRoot.path, 'Scans', 'Vol.02'));
        await vol1.create(recursive: true);
        await vol2.create(recursive: true);
        await File(p.join(vol1.path, '01.png')).writeAsBytes(_sample1x1Png);
        await File(p.join(vol1.path, '02.png')).writeAsBytes(_sample1x1Png);
        await File(p.join(vol2.path, '03.png')).writeAsBytes(_sample1x1Png);
      });

      final localSource = MediaSource(
        id: 'src_local',
        label: '本地画集',
        kind: MediaSourceKind.local,
        location: tempRoot!.path,
        createdAt: DateTime(2026),
      );
      const work = Work(
        id: 'w_scan_ui',
        title: '轻音少女',
        year: 2009,
        posterPath: '/k_on_poster.jpg',
        scrapeStatus: ScrapeStatus.matched,
      );
      const cdVar = MediaVariant(
        id: 'cd_1',
        workId: 'w_scan_ui',
        sourceId: 'src_local',
        relativePath: 'CD/01 Cagayake!GIRLS.flac',
        fileName: '01 Cagayake!GIRLS.flac',
        fileSize: 32 * 1024 * 1024,
        assetKind: AssetKind.cdAlbum,
      );
      const scanVars = [
        MediaVariant(
          id: 'sc_1',
          workId: 'w_scan_ui',
          sourceId: 'src_local',
          relativePath: 'Scans/Vol.01/01.png',
          fileName: '01.png',
          fileSize: 1200,
          assetKind: AssetKind.scanGallery,
        ),
        MediaVariant(
          id: 'sc_2',
          workId: 'w_scan_ui',
          sourceId: 'src_local',
          relativePath: 'Scans/Vol.01/02.png',
          fileName: '02.png',
          fileSize: 1200,
          assetKind: AssetKind.scanGallery,
        ),
        MediaVariant(
          id: 'sc_3',
          workId: 'w_scan_ui',
          sourceId: 'src_local',
          relativePath: 'Scans/Vol.02/03.png',
          fileName: '03.png',
          fileSize: 1200,
          assetKind: AssetKind.scanGallery,
        ),
      ];

      final bundle = WorkDetailBundle(
        work: work,
        episodes: const [],
        variants: const [cdVar, ...scanVars],
        sourcesById: {'src_local': localSource},
        latestPlayback: null,
        cdVariants: const [cdVar],
        scanVariants: scanVars,
      );

      final scheduler = ScanThumbnailScheduler(
        photosStorage: PhotosStorage(overrideRoot: tempPhotos!),
      );
      addTearDown(scheduler.dispose);

      // 1. 验证 CD 卡片采用 1:1 正方形封面
      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: CdDrawerCard(
              variant: cdVar,
              source: localSource,
              workId: work.id,
              workPosterPath: work.posterPath,
              imageLoader: (_, {targetWidth, imageSize}) async => _sample1x1Png,
              showSeriesSharedBadge: false,
              onTap: () {},
            ),
          ),
          overrides: [
            scanThumbnailSchedulerProvider.overrideWithValue(scheduler),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final aspect = tester.widget<AspectRatio>(find.byType(AspectRatio).first);
      expect(aspect.aspectRatio, 1.0);

      // 2. 验证完整列表 Scan 双模式画廊（保序画框 <-> 等高流 + 3 档密度）
      String? tappedVolumeKey;
      MediaVariant? tappedScan;
      await tester.pumpWidget(
        _wrapApp(
          DetailFullListDialog(
            bundle: bundle,
            imageLoader: (_, {targetWidth, imageSize}) async => _sample1x1Png,
            initialTab: DetailDrawerTab.scan,
            onEpisodeTap: (_) {},
            onEpisodeAdjustSlot: (_) {},
            onScanTap: (v, {volumeKey}) {
              tappedScan = v;
              tappedVolumeKey = volumeKey;
            },
          ),
          overrides: [
            scanThumbnailSchedulerProvider.overrideWithValue(scheduler),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('scan_gallery_uniform_list')),
        findsOneWidget,
      );
      await tester.tap(find.text('等高流'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('scan_gallery_justified_list')),
        findsOneWidget,
      );
      await tester.tap(find.text('大图'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('full_list_scan_sc_1')));
      await tester.pumpAndSettle();
      expect(tappedScan?.id, 'sc_1');
      expect(tappedVolumeKey, isNull);

      // 3. 验证内置高清灯箱：打开时暂停后台远程队列、显示底部胶片条、关闭即恢复远程队列
      expect(scheduler.isRemotePaused, isFalse);
      await tester.pumpWidget(
        _wrapApp(
          ScanLightboxDialog(
            bundle: bundle,
            initialVariant: scanVars[0],
          ),
          overrides: [
            scanThumbnailSchedulerProvider.overrideWithValue(scheduler),
          ],
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      expect(scheduler.isRemotePaused, isTrue);
      expect(
        find.byKey(const ValueKey('scan_lightbox_filmstrip')),
        findsOneWidget,
      );
      expect(find.textContaining('1 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 关闭灯箱后自动恢复后台远程缩略图队列
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(scheduler.isRemotePaused, isFalse);
    });

    test('analyzeClearLogoRgba 精准区分亮色/带白边、单色深黑与深彩色无白边透明标题', () {
      Uint8List solidRgba(int r, int g, int b, int a, {int count = 20}) {
        final out = Uint8List(count * 4);
        for (var i = 0; i < count; i++) {
          out[i * 4] = r;
          out[i * 4 + 1] = g;
          out[i * 4 + 2] = b;
          out[i * 4 + 3] = a;
        }
        return out;
      }

      // 纯白与亮彩色保持原图
      expect(
        analyzeClearLogoRgba(solidRgba(245, 248, 255, 255)),
        ClearLogoLegibilityMode.original,
      );
      expect(
        analyzeClearLogoRgba(solidRgba(255, 110, 160, 255)),
        ClearLogoLegibilityMode.original,
      );
      // 全透明或空数据保持原图
      expect(
        analyzeClearLogoRgba(solidRgba(0, 0, 0, 0)),
        ClearLogoLegibilityMode.original,
      );
      // 含 30% 白色外描边的黑字保持原图
      final outlined = Uint8List(40 * 4);
      for (var i = 0; i < 40; i++) {
        final v = i < 12 ? 250 : 12;
        outlined[i * 4] = v;
        outlined[i * 4 + 1] = v;
        outlined[i * 4 + 2] = v;
        outlined[i * 4 + 3] = 255;
      }
      expect(analyzeClearLogoRgba(outlined), ClearLogoLegibilityMode.original);

      // 纯黑 / 炭黑单色标题（含透明背景）触发保色相亮度反相为清晰象牙白
      final fmpBlack = Uint8List(40 * 4);
      for (var i = 0; i < 20; i++) {
        fmpBlack[i * 4] = 18;
        fmpBlack[i * 4 + 1] = 15;
        fmpBlack[i * 4 + 2] = 14;
        fmpBlack[i * 4 + 3] = 255;
      }
      expect(
        analyzeClearLogoRgba(fmpBlack),
        ClearLogoLegibilityMode.smartInvert,
      );

      // 深酒红 / 深海蓝高饱和暗色无白边标题保留原色相并叠加字形轮廓霜白背晕
      expect(
        analyzeClearLogoRgba(solidRgba(96, 12, 16, 255)),
        ClearLogoLegibilityMode.softHalo,
      );
      expect(
        analyzeClearLogoRgba(solidRgba(14, 34, 112, 255)),
        ClearLogoLegibilityMode.softHalo,
      );
    });

    testWidgets(
      'DetailLockedClearLogo 按采样结果切换智能反白/字形背晕且保持唯一 ManagedImage，宽屏详情页采用左下角斜向柔晕',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const workInvert = Work(
          id: 'w_fmp',
          title: '全金属狂潮',
          backdropPath: '/backdrop_fmp.jpg',
          logoPath: '/logo_black.png',
        );
        const workHalo = Work(
          id: 'w_crimson',
          title: '深红标题作品',
          logoPath: '/logo_crimson.png',
        );

        final cache = ClearLogoLegibilityCache()
          ..put(
            '${workInvert.id}|${workInvert.logoPath}',
            ClearLogoLegibilityMode.smartInvert,
          )
          ..put(
            '${workHalo.id}|${workHalo.logoPath}',
            ClearLogoLegibilityMode.softHalo,
          );

        // 1. 验证单色深黑 ClearLogo 启用保色相亮度反相滤镜，且保持唯一 ManagedImage
        await tester.pumpWidget(
          _wrapApp(
            Scaffold(
              backgroundColor: KonataTheme.cinemaObsidian,
              body: Center(
                child: DetailLockedClearLogo(
                  key: const ValueKey('detail_hero_locked_logo'),
                  work: workInvert,
                  imageLoader: (_, {targetWidth, imageSize}) async =>
                      _sample1x1Png,
                  maxHeight: 80,
                  maxWidth: 340,
                ),
              ),
            ),
            overrides: [
              clearLogoLegibilityCacheProvider.overrideWithValue(cache),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('detail_clear_logo_smart_invert')),
          findsOneWidget,
        );
        expect(find.byType(ManagedImage), findsOneWidget);

        // 2. 验证深彩色无白边 ClearLogo 启用字形轮廓霜白背晕（双层 ImageFiltered），仍保持唯一 ManagedImage
        await tester.pumpWidget(
          _wrapApp(
            Scaffold(
              backgroundColor: KonataTheme.cinemaObsidian,
              body: Center(
                child: DetailLockedClearLogo(
                  key: const ValueKey('detail_hero_locked_logo'),
                  work: workHalo,
                  imageLoader: (_, {targetWidth, imageSize}) async =>
                      _sample1x1Png,
                  maxHeight: 80,
                  maxWidth: 340,
                ),
              ),
            ),
            overrides: [
              clearLogoLegibilityCacheProvider.overrideWithValue(cache),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('detail_clear_logo_soft_halo')),
          findsOneWidget,
        );
        expect(find.byType(ImageFiltered), findsNWidgets(2));
        expect(find.byType(ManagedImage), findsOneWidget);

        // 3. 验证桌面宽屏详情页使用左下角定向斜向柔晕（不再使用从顶到底全高左暗帘压暗左上人物）
        await tester.pumpWidget(const SizedBox.shrink());
        final db = KonataDatabase(NativeDatabase.memory());
        final repo = DriftLibraryRepository(db);
        await repo.upsertWork(workInvert);
        await tester.pumpWidget(
          _wrapApp(
            const WorkDetailPage(workId: 'w_fmp'),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              clearLogoLegibilityCacheProvider.overrideWithValue(cache),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _sample1x1Png,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final cornerScrim = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('detail_wide_corner_scrim')),
        );
        final gradient =
            (cornerScrim.decoration as BoxDecoration).gradient!
                as LinearGradient;
        expect(gradient.begin, Alignment.bottomLeft);
        expect(gradient.end, isNot(Alignment.centerRight));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(db.close);
      },
    );

    testWidgets(
      'ManagedImageProvider 值相等保持缩放同档零重解，且真实解码后 DetailLockedClearLogo 收敛至零待调度帧',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        Future<Uint8List> stableLoader(
          String url, {
          int? targetWidth,
          TmdbImageSize? imageSize,
        }) async => _sample1x1Png;

        // 1. 验证 ManagedImageProvider 及 ResizeImage 包装具备值相等性，消除缩放同档重建流。
        final p1 = ManagedImageProvider(
          '/poster.jpg',
          loader: stableLoader,
          targetWidth: 320,
          artwork: ManagedArtwork.poster,
          owner: 'w_eq',
        );
        final p2 = ManagedImageProvider(
          '/poster.jpg',
          loader: stableLoader,
          targetWidth: 320,
          artwork: ManagedArtwork.poster,
          owner: 'w_eq',
        );
        final pDiffWidth = ManagedImageProvider(
          '/poster.jpg',
          loader: stableLoader,
          targetWidth: 480,
          artwork: ManagedArtwork.poster,
          owner: 'w_eq',
        );
        expect(p1, equals(p2));
        expect(p1.hashCode, equals(p2.hashCode));
        expect(p1, isNot(equals(pDiffWidth)));
        expect(
          ResizeImage.resizeIfNeeded(320, null, p1),
          equals(ResizeImage.resizeIfNeeded(320, null, p2)),
        );

        // 2. 验证真实解码进入 ImageCache 后，DetailLockedClearLogo 不进入每帧 setState 死循环。
        const work = Work(
          id: 'w_idle_logo',
          title: '静置零帧循环作品',
          logoPath: '/logo_idle.png',
        );
        final cache = ClearLogoLegibilityCache();
        final rebuildTick = ValueNotifier<int>(0);
        addTearDown(rebuildTick.dispose);

        await tester.pumpWidget(
          _wrapApp(
            ValueListenableBuilder<int>(
              valueListenable: rebuildTick,
              builder: (_, tick, _) => Center(
                child: DetailLockedClearLogo(
                  work: work,
                  imageLoader: tick == 0
                      ? stableLoader
                      : (url, {targetWidth, imageSize}) async => _sample1x1Png,
                  maxHeight: 80,
                  maxWidth: 340,
                ),
              ),
            ),
            overrides: [
              clearLogoLegibilityCacheProvider.overrideWithValue(cache),
            ],
          ),
        );

        // 让原生图像编解码器真实解码并写入 ImageCache，复现实机同步缓存命中与亮度采样路径。
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        });
        await tester.pumpAndSettle();

        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.binding.transientCallbackCount, equals(0));
        expect(cache.get('${work.id}|${work.logoPath}'), isNotNull);

        // 即使外层父级重建并传入新的临时闭包 loader，也必须在有限帧内收敛至零待调度帧。
        rebuildTick.value = 1;
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        });
        await tester.pumpAndSettle();

        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.binding.transientCallbackCount, equals(0));
      },
    );

    test('SmartCoverFraming 16:9 滑窗自动保留竖版海报上方人物头部，原生横版图保持正中', () {
      // 构造 72x108 (2:3) 竖版海报：顶部留白背景，y=10..34 为暖肤色人物头部与高对比头发，下方为深色衣身。
      const w = 72;
      const h = 108;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          var r = 24;
          var g = 28;
          var b = 36;
          if (y >= 10 && y <= 34 && x >= 22 && x <= 50) {
            // 人物面部暖肤色 + 眉眼边缘对比
            r = (x + y).isEven ? 242 : 210;
            g = (x + y).isEven ? 202 : 168;
            b = (x + y).isEven ? 182 : 146;
          } else if (y > 34 && y <= 92 && x >= 18 && x <= 54) {
            // 衣领与躯干轮廓
            r = 68;
            g = 72;
            b = 84;
          }
          rgba[i] = r;
          rgba[i + 1] = g;
          rgba[i + 2] = b;
          rgba[i + 3] = 255;
        }
      }

      final align169 = SmartCoverFraming.solveRgbaAlignment(
        rgba,
        w,
        h,
        targetAspectRatio: 16 / 9,
      );
      expect(align169.y, lessThan(-0.5));

      // 原生 16:9 横版图无需偏移，保持 Alignment.center。
      const lw = 128;
      const lh = 72;
      final landscapeRgba = Uint8List(lw * lh * 4)..fillRange(0, lw * lh * 4, 200);
      final alignLandscape = SmartCoverFraming.solveRgbaAlignment(
        landscapeRgba,
        lw,
        lh,
        targetAspectRatio: 16 / 9,
      );
      expect(alignLandscape, equals(Alignment.center));
    });

    testWidgets(
      '详情页宽屏背景与正片剧照回退竖版海报时启用防切头对齐，有真实横版图时保持居中',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        Future<Uint8List> loader(
          String url, {
          int? targetWidth,
          TmdbImageSize? imageSize,
        }) async => _sample1x1Png;

        const ep = Episode(
          id: 'ep_fallback_1',
          workId: 'w_dr25',
          seasonNumber: 1,
          episodeNumber: 1,
          title: 'SP 2.5',
        );

        await tester.pumpWidget(
          _wrapApp(
            Column(
              children: [
                Expanded(
                  child: DetailWideBackdropStage(
                    workId: 'w_dr25',
                    bgPath: '/poster_dr25.jpg',
                    hasBackdrop: false,
                    isDrawerExpanded: true,
                    imageLoader: loader,
                  ),
                ),
                EpisodeDrawerCard(
                  episode: ep,
                  variants: const [],
                  fallbackBackdropPath: '/poster_dr25.jpg',
                  fallbackIsPoster: true,
                  imageLoader: loader,
                  onTap: () {},
                  onAdjustSlot: () {},
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        final images = tester
            .widgetList<ManagedImage>(find.byType(ManagedImage))
            .toList();
        expect(images, hasLength(2));
        expect(images[0].artwork, ManagedArtwork.poster);
        expect(
          images[0].alignment,
          equals(SmartCoverFraming.defaultPosterAlignment),
        );
        expect(images[1].artwork, ManagedArtwork.poster);
        expect(
          images[1].alignment,
          equals(SmartCoverFraming.defaultPosterAlignment),
        );

        // 当存在真实横版背景图时，两者均保持 Alignment.center 与 ManagedArtwork.backdrop。
        await tester.pumpWidget(
          _wrapApp(
            Column(
              children: [
                Expanded(
                  child: DetailWideBackdropStage(
                    workId: 'w_dr25',
                    bgPath: '/backdrop_dr25.jpg',
                    hasBackdrop: true,
                    isDrawerExpanded: true,
                    imageLoader: loader,
                  ),
                ),
                EpisodeDrawerCard(
                  episode: ep,
                  variants: const [],
                  fallbackBackdropPath: '/backdrop_dr25.jpg',
                  fallbackIsPoster: false,
                  imageLoader: loader,
                  onTap: () {},
                  onAdjustSlot: () {},
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        final backdropImages = tester
            .widgetList<ManagedImage>(find.byType(ManagedImage))
            .toList();
        expect(backdropImages, hasLength(2));
        expect(backdropImages[0].artwork, ManagedArtwork.backdrop);
        expect(backdropImages[0].alignment, equals(Alignment.center));
        expect(backdropImages[1].artwork, ManagedArtwork.backdrop);
        expect(backdropImages[1].alignment, equals(Alignment.center));
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );
  });
}
