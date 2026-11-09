import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'metadata_servers.dart';
import 'debug_log.dart';
import 'request_budget.dart';
import 'transient_tls.dart';

/// Shared transport: bounded retries, no credential-bearing redirects, disk JSON
/// fallback. Diagnostics use [raw] to test exactly the entered server.
class MetadataHttp extends http.BaseClient {
  MetadataHttp({
    http.Client? inner,
    this.raw = false,
    this.trustCustom = false,
    this.fresh = false,
    this.headerTimeout = const Duration(seconds: 15),
  }) : _inner = inner ?? http.Client();
  final http.Client _inner;
  final bool raw, trustCustom;

  /// Credential checks must not reuse disk results or remembered host failures.
  final bool fresh;
  final Duration headerTimeout;
  static const userAgent =
      'ClainSt/Konata/1.0.0 (https://github.com/ClainSt/Konata)';
  static final Map<String, DateTime> _unhealthy = {};
  static Directory? cacheDirectory;
  static int _writes = 0;
  static Future<void> initialize() async {
    cacheDirectory = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'metadata_cache'),
    );
    try {
      await cacheDirectory!.create(recursive: true);
      await _trimCache();
    } catch (_) {
      cacheDirectory = null;
    }
  }

  static Future<void> _trimCache() async {
    final dir = cacheDirectory;
    if (dir == null) return;
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final stats = <File, FileStat>{};
    var size = 0;
    for (final file in files) {
      final stat = await file.stat();
      stats[file] = stat;
      size += stat.size;
    }
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    for (final file in files) {
      if (size <= 64 * 1024 * 1024) break;
      await file.delete();
      size -= stats[file]!.size;
    }
  }

  static int? provider(Uri uri) {
    if (['api.themoviedb.org', 'api.tmdb.org'].contains(uri.host)) return 0;
    if (['api.bgm.tv', 'api.bangumi.lat'].contains(uri.host)) return 2;
    return null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      RequestBudget.run(() => _send(request));

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final source = request.url;
    final index = provider(source);
    var target = source;
    if (!raw && index != null) {
      target = MetadataServers.endpoint(
        index,
        source.path.replaceFirst(
          index == 0 ? RegExp(r'^/3/?') : RegExp(r'^/v0/?'),
          '',
        ),
      ).replace(query: source.hasQuery ? source.query : null);
    }
    final key = sha256
        .convert(
          utf8.encode(
            '${request.method}|${source.path}|${jsonEncode({...source.queryParameters}..remove('api_key'))}|${sha256.convert(bytes)}',
          ),
        )
        .toString();
    File? cache;
    if (!raw && !fresh && cacheDirectory != null) {
      cache = File(p.join(cacheDirectory!.path, '$key.json'));
    }
    final candidates = <Uri>[target];
    if (!raw && MetadataServers.fallback && index != null) {
      for (final base in [
        MetadataServers.defaults[index],
        MetadataServers.official[index],
      ]) {
        final alt = MetadataServers.endpoint(
          index,
          source.path.replaceFirst(
            index == 0 ? RegExp(r'^/3/?') : RegExp(r'^/v0/?'),
            '',
          ),
          base: base,
        ).replace(query: source.hasQuery ? source.query : null);
        if (!candidates.contains(alt)) candidates.add(alt);
      }
    }
    Object? failure;
    final hasHealthyRoute = candidates.any(
      (uri) => !(_unhealthy[uri.host]?.isAfter(DateTime.now()) ?? false),
    );
    for (final uri in candidates) {
      if (!raw &&
          !fresh &&
          candidates.length > 1 &&
          hasHealthyRoute &&
          _unhealthy[uri.host]?.isAfter(DateTime.now()) == true) {
        continue;
      }
      final headers = {...request.headers, 'User-Agent': userAgent};
      final hasAuth =
          headers.keys.any((k) => k.toLowerCase() == 'authorization') ||
          uri.queryParameters.containsKey('api_key');
      if (hasAuth &&
          (!uri.isScheme('https') ||
              !['api.themoviedb.org', 'api.tmdb.org'].contains(uri.host) &&
                  !(raw ? trustCustom : MetadataServers.trustCustomTmdb))) {
        throw StateError('自定义 TMDB 服务未获凭证发送授权（仅支持 HTTPS）');
      }
      final watch = Stopwatch()..start();
      final abort = Completer<void>();
      try {
        Future<http.StreamedResponse> open() {
          final copy =
              http.AbortableRequest(
                  request.method,
                  uri,
                  abortTrigger: abort.future,
                )
                ..headers.addAll(headers)
                ..bodyBytes = bytes;
          copy.followRedirects = !hasAuth;
          return _inner.send(copy);
        }

        final streamed =
            await ((request.method == 'GET' ||
                            index == 2 &&
                                request.method == 'POST' &&
                                source.path == '/v0/search/subjects') &&
                        !raw
                    ? retryInterruptedTls(open)
                    : open())
                .timeout(headerTimeout);
        final body = BytesBuilder();
        await for (final chunk in streamed.stream.timeout(
          const Duration(seconds: 20),
        )) {
          body.add(chunk);
          if (body.length > 32 * 1024 * 1024) {
            throw const HttpException('响应超过 32 MB');
          }
        }
        final responseBytes = body.takeBytes();
        DebugLog.write(
          index == 0 ? 'TMDB' : 'Bangumi',
          '${request.method} host=${uri.host} resource=${index != null ? source.path : "diagnostic"} status=${streamed.statusCode} elapsed=${watch.elapsedMilliseconds}ms',
        );
        if (streamed.statusCode >= 500) {
          throw HttpException('HTTP ${streamed.statusCode}');
        }
        _unhealthy.remove(uri.host);
        // Authentication/rate limiting are returned without retrying or cached success.
        if (streamed.statusCode == 200 && cache != null) {
          try {
            jsonDecode(utf8.decode(responseBytes));
            await cache.writeAsBytes(responseBytes);
            if (++_writes % 32 == 0) await _trimCache();
          } catch (_) {}
        }
        return http.StreamedResponse(
          Stream.value(responseBytes),
          streamed.statusCode,
          headers: streamed.headers,
          request: request,
        );
      } catch (e) {
        failure = e;
        if (e is! TimeoutException &&
            e is! IOException &&
            e is! http.ClientException) {
          rethrow;
        }
        if (!fresh) {
          _unhealthy[uri.host] = DateTime.now().add(
            const Duration(seconds: 45),
          );
        }
        DebugLog.write(
          'Network',
          'host=${uri.host} error=${e.runtimeType} elapsed=${watch.elapsedMilliseconds}ms; fallback=${!raw && candidates.length > 1}',
          level: 'WARN',
        );
      } finally {
        // Future.timeout alone leaves the underlying socket request alive.
        // Abort also covers body failures before giving the budget slot back.
        abort.complete();
      }
    }
    if (cache != null && await cache.exists()) {
      DebugLog.write('Cache', 'offline metadata hit');
      return http.StreamedResponse(
        cache.openRead(),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }
    throw failure ?? const HttpException('服务暂时不可用');
  }

  @override
  void close() => _inner.close();
}
