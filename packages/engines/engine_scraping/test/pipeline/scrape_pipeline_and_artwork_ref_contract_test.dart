import 'dart:convert';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/test_helpers.dart';

void main() {
  group('ArtworkRef 双向契约与三库持久化往返测试', () {
    test('TMDB / Bangumi / Fanart 与本机自定义封面均无损落盘 ArtworkRef 与锁定态及负缓存', () async {
      final testDb = openTestScrapeDatabase();
      final repo = testDb.repository;

      final until = DateTime.utc(2026, 12, 1, 8, 30);
      const work = Work(
        id: 'w_art_contract',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        bangumiId: 400602,
        tvdbId: 424536,
        matchedSeason: 1,
        title: '葬送的芙莉莲',
        posterPath: '/frieren_poster.jpg',
        posterFallback: 'https://lain.bgm.tv/pic/cover/l/frieren.jpg',
        bangumiPosterPath: 'https://lain.bgm.tv/pic/cover/l/frieren.jpg',
        backdropPath: 'https://assets.fanart.tv/fanart/tv/424536/showbackground/frieren.jpg',
        logoPath: 'cover://local_custom/custom_logo.png',
        posterLocked: true,
        backdropLocked: false,
        logoLocked: true,
        logoNegativeMask: ClearLogoNegativeMask.tmdb | ClearLogoNegativeMask.fanart,
        scrapeStatus: ScrapeStatus.matched,
      );
      final withNeg = work.copyWith(logoNegativeUntil: until);

      expect(withNeg.posterRef, isA<RemoteArtworkRef>());
      expect((withNeg.posterRef! as RemoteArtworkRef).source, ArtworkSource.tmdb);
      expect(withNeg.posterRef!.locked, isTrue);

      expect(withNeg.backdropRef, isA<RemoteArtworkRef>());
      expect((withNeg.backdropRef! as RemoteArtworkRef).source, ArtworkSource.fanart);
      expect(withNeg.backdropRef!.locked, isFalse);

      expect(withNeg.logoRef, isA<LocalCustomArtworkRef>());
      expect((withNeg.logoRef! as LocalCustomArtworkRef).localPath, 'cover://local_custom/custom_logo.png');
      expect(withNeg.logoRef!.locked, isTrue);

      await repo.upsertWork(withNeg);

      final rawRecord = testDb.bundle.library.works.findById(
        WorkId.trusted(withNeg.id),
      );
      expect(rawRecord, isNotNull);
      expect(rawRecord!.posterRef, isA<RemoteArtworkRef>());
      expect((rawRecord.posterRef! as RemoteArtworkRef).source, ArtworkSource.tmdb);
      expect(rawRecord.posterRef!.locked, isTrue);
      expect(rawRecord.backdropRef, isA<RemoteArtworkRef>());
      expect((rawRecord.backdropRef! as RemoteArtworkRef).source, ArtworkSource.fanart);
      expect(rawRecord.logoRef, isA<LocalCustomArtworkRef>());
      expect(rawRecord.logoRef!.locked, isTrue);

      final loaded = await repo.findWorkById(withNeg.id);
      expect(loaded, isNotNull);
      expect(loaded!.posterPath, '/frieren_poster.jpg');
      expect(loaded.posterLocked, isTrue);
      expect(loaded.backdropPath, contains('fanart.tv'));
      expect(loaded.backdropLocked, isFalse);
      expect(loaded.logoPath, 'cover://local_custom/custom_logo.png');
      expect(loaded.logoLocked, isTrue);
      expect(loaded.logoNegativeUntil?.toUtc(), until);
      expect(
        loaded.logoNegativeMask,
        ClearLogoNegativeMask.tmdb | ClearLogoNegativeMask.fanart,
      );
    });
  });

  group('有序 ScrapePipeline 全链路编排、锁定保护与诊断日志测试', () {
    test('完整执行扫描->匹配->ArtworkRef落盘->DiagnosticLogPort事件记录->manual_lock防覆写与瞬态隔离', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_pipeline_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final workDir = Directory(
        p.join(tempDir.path, 'Sousou no Frieren (2023)'),
      )..createSync(recursive: true);
      File(
        p.join(workDir.path, '[LoliHouse] Sousou no Frieren - 01 [1080p].mkv'),
      ).writeAsBytesSync(const [1, 2, 3]);
      File(
        p.join(workDir.path, '[LoliHouse] Sousou no Frieren - 02 [1080p].mkv'),
      ).writeAsBytesSync(const [1, 2, 3]);

      final testDb = openTestScrapeDatabase();
      final repo = testDb.repository;
      const source = MediaSource(
        id: 'src_pipe_local',
        kind: MediaSourceKind.local,
        label: '本地测试源',
        location: '',
      );
      final actualSource = MediaSource(
        id: source.id,
        kind: source.kind,
        label: source.label,
        location: tempDir.path,
      );
      await repo.upsertMediaSource(actualSource);

      var failTmdbTransient = false;
      final mockHttp = MockClient((request) async {
        if (failTmdbTransient) {
          throw const SocketException('模拟上游临时断网');
        }
        final path = request.url.path;
        if (path.endsWith('/search/movie')) {
          return http.Response(
            jsonEncode({'results': <Map<String, Object?>>[]}),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path.endsWith('/search/tv')) {
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'id': 209867,
                  'name': '葬送的芙莉莲',
                  'original_name': '葬送のフリーレン',
                  'first_air_date': '2023-09-29',
                  'overview': '勇者一行打倒魔王之后的故事。',
                  'poster_path': '/frieren_poster.jpg',
                  'backdrop_path': '/frieren_bg.jpg',
                  'vote_average': 8.9,
                  'genre_ids': [16],
                  'origin_country': ['JP'],
                },
              ],
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path == '/3/tv/209867') {
          return http.Response(
            jsonEncode({
              'id': 209867,
              'name': '葬送的芙莉莲',
              'original_name': '葬送のフリーレン',
              'first_air_date': '2023-09-29',
              'overview': '勇者一行打倒魔王之后的故事。',
              'poster_path': '/frieren_poster.jpg',
              'backdrop_path': '/frieren_bg.jpg',
              'vote_average': 8.9,
              'genres': [
                {'id': 16, 'name': '动画'},
              ],
              'origin_country': ['JP'],
              'number_of_episodes': 28,
              'alternative_titles': {
                'results': [
                  {'title': 'Sousou no Frieren', 'iso_3166_1': 'JP'},
                  {'title': 'Frieren: Beyond Journey\'s End', 'iso_3166_1': 'US'},
                ],
              },
              'external_ids': {'tvdb_id': 424536},
              'seasons': [
                {
                  'season_number': 1,
                  'name': '第 1 季',
                  'episode_count': 28,
                  'air_date': '2023-09-29',
                },
              ],
              'images': {
                'backdrops': [
                  {
                    'file_path': '/frieren_bg.jpg',
                    'iso_639_1': null,
                    'width': 1920,
                    'height': 1080,
                    'vote_average': 8.0,
                    'vote_count': 10,
                  },
                ],
                'posters': [
                  {
                    'file_path': '/frieren_poster.jpg',
                    'iso_639_1': 'zh',
                    'width': 1000,
                    'height': 1500,
                    'vote_average': 8.0,
                    'vote_count': 10,
                  },
                ],
                'logos': [
                  {
                    'file_path': '/frieren_logo.png',
                    'iso_639_1': 'zh',
                    'width': 800,
                    'height': 310,
                    'vote_average': 8.0,
                    'vote_count': 10,
                  },
                ],
              },
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path == '/3/tv/209867/season/1') {
          return http.Response(
            jsonEncode({
              'season_number': 1,
              'name': '第 1 季',
              'episodes': [
                {'episode_number': 1, 'name': '冒险的终点'},
                {'episode_number': 2, 'name': '那不一定需要魔法'},
              ],
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host.contains('bgm.tv')) {
          if (path.endsWith('/search/subjects')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 400602,
                    'type': 2,
                    'name': '葬送のフリーレン',
                    'name_cn': '葬送的芙莉莲',
                    'date': '2023-09-29',
                    'eps': 28,
                    'rating': {'score': 8.9},
                    'infobox': [
                      {
                        'key': '别名',
                        'value': [
                          {'v': 'Sousou no Frieren'},
                        ],
                      },
                    ],
                    'images': {
                      'large': 'https://lain.bgm.tv/pic/cover/l/frieren.jpg',
                    },
                  },
                ],
              }),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({'data': <Map<String, Object?>>[]}),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final httpClient = TmdbHttpClient(
        config: const KonataNetworkConfig(credential: 'v3_test'),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: mockHttp,
        maxTransientTransportRetries: 0,
      );
      final diagStore = DiagnosticLogStore();
      final eventBus = InMemoryDomainEventBus();
      final events = <DomainEvent>[];
      final sub = eventBus.stream.listen(events.add);
      addTearDown(sub.cancel);

      final pipeline = ScrapePipeline(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        bangumiService: BangumiService(httpClient: httpClient),
        gatewayBuilder: (s) async => TestLocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
        photosStorage: StorageRootWorkArtworkStorage(
          storageRoot: PortableStorageRootService(overrideRootPath: tempDir.path),
        ),
        diagnosticLog: diagStore,
        eventBus: eventBus,
      );

      final progress = await pipeline.scanAndScrapeSource(actualSource);
      expect(progress.phase, ScrapePhase.completed);
      expect(progress.matchedWorks, 1);

      final works = await repo.getAllWorks();
      expect(works.length, 1);
      final persisted = works.single;
      expect(persisted.scrapeStatus, ScrapeStatus.matched);
      expect(persisted.tmdbId, 209867);
      expect((persisted.posterRef! as RemoteArtworkRef).source, ArtworkSource.tmdb);
      expect(persisted.logoPath, '/frieren_logo.png');

      // 验证诊断日志与事件总线均记录关键落库事件
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<LibraryWorkChangedEvent>(), isNotEmpty);
      final codes = diagStore.snapshotEvents().map((e) => e.code).toList();
      expect(codes, contains('scraper.scan.start'));
      expect(codes, contains('scraper.work.persisted'));

      // 为该作品启用人工锁定并新增第 3 集，重扫时绝不能覆写既有标题/ID 且需记入锁定保护日志
      await repo.upsertWork(
        persisted.copyWith(
          title: '用户人工锁定的标题',
          isManualLocked: true,
          posterLocked: true,
        ),
      );
      File(
        p.join(workDir.path, '[LoliHouse] Sousou no Frieren - 03 [1080p].mkv'),
      ).writeAsBytesSync(const [1, 2, 3]);

      await pipeline.scanAndScrapeSource(actualSource, forceFullRescan: true);
      final afterLock = await repo.findWorkById(persisted.id);
      expect(afterLock?.title, '用户人工锁定的标题');
      expect(afterLock?.isManualLocked, isTrue);
      expect(afterLock?.posterLocked, isTrue);
      expect((await repo.getEpisodesByWork(persisted.id)).length, 3);
      expect(
        diagStore.snapshotEvents().map((e) => e.code),
        contains('scraper.work.manual_lock_preserved'),
      );

      // 模拟解除锁定且 TMDB 临时断网（新增第 4 集触发重扫）：瞬态故障必须被隔离且不降级既有已匹配状态
      await repo.upsertWork(afterLock!.copyWith(isManualLocked: false));
      File(
        p.join(workDir.path, '[LoliHouse] Sousou no Frieren - 04 [1080p].mkv'),
      ).writeAsBytesSync(const [1, 2, 3]);
      failTmdbTransient = true;

      await pipeline.scanAndScrapeSource(actualSource, forceFullRescan: true);
      final afterTransient = await repo.findWorkById(persisted.id);
      expect(afterTransient?.scrapeStatus, ScrapeStatus.matched);
      expect(afterTransient?.tmdbId, 209867);
    });

    test('BangumiTmdbMapUpdater 可直接注入 ScopedPrefsStore 与 PortableStorageRootService 持久化状态', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_upd_prefs_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final testDb = openTestScrapeDatabase();
      final prefsStore = ScopedPrefsStore(testDb.bundle.userState);
      final storageRoot = PortableStorageRootService(overrideRootPath: tempDir.path);
      final bundled = BangumiTmdbIndex.encode(const [
        BangumiTmdbRecord(
          bangumiId: 400602,
          type: TmdbMediaType.tv,
          tmdbId: 209867,
          season: 1,
          tvdbId: 424536,
        ),
      ], snapshotDateYyyymmdd: 20261120);

      final updater = BangumiTmdbMapUpdater(
        storageRoot: storageRoot,
        prefsStore: prefsStore,
        bundledAssetLoader: (_) async => bundled,
      );
      final snap = await updater.loadActiveSnapshot();
      expect(snap.source, BangumiTmdbMapSource.bundledAsset);
      expect(snap.index.lookup(400602).single.tvdbId, 424536);
    });
  });
}
