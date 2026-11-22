import 'package:http/http.dart' as http;

import '../network/priority_http_scheduler.dart';
import '../network/tmdb_http_client.dart';
import 'lyric_http_transport.dart';

/// 复用全局 [TmdbHttpClient]（代理、DoH、Keep-Alive 连接池与前台调度通道）的歌词传输实现。
class AppNetworkLyricTransport implements LyricHttpTransport {
  /// 创建传输实例。
  AppNetworkLyricTransport(this._client);

  final TmdbHttpClient _client;

  @override
  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
    required Duration timeout,
  }) {
    return _client
        .get(uri, headers: headers, priority: RequestPriority.interactive)
        .timeout(timeout);
  }

  @override
  Future<http.Response> post(
    Uri uri, {
    Map<String, String> headers = const {},
    Object? body,
    required Duration timeout,
  }) {
    return _client
        .post(
          uri,
          headers: headers,
          body: body,
          priority: RequestPriority.interactive,
        )
        .timeout(timeout);
  }
}
