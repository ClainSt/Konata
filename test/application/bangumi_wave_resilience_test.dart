import 'dart:convert';

import 'package:konata/application/scraping/scrape_candidate_fetcher.dart';
import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/infrastructure/network/bangumi_service.dart';
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

/// Bangumi 首波检索的容错：单条检索词失败不得连带丢弃其余检索词的结果，
/// 否则一次网络抖动就会让整部作品静默降级为仅 TMDB 匹配。
void main() {
  const folder = GroupedWorkFolder(
    folderRelativePath: '动画/CLANNAD (2007)',
    folderName: 'CLANNAD (2007)',
    cleanTitle: 'CLANNAD',
    year: 2007,
    mainEpisodeNumbers: [1, 2],
    titleHints: ['CLANNAD', 'クラナド'],
    variants: [
      MediaVariant(
        id: 'v1',
        workId: 'w',
        sourceId: 's',
        relativePath: '动画/CLANNAD (2007)/CLANNAD - 01.mkv',
        fileName: 'CLANNAD - 01.mkv',
        fileSize: 1,
      ),
      MediaVariant(
        id: 'v2',
        workId: 'w',
        sourceId: 's',
        relativePath: '动画/CLANNAD (2007)/CLANNAD - 02.mkv',
        fileName: 'CLANNAD - 02.mkv',
        fileSize: 1,
      ),
    ],
  );

  ScrapeCandidateFetcher fetcherWith(MockClient client) {
    final http_ = TmdbHttpClient(
      config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
      scheduler: PriorityHttpScheduler(maxRetries: 0),
      httpClient: client,
    );
    return ScrapeCandidateFetcher(
      TmdbService(httpClient: http_),
      bangumiService: BangumiService(httpClient: http_),
    );
  }

  test('单条检索词失败时保留其余检索词命中的候选', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v0/search/subjects') {
        final keyword =
            (jsonDecode(request.body) as Map<String, dynamic>)['keyword'];
        if (keyword == 'CLANNAD') return _json({'error': 'boom'}, 503);
        return _json({
          'data': [
            {
              'id': 51,
              'name': 'CLANNAD -クラナド-',
              'name_cn': 'CLANNAD',
              'date': '2007-10-04',
              'eps': 23,
              'type': 2,
            },
          ],
        });
      }
      return _json({}, 404);
    });

    final candidates = await fetcherWith(client).fetchBangumiCandidates(folder);
    expect(candidates.map((c) => c.id), contains(51));
  });

  test('首波检索全部失败时短暂等待后重试一次', () async {
    var calls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v0/search/subjects') {
        calls++;
        // 首波（每个检索词一次）全部 503，重试波次恢复正常。
        if (calls <= 2) return _json({'error': 'boom'}, 503);
        return _json({
          'data': [
            {
              'id': 51,
              'name': 'CLANNAD -クラナド-',
              'name_cn': 'CLANNAD',
              'date': '2007-10-04',
              'eps': 23,
              'type': 2,
            },
          ],
        });
      }
      return _json({}, 404);
    });

    final candidates = await fetcherWith(client).fetchBangumiCandidates(folder);
    expect(candidates.map((c) => c.id), contains(51));
  });
}
