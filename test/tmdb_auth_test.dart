import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/tmdb_auth.dart';

void main() {
  test('v4 token uses Bearer authorization only', () {
    const creds = TmdbCredentials(mode: 'token', value: 'test-token');
    final url = creds.uri('/search/tv', {'query': '86', 'language': 'zh-CN'});
    expect(url.host, 'api.themoviedb.org');
    expect(url.queryParameters['api_key'], isNull);
    expect(creds.headers['Authorization'], 'Bearer test-token');
  });
  test('v3 API Key uses query parameter, without Bearer', () {
    const creds = TmdbCredentials(mode: 'apiKey', value: 'fake-api-key');
    final url = creds.uri('/tv/100565', const {});
    expect(url.queryParameters['api_key'], 'fake-api-key');
    expect(creds.headers.containsKey('Authorization'), false);
  });
  test('missing keys and unsafe endpoint are rejected', () {
    const empty = TmdbCredentials(mode: 'apiKey', value: '');
    expect(empty.isConfigured, false);
    expect(() => empty.uri('/configuration', const {}), throwsStateError);
    const valid = TmdbCredentials(mode: 'token', value: 'demo');
    expect(
      () => valid.uri('//another-host/path', const {}),
      throwsArgumentError,
    );
  });
}
