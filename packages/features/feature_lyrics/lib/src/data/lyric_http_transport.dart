import 'package:http/http.dart' as http;
import 'package:konata_contracts/konata_contracts.dart';

/// 在线歌词检索集中配置（端点、镜像、超时、竞速预算与缓存有效期）。
abstract final class LyricLookupConfig {
  /// 歌词引擎版本号（版本更新后自动刷新旧缓存，确保逐字结束时间与完整译文补齐生效）。
  static const int engineVersion = 4;

  /// LRCLIB 精确时长匹配端点。
  static const String lrclibGetEndpoint = 'https://lrclib.net/api/get';

  /// LRCLIB 同步歌词搜索端点。
  static const String lrclibSearchEndpoint = 'https://lrclib.net/api/search';

  /// 网易云歌曲搜索端点。
  static const String neteaseSearchEndpoint =
      'https://music.163.com/api/search/get';

  /// 网易云歌词正文端点。
  static const String neteaseLyricEndpoint =
      'https://music.163.com/api/song/lyric';

  /// 网易云搜索结果条数上限。
  static const int neteaseSearchLimit = 8;

  /// QQ 音乐统一网关端点（搜索与歌词拉取）。
  static const String qqMusicUnifiedEndpoint =
      'https://u.y.qq.com/cgi-bin/musicu.fcg';

  /// QQ 音乐请求来源头（防盗链校验）。
  static const String qqMusicReferer = 'https://y.qq.com/';

  /// QQ 音乐单次搜索条数上限。
  static const int qqSearchLimit = 8;

  /// AMLL TTML 按网易云歌曲标识直取的镜像基址（按优先级排列，后者作为对冲请求）。
  static const List<String> amllNcmLyricMirrors = <String>[
    'https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/ncm-lyrics/',
    'https://fastly.jsdelivr.net/gh/amll-dev/amll-ttml-db@main/ncm-lyrics/',
  ];

  /// 主镜像未返回时发起下一镜像对冲请求的等待时长。
  static const Duration amllHedgeDelay = Duration(milliseconds: 700);

  /// 移动计量网络下的对冲等待时长（减少重复流量）。
  static const Duration amllMeteredHedgeDelay = Duration(milliseconds: 1600);

  /// 单次歌词请求超时时长。
  static const Duration requestTimeout = Duration(milliseconds: 3500);

  /// 首个可自动采用的候选出现后，继续等待更优候选的宽限期。
  static const Duration firstPaintGrace = Duration(milliseconds: 300);

  /// 仅有低置信度合格候选时，自竞速开始起的首屏软截止。
  static const Duration lowConfidencePaintAfter = Duration(milliseconds: 1200);

  /// 单次竞速总预算（到期后以当前最优候选收束）。
  static const Duration raceDeadline = Duration(milliseconds: 4500);

  /// 负缓存（未找到）重新检索间隔。
  static const Duration notFoundRetryAfter = Duration(days: 7);

  /// LRCLIB 要求的应用标识用户代理。
  static const String userAgent =
      'Konata/3.0 (+https://github.com/konata-player)';
}

/// 歌词检索传输抽象（生产环境接入统一网络客户端端口，测试注入模拟客户端）。
abstract interface class LyricHttpTransport {
  /// 发起 GET 请求，超过 [timeout] 抛出超时异常。
  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
    required Duration timeout,
  });

  /// 发起 POST 请求，超过 [timeout] 抛出超时异常。
  Future<http.Response> post(
    Uri uri, {
    Map<String, String> headers = const {},
    Object? body,
    required Duration timeout,
  });
}

/// 基于统一网络客户端端口的歌词传输适配器（复用全局代理与限流策略）。
class KonataHttpClientLyricTransport implements LyricHttpTransport {
  /// 使用统一网络客户端端口构造传输适配器。
  const KonataHttpClientLyricTransport(
    this._client, {
    this.priority = RequestPriority.interactive,
  });

  final KonataHttpClientPort _client;

  /// 请求优先级通道。
  final RequestPriority priority;

  @override
  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
    required Duration timeout,
  }) async {
    final resp = await _client.getWithFallback(
      uri,
      headers: headers,
      priority: priority,
      dedupeKey: 'lyric:get:$uri',
      bucketKey: 'lyrics:${uri.host}',
      retryOnRateLimit: false,
      timeoutOverride: timeout,
    );
    return http.Response.bytes(
      resp.bodyBytes,
      resp.statusCode,
      headers: resp.headers,
      reasonPhrase: resp.reasonPhrase,
    );
  }

  @override
  Future<http.Response> post(
    Uri uri, {
    Map<String, String> headers = const {},
    Object? body,
    required Duration timeout,
  }) async {
    final resp = await _client.postWithFallback(
      uri,
      headers: headers,
      body: body,
      priority: priority,
      bucketKey: 'lyrics:${uri.host}',
      retryOnRateLimit: false,
      timeoutOverride: timeout,
    );
    return http.Response.bytes(
      resp.bodyBytes,
      resp.statusCode,
      headers: resp.headers,
      reasonPhrase: resp.reasonPhrase,
    );
  }
}

/// 基于普通客户端的歌词传输实现（供命令行基准或隔离单测注入）。
class ClientLyricTransport implements LyricHttpTransport {
  /// 创建传输实例。
  ClientLyricTransport(this._client);

  final http.Client _client;

  @override
  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
    required Duration timeout,
  }) {
    return _client.get(uri, headers: headers).timeout(timeout);
  }

  @override
  Future<http.Response> post(
    Uri uri, {
    Map<String, String> headers = const {},
    Object? body,
    required Duration timeout,
  }) {
    return _client.post(uri, headers: headers, body: body).timeout(timeout);
  }
}
