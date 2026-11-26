import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'support/detail_test_fixtures.dart';

void main() {
  group('DetailDisplayPreferencesStore 展示偏好持久化切片', () {
    test('标题模式互斥并兼容旧版双选、空选与明确文字模式', () {
      for (final text in [true, false]) {
        for (final logo in [true, false]) {
          final prefs = DetailDisplayPreferences.decodeJson({
            'showTitleText': text,
            'showTitleLogo': logo,
          }, 1);
          expect(prefs.showTitleLogo, logo || !text);
          expect(prefs.showTitleText, !prefs.showTitleLogo);
          expect(prefs.copyWith(showTitleLogo: false).showTitleText, isTrue);
          expect(prefs.copyWith(showTitleLogo: true).showTitleText, isFalse);
        }
      }
    });
    test('读取默认值、写入同步事件流、10 键共享切片与未知扩展字段透传往返一致', () async {
      final harness = await DetailTestHarness.create();
      final store = DetailDisplayPreferencesStore(harness.scopedPrefs);

      final initial = store.read();
      expect(initial.showTitleText, isFalse);
      expect(initial.showTitleLogo, isTrue);
      expect(initial.showOverview, isTrue);
      expect(initial.showRawVideoFilename, isTrue);
      expect(initial.showCdTab, isTrue);
      expect(initial.showScanTab, isTrue);
      expect(initial.showMainHeroBackdrop, isTrue);
      expect(initial.showEpisodeStillThumbnails, isTrue);
      expect(initial.showOriginalSubtitlesOnCards, isTrue);
      expect(initial.autoSilentWarmup, isTrue);

      final rawWithExtras = <String, Object?>{
        'showTitleText': false,
        'showRawVideoFilename': true,
        'showCdTab': false,
        'futureExperimentalToggle': 'keep_me',
        'customDensity': 2,
      };
      final decoded = DetailDisplayPreferences.decodeJson(rawWithExtras, 1);
      expect(decoded.showTitleText, isFalse);
      expect(decoded.showRawVideoFilename, isTrue);
      expect(decoded.showCdTab, isFalse);
      expect(decoded.extraFields['futureExperimentalToggle'], 'keep_me');
      expect(decoded.extraFields['customDensity'], 2);

      store.write(decoded);
      store.setShowOverview(false);
      store.setShowScanTab(false);

      final reloaded = store.read();
      expect(reloaded.showTitleText, isFalse);
      expect(reloaded.showOverview, isFalse);
      expect(reloaded.showRawVideoFilename, isTrue);
      expect(reloaded.showCdTab, isFalse);
      expect(reloaded.showScanTab, isFalse);
      expect(reloaded.extraFields['futureExperimentalToggle'], 'keep_me');
      expect(DetailDisplayPreferences.encodeJson(reloaded)['customDensity'], 2);

      final emissions = <DetailDisplayPreferences>[];
      final sub = store.watch().listen(emissions.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      store.setShowEpisodeStillThumbnails(false);
      store.setShowOriginalSubtitlesOnCards(false);
      await Future<void>.delayed(Duration.zero);

      final updated = store.read();
      expect(updated.showEpisodeStillThumbnails, isFalse);
      expect(updated.showOriginalSubtitlesOnCards, isFalse);
      expect(emissions, isNotEmpty);
      expect(emissions.last.showEpisodeStillThumbnails, isFalse);
    });
  });

  group('WorkDetailController 数据聚合、重刮状态机、人工锁与系列切换', () {
    for (final platform in [
      KonataPlatform.windows,
      KonataPlatform.androidPhone,
    ]) {
      test('跨季共享 SP/CD 按资源归属播放，独享及重复季度隔离：$platform', () async {
        final h = await DetailTestHarness.create();
        const source = MediaSource(
          id: 'bd-source',
          kind: MediaSourceKind.local,
          label: 'BDRIP 隔离夹具',
          location: 'D:/AuditOnly',
        );
        await h.repository.upsertMediaSource(source);
        await h.repository.upsertSeriesGroup(
          SeriesGroup(
            id: 'bd-series',
            title: 'BDRIP 系列',
            createdAt: DateTime.utc(2025),
            updatedAt: DateTime.utc(2025),
          ),
        );
        for (final (id, season) in [('a', 1), ('b', 2), ('duplicate', 1)]) {
          await h.repository.upsertWork(
            Work(
              id: id,
              title: '收藏 $id',
              seriesId: 'bd-series',
              seriesOrder: season,
              tmdbId: 90001,
              tmdbMediaType: TmdbMediaType.tv,
              matchedSeason: season,
              scrapeStatus: ScrapeStatus.matched,
            ),
          );
        }
        Future<void> addVideo(
          String owner,
          String name,
          EpisodeCategory category, {
          SupplementaryAssetScope scope = SupplementaryAssetScope.workExclusive,
          int versions = 1,
        }) async {
          final episodeId = '$owner-$name';
          await h.repository.upsertEpisode(
            Episode(
              id: episodeId,
              workId: owner,
              seasonNumber: category == EpisodeCategory.main ? 1 : 0,
              episodeNumber: 1,
              category: category,
              extraType: category == EpisodeCategory.extra
                  ? ExtraKind.sp
                  : null,
              title: name,
            ),
          );
          for (var i = 0; i < versions; i++) {
            await h.repository.upsertMediaVariant(
              MediaVariant(
                id: '$episodeId-v$i',
                workId: owner,
                episodeId: episodeId,
                sourceId: source.id,
                relativePath: '$owner/$name/v$i.mkv',
                fileName: 'v$i.mkv',
                fileSize: 1024,
                assetScope: scope,
              ),
            );
          }
        }

        Future<void> addAsset(
          String owner,
          String name,
          AssetKind kind,
          SupplementaryAssetScope scope,
        ) async {
          await h.repository.upsertMediaVariant(
            MediaVariant(
              id: '$owner-$name',
              workId: owner,
              sourceId: source.id,
              relativePath: '$owner/$name',
              fileName: name,
              fileSize: 512,
              assetKind: kind,
              assetScope: scope,
            ),
          );
        }

        await addVideo('a', 'main', EpisodeCategory.main, versions: 2);
        await addVideo('b', 'main', EpisodeCategory.main);
        await addVideo(
          'b',
          'SP-shared',
          EpisodeCategory.extra,
          scope: SupplementaryAssetScope.seriesShared,
          versions: 2,
        );
        await addVideo('b', 'SP-private', EpisodeCategory.extra);
        await addVideo(
          'duplicate',
          'SP-duplicate',
          EpisodeCategory.extra,
          scope: SupplementaryAssetScope.seriesShared,
        );
        await addAsset(
          'a',
          'own.flac',
          AssetKind.cdAlbum,
          SupplementaryAssetScope.workExclusive,
        );
        await addAsset(
          'b',
          'shared.flac',
          AssetKind.cdAlbum,
          SupplementaryAssetScope.seriesShared,
        );
        await addAsset(
          'b',
          'private.flac',
          AssetKind.cdAlbum,
          SupplementaryAssetScope.workExclusive,
        );
        await addAsset(
          'duplicate',
          'duplicate.flac',
          AssetKind.cdAlbum,
          SupplementaryAssetScope.seriesShared,
        );
        await addAsset(
          'a',
          'own.png',
          AssetKind.scanGallery,
          SupplementaryAssetScope.workExclusive,
        );
        await addAsset(
          'b',
          'shared.png',
          AssetKind.scanGallery,
          SupplementaryAssetScope.seriesShared,
        );
        await addAsset(
          'b',
          'private.png',
          AssetKind.scanGallery,
          SupplementaryAssetScope.workExclusive,
        );
        await addAsset(
          'duplicate',
          'duplicate.png',
          AssetKind.scanGallery,
          SupplementaryAssetScope.seriesShared,
        );
        Future<void> history(
          String owner,
          String episode,
          String variant,
          int position,
          int day, {
          String? recordId,
        }) async {
          await h.repository.recordPlayback(
            PlaybackRecord(
              id: recordId ?? '$owner::$episode',
              workId: owner,
              episodeId: episode,
              variantId: variant,
              seasonNumber: 1,
              episodeNumber: 1,
              episodeTitle: episode,
              sourceType: MediaSourceKind.local,
              playedAt: DateTime.utc(2025, 1, day),
              positionSeconds: position,
              durationSeconds: 120,
            ),
          );
        }

        await history('a', 'a-main', 'a-main-v1', 17, 1);
        await history('b', 'b-main', 'b-main-v0', 30, 2);
        await history(
          'b',
          'b-SP-shared',
          'b-SP-shared-v0',
          8,
          2,
          recordId: 'old-shared',
        );
        await history('b', 'b-SP-shared', 'b-SP-shared-v1', 21, 3);
        await history('b', 'b-SP-private', 'b-SP-private-v0', 33, 4);
        await history(
          'duplicate',
          'duplicate-SP-duplicate',
          'duplicate-SP-duplicate-v0',
          44,
          5,
        );
        await history('b', 'cd::b-shared.flac', 'b-shared.flac', 5, 6);

        final ctrl = h.createController(
          const WorkId.trusted('a'),
          platform: platform,
        );
        final bundle = (await ctrl.load())!;
        expect(bundle.mainEpisodes.map((e) => e.id), ['a-main']);
        expect(bundle.extraEpisodes.map((e) => e.id), ['b-SP-shared']);
        expect(bundle.variantsForEpisode('a-main').map((v) => v.id), [
          'a-main-v0',
          'a-main-v1',
        ]);
        expect(bundle.variantsForEpisode('b-SP-shared').map((v) => v.id), [
          'b-SP-shared-v0',
          'b-SP-shared-v1',
        ]);
        expect(bundle.cdVariants.map((v) => v.id), [
          'a-own.flac',
          'b-shared.flac',
        ]);
        expect(bundle.visibleScanCount, 2);
        expect(
          bundle.playbackByEpisodeId['b-SP-shared']?.positionSeconds,
          21,
          reason: '共享特典卡片应读取原始归属的最新播放记录',
        );
        expect(
          bundle.playbackByEpisodeId['b-SP-shared']?.variantId,
          'b-SP-shared-v1',
        );
        expect(bundle.playbackByEpisodeId['b-SP-shared']?.workId, 'b');
        expect(bundle.playbackByEpisodeId.keys.toSet(), {
          'a-main',
          'b-SP-shared',
        });
        expect(bundle.latestPlayback?.episodeId, 'a-main');
        expect(bundle.resumePlan?.targetEpisode.id.value, 'a-main');
        expect(bundle.resumePlan?.startSeconds, 17);

        Future<void> waitForBundle(
          bool Function(WorkDetailBundle) predicate,
        ) async {
          final timer = Stopwatch()..start();
          while (timer.elapsed < const Duration(seconds: 3)) {
            final current = ctrl.bundle;
            if (current != null && predicate(current)) return;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(
            ctrl.bundle != null && predicate(ctrl.bundle!),
            isTrue,
            reason: '历史或共享范围变更应触发详情自动刷新',
          );
        }

        await history('b', 'b-SP-shared', 'b-SP-shared-v1', 42, 7);
        await waitForBundle(
          (b) => b.playbackByEpisodeId['b-SP-shared']?.positionSeconds == 42,
        );
        expect(ctrl.bundle!.resumePlan?.startSeconds, 17);
        final sharedVariants = bundle.variantsForEpisode('b-SP-shared');
        for (final v in sharedVariants) {
          await h.repository.upsertMediaVariant(
            v.copyWith(assetScope: SupplementaryAssetScope.workExclusive),
          );
        }
        await waitForBundle(
          (b) =>
              b.extraEpisodes.isEmpty &&
              !b.playbackByEpisodeId.containsKey('b-SP-shared'),
        );
        for (final v in sharedVariants) {
          await h.repository.upsertMediaVariant(v);
        }
        await waitForBundle(
          (b) => b.playbackByEpisodeId['b-SP-shared']?.positionSeconds == 42,
        );
        expect(ctrl.bundle!.resumePlan?.targetEpisode.id.value, 'a-main');

        expect(
          bundle.editableSupplementaryItems.map((item) => item.variant.id),
          containsAll(['b-SP-private-v0', 'b-private.flac', 'b-private.png']),
        );

        await ctrl.playEpisode(
          episodeId: const EpisodeId.trusted('a-main'),
          variantId: const VariantId.trusted('a-main-v1'),
        );
        await ctrl.playEpisode(
          episodeId: const EpisodeId.trusted('b-SP-shared'),
          variantId: const VariantId.trusted('b-SP-shared-v1'),
        );
        await ctrl.playEpisode(
          episodeId: const EpisodeId.trusted('b-SP-shared'),
        );
        await ctrl.playCdAlbum(
          variantId: const VariantId.trusted('a-own.flac'),
        );
        await ctrl.playCdAlbum(
          variantId: const VariantId.trusted('b-shared.flac'),
        );
        await ctrl.playCdAlbum();
        expect(h.navigator.videoPlayerCalls.map((c) => c.workId.value), [
          'a',
          'b',
          'b',
        ], reason: '共享特典必须按原始作品归属进入播放器');
        expect(h.navigator.videoPlayerCalls.map((c) => c.variantId?.value), [
          'a-main-v1',
          'b-SP-shared-v1',
          null,
        ]);
        expect(h.navigator.audioPlayerCalls.map((c) => c.workId.value), [
          'a',
          'b',
          'a',
        ], reason: '共享 CD 必须按原始作品归属进入播放器');
        expect(h.navigator.audioPlayerCalls.map((c) => c.variantId?.value), [
          'a-own.flac',
          'b-shared.flac',
          null,
        ]);

        // 播放器按传入作品查询实际索引；确认目标分集与版本都在该作品下。
        for (final call in h.navigator.videoPlayerCalls) {
          expect(
            (await h.repository.getEpisodesByWork(
              call.workId.value,
            )).map((e) => e.id),
            contains(call.episodeId!.value),
          );
          if (call.variantId != null) {
            expect(
              (await h.repository.getVariantsByWork(
                call.workId.value,
              )).map((v) => v.id),
              contains(call.variantId!.value),
            );
          }
        }
        for (final call in h.navigator.audioPlayerCalls.where(
          (c) => c.variantId != null,
        )) {
          expect(
            (await h.repository.getVariantsByWork(
              call.workId.value,
            )).map((v) => v.id),
            contains(call.variantId!.value),
          );
        }
      });
    }

    test('详情移除清理所属索引，保留系列兄弟和实际源文件', () async {
      final h = await DetailTestHarness.create();
      final file = File('${h.tempRoot.path}/source/A/01.mkv');
      await file.parent.create(recursive: true);
      await file.writeAsString('只读源文件');
      await h.repository.upsertMediaSource(
        MediaSource(
          id: 'src-del',
          kind: MediaSourceKind.local,
          label: '测试',
          location: '${h.tempRoot.path}/source',
        ),
      );
      await h.repository.upsertSeriesGroup(
        SeriesGroup(
          id: 'ser-del',
          title: '系列',
          createdAt: DateTime.utc(2025),
          updatedAt: DateTime.utc(2025),
        ),
      );
      await h.repository.upsertWork(
        const Work(
          id: 'work-del',
          title: '移除',
          seriesId: 'ser-del',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await h.repository.upsertWork(
        const Work(
          id: 'work-keep',
          title: '保留',
          seriesId: 'ser-del',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await h.repository.upsertEpisode(
        const Episode(
          id: 'ep-del',
          workId: 'work-del',
          seasonNumber: 1,
          episodeNumber: 1,
        ),
      );
      await h.repository.upsertMediaVariant(
        const MediaVariant(
          id: 'var-del',
          workId: 'work-del',
          episodeId: 'ep-del',
          sourceId: 'src-del',
          relativePath: 'A/01.mkv',
          fileName: '01.mkv',
          fileSize: 100,
        ),
      );
      final ctrl = h.createController(const WorkId.trusted('work-del'));
      await ctrl.deleteWorkFromLibrary();
      expect(await h.repository.findWorkById('work-del'), isNull);
      expect(await h.repository.getEpisodesByWork('work-del'), isEmpty);
      expect(await h.repository.getVariantsBySource('src-del'), isEmpty);
      expect(await h.repository.findWorkById('work-keep'), isNotNull);
      expect(await h.repository.getIgnoredFolders('src-del'), isEmpty);
      expect(
        h.databases.library.mediaVariants
            .findById(const VariantId.trusted('var-del'), includeDeleted: true)
            ?.deletedAtMs,
        isNotNull,
      );
      expect(await file.readAsString(), '只读源文件');
    });
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

      expect(
        harness.navigator.videoPlayerCalls.single.episodeId?.value,
        'ep_1',
      );
      expect(
        harness.navigator.audioPlayerCalls.single.variantId?.value,
        'v_cd1',
      );
      expect(harness.navigator.workDetailCalls.single.workId.value, 'w_s2');
      expect(harness.navigator.popCount, 1);
    });

    test(
      '单作重刮驱动 Idle -> Running -> Succeeded 状态机与领域事件发布，失败转入 Failed',
      () async {
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
                  'translations': <String, Object?>{
                    'translations': <Object?>[],
                  },
                  'alternative_titles': <String, Object?>{
                    'results': <Object?>[],
                  },
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

        final ctrl = harness.createController(
          const WorkId.trusted('w_rescrape'),
        );
        await ctrl.load();

        final observedStates = <WorkRescrapeState>[ctrl.rescrapeState];
        ctrl.addListener(() {
          observedStates.add(ctrl.rescrapeState);
        });

        final publishedEvents = <LibraryWorkChangedEvent>[];
        final sub = harness.domainEventBus.on<LibraryWorkChangedEvent>().listen(
          publishedEvents.add,
        );
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
      },
    );

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

      await ctrl.updateWorkArtwork(
        posterPath: 'https://example.com/custom.jpg',
      );
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

    test(
      '通过 FilePickerPort 选取本机图片执行比例裁切入 PhotosStorage 并生成 LocalCustomArtworkRef',
      () async {
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

        final portraitSaved = await ctrl.cropAndSaveLocalArtwork(
          isPoster: true,
          isPortraitBackdrop: true,
          source: loaded,
          cropRect: cropRect,
        );
        expect(File(portraitSaved).existsSync(), isTrue);
        expect(ctrl.bundle!.work.portraitBackdropLocked, isTrue);
        expect(
          ctrl.bundle!.work.portraitBackdropRef,
          isA<LocalCustomArtworkRef>(),
        );

        // 手动更新基础信息时严禁丢失已锁定的竖版原画路径与锁定状态
        await ctrl.updateWorkManualMetadata(title: '保留竖版原画测试');
        expect(ctrl.bundle!.work.portraitBackdropPath, portraitSaved);
        expect(ctrl.bundle!.work.portraitBackdropLocked, isTrue);

        await ctrl.resetArtworkLockToAuto(resetPortraitBackdrop: true);
        expect(ctrl.bundle!.work.portraitBackdropLocked, isFalse);
        expect(ctrl.bundle!.work.portraitBackdropPath, isNull);
      },
    );

    test('ArtworkDominantColor 正确吸色并适配深浅主题背景溶底，空载荷安全降级', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 48, 48),
        ui.Paint()..color = const ui.Color(0xFF3E6BE0),
      );
      final pic = recorder.endRecording();
      final img = await pic.toImage(48, 48);
      final bytes = (await img.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      img.dispose();
      pic.dispose();

      final darkDissolve = await ArtworkDominantColor.sampleBottomDissolveColor(
        bytes: bytes,
        cacheKey: 'test_palette_key',
        isDark: true,
        themeBackground: const ui.Color(0xFF0F1117),
      );
      final lightDissolve =
          await ArtworkDominantColor.sampleBottomDissolveColor(
            bytes: bytes,
            cacheKey: 'test_palette_key',
            isDark: false,
            themeBackground: const ui.Color(0xFFF5F6FA),
          );
      expect(darkDissolve, isNotNull);
      expect(lightDissolve, isNotNull);
      expect(darkDissolve!.computeLuminance(), lessThan(0.15));
      expect(lightDissolve!.computeLuminance(), greaterThan(0.65));

      final emptyFallback =
          await ArtworkDominantColor.sampleBottomDissolveColor(
            bytes: Uint8List(0),
            cacheKey: 'empty_key',
            isDark: true,
            themeBackground: const ui.Color(0xFF0F1117),
          );
      expect(emptyFallback, isNull);
    });

    test(
      'WorkArtworkOptionsService.mergePortraitBackdropOptions 无字竖版原画排在有字海报之前',
      () {
        const detail = TmdbWorkDetail(
          tmdbId: 501,
          mediaType: TmdbMediaType.tv,
          title: '测试番剧',
          candidatePosters: <TmdbArtworkImage>[
            TmdbArtworkImage(
              filePath: '/texted_zh.jpg',
              isoLanguage: 'zh',
              voteAverage: 9.0,
            ),
            TmdbArtworkImage(
              filePath: '/textless_portrait.jpg',
              isoLanguage: null,
              voteAverage: 7.5,
            ),
          ],
        );
        final merged = WorkArtworkOptionsService.mergePortraitBackdropOptions(
          tmdbDetail: detail,
          fanartPosters: const <FanartPosterCandidate>[
            FanartPosterCandidate(
              id: 'f1',
              url: 'https://assets.fanart.tv/fanart/tv/1/tvposter/clean.jpg',
              lang: '00',
              likes: 12,
            ),
          ],
        );
        expect(merged.length, greaterThanOrEqualTo(3));
        expect(merged.first.langTag, '无字');
        expect(merged.last.filePath, '/texted_zh.jpg');
      },
    );
  });
}
