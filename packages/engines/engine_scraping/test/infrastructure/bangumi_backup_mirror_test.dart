import 'dart:convert';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _json(Object data) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// Bangumi 备用镜像迁址（旧地址对全部请求返回 301）时不得让整批检索静默落空。
void main() {
  

  test('冷却期内备用镜像返回重定向时解除冷却并改回官方地址', () async {
    final now = DateTime(2026, 11, 20, 12);
    final cooldown = DomainCooldownRegistry()..markBlocked('api.bgm.tv', now);
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      if (request.url.host != 'api.bgm.tv') {
        return http.Response('', 301, headers: {'location': 'https://x/'});
      }
      return _json({
        'data': [
          {'id': 51, 'name': 'CLANNAD', 'name_cn': 'CLANNAD', 'type': 2},
        ],
      });
    });
    final service = BangumiService(
      httpClient: TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: client,
        cooldownRegistry: cooldown,
        nowProvider: () => now,
      ),
    );

    final results = await service.searchSubjects('CLANNAD');
    expect(results.map((r) => r.id), [51]);
    expect(hosts.first, 'api.bgm.lat');
    expect(hosts.last, 'api.bgm.tv');
    expect(cooldown.isCoolingDown('api.bgm.tv', now), isFalse);
  });

  test('Bangumi 检索收到重定向时按失败上抛而不是当作无结果', () async {
    final client = MockClient(
      (request) async =>
          http.Response('', 301, headers: {'location': 'https://x/'}),
    );
    final service = BangumiService(
      httpClient: TmdbHttpClient(
        config: const TmdbNetworkConfig(
          credential: 'dummy_v3_key',
          bangumiBackupApiBase: '',
        ),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
        httpClient: client,
      ),
    );
    await expectLater(service.searchSubjects('CLANNAD'), throwsStateError);
  });

}
