import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/scraping/scrape_candidate_fetcher.dart';
import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_match_resolver.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:ccplayer/infrastructure/network/bangumi_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'scrape_eval_support.dart';

/// 刮削在线准确率评测：对清单中的每个作品分组执行与应用完全相同的在线匹配决策（Bangumi + TMDB），
/// 逐作品导出决策结果供真值比对。HTTP 响应按 URL 落盘缓存，重复评测不再请求网络。
///
/// 由环境变量驱动（因网络层依赖 Flutter 绑定，以 `flutter test tool/scrape_eval_online_test.dart` 运行）：
/// - `KONATA_EVAL_LISTING`：`路径\t字节数` 清单；
/// - `KONATA_EVAL_OUT`：输出 JSONL；
/// - `KONATA_EVAL_KEYS`：密钥文件（`TMDB=...` / `BGM=...`，仅运行时读取，不打印）；
/// - `KONATA_EVAL_CACHE`：HTTP 缓存目录；
/// - `KONATA_EVAL_ONLY`：可选，仅评测作品路径包含该子串的分组（多个用 `|` 分隔）；
/// - `KONATA_EVAL_EXPLICIT`：为 `1` 时同时评测显式 `{tmdb-N}` 未写类型时的剧集/电影择优；
/// - `KONATA_EVAL_WORKERS`：可选，并行评测的作品数与后台网络并发（默认 10）。
void main() {
  final env = Platform.environment;
  final listing = env['KONATA_EVAL_LISTING'];
  test(
    '刮削在线准确率评测',
    () async {
      final keys = _readKeys(env['KONATA_EVAL_KEYS']!);
      final cache = Directory(env['KONATA_EVAL_CACHE']!)
        ..createSync(recursive: true);
      // 评测环境经本机代理访问 TMDB/Bangumi（Dart HttpClient 默认不读取代理环境变量）。
      final io = HttpClient()
        ..findProxy = (uri) =>
            HttpClient.findProxyFromEnvironment(uri, environment: env);
      final client = _DiskCachingClient(IOClient(io), cache);
      final workers = int.tryParse(env['KONATA_EVAL_WORKERS'] ?? '') ?? 10;
      final tmdbHttp = TmdbHttpClient(
        config: TmdbNetworkConfig(credential: keys['TMDB'] ?? ''),
        httpClient: client,
        scheduler: PriorityHttpScheduler(backgroundConcurrency: workers),
        primaryTimeout: const Duration(seconds: 60),
        backupTimeout: const Duration(seconds: 60),
      );
      final bangumi = BangumiService(httpClient: tmdbHttp);
      final tmdb = TmdbService(httpClient: tmdbHttp);
      final fetcher = ScrapeCandidateFetcher(tmdb, bangumiService: bangumi);
      final resolver = ScrapeMatchResolver(
        fetcher: fetcher,
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );
      final grouped = await groupListing(listing!);
      final only = (env['KONATA_EVAL_ONLY'] ?? '')
          .split('|')
          .where((s) => s.isNotEmpty)
          .toList();
      final targets = [
        for (final g in grouped.groups)
          if (only.isEmpty || only.any((o) => g.folderRelativePath.contains(o)))
            g,
      ];
      final checkExplicit = env['KONATA_EVAL_EXPLICIT'] == '1';
      final sink = File(env['KONATA_EVAL_OUT']!).openWrite();
      var done = 0;
      final clock = Stopwatch()..start();
      Future<void> evaluate(GroupedWorkFolder g) async {
        final row = <String, Object?>{
          'folder': g.folderRelativePath,
          'title': g.cleanTitle,
          'movieHint': g.isMovieHint,
        };
        try {
          if (checkExplicit && g.explicitTmdbId != null) {
            final chosen = await fetcher.fetchExplicitDetail(g);
            final tv = await tmdb.getWorkDetail(
              g.explicitTmdbId!,
              TmdbMediaType.tv,
            );
            final movie = await tmdb.getWorkDetail(
              g.explicitTmdbId!,
              TmdbMediaType.movie,
            );
            row['explicit'] = {
              'chosen': chosen?.mediaType.name,
              'tv': tv?.title,
              'tvOriginal': tv?.originalTitle,
              'tvYear': tv?.year,
              'movie': movie?.title,
              'movieOriginal': movie?.originalTitle,
              'movieYear': movie?.year,
            };
          } else {
            final r = await resolver.resolve(g.withoutExplicitTmdb());
            final d = r.decision;
            row['level'] = d.level.name;
            row['best'] = d.best == null
                ? null
                : '${d.best!.detail.mediaType.name}:${d.best!.detail.tmdbId}';
            row['bestTitle'] = d.best?.detail.title;
            row['season'] = d.matchedSeason ?? d.best?.matchedSeason;
            row['reason'] = d.primaryReason;
            row['bestYear'] = d.best?.detail.year;
            row['bangumi'] = d.bestBangumi?.subject.id;
            row['bangumiName'] = d.bestBangumi?.subject.displayTitle;
            row['bangumiTier'] = r.bangumiTier.name;
            row['queries'] = ScrapeDomainAdapter.buildSearchQueries(g);
            row['top'] = [
              for (final c in d.topCandidates.take(5))
                '${c.detail.mediaType.name}:${c.detail.tmdbId}:${c.score.round()}:${c.detail.title}',
            ];
            row['reasons'] = [
              for (final c in d.topCandidates.take(3)) c.reasons.join(','),
            ];
            row['bgmTop'] = [
              for (final b in d.topBangumiCandidates.take(3))
                '${b.subject.id}:${b.score.round()}:${b.subject.displayTitle}',
            ];
            row['candidates'] = [
              for (final c in r.candidates) '${c.mediaType.name}:${c.tmdbId}',
            ];
            row['error'] = r.networkError?.toString();
          }
        } catch (error) {
          row['exception'] = error.toString();
        }
        sink.writeln(jsonEncode(row));
        done++;
        if (done % 50 == 0) {
          stderr.writeln(
            '已评测 $done/${targets.length}，耗时 ${clock.elapsed.inSeconds}s',
          );
        }
      }

      // 以固定并发数推进，网络层自带优先级调度与限流。
      // `KONATA_EVAL_REVERSE=1` 时从清单另一端推进，便于两轮评测并行共享 HTTP 缓存。
      final queue = env['KONATA_EVAL_REVERSE'] == '1'
          ? [...targets.reversed]
          : [...targets];
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          await evaluate(queue.removeLast());
        }
      }

      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
      await sink.close();
      stderr.writeln('完成 $done 个作品，耗时 ${clock.elapsed.inSeconds}s');
    },
    skip: listing == null ? '未设置 KONATA_EVAL_LISTING，跳过在线评测' : false,
    timeout: Timeout.none,
  );
}

Map<String, String> _readKeys(String path) => {
  for (final line in File(path).readAsLinesSync())
    if (line.contains('='))
      line.substring(0, line.indexOf('=')).trim(): line
          .substring(line.indexOf('=') + 1)
          .trim(),
};

/// 按请求 URL（剔除 `api_key` 参数）与请求体落盘缓存 GET/POST 响应的 HTTP 客户端，仅缓存 200 与 404。
class _DiskCachingClient extends http.BaseClient {
  _DiskCachingClient(this._inner, this._dir);

  final http.Client _inner;
  final Directory _dir;

  File _fileFor(http.BaseRequest request) {
    final url = request.url;
    final params = Map.of(url.queryParameters)..remove('api_key');
    var stable = url.replace(queryParameters: params).toString();
    if (request.method != 'GET' && request is http.Request) {
      stable = '${request.method} $stable ${request.body}';
    }
    final digest = sha1.convert(utf8.encode(stable)).toString();
    return File('${_dir.path}${Platform.pathSeparator}$digest.json');
  }

  /// 评测只关心匹配决策：代理握手中断、连接提前关闭等瞬时传输错误按指数退避重试，
  /// 避免网络抖动污染准确率统计（应用自身的容灾由 TmdbHttpClient 负责）。
  Future<(http.StreamedResponse, List<int>)> _sendWithRetry(
    http.BaseRequest request,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..followRedirects = request.followRedirects;
      if (request is http.Request) copy.bodyBytes = request.bodyBytes;
      try {
        final response = await _inner.send(copy);
        final bytes = await response.stream.toBytes();
        if (response.statusCode >= 500 && attempt < 4) {
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
          continue;
        }
        return (response, bytes);
      } on Object catch (error) {
        final transient =
            error is SocketException ||
            error is HandshakeException ||
            error is http.ClientException ||
            error is HttpException;
        if (!transient || attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final cacheable =
        request.method == 'GET' ||
        (request.method == 'POST' && request is http.Request);
    if (!cacheable) return _inner.send(request);
    final file = _fileFor(request);
    if (file.existsSync()) {
      final cached =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final body = utf8.encode(cached['body']! as String);
      return http.StreamedResponse(
        Stream.value(body),
        cached['status']! as int,
        headers: {'content-type': 'application/json; charset=utf-8'},
        request: request,
        contentLength: body.length,
      );
    }
    final (response, bytes) = await _sendWithRetry(request);
    if (response.statusCode == 200 || response.statusCode == 404) {
      file.writeAsStringSync(
        jsonEncode({
          'status': response.statusCode,
          'body': utf8.decode(bytes, allowMalformed: true),
        }),
      );
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
      request: request,
      contentLength: bytes.length,
      reasonPhrase: response.reasonPhrase,
    );
  }
}
