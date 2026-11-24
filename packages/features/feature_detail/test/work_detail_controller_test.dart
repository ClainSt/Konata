import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'support/detail_test_fixtures.dart';

void main() {
  group('DetailDisplayPreferencesStore 展示偏好持久化切片', () {
    test('读取默认值、写入同步事件流与跨实例往返一致', () async {
      final harness = await DetailTestHarness.create();
      final store = DetailDisplayPreferencesStore(harness.scopedPrefs);

      final initial = store.read();
      expect(initial.showEpisodeStillThumbnails, isTrue);
      expect(initial.showOriginalSubtitlesOnCards, isTrue);
      expect(initial.showMainHeroBackdrop, isTrue);

      final emissions = <DetailDisplayPreferences>[];
      final sub = store.watch().listen(emissions.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      store.setShowEpisodeStillThumbnails(false);
      store.setShowOriginalSubtitlesOnCards(false);
      await Future<void>.delayed(Duration.zero);

      final reloaded = store.read();
      expect(reloaded.showEpisodeStillThumbnails, isFalse);
      expect(reloaded.showOriginalSubtitlesOnCards, isFalse);
      expect(emissions, isNotEmpty);
      expect(emissions.last.showEpisodeStillThumbnails, isFalse);
    });
  });

  group('WorkDetailController 数据聚合、重刮状态机、人工锁与系列切换', () {
    test('正确聚合正片/特典/CD/系列并转发播放、系列跳转与返回导航调用', () async {
      final harness = await DetailTestHarness.create();

      await harness.repository.upsertMediaSource(
        const MediaSource(
          id: 'src_1',
          kind: MediaSourceKind.local,
          label: '测试媒体源',
          location: 'D:/Anime/Test',
        ),
      );
      await harness.repository.upsertSeriesGroup(
        SeriesGroup(
          id: 'ser_1',
          title: '测试系列全集',
          createdAt: DateTime.utc(2025, 1, 1),
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
      );
      const w1 = Work(
        id: 'w_s1',
        seriesId: 'ser_1',
        seriesOrder: 1,
        seriesLabel: '第一季',
        title: '第一季作品',
        matchedSeason: 1,
        scrapeStatus: ScrapeStatus.matched,
      );
      const w2 = Work(
        id: 'w_s2',
        seriesId: 'ser_1',
        seriesOrder: 2,
        seriesLabel: '剧场版',
        title: '剧场版作品',
        scrapeStatus: ScrapeStatus.matched,
      );
      await harness.repository.upsertWork(w1);
      await harness.repository.upsertWork(w2);

      const ep1 = Episode(
        id: 'ep_1',
        workId: 'w_s1',
        seasonNumber: 1,
        episodeNumber: 1,
        category: EpisodeCategory.main,
        title: '相遇',
      );
      const sp1 = Episode(
        id: 'ep_sp_1',
        workId: 'w_s1',
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.ncop,
        title: 'NCOP01',
      );
      await harness.repository.upsertEpisode(ep1);
      await harness.repository.upsertEpisode(sp1);

      await harness.repository.upsertMediaVariant(
        const MediaVariant(
          id: 'v_ep1',
          workId: 'w_s1',
          episodeId: 'ep_1',
          sourceId: 'src_1',
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: 500,
        ),
      );
      await harness.repository.upsertMediaVariant(
        const MediaVariant(
          id: 'v_cd1',
          workId: 'w_s1',
          sourceId: 'src_1',
          relativePath: 'CD/OST.flac',
          fileName: 'OST.flac',
          fileSize: 200,
          assetKind: AssetKind.cdAlbum,
        ),
      );

      final ctrl = harness.createController(const WorkId.trusted('w_s1'));
      final bundle = await ctrl.load();

      expect(bundle, isNotNull);
      expect(bundle!.mainEpisodes.map((e) => e.id), <String>['ep_1']);
      expect(bundle.extraEpisodes.map((e) => e.id), <String>['ep_sp_1']);
      expect(bundle.cdVariants.map((v) => v.id), <String>['v_cd1']);
      expect(bundle.seriesMembers.length, 2);

      await ctrl.playEpisode(
        episodeId: const EpisodeId.trusted('ep_1'),
        variantId: const VariantId.trusted('v_ep1'),
      );
      await ctrl.playCdAlbum(variantId: const VariantId.trusted('v_cd1'));
      await ctrl.switchSeriesMember(const WorkId.trusted('w_s2'));
      await ctrl.navigateBack();

      expect(harness.navigator.videoPlayerCalls.single.episodeId?.value, 'ep_1');
      expect(harness.navigator.audioPlayerCalls.single.variantId?.value, 'v_cd1');
      expect(harness.navigator.workDetailCalls.single.workId.value, 'w_s2');
      expect(harness.navigator.popCount, 1);
    });

    test('单作重刮驱动 Idle -> Running -> Succeeded 状态机与领域事件发布，失败转入 Failed', () async {
      final harness = await DetailTestHarness.create(
        httpHandler: (method, uri) {
          if (uri.host == 'api.themoviedb.org' && uri.path == '/3/tv/999') {
            return KonataHttpResponse.text(
              jsonEncode(<String, Object?>{
                'id': 999,
                'name': '轻音少女 重刮新版',
                'original_name': 'けいおん!',
                'first_air_date': '2009-04-03',
                'overview': '最新同步简介',
                'poster_path': '/k_on_new_poster.jpg',
                'backdrop_path': '/k_on_new_bg.jpg',
                'vote_average': 8.6,
                'vote_count': 520,
                'genre_ids': <int>[16],
                'seasons': <Object?>[
                  <String, Object?>{
                    'season_number': 1,
                    'name': '第 1 季',
                    'episode_count': 1,
                  },
                ],
                'images': <String, Object?>{
                  'posters': <Object?>[],
                  'backdrops': <Object?>[],
                  'logos': <Object?>[],
                },
                'translations': <String, Object?>{'translations': <Object?>[]},
                'alternative_titles': <String, Object?>{'results': <Object?>[]},
              }),
            );
          }
          if (uri.host == 'api.themoviedb.org' &&
              uri.path == '/3/tv/999/season/1') {
            return KonataHttpResponse.text(
              jsonEncode(<String, Object?>{
                'season_number': 1,
                'name': '第 1 季',
                'episodes': <Object?>[
                  <String, Object?>{
                    'episode_number': 1,
                    'name': '废部!',
                    'overview': '轻音部面临废部危机',
                    'still_path': '/ep1_still.jpg',
                  },
                ],
              }),
            );
          }
          return KonataHttpResponse.text('{}', statusCode: 404);
        },
      );

      await harness.repository.upsertWork(
        const Work(
          id: 'w_rescrape',
          title: '轻音少女',
          tmdbId: 999,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );

      final ctrl = harness.createController(const WorkId.trusted('w_rescrape'));
      await ctrl.load();

      final observedStates = <WorkRescrapeState>[ctrl.rescrapeState];
      ctrl.addListener(() {
        observedStates.add(ctrl.rescrapeState);
      });

      final publishedEvents = <LibraryWorkChangedEvent>[];
      final sub = harness.domainEventBus
          .on<LibraryWorkChangedEvent>()
          .listen(publishedEvents.add);
      addTearDown(sub.cancel);

      expect(ctrl.rescrapeState, isA<WorkRescrapeIdle>());
      final result = await ctrl.rescrapeMetadata();

      expect(result, isA<WorkRescrapeSucceeded>());
      expect(observedStates.any((s) => s is WorkRescrapeRunning), isTrue);
      expect(ctrl.rescrapeState, isA<WorkRescrapeSucceeded>());
      await Future<void>.delayed(Duration.zero);
      expect(publishedEvents, isNotEmpty);

      ctrl.dismissRescrapeStatus();
      expect(ctrl.rescrapeState, isA<WorkRescrapeIdle>());

      // 模拟底层仓储故障验证 Failed 状态分支
      await harness.databases.close();
      final failed = await ctrl.rescrapeMetadata();
      expect(failed, isA<WorkRescrapeFailed>());
      expect(ctrl.rescrapeState, isA<WorkRescrapeFailed>());
      ctrl.dismissRescrapeStatus();
    });

    test('人工元数据锁、分集重映射锁与艺术图锁持久化与重置生效', () async {
      final harness = await DetailTestHarness.create();
      await harness.repository.upsertMediaSource(
        const MediaSource(
          id: 'src_1',
          kind: MediaSourceKind.local,
          label: '测试媒体源',
          location: 'D:/Anime/Test',
        ),
      );
      await harness.repository.upsertWork(
        const Work(
          id: 'w_lock',
          title: '原始标题',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await harness.repository.upsertEpisode(
        const Episode(
          id: 'ep_lock_1',
          workId: 'w_lock',
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '第 1 话',
        ),
      );
      await harness.repository.upsertMediaVariant(
        const MediaVariant(
          id: 'var_lock_1',
          workId: 'w_lock',
          episodeId: 'ep_lock_1',
          sourceId: 'src_1',
          relativePath: '01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
        ),
      );

      final ctrl = harness.createController(const WorkId.trusted('w_lock'));
      await ctrl.load();

      await ctrl.updateWorkManualMetadata(
        title: '人工锁定新标题',
        originalTitle: 'Original Manual',
        year: 2024,
        overview: '自定义简介',
      );
      expect(ctrl.bundle!.work.title, '人工锁定新标题');
      expect(ctrl.bundle!.work.isManualLocked, isTrue);
      expect(ctrl.bundle!.work.metadataLocked, isTrue);

      await ctrl.updateWorkArtwork(posterPath: 'https://example.com/custom.jpg');
      expect(ctrl.bundle!.work.posterLocked, isTrue);
      expect(ctrl.bundle!.work.posterPath, 'https://example.com/custom.jpg');

      await ctrl.saveEpisodeMappings(const <EpisodeFileMappingEdit>[
        EpisodeFileMappingEdit(
          variantId: 'var_lock_1',
          category: EpisodeCategory.extra,
          seasonNumber: 0,
          episodeNumber: 2,
          extraType: ExtraKind.pv,
        ),
      ]);
      final mappedVariant = ctrl.bundle!.variants.first;
      expect(mappedVariant.mappingLocked, isTrue);
      expect(ctrl.bundle!.extraEpisodes, isNotEmpty);

      await ctrl.resetArtworkLockToAuto(resetPoster: true);
      expect(ctrl.bundle!.work.posterLocked, isFalse);

      await ctrl.resetMetadataLockToAuto();
      expect(ctrl.bundle!.work.metadataLocked, isFalse);

      await ctrl.resetFileMappingsToAuto();
      expect(ctrl.bundle!.variants.first.mappingLocked, isFalse);
    });

    test('通过 FilePickerPort 选取本机图片执行比例裁切入 PhotosStorage 并生成 LocalCustomArtworkRef', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final harness = await DetailTestHarness.create();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 120, 180),
        ui.Paint()..color = const ui.Color(0xFF3A7AFE),
      );
      final picture = recorder.endRecording();
      final rawImg = await picture.toImage(120, 180);
      final pngByteData = await rawImg.toByteData(
        format: ui.ImageByteFormat.png,
      );
      rawImg.dispose();
      picture.dispose();

      final srcImage = File(
        '${harness.tempRoot.path}${Platform.pathSeparator}picked_cover.png',
      )..writeAsBytesSync(pngByteData!.buffer.asUint8List());
      harness.filePicker.nextImagePath = srcImage.path;

      await harness.repository.upsertWork(
        const Work(
          id: 'w_crop',
          title: '本地自定义封面作品',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      final ctrl = harness.createController(const WorkId.trusted('w_crop'));
      await ctrl.load();

      final picked = await ctrl.pickLocalImageFile(dialogTitle: '选择封面');
      expect(picked, srcImage.path);

      final loaded = await ctrl.loadLocalArtworkForCrop(picked!);
      addTearDown(loaded.dispose);
      final cropRect = ArtworkCropMath.initialMaxCenteredRect(
        imageWidth: loaded.width,
        imageHeight: loaded.height,
        aspectRatio: ArtworkCropMath.posterAspectRatio,
      );

      final savedPath = await ctrl.cropAndSaveLocalArtwork(
        isPoster: true,
        source: loaded,
        cropRect: cropRect,
      );

      expect(File(savedPath).existsSync(), isTrue);
      expect(ctrl.bundle!.work.posterLocked, isTrue);
      expect(ctrl.bundle!.work.posterRef, isA<LocalCustomArtworkRef>());
    });
  });
}
