import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:konata/application/scraping/scrape_orchestrator.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/bangumi_service.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:konata/infrastructure/sources/source_gateway_factory.dart';

http.Response _jsonResp(Object body) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('第四轮阶段 6 · TV 透明标题优先级与自动补绑回填回归测试', () {
    test('1. TmdbService 顶层 /tv/{id} 请求包含英文徽标，严格遵循 简中->繁中->日文->英文->无语言 优先级并选无字背景', () async {
      List<Map<String, Object?>> activeLogos = [
        {
          'iso_639_1': null,
          'iso_3166_1': null,
          'file_path': '/neutral_logo.png',
          'width': 1200,
          'height': 320,
          'vote_average': 9.8,
          'vote_count': 20,
        },
        {
          'iso_639_1': 'en',
          'iso_3166_1': 'US',
          'file_path': '/en_logo.png',
          'width': 1600,
          'height': 340,
          'vote_average': 9.2,
          'vote_count': 15,
        },
        {
          'iso_639_1': 'ja',
          'iso_3166_1': 'JP',
          'file_path': '/ja_logo.png',
          'width': 1400,
          'height': 360,
          'vote_average': 8.5,
          'vote_count': 10,
        },
        {
          'iso_639_1': 'zh',
          'iso_3166_1': 'TW',
          'file_path': '/zh_tw_logo.png',
          'width': 1300,
          'height': 350,
          'vote_average': 9.0,
          'vote_count': 12,
        },
        {
          'iso_639_1': 'zh',
          'iso_3166_1': 'CN',
          'file_path': '/zh_cn_logo.png',
          'width': 1300,
          'height': 350,
          'vote_average': 6.0,
          'vote_count': 3,
        },
      ];

      final client = MockClient((request) async {
        expect(request.url.path, endsWith('/tv/43167'));
        expect(
          request.url.queryParameters['include_image_language'],
          'zh,ja,en,null',
        );
        return _jsonResp({
          'id': 43167,
          'name': '加速世界',
          'original_name': 'アクセル・ワールド',
          'first_air_date': '2012-04-07',
          'backdrop_path': '/default_backdrop.jpg',
          'images': {
            'logos': [
              // 已知误传的剧场版徽标必须继续被过滤
              {
                'iso_639_1': 'zh',
                'iso_3166_1': 'CN',
                'file_path': '/wsQCRIHeVQJlO0MgU2oA3z6hgQd.png',
                'vote_average': 10.0,
                'vote_count': 99,
              },
              ...activeLogos,
            ],
            'backdrops': [
              {
                'iso_639_1': 'ja',
                'file_path': '/baked_text_ja_backdrop.jpg',
                'width': 1920,
                'height': 1080,
                'vote_average': 9.5,
              },
              {
                'iso_639_1': 'zh',
                'file_path': '/baked_text_zh_backdrop.jpg',
                'width': 1920,
                'height': 1080,
                'vote_average': 9.2,
              },
              {
                'iso_639_1': null,
                'file_path': '/clean_textless_backdrop.jpg',
                'width': 1920,
                'height': 1080,
                'vote_average': 7.4,
              },
            ],
          },
        });
      });

      final service = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_key'),
          scheduler: PriorityHttpScheduler(),
          httpClient: client,
        ),
      );

      // 5 档逐层剔除验证：简中 -> 繁中 -> 日文 -> 英文 -> 无语言
      var detail = await service.getWorkDetail(43167, TmdbMediaType.tv);
      expect(detail?.logoPath, '/zh_cn_logo.png');
      expect(detail?.backdropPath, '/clean_textless_backdrop.jpg');

      activeLogos = activeLogos
          .where((m) => m['file_path'] != '/zh_cn_logo.png')
          .toList();
      detail = await service.getWorkDetail(43167, TmdbMediaType.tv);
      expect(detail?.logoPath, '/zh_tw_logo.png');

      activeLogos = activeLogos
          .where((m) => m['file_path'] != '/zh_tw_logo.png')
          .toList();
      detail = await service.getWorkDetail(43167, TmdbMediaType.tv);
      expect(detail?.logoPath, '/ja_logo.png');

      activeLogos = activeLogos
          .where((m) => m['file_path'] != '/ja_logo.png')
          .toList();
      detail = await service.getWorkDetail(43167, TmdbMediaType.tv);
      expect(detail?.logoPath, '/en_logo.png');

      activeLogos = activeLogos
          .where((m) => m['file_path'] != '/en_logo.png')
          .toList();
      detail = await service.getWorkDetail(43167, TmdbMediaType.tv);
      expect(detail?.logoPath, '/neutral_logo.png');
    });

    test('2. 超宽横版与紧凑型近方形透明徽标均不被纵横比误杀', () async {
      var width = 2000;
      var height = 320;
      final client = MockClient((_) async {
        return _jsonResp({
          'id': 100565,
          'name': '86-不存在的战区-',
          'images': {
            'logos': [
              {
                'iso_639_1': 'ja',
                'file_path': '/logo_${width}x$height.png',
                'width': width,
                'height': height,
                'vote_average': 8.0,
              },
            ],
          },
        });
      });
      final service = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_key'),
          scheduler: PriorityHttpScheduler(),
          httpClient: client,
        ),
      );

      final wideDetail = await service.getWorkDetail(100565, TmdbMediaType.tv);
      expect(wideDetail?.logoPath, '/logo_2000x320.png');

      width = 520;
      height = 580;
      final compactDetail = await service.getWorkDetail(
        100565,
        TmdbMediaType.tv,
      );
      expect(compactDetail?.logoPath, '/logo_520x580.png');
    });

    test('3. 已绑定 TMDB 的《加速世界》TV 条目与仅入库 Bangumi 的条目均能自动补绑回填 Logo 和无字横版头图', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_dav',
          kind: MediaSourceKind.webdav,
          label: 'dav',
          location: 'http://192.168.1.178:29798/dav',
        ),
      );

      // 场景 A：真机复现——已绑定 tmdbId=43167 但缺 logoPath，且存有旧版带字头图
      await repo.upsertWork(
        const Work(
          id: 'w_accel_existing_tmdb',
          tmdbId: 43167,
          tmdbMediaType: TmdbMediaType.tv,
          bangumiId: 23685,
          matchedSeason: 1,
          title: '加速世界',
          originalTitle: 'アクセル・ワールド',
          year: 2012,
          backdropPath: '/nr72nupPtZuA7HGPQUU2DYSOHoy.jpg',
          logoPath: null,
          isManualLocked: true,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );

      // 场景 B：此前扫描时因网络波动仅入库了 Bangumi 数据（缺 tmdbId、logoPath、backdropPath）
      await repo.upsertWork(
        const Work(
          id: 'w_accel_bgm_only',
          tmdbId: null,
          tmdbMediaType: null,
          bangumiId: 23685,
          title: '加速世界',
          originalTitle: 'アクセル・ワールド',
          year: 2012,
          posterPath: 'https://lain.bangumi.lat/pic/cover/l/d9/d8/23685_Y1wYG.jpg',
          bangumiPosterPath:
              'https://lain.bangumi.lat/pic/cover/l/d9/d8/23685_Y1wYG.jpg',
          bangumiScore: 6.7,
          scrapeStatus: ScrapeStatus.needsReview,
        ),
      );
      for (var ep = 1; ep <= 24; ep++) {
        final numStr = ep.toString().padLeft(2, '0');
        await repo.upsertEpisode(
          Episode(
            id: 'ep_bgm_$ep',
            workId: 'w_accel_bgm_only',
            seasonNumber: 1,
            episodeNumber: ep,
            category: EpisodeCategory.main,
            title: '第 $ep 话',
          ),
        );
        await repo.upsertMediaVariant(
          MediaVariant(
            id: 'var_bgm_$ep',
            workId: 'w_accel_bgm_only',
            episodeId: 'ep_bgm_$ep',
            sourceId: 'src_dav',
            relativePath: 'Anime/Accel World/[VCB-Studio] Accel World [$numStr][Ma10p_1080p][x265_flac].mkv',
            fileName: '[VCB-Studio] Accel World [$numStr][Ma10p_1080p][x265_flac].mkv',
            fileSize: 600 * 1024 * 1024,
          ),
        );
      }

      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/subjects/23685') || path.contains('/v0/subjects/23685')) {
          return _jsonResp({
            'id': 23685,
            'type': 2,
            'name': 'アクセル・ワールド',
            'name_cn': '加速世界',
            'date': '2012-04-06',
            'eps': 24,
            'total_episodes': 24,
            'rating': {'score': 6.7},
            'images': {
              'large': 'https://lain.bangumi.lat/pic/cover/l/d9/d8/23685_Y1wYG.jpg',
            },
            'infobox': [
              {'key': '别名', 'value': 'Accel World'},
            ],
          });
        }
        if (path.contains('/search/subjects')) {
          return _jsonResp({
            'data': [
              {
                'id': 23685,
                'type': 2,
                'name': 'アクセル・ワールド',
                'name_cn': '加速世界',
                'date': '2012-04-06',
                'eps': 24,
                'rating': {'score': 6.7},
                'images': {
                  'large':
                      'https://lain.bangumi.lat/pic/cover/l/d9/d8/23685_Y1wYG.jpg',
                },
              },
            ],
          });
        }
        if (path.endsWith('/search/tv')) {
          return _jsonResp({
            'results': [
              {
                'id': 43167,
                'name': '加速世界',
                'original_name': 'アクセル・ワールド',
                'first_air_date': '2012-04-07',
                'genre_ids': [16, 10759],
                'poster_path': '/uM3dvx55S1lMqTgYrCpWtrWyOQ3.jpg',
                'backdrop_path': '/clean_accel_tv_backdrop.jpg',
              },
            ],
          });
        }
        if (path.endsWith('/search/movie')) {
          return _jsonResp({'results': []});
        }
        if (path.endsWith('/tv/43167')) {
          return _jsonResp({
            'id': 43167,
            'name': '加速世界',
            'original_name': 'アクセル・ワールド',
            'first_air_date': '2012-04-07',
            'vote_average': 7.4,
            'poster_path': '/uM3dvx55S1lMqTgYrCpWtrWyOQ3.jpg',
            'backdrop_path': '/clean_accel_tv_backdrop.jpg',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'seasons': [
              {
                'season_number': 1,
                'name': '第 1 季',
                'episode_count': 24,
                'air_date': '2012-04-07',
                'poster_path': '/uM3dvx55S1lMqTgYrCpWtrWyOQ3.jpg',
              },
            ],
            'images': {
              'logos': [
                {
                  'iso_639_1': 'zh',
                  'iso_3166_1': 'CN',
                  'file_path': '/wsQCRIHeVQJlO0MgU2oA3z6hgQd.png',
                  'vote_average': 8.0,
                },
                {
                  'iso_639_1': 'en',
                  'iso_3166_1': 'US',
                  'file_path': '/accel_world_tv_en_logo.png',
                  'width': 1520,
                  'height': 310,
                  'vote_average': 7.8,
                },
              ],
              'backdrops': [
                {
                  'iso_639_1': 'ja',
                  'file_path': '/nr72nupPtZuA7HGPQUU2DYSOHoy.jpg',
                  'width': 1920,
                  'height': 1080,
                  'vote_average': 9.0,
                },
                {
                  'iso_639_1': null,
                  'file_path': '/clean_accel_tv_backdrop.jpg',
                  'width': 1280,
                  'height': 720,
                  'vote_average': 7.5,
                },
              ],
            },
          });
        }
        if (path.endsWith('/tv/43167/season/1')) {
          return _jsonResp({
            'season_number': 1,
            'name': '第 1 季',
            'air_date': '2012-04-07',
            'poster_path': '/uM3dvx55S1lMqTgYrCpWtrWyOQ3.jpg',
            'episodes': [
              for (var i = 1; i <= 24; i++)
                {
                  'season_number': 1,
                  'episode_number': i,
                  'name': '第 $i 话',
                  'air_date': '2012-04-07',
                },
            ],
          });
        }
        return _jsonResp({});
      });

      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'v3_key'),
        scheduler: PriorityHttpScheduler(),
        httpClient: client,
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        bangumiService: BangumiService(httpClient: httpClient),
        gatewayBuilder: const MediaSourceGatewayFactory().create,
      );

      final updatedA = await orchestrator.autoBindOrBackfillWorkTmdb(
        'w_accel_existing_tmdb',
      );
      expect(updatedA, isNotNull);
      expect(updatedA!.logoPath, '/accel_world_tv_en_logo.png');
      expect(updatedA.backdropPath, '/clean_accel_tv_backdrop.jpg');

      final updatedB = await orchestrator.autoBindOrBackfillWorkTmdb(
        'w_accel_bgm_only',
      );
      expect(updatedB, isNotNull);
      expect(updatedB!.tmdbId, 43167);
      expect(updatedB.tmdbMediaType, TmdbMediaType.tv);
      expect(updatedB.logoPath, '/accel_world_tv_en_logo.png');
      expect(updatedB.backdropPath, '/clean_accel_tv_backdrop.jpg');
      expect(updatedB.scrapeStatus, ScrapeStatus.matched);
    });
  });
}
