import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/providers/work_management_provider.dart';
import 'package:ccplayer/domain/matching/supplementary_subclassifier.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/series_group.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/parsing/bdrip_parser.dart';
import 'package:ccplayer/domain/scraping/cloud_media_asset_presentation.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:ccplayer/domain/sources/artwork_crop_math.dart';
import 'package:ccplayer/infrastructure/cache/local_artwork_cropper.dart';
import 'package:ccplayer/infrastructure/cache/photos_storage.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/detail/detail_bottom_drawer.dart';
import 'package:ccplayer/presentation/detail/detail_secondary_filter_bar.dart';
import 'package:ccplayer/presentation/dialogs/artwork_crop_dialog.dart';
import 'package:ccplayer/presentation/dialogs/supplementary_scope_panel.dart';
import 'package:ccplayer/presentation/dialogs/work_artwork_picker_dialog.dart';
import 'package:ccplayer/presentation/settings/settings_network_panel.dart';
import 'package:ccplayer/presentation/shell/top_nav_bar.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_dropdown.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_surface_card.dart';

final Uint8List _tinyPng = Uint8List.fromList([
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

Widget _wrapTestApp(
  Widget child, {
  Key? scopeKey,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    key: scopeKey,
    overrides: [
      tmdbImageLoaderProvider.overrideWithValue(
        (_, {targetWidth, imageSize}) async => _tinyPng,
      ),
      ...overrides,
    ],
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: KonataTheme.darkTheme(),
      home: Scaffold(body: child),
    ),
  );
}

class _StubArtworkManagementActions extends WorkManagementActions {
  _StubArtworkManagementActions(super.ref, this._options);

  final WorkArtworkOptions _options;

  @override
  Future<WorkArtworkOptions> fetchWorkArtworkOptions(Work work) async {
    return _options;
  }
}

Future<ui.Image> _renderSolidTestImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const Color(0xFF336699),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(
      width * 0.25,
      height * 0.25,
      width * 0.5,
      height * 0.5,
    ),
    ui.Paint()..color = const Color(0xFFEE8833),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('7a. 特典语义限定词保留、子变体识别与精准多版本合并键', () {
    test('完整保留 Character/Teaser/Main/Climax PV、BD/TV CM 与 NCED1a/1b 标题及分类', () {
      const cases = <({
        String file,
        ExtraKind expectedKind,
        String expectedTitle,
      })>[
        (
          file: '[VCB-Studio] Frieren [Character PV 01][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.pv,
          expectedTitle: 'Character PV 01',
        ),
        (
          file: '[VCB-Studio] Frieren [Character PV 02][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.pv,
          expectedTitle: 'Character PV 02',
        ),
        (
          file: '[VCB-Studio] Frieren [Teaser PV 01][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.pv,
          expectedTitle: 'Teaser PV 01',
        ),
        (
          file: '[VCB-Studio] Frieren [Main PV][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.pv,
          expectedTitle: 'Main PV',
        ),
        (
          file: '[VCB-Studio] Frieren [Climax PV][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.pv,
          expectedTitle: 'Climax PV',
        ),
        (
          file: '[VCB-Studio] Frieren [BD CM 01][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.pv,
          expectedTitle: 'BD CM 01',
        ),
        (
          file: '[VCB-Studio] Frieren [TV CM 01][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.pv,
          expectedTitle: 'TV CM 01',
        ),
        (
          file: '[VCB-Studio] Frieren [NCED1a][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.nced,
          expectedTitle: 'NCED1a',
        ),
        (
          file: '[VCB-Studio] Frieren [NCED1b][Ma10p_1080p].mkv',
          expectedKind: ExtraKind.nced,
          expectedTitle: 'NCED1b',
        ),
      ];

      for (final c in cases) {
        final kind = SupplementarySubclassifier.classifyExtraVideo(
          fileName: c.file,
          relativePath: 'SPs/${c.file}',
        );
        expect(kind, c.expectedKind, reason: c.file);

        final title = CloudMediaAssetPresentation.extraTitle({
          'name': c.file,
          'relative_path': 'SPs/${c.file}',
          'category': 'extra',
        });
        expect(title, c.expectedTitle, reason: c.file);

        final parsed = BdripParser.parseFileName(
          c.file,
          relativePath: 'SPs/${c.file}',
        );
        final slot = ScrapeDomainAdapter.resolveExtraSlotAssignment(
          fileName: c.file,
          relativePath: 'SPs/${c.file}',
          parsed: parsed,
          folderCleanTitle: 'Frieren',
        );
        expect(slot.extraType, c.expectedKind, reason: c.file);
        expect(slot.extraTitleHint, c.expectedTitle, reason: c.file);
      }
    });

    test('同支短片不同规格版本精准合并，同序号不同限定词与子变体绝不误合并', () {
      final pv01Fhd = SupplementarySubclassifier.buildExtraCanonicalMergeKey(
        fileName: '[VCB-Studio] Frieren [PV01][1080p].mkv',
        relativePath: 'SPs/[VCB-Studio] Frieren [PV01][1080p].mkv',
      );
      final pv01Uhd = SupplementarySubclassifier.buildExtraCanonicalMergeKey(
        fileName: '[SweetSub] Frieren [PV 01][2160p_HEVC].mkv',
        relativePath: 'SPs/[SweetSub] Frieren [PV 01][2160p_HEVC].mkv',
      );
      expect(pv01Fhd, equals(pv01Uhd));

      final distinctKeys = <String>[
        pv01Fhd,
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [Character PV 01][1080p].mkv',
        ),
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [Character PV 02][1080p].mkv',
        ),
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [Teaser PV 01][1080p].mkv',
        ),
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [Main PV][1080p].mkv',
        ),
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [Climax PV][1080p].mkv',
        ),
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [BD CM 01][1080p].mkv',
        ),
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [TV CM 01][1080p].mkv',
        ),
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [NCED1a][1080p].mkv',
        ),
        SupplementarySubclassifier.buildExtraCanonicalMergeKey(
          fileName: '[VCB-Studio] Frieren [NCED1b][1080p].mkv',
        ),
      ];
      expect(distinctKeys.toSet().length, equals(distinctKeys.length));
    });
  });

  group('7b. 详情页加载期无需重扫自动自愈拆解历史误合并特典', () {
    test('workDetailBundleProvider 自动拆解 PV01 / NCED1 混杂分组并修复旧截断标题', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const sourceId = 'src_heal';
      const source = MediaSource(
        id: sourceId,
        kind: MediaSourceKind.local,
        label: '本地库',
        location: 'D:/Anime',
      );
      await repo.upsertMediaSource(source);

      const workId = 'w_frieren_heal';
      const work = Work(
        id: workId,
        title: '葬送的芙莉莲',
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(work);

      // 1) 历史误合并集：ep_pv1 错把 [PV01]1080p、[PV 01]4K、[Character PV 01]、[Character PV 02]、[Teaser PV 01] 合在一起
      const epPv1 = Episode(
        id: 'ep_legacy_pv1',
        workId: workId,
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.pv,
        title: 'PV01',
      );
      // 2) 历史误合并集：ep_nced1 错把 [NCED1a]、[NCED1b] 合在一起
      const epNced1 = Episode(
        id: 'ep_legacy_nced1',
        workId: workId,
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.nced,
        title: 'NCED1',
      );
      // 3) 历史单集标题截断：[Climax PV] 被保存成截断的 PV
      const epClimaxTrunc = Episode(
        id: 'ep_legacy_climax',
        workId: workId,
        seasonNumber: 0,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.sp,
        title: 'PV',
      );
      // 4) 人工锁定集：严禁自愈修改
      const epLocked = Episode(
        id: 'ep_locked_custom',
        workId: workId,
        seasonNumber: 0,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.sp,
        title: '用户定制特典标题',
      );

      for (final ep in [epPv1, epNced1, epClimaxTrunc, epLocked]) {
        await repo.upsertEpisode(ep);
      }

      const variants = <MediaVariant>[
        MediaVariant(
          id: 'v_pv1_fhd',
          workId: workId,
          episodeId: 'ep_legacy_pv1',
          sourceId: sourceId,
          relativePath: 'Frieren/SPs/[VCB-Studio] Frieren [PV01][1080p].mkv',
          fileName: '[VCB-Studio] Frieren [PV01][1080p].mkv',
          fileSize: 1000,
        ),
        MediaVariant(
          id: 'v_pv1_4k',
          workId: workId,
          episodeId: 'ep_legacy_pv1',
          sourceId: sourceId,
          relativePath: 'Frieren/SPs/[SweetSub] Frieren [PV 01][2160p].mkv',
          fileName: '[SweetSub] Frieren [PV 01][2160p].mkv',
          fileSize: 2000,
        ),
        MediaVariant(
          id: 'v_char_pv1',
          workId: workId,
          episodeId: 'ep_legacy_pv1',
          sourceId: sourceId,
          relativePath:
              'Frieren/SPs/[VCB-Studio] Frieren [Character PV 01][1080p].mkv',
          fileName: '[VCB-Studio] Frieren [Character PV 01][1080p].mkv',
          fileSize: 1100,
        ),
        MediaVariant(
          id: 'v_char_pv2',
          workId: workId,
          episodeId: 'ep_legacy_pv1',
          sourceId: sourceId,
          relativePath:
              'Frieren/SPs/[VCB-Studio] Frieren [Character PV 02][1080p].mkv',
          fileName: '[VCB-Studio] Frieren [Character PV 02][1080p].mkv',
          fileSize: 1200,
        ),
        MediaVariant(
          id: 'v_teaser_pv1',
          workId: workId,
          episodeId: 'ep_legacy_pv1',
          sourceId: sourceId,
          relativePath:
              'Frieren/SPs/[VCB-Studio] Frieren [Teaser PV 01][1080p].mkv',
          fileName: '[VCB-Studio] Frieren [Teaser PV 01][1080p].mkv',
          fileSize: 1300,
        ),
        MediaVariant(
          id: 'v_nced1a',
          workId: workId,
          episodeId: 'ep_legacy_nced1',
          sourceId: sourceId,
          relativePath: 'Frieren/SPs/[VCB-Studio] Frieren [NCED1a][1080p].mkv',
          fileName: '[VCB-Studio] Frieren [NCED1a][1080p].mkv',
          fileSize: 1400,
        ),
        MediaVariant(
          id: 'v_nced1b',
          workId: workId,
          episodeId: 'ep_legacy_nced1',
          sourceId: sourceId,
          relativePath: 'Frieren/SPs/[VCB-Studio] Frieren [NCED1b][1080p].mkv',
          fileName: '[VCB-Studio] Frieren [NCED1b][1080p].mkv',
          fileSize: 1500,
        ),
        MediaVariant(
          id: 'v_climax',
          workId: workId,
          episodeId: 'ep_legacy_climax',
          sourceId: sourceId,
          relativePath:
              'Frieren/SPs/[VCB-Studio] Frieren [Climax PV][1080p].mkv',
          fileName: '[VCB-Studio] Frieren [Climax PV][1080p].mkv',
          fileSize: 1600,
        ),
        MediaVariant(
          id: 'v_locked_1',
          workId: workId,
          episodeId: 'ep_locked_custom',
          sourceId: sourceId,
          relativePath: 'Frieren/SPs/[BD CM 01].mkv',
          fileName: '[BD CM 01].mkv',
          fileSize: 800,
          mappingLocked: true,
        ),
        MediaVariant(
          id: 'v_locked_2',
          workId: workId,
          episodeId: 'ep_locked_custom',
          sourceId: sourceId,
          relativePath: 'Frieren/SPs/[TV CM 01].mkv',
          fileName: '[TV CM 01].mkv',
          fileSize: 900,
          mappingLocked: true,
        ),
      ];
      for (final v in variants) {
        await repo.upsertMediaVariant(v);
      }

      // 在 ep_legacy_pv1 上记录一条播放进度，验证拆分后播放记录仍正常保留给原 PV01
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'pb_legacy_pv1',
          workId: workId,
          episodeId: 'ep_legacy_pv1',
          variantId: 'v_pv1_fhd',
          seasonNumber: 0,
          episodeNumber: 1,
          episodeTitle: 'PV01',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 5, 1),
          positionSeconds: 45,
          durationSeconds: 120,
        ),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      // 打开详情页加载 bundle —— 未触发重扫即完成自动拆解与自愈
      final bundle = await container.read(
        workDetailBundleProvider(work.id).future,
      );
      expect(bundle, isNotNull);

      final titles = bundle!.episodes.map((e) => e.title).toSet();
      expect(
        titles,
        containsAll(<String>[
          'PV01',
          'Character PV 01',
          'Character PV 02',
          'Teaser PV 01',
          'NCED1a',
          'NCED1b',
          'Climax PV',
          '用户定制特典标题',
        ]),
      );

      // 确认 PV01 仍合法保留 2 个版本，其余各自 1 个版本，已锁定的维持 2 个版本
      int variantCountForTitle(String title) {
        final ep = bundle.episodes.firstWhere((e) => e.title == title);
        return bundle.variants.where((v) => v.episodeId == ep.id).length;
      }

      expect(variantCountForTitle('PV01'), equals(2));
      expect(variantCountForTitle('Character PV 01'), equals(1));
      expect(variantCountForTitle('Character PV 02'), equals(1));
      expect(variantCountForTitle('Teaser PV 01'), equals(1));
      expect(variantCountForTitle('NCED1a'), equals(1));
      expect(variantCountForTitle('NCED1b'), equals(1));
      expect(variantCountForTitle('Climax PV'), equals(1));
      expect(variantCountForTitle('用户定制特典标题'), equals(2));

      final climaxEp = bundle.episodes.firstWhere(
        (e) => e.title == 'Climax PV',
      );
      expect(climaxEp.extraType, ExtraKind.pv);

      // 原 ep_legacy_pv1 保留给了 PV01，播放历史未丢失
      final pv01Ep = bundle.episodes.firstWhere((e) => e.title == 'PV01');
      expect(pv01Ep.id, equals('ep_legacy_pv1'));
      expect(bundle.playbackByEpisodeId['ep_legacy_pv1']?.positionSeconds, 45);

      // 二次从真实仓储重查确认已经持久化落库，且再次加载保持幂等
      final persistedEpisodes = await repo.getEpisodesByWork(work.id);
      expect(persistedEpisodes.length, equals(8));
      final secondLoad = await container.refresh(
        workDetailBundleProvider(work.id).future,
      );
      expect(secondLoad!.episodes.length, equals(8));
    });
  });

  group('5. 本地图片固定比例框选裁切（2:3 海报 / 16:9 背景）与真实像素落盘', () {
    test('ArtworkCropMath 比例锁定、边缘钳制、四角缩放与 4K 像素还原精度', () {
      // 16:9 横版背景在 2000x3000 竖图上应居中铺满全宽 (w=1.0)
      final backdropInit = ArtworkCropMath.initialMaxCenteredRect(
        imageWidth: 2000,
        imageHeight: 3000,
        aspectRatio: ArtworkCropMath.backdropAspectRatio,
      );
      expect(backdropInit.width, closeTo(1.0, 1e-6));
      final bdPx = ArtworkCropMath.toSourcePixelRect(
        backdropInit,
        imageWidth: 2000,
        imageHeight: 3000,
      );
      expect(bdPx.width / bdPx.height, closeTo(16.0 / 9.0, 0.02));

      // 2:3 竖版海报在 3840x2160 4K 图上居中全高
      final posterInit = ArtworkCropMath.initialMaxCenteredRect(
        imageWidth: 3840,
        imageHeight: 2160,
        aspectRatio: ArtworkCropMath.posterAspectRatio,
      );
      expect(posterInit.height, closeTo(1.0, 1e-6));
      final pPx = ArtworkCropMath.toSourcePixelRect(
        posterInit,
        imageWidth: 3840,
        imageHeight: 2160,
      );
      expect(pPx.width, equals(1440));
      expect(pPx.height, equals(2160));
      expect(pPx.width / pPx.height, closeTo(2.0 / 3.0, 0.005));

      // 平移溢出边界钳制
      final pannedOut = ArtworkCropMath.panCrop(
        posterInit,
        deltaNormX: 2.5,
        deltaNormY: -1.5,
      );
      expect(pannedOut.right, closeTo(1.0, 1e-6));
      expect(pannedOut.top, greaterThanOrEqualTo(0.0));

      // 右下角缩放严格锁死 2:3 比例
      final resized = ArtworkCropMath.resizeFromCorner(
        posterInit,
        corner: ArtworkCropCorner.bottomRight,
        pointerNormX: posterInit.left + 0.15,
        pointerNormY: posterInit.top + 0.55,
        imageWidth: 3840,
        imageHeight: 2160,
        aspectRatio: ArtworkCropMath.posterAspectRatio,
      );
      final resizedPx = ArtworkCropMath.toSourcePixelRect(
        resized,
        imageWidth: 3840,
        imageHeight: 2160,
      );
      expect(resizedPx.width / resizedPx.height, closeTo(2.0 / 3.0, 0.01));

      // 滚轮缩小围绕中心并保持比例
      final zoomedIn = ArtworkCropMath.zoomAroundCenter(
        posterInit,
        zoomScale: 0.7,
        imageWidth: 3840,
        imageHeight: 2160,
        aspectRatio: ArtworkCropMath.posterAspectRatio,
      );
      expect(zoomedIn.width, lessThan(posterInit.width));
      final zoomedPx = ArtworkCropMath.toSourcePixelRect(
        zoomedIn,
        imageWidth: 3840,
        imageHeight: 2160,
      );
      expect(zoomedPx.width / zoomedPx.height, closeTo(2.0 / 3.0, 0.01));
    });

    test('LocalArtworkCropper 读取原图执行真实 2:3 / 16:9 像素裁切并保存至 photos 子目录', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final tempRoot = Directory.systemTemp.createTempSync('konata_crop_test_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final srcImage = await _renderSolidTestImage(600, 400);
      final srcBytes = (await srcImage.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      srcImage.dispose();

      final srcFile = File('${tempRoot.path}/source_sample.png');
      await srcFile.writeAsBytes(srcBytes, flush: true);

      final storage = PhotosStorage(
        overrideRoot: Directory('${tempRoot.path}/photos'),
      );
      final loaded = await LocalArtworkCropper.loadFullResolution(srcFile.path);
      addTearDown(loaded.dispose);
      expect(loaded.width, equals(600));
      expect(loaded.height, equals(400));

      // 2:3 竖版封面裁切
      final posterCrop = ArtworkCropMath.initialMaxCenteredRect(
        imageWidth: loaded.width,
        imageHeight: loaded.height,
        aspectRatio: ArtworkCropMath.posterAspectRatio,
      );
      final posterPath = await LocalArtworkCropper.cropAndSaveToPhotos(
        source: loaded,
        cropRect: posterCrop,
        photosStorage: storage,
        workId: 'w_crop_1',
        workTitle: '葬送的芙莉莲',
        subfolder: PhotoSubfolder.posters,
      );
      expect(
        posterPath.replaceAll('\\', '/'),
        contains('/posters/local_crop_'),
      );
      final posterOut = await LocalArtworkCropper.loadFullResolution(posterPath);
      addTearDown(posterOut.dispose);
      expect(posterOut.width / posterOut.height, closeTo(2.0 / 3.0, 0.02));

      // 16:9 横版背景裁切
      final backdropCrop = ArtworkCropMath.initialMaxCenteredRect(
        imageWidth: loaded.width,
        imageHeight: loaded.height,
        aspectRatio: ArtworkCropMath.backdropAspectRatio,
      );
      final backdropPath = await LocalArtworkCropper.cropAndSaveToPhotos(
        source: loaded,
        cropRect: backdropCrop,
        photosStorage: storage,
        workId: 'w_crop_1',
        workTitle: '葬送的芙莉莲',
        subfolder: PhotoSubfolder.backdrops,
      );
      expect(
        backdropPath.replaceAll('\\', '/'),
        contains('/backdrops/local_crop_'),
      );
      final backdropOut = await LocalArtworkCropper.loadFullResolution(
        backdropPath,
      );
      addTearDown(backdropOut.dispose);
      expect(
        backdropOut.width / backdropOut.height,
        closeTo(16.0 / 9.0, 0.02),
      );
    });

    testWidgets('ArtworkCropDialog 正确展示 2:3 比例提示与交互控制并可确认返回', (tester) async {
      late LoadedLocalArtwork source;
      await tester.runAsync(() async {
        final img = await _renderSolidTestImage(300, 200);
        source = LoadedLocalArtwork(
          sourcePath: 'memory://sample.png',
          fullImage: img,
          width: img.width,
          height: img.height,
        );
      });
      addTearDown(source.dispose);

      ArtworkNormalizedCropRect? dialogResult;
      await tester.pumpWidget(
        _wrapTestApp(
          Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  dialogResult = await showDialog<ArtworkNormalizedCropRect>(
                    context: context,
                    builder: (_) =>
                        ArtworkCropDialog(source: source, isPoster: true),
                  );
                },
                child: const Text('打开裁切'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('打开裁切'));
      await tester.pumpAndSettle();

      expect(find.text('裁剪作品封面海报'), findsOneWidget);
      expect(find.text('锁定比例 2 : 3'), findsOneWidget);
      expect(find.text('重置选框'), findsOneWidget);
      expect(find.text('确认应用'), findsOneWidget);

      await tester.tap(find.text('确认应用'));
      await tester.pumpAndSettle();

      expect(dialogResult, isNotNull);
      expect(dialogResult!.height, closeTo(1.0, 1e-6));
    });
  });

  group('1 & 2 & 3 & 4 & 6. 布局对称、顶栏防缺字、下拉互斥、对角角标与详情固定入口', () {
    testWidgets('1. 刮削与网络重构为首行独立密钥卡 + 次行 1:1 对称服务卡且无溢出', (
      tester,
    ) async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      Future<void> pumpAtWidth(double width) async {
        tester.view.physicalSize = Size(width, 920);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(
          _wrapTestApp(
            const SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: SettingsNetworkPanel(),
            ),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbNetworkConfigProvider.overrideWith(
                (_) async => const TmdbNetworkConfig(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
      }

      addTearDown(tester.view.resetPhysicalSize);

      await pumpAtWidth(1120);
      expect(find.text('TMDB API 密钥'), findsOneWidget);
      expect(find.text('如何获取TMDB API'), findsOneWidget);
      expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
      // 彻底移除旧的破坏对称性的副标题说明
      expect(find.textContaining('供分集放送顺与特别篇协同校准使用'), findsNothing);

      final keyCard = tester.getRect(
        find.ancestor(
          of: find.text('TMDB API 密钥'),
          matching: find.byType(KonataSurfaceCard),
        ).first,
      );
      final tmdbCard = tester.getRect(
        find.ancestor(
          of: find.text('TMDB 服务'),
          matching: find.byType(KonataSurfaceCard),
        ).first,
      );
      final bgmCard = tester.getRect(
        find.ancestor(
          of: find.text('Bangumi 服务'),
          matching: find.byType(KonataSurfaceCard),
        ).first,
      );
      expect(tmdbCard.top, greaterThan(keyCard.bottom - 1));
      expect(tmdbCard.top, equals(bgmCard.top));
      expect(bgmCard.left, greaterThan(tmdbCard.left));
      expect((tmdbCard.height - bgmCard.height).abs(), lessThanOrEqualTo(2.0));

      // 窄屏回退为单列堆叠仍零溢出
      await pumpAtWidth(680);
      expect(
        tester.getTopLeft(find.text('Bangumi 服务')).dy,
        greaterThan(tester.getTopLeft(find.text('TMDB 服务')).dy),
      );
    });

    testWidgets('2. TopNavBar 隐形粗体自然占位完整显示四字导航且指示线严格居中', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 120);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var active = KonataNavSection.library;
      await tester.pumpWidget(
        _wrapTestApp(
          StatefulBuilder(
            builder: (context, setState) {
              return TopNavBar(
                activeSection: active,
                onSectionChanged: (s) => setState(() => active = s),
                searchQuery: '',
                onSearchChanged: (_) {},
                searchFocusNode: FocusNode(),
                searchExpanded: false,
                onSearchExpandedChanged: (_) {},
                onToggleTheme: () {},
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final widthsBefore = <String, double>{};
      for (final label in const ['媒体库', '媒体源', '播放记录', '设置']) {
        final visibleFinder = find.text(label);
        expect(visibleFinder, findsOneWidget, reason: label);
        final tw = tester.widget<Text>(visibleFinder);
        expect(tw.softWrap, isFalse);
        expect(tw.maxLines, equals(1));
        expect(
          find.text(label, findRichText: true),
          findsNWidgets(2),
          reason: '$label 应包含 1 个可见 Text 与 1 个隐形粗体 RichText 等宽占位',
        );
        widthsBefore[label] = tester.getSize(visibleFinder).width;
      }

      // 直接点击「播放记录」（无需 .last）验证零歧义且切换字重后零横向抖动
      await tester.tap(find.text('播放记录'));
      await tester.pumpAndSettle();
      expect(active, equals(KonataNavSection.history));
      for (final label in const ['媒体库', '媒体源', '播放记录', '设置']) {
        final tabStack = find.ancestor(
          of: find.text(label),
          matching: find.byType(Stack),
        );
        expect(tabStack, findsWidgets);
        expect(
          tester.getSize(find.text(label)).width,
          greaterThanOrEqualTo(widthsBefore[label]! - 1e-6),
        );
      }
    });

    testWidgets('3. KonataDropdown 单一互斥悬停、右侧滚动留白与系列特别篇消歧标题', (
      tester,
    ) async {
      // A. 系列特别篇标签消歧校验
      const members = <Work>[
        Work(
          id: 'w_m1',
          title: '葬送的芙莉莲',
          matchedSeason: 1,
          seriesLabel: '第 1 季',
          seriesOrder: 1,
        ),
        Work(
          id: 'w_m2',
          title: '葬送的芙莉莲 OAD',
          matchedSeason: 0,
          seriesLabel: '特别篇',
          seriesOrder: 2,
        ),
      ];
      expect(
        SeriesLabelPresets.formatDisambiguatedMemberLabel(
          members[1],
          members,
          fallbackOrder: 2,
        ),
        equals('特别篇 · 葬送的芙莉莲 OAD'),
      );
      expect(
        SeriesLabelPresets.formatDisambiguatedMemberLabel(
          members[0],
          members,
          fallbackOrder: 1,
        ),
        equals('第 1 季'),
      );

      // 渲染 SupplementaryScopePanel 验证菜单提示清晰展示 `仅「特别篇 · 葬送的芙莉莲 OAD」独享`
      await tester.pumpWidget(
        _wrapTestApp(
          SupplementaryScopePanel(
            drafts: [
              SupplementaryScopeDraft(
                item: const SupplementaryEditableItem(
                  variant: MediaVariant(
                    id: 'mv_scope_1',
                    workId: 'w_m2',
                    sourceId: 's1',
                    relativePath: 'SP/Special.mkv',
                    fileName: 'Special.mkv',
                    fileSize: 100,
                    assetScope: SupplementaryAssetScope.workExclusive,
                  ),
                  ownerWorkId: 'w_m2',
                  ownerLabel: '特别篇 · 葬送的芙莉莲 OAD',
                ),
              ),
            ],
            seriesMembers: members,
            saving: false,
            onChanged: () {},
            onOpenSeriesManage: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('仅「特别篇 · 葬送的芙莉莲 OAD」独享'),
        findsWidgets,
      );

      // B. KonataDropdown 互斥悬停与右侧 14px 滚动留白校验
      var selected = 'opt3';
      await tester.pumpWidget(
        _wrapTestApp(
          Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                return KonataDropdown<String>(
                  value: selected,
                  options: const [
                    KonataDropdownOption(value: 'opt1', label: '选项 Alpha'),
                    KonataDropdownOption(value: 'opt2', label: '选项 Beta'),
                    KonataDropdownOption(value: 'opt3', label: '选项 Gamma'),
                  ],
                  onChanged: (v) => setState(() => selected = v),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('选项 Gamma'));
      await tester.pumpAndSettle();

      final listView = tester.widget<ListView>(find.byType(ListView));
      expect((listView.padding! as EdgeInsets).right, greaterThanOrEqualTo(14.0));

      int countGreyHoverTiles() {
        var greyCount = 0;
        for (final label in const ['选项 Alpha', '选项 Beta']) {
          final inkFinder = find.ancestor(
            of: find.text(label),
            matching: find.byType(InkWell),
          );
          final tileContainers = find.descendant(
            of: inkFinder.first,
            matching: find.byType(AnimatedContainer),
          );
          for (final element in tileContainers.evaluate()) {
            final widget = element.widget as AnimatedContainer;
            final deco = widget.decoration;
            if (deco is BoxDecoration &&
                deco.color != null &&
                deco.color!.a > 0) {
              greyCount++;
              break;
            }
          }
        }
        return greyCount;
      }

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.text('选项 Alpha'))),
      );
      await tester.pumpAndSettle();
      expect(countGreyHoverTiles(), equals(1));

      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.text('选项 Beta'))),
      );
      await tester.pumpAndSettle();
      expect(countGreyHoverTiles(), equals(1));

      // 移入当前已选中蓝色高亮项时，灰色悬停底色必须归零
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.text('选项 Gamma').last)),
      );
      await tester.pumpAndSettle();
      expect(countGreyHoverTiles(), equals(0));
    });

    testWidgets('4 & 6. 候选卡左上紧凑来源 + 右下分辨率，详情展开抽屉右上常驻 ⊞ 按钮', (
      tester,
    ) async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const workSp = Work(
        id: 'w_art_sp',
        title: '测试特别篇',
        tmdbId: 1001,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 0,
      );
      await repo.upsertWork(workSp);

      await tester.pumpWidget(
        _wrapTestApp(
          const WorkArtworkPickerDialog(
            work: workSp,
            kind: WorkArtworkKind.poster,
          ),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(),
            ),
            workManagementProvider.overrideWith(
              (ref) => _StubArtworkManagementActions(
                ref,
                const WorkArtworkOptions(
                  posters: [
                    WorkArtworkOption(
                      filePath: '/sp_season.jpg',
                      sourceLabel: 'TMDB 第0季',
                      isSeasonPoster: true,
                      width: 2000,
                      height: 3000,
                    ),
                    WorkArtworkOption(
                      filePath: 'https://lain.bgm.tv/pic/cover/l/demo.jpg',
                      sourceLabel: 'Bangumi',
                      isBangumi: true,
                      width: 1200,
                      height: 1693,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final spBadge = find.text('TMDB·SP');
      final bgmBadge = find.text('Bangumi');
      final res2k = find.text('2000×3000');
      expect(spBadge, findsOneWidget);
      expect(bgmBadge, findsOneWidget);
      expect(res2k, findsOneWidget);

      // 验证第 1 张卡片左上来源与右下分辨率的对角分布（来源靠上靠左，分辨率靠下靠右）
      final spRect = tester.getRect(spBadge);
      final resRect = tester.getRect(res2k);
      expect(spRect.top, lessThan(resRect.top));
      expect(spRect.left, lessThan(resRect.left));

      // 验证第 6 项：展开详情抽屉出现二次筛选栏时，右上角依然固定展示 `⊞` (`Icons.grid_view_rounded`)，且二次筛选栏右侧无重复 `完整列表` 文字
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final cdBundle = WorkDetailBundle(
        work: workSp,
        episodes: const [
          Episode(
            id: 'e1',
            workId: 'w_art_sp',
            seasonNumber: 0,
            episodeNumber: 1,
            category: EpisodeCategory.main,
            title: '第 1 集',
          ),
        ],
        variants: const [],
        cdVariants: const [
          MediaVariant(
            id: 'cd_a',
            workId: 'w_art_sp',
            sourceId: 's1',
            relativePath: 'CDs/OST_1/01.flac',
            fileName: '01.flac',
            fileSize: 1000,
            assetKind: AssetKind.cdAlbum,
          ),
          MediaVariant(
            id: 'cd_b',
            workId: 'w_art_sp',
            sourceId: 's1',
            relativePath: 'CDs/OP_Single/01.flac',
            fileName: '01.flac',
            fileSize: 1000,
            assetKind: AssetKind.cdAlbum,
          ),
        ],
        scanVariants: const [],
        sourcesById: const {},
        latestPlayback: null,
      );

      await tester.pumpWidget(
        _wrapTestApp(
          Align(
            alignment: Alignment.bottomCenter,
            child: DetailBottomDrawer(
              bundle: cdBundle,
              activeTab: DetailDrawerTab.cd,
              imageLoader: (_, {targetWidth, imageSize}) async => _tinyPng,
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
          scopeKey: const ValueKey('drawer_step'),
        ),
      );
      await tester.pumpAndSettle();

      // 二次筛选栏已渲染多专辑胶囊，且右侧无 `完整列表` 文字按钮
      expect(find.byType(DetailSecondaryFilterBar), findsOneWidget);
      expect(find.text('完整列表'), findsNothing);

      // 展开态右上方控件栏固定展示 `[ ⊞ < > ⌄ ⚙ ]`，且 `⊞` 严格位于 `<` 左侧
      final gridBtn = find.byIcon(Icons.grid_view_rounded);
      final prevBtn = find.byIcon(Icons.chevron_left_rounded);
      expect(gridBtn, findsOneWidget);
      expect(prevBtn, findsOneWidget);
      expect(
        tester.getTopLeft(gridBtn).dx,
        lessThan(tester.getTopLeft(prevBtn).dx),
      );
    });
  });
}
