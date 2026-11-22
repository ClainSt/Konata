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
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/cache/scan_thumbnail_scheduler.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/presentation/detail/detail_bottom_drawer.dart';
import 'package:konata/presentation/detail/detail_full_list_dialog.dart';
import 'package:konata/presentation/detail/detail_hero_info.dart';
import 'package:konata/presentation/detail/episode_drawer_card.dart';
import 'package:konata/presentation/detail/episode_media_info_dialog.dart';
import 'package:konata/presentation/detail/supplementary_asset_cards.dart';
import 'package:konata/presentation/detail/work_detail_page.dart';
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
  });
}
