import 'dart:convert';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/test_helpers.dart';

http.Response _jsonRes(Object data, [int statusCode = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  statusCode,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('显式 ID 语法、分辨率与年份区分以及 WorkSeason 严苛年份校验保持完整无损', () {
    for (final marker in [
      '{tmdb-65844}',
      '{tmdbtv=65844}',
      '{tmdbid:65844}',
      '[tmdb=65844]',
      '{[tmdbid=65844;type=tv]}',
    ]) {
      expect(BdripParser.parseFolderName('Show (2017) $marker').tmdbId, 65844);
    }
    expect(
      BdripParser.parseFolderName('{tmdbmovie-123}').tmdbMediaType,
      TmdbMediaType.movie,
    );
    expect(
      BdripParser.parseFolderName('Show (2017) {tmdb-65844}').year,
      2017,
    );
    expect(BdripParser.parseFolderName('Show (1920x1080)').year, isNull);
    expect(
      WorkSeason.resolve(
        {'title': 'Show S1+S2 (2018)'},
        const [
          {'season_number': 1, 'air_date': '2018-01-01'},
          {'season_number': 2, 'air_date': '2019-01-01'},
        ],
      ),
      isNull,
    );
  });

  test('同一 TMDB ID 下三季独立目录保留各自季标题、季封面与年份且不丢失播放进度', () async {
    final tempRoot = await Directory.systemTemp.createTemp('konata_season_id_');
    final testDb = openTestScrapeDatabase();
      final repo = testDb.repository;
    addTearDown(() async {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    const base = '为美好的世界献上祝福！';
    const years = [2016, 2017, 2024];
    const suffixes = ['', ' 第二季', ' 第三季'];
    for (var i = 0; i < 3; i++) {
      final dir = Directory(
        p.join(tempRoot.path, '$base${suffixes[i]} (${years[i]}) {tmdb-65844}'),
      );
      await dir.create(recursive: true);
      await File(p.join(dir.path, '[Group] Show [01].mkv')).writeAsBytes([1]);
    }

    final seasonCalls = <String>[];
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/tv/65844')) {
        return _jsonRes({
          'id': 65844,
          'name': base,
          'poster_path': '/latest-s3.jpg',
          'first_air_date': '2016-01-01',
          'seasons': [
            for (var i = 0; i < 3; i++)
              {
                'season_number': i + 1,
                'name': '$base 第${i + 1}季',
                'episode_count': 10,
                'air_date': '${years[i]}-01-01',
                'poster_path': '/s${i + 1}.jpg',
              },
          ],
        });
      }
      if (path.contains('/tv/65844/season/')) {
        seasonCalls.add(path);
        final number = int.parse(path.split('/').last);
        return _jsonRes({
          'season_number': number,
          'name': '$base 第$number季',
          'air_date': '${years[number - 1]}-01-01',
          'poster_path': '/s$number.jpg',
          'episodes': [
            {'episode_number': 1, 'name': '第 $number 季第 1 话'},
          ],
        });
      }
      return http.Response('{}', 404);
    });

    final source = MediaSource(
      id: 'src_konosuba',
      kind: MediaSourceKind.local,
      label: '多季测试盘',
      location: tempRoot.path,
    );
    await repo.upsertMediaSource(source);

    final orchestrator = ScrapeOrchestrator(
      repository: repo,
      tmdbService: TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_test'),
          scheduler: PriorityHttpScheduler(),
          httpClient: client,
        ),
      ),
      gatewayBuilder: (s) async => TestLocalSourceGateway(rootPath: s.location),
      computeWorker: const ScrapeComputeWorker(useIsolate: false),
    );

    final progress1 = await orchestrator.scanAndScrapeSource(source);
    expect(progress1.totalWorks, 3);
    expect(progress1.matchedWorks, 3);

    final works = await repo.getAllWorks();
    expect(works, hasLength(3));
    for (var i = 0; i < 3; i++) {
      final sNum = i + 1;
      final work = works.firstWhere((w) => w.matchedSeason == sNum);
      expect(work.year, years[i]);
      expect(work.posterPath, '/s$sNum.jpg');
      expect(work.posterFallback, '/latest-s3.jpg');
      expect(work.title, sNum == 1 ? base : '$base 第$sNum季');

      final eps = await repo.getEpisodesByWork(work.id);
      expect(eps.single.seasonNumber, sNum);
      expect(eps.single.episodeNumber, 1);
      final variants = await repo.getVariantsByWork(work.id);
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'rec-$sNum',
          workId: work.id,
          episodeId: eps.single.id,
          variantId: variants.single.id,
          episodeTitle: eps.single.title ?? '',
          seasonNumber: sNum,
          episodeNumber: 1,
          sourceType: MediaSourceKind.local,
          positionSeconds: 42,
          durationSeconds: 1400,
          playedAt: DateTime(2026, 1, 1),
        ),
      );
    }

    expect(
      seasonCalls,
      containsAll([
        '/3/tv/65844/season/1',
        '/3/tv/65844/season/2',
        '/3/tv/65844/season/3',
      ]),
    );

    // 二次重扫后季卡片数量与历史播放进度必须完全保留
    await orchestrator.scanAndScrapeSource(source);
    final worksAfter = await repo.getAllWorks();
    expect(worksAfter, hasLength(3));
    final history = await repo.getPlaybackHistory();
    expect(history, hasLength(3));
    expect(history.every((h) => h.positionSeconds == 42), isTrue);
  });

  test('中文季号目录（第二季 / 第三季）在 BdripParser 中精准识别季号', () {
    expect(BdripParser.parseFolderName('为美好的世界献上祝福！ 第二季 (2017)').season, 2);
    expect(BdripParser.parseFolderName('为美好的世界献上祝福！ 第三季 (2024)').season, 3);
  });
}
