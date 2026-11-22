import 'dart:convert';
import 'dart:io';

import 'package:konata/application/scraping/scrape_candidate_fetcher.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object data, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// 候选详情与季详情改为并发拉取后，必须保持逐条串行时的结果顺序与“遇瞬时网络异常即截断”语义。
void main() {
  late int inFlight;
  late int peakInFlight;

  ScrapeCandidateFetcher fetcherWith(
    Future<http.Response> Function(http.Request request) handler,
  ) {
    inFlight = 0;
    peakInFlight = 0;
    final client = MockClient((request) async {
      inFlight++;
      if (inFlight > peakInFlight) peakInFlight = inFlight;
      try {
        return await handler(request);
      } finally {
        inFlight--;
      }
    });
    final http_ = TmdbHttpClient(
      config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
      scheduler: PriorityHttpScheduler(maxRetries: 0),
      httpClient: client,
    );
    return ScrapeCandidateFetcher(TmdbService(httpClient: http_));
  }

  Map<String, Object?> tvDetail(int id) => {
    'id': id,
    'name': '作品 $id',
    'original_name': 'Work $id',
    'first_air_date': '2020-01-01',
  };

  test('按 ID 补拉详情：请求并发重叠，结果仍按传入顺序排列', () async {
    final fetcher = fetcherWith((request) async {
      final id = int.parse(request.url.pathSegments.last);
      // 第一条最慢返回，验证结果顺序不随完成先后改变。
      if (id == 1) await Future<void>.delayed(const Duration(milliseconds: 80));
      return _json(tvDetail(id));
    });

    final details = await fetcher.fetchDetailsByIds([
      (type: TmdbMediaType.tv, id: 1),
      (type: TmdbMediaType.tv, id: 2),
      (type: TmdbMediaType.tv, id: 3),
    ]);

    expect(details.map((d) => d.tmdbId), [1, 2, 3]);
    expect(peakInFlight, greaterThan(1));
  });

  test('按 ID 补拉详情：遇瞬时网络异常只上报一次，并丢弃其后的结果', () async {
    final fetcher = fetcherWith((request) async {
      final id = int.parse(request.url.pathSegments.last);
      if (id == 2) throw const SocketException('连接被重置');
      if (id == 3) return _json({'status_code': 34}, 404);
      return _json(tvDetail(id));
    });
    final errors = <Object>[];

    final details = await fetcher.fetchDetailsByIds([
      (type: TmdbMediaType.tv, id: 1),
      (type: TmdbMediaType.tv, id: 2),
      (type: TmdbMediaType.tv, id: 4),
    ], onNetworkError: errors.add);

    expect(details.map((d) => d.tmdbId), [1]);
    expect(errors, hasLength(1));
  });

  test('季详情包：多季并发拉取，分集按季顺序拼接，缺失季跳过', () async {
    final fetcher = fetcherWith((request) async {
      final season = int.parse(request.url.pathSegments.last);
      if (season == 2) return _json({'status_code': 34}, 404);
      if (season == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      return _json({
        'name': '第 $season 季',
        'episodes': [
          for (var e = 1; e <= 2; e++)
            {'episode_number': e, 'name': 'S$season E$e'},
        ],
      });
    });

    final bundle = await fetcher.fetchSeasonBundle(10, TmdbMediaType.tv, {
      1,
      2,
      3,
    });

    expect(bundle.seasonDetails.keys, [1, 3]);
    expect(bundle.episodes.map((e) => '${e.seasonNumber}:${e.episodeNumber}'), [
      '1:1',
      '1:2',
      '3:1',
      '3:2',
    ]);
    expect(peakInFlight, greaterThan(1));
  });
}
