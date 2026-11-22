import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata/domain/formatting/network_error_sanitizer.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 评测缓存刷新策略。
enum EvalCacheRefreshPolicy {
  /// 默认模式：优先命中本地脱敏缓存。
  none,

  /// 强制刷新全部请求的本地缓存。
  all,

  /// 仅刷新此前返回 404 的缓存条目。
  notFound,

  /// 仅刷新 TMDB 域缓存。
  tmdb,

  /// 仅刷新 Bangumi 域缓存。
  bgm,

  /// 仅刷新 Fanart.tv 域缓存。
  fanart,
}

/// 评测触发真实回源但缺少对应服务密钥时抛出的信号异常（驱动外层按需延迟弹窗）。
class EvalKeyRequiredException implements Exception {
  /// 创建缺密信号异常。
  const EvalKeyRequiredException({
    required this.service,
    required this.canonicalKey,
  });

  /// 缺失密钥的目标服务名（如 `tmdb`、`fanart`）。
  final String service;

  /// 触发回源的脱敏规范化请求键（不含任何密钥）。
  final String canonicalKey;

  @override
  String toString() =>
      'EvalKeyRequiredException(service=$service, key=$canonicalKey)';
}

/// 单个上游域的速率与并发限流配置。
class EvalDomainQuota {
  /// 创建域限流配置。
  const EvalDomainQuota({
    required this.maxConcurrency,
    required this.maxRequestsPerSecond,
  });

  /// 最大并发请求数。
  final int maxConcurrency;

  /// 每秒最大回源请求数（令牌桶速率上限）。
  final double maxRequestsPerSecond;
}

/// 单域网络与缓存命中统计计数。
class EvalDomainStats {
  /// 命中本地脱敏缓存次数。
  int cacheHits = 0;

  /// 未命中缓存次数。
  int cacheMisses = 0;

  /// 实际发往外部网络的请求尝试次数（含重试）。
  int networkRequests = 0;

  /// 遭遇 HTTP 429 限流次数。
  int http429Count = 0;

  /// 发生瞬态或服务端错误重试次数。
  int retryCount = 0;

  /// 最终失败次数。
  int errorCount = 0;

  /// 是否观测到中继或平台日配额耗尽（如 Cloudflare 1027）。
  bool quotaExhausted = false;

  /// 导出可序列化统计快照。
  Map<String, Object?> toJson() => {
    'cacheHits': cacheHits,
    'cacheMisses': cacheMisses,
    'networkRequests': networkRequests,
    'http429Count': http429Count,
    'retryCount': retryCount,
    'errorCount': errorCount,
    'quotaExhausted': quotaExhausted,
  };
}

/// 评测网络层汇总统计。
class EvalNetworkStats {
  final Map<String, EvalDomainStats> _byDomain = {
    'tmdb': EvalDomainStats(),
    'bgm': EvalDomainStats(),
    'fanart': EvalDomainStats(),
    'other': EvalDomainStats(),
  };

  /// 获取指定服务域的统计对象。
  EvalDomainStats of(String domain) =>
      _byDomain.putIfAbsent(domain, EvalDomainStats.new);

  /// 总缓存命中次数。
  int get totalCacheHits =>
      _byDomain.values.fold(0, (sum, item) => sum + item.cacheHits);

  /// 总缓存未命中次数。
  int get totalCacheMisses =>
      _byDomain.values.fold(0, (sum, item) => sum + item.cacheMisses);

  /// 总真实网络请求次数。
  int get totalNetworkRequests =>
      _byDomain.values.fold(0, (sum, item) => sum + item.networkRequests);

  /// 总 429 限流次数。
  int get totalHttp429 =>
      _byDomain.values.fold(0, (sum, item) => sum + item.http429Count);

  /// 导出各域汇总映射。
  Map<String, Object?> toJson() => {
    'totalCacheHits': totalCacheHits,
    'totalCacheMisses': totalCacheMisses,
    'totalNetworkRequests': totalNetworkRequests,
    'totalHttp429': totalHttp429,
    'domains': {for (final e in _byDomain.entries) e.key: e.value.toJson()},
  };
}

/// 脱敏录制回放（VCR）与按域令牌桶流控 HTTP 客户端。
///
/// 职责边界：
/// - 将官方与备用镜像归一化为统一逻辑缓存键，彻底剥离 Query 与 Header 中的全部鉴权字段；
/// - 两级哈希目录分片与临时文件原子重命名落盘，仅缓存 `200` 与 `404` 响应；
/// - 命中缓存零延迟直出且不扣减流控令牌；真实回源严格受并发、QPS 令牌桶及 `429 Retry-After` 退避约束。
class EvalVcrHttpClient extends http.BaseClient {
  /// 创建评测用脱敏缓存与流控客户端。
  EvalVcrHttpClient({
    required http.Client inner,
    required Directory cacheDir,
    this.refreshPolicy = EvalCacheRefreshPolicy.none,
    this.offlineOnly = false,
    this.offlineSoft = false,
    this.allowFanartRelay = false,
    Map<String, EvalDomainQuota>? domainQuotas,
    this.maxRetries = 4,
    this.nowProvider = DateTime.now,
  }) : _inner = inner,
       _cacheDir = cacheDir,
       _quotas = domainQuotas ?? defaultQuotas(allowFanartRelay: allowFanartRelay) {
    _cacheDir.createSync(recursive: true);
  }

  /// 生成默认的各上游服务安全限流配额（TMDB 并发 ≤ 5、速率 ≤ 15 req/s）。
  static Map<String, EvalDomainQuota> defaultQuotas({
    bool allowFanartRelay = false,
  }) => <String, EvalDomainQuota>{
    'tmdb': const EvalDomainQuota(
      maxConcurrency: 5,
      maxRequestsPerSecond: 15.0,
    ),
    'bgm': const EvalDomainQuota(
      maxConcurrency: 3,
      maxRequestsPerSecond: 5.0,
    ),
    'fanart': allowFanartRelay
        ? const EvalDomainQuota(maxConcurrency: 1, maxRequestsPerSecond: 1.0)
        : const EvalDomainQuota(maxConcurrency: 2, maxRequestsPerSecond: 4.0),
    'other': const EvalDomainQuota(
      maxConcurrency: 2,
      maxRequestsPerSecond: 5.0,
    ),
  };

  static const Set<String> _secretQueryParams = <String>{
    'api_key',
    'client_key',
    'api-key',
    'client-key',
    'access_token',
    'token',
  };

  final http.Client _inner;
  final Directory _cacheDir;

  /// 缓存刷新策略。
  final EvalCacheRefreshPolicy refreshPolicy;

  /// 仅读缓存模式（未命中时不触发真实网络，直接抛出缺密或返回 503）。
  final bool offlineOnly;

  /// 离线软回退模式（仅读缓存，未命中时不中止批处理，而是返回空搜索结果或 404 并记录未命中键）。
  final bool offlineSoft;

  /// 本次离线软回退期间记录到的缓存未命中规范化键列表。
  final List<String> missedKeys = <String>[];

  /// 是否允许在未配置直连项目密钥时低速访问公开 Fanart 中继。
  final bool allowFanartRelay;

  /// 429 与瞬态传输异常最大重试次数。
  final int maxRetries;

  /// 当前时钟提供函数（便于测试注入）。
  final DateTime Function() nowProvider;

  static final RegExp _multiSlash = RegExp(r'/+');
  static const int _maxMemCacheEntries = 16384;

  final Map<String, EvalDomainQuota> _quotas;
  final Map<String, _DomainGate> _gates = <String, _DomainGate>{};
  final Map<String, ({int status, Uint8List bytes})> _memCache =
      <String, ({int status, Uint8List bytes})>{};

  /// 本次评测累计网络与缓存统计。
  final EvalNetworkStats stats = EvalNetworkStats();

  int _tmpSeq = 0;

  /// 判定请求所属逻辑服务域（`tmdb` / `bgm` / `fanart` / `other`）。
  static String classifyDomain(Uri uri) {
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (host == 'api.themoviedb.org' || host == 'api.tmdb.org') {
      return 'tmdb';
    }
    if (host == 'api.bgm.tv' || host == 'api.bgm.lat') {
      return 'bgm';
    }
    if (host == 'webservice.fanart.tv' || path.contains('/fanart/v3/')) {
      return 'fanart';
    }
    return 'other';
  }

  /// 生成跨镜像归一化、彻底剥离鉴权字段的稳定规范化请求键。
  static ({String domain, String canonicalKey, String sha256Hex})
  buildCanonicalRequestKey({
    required String method,
    required Uri uri,
    String? body,
  }) {
    final domain = classifyDomain(uri);
    var normalizedPath = uri.path.contains('//')
        ? uri.path.replaceAll(_multiSlash, '/')
        : uri.path;
    if (domain == 'fanart') {
      final fanartIdx = normalizedPath.toLowerCase().indexOf('/fanart/v3/');
      if (fanartIdx >= 0) {
        normalizedPath = normalizedPath.substring(fanartIdx + 7);
      }
    }

    final cleanQueryEntries = <MapEntry<String, String>>[
      for (final e in uri.queryParameters.entries)
        if (!_secretQueryParams.contains(e.key.trim().toLowerCase()))
          MapEntry(e.key, e.value),
    ]..sort((a, b) => a.key.compareTo(b.key));

    final queryPart = cleanQueryEntries.isEmpty
        ? ''
        : '?${Uri(queryParameters: Map.fromEntries(cleanQueryEntries)).query}';

    final upperMethod = method.toUpperCase();
    final target = switch (domain) {
      'tmdb' => 'tmdb:$normalizedPath$queryPart',
      'bgm' => 'bgm:$normalizedPath$queryPart',
      'fanart' => 'fanart:$normalizedPath$queryPart',
      _ => '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}$normalizedPath$queryPart',
    };

    var canonical = '$upperMethod $target';
    if (upperMethod != 'GET' && body != null && body.isNotEmpty) {
      canonical = '$canonical ${_normalizeBody(body)}';
    }
    final digest = sha256.convert(utf8.encode(canonical)).toString();
    return (domain: domain, canonicalKey: canonical, sha256Hex: digest);
  }

  static String _normalizeBody(String rawBody) {
    try {
      final decoded = jsonDecode(rawBody);
      return jsonEncode(_sortJsonValue(decoded));
    } catch (_) {
      return rawBody.trim();
    }
  }

  static Object? _sortJsonValue(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _sortJsonValue(value[k])};
    }
    if (value is List) {
      return [for (final item in value) _sortJsonValue(item)];
    }
    return value;
  }

  File _cacheFileFor(String sha256Hex) {
    final shard = sha256Hex.substring(0, 2);
    return File(
      '${_cacheDir.path}${Platform.pathSeparator}$shard'
      '${Platform.pathSeparator}$sha256Hex.json',
    );
  }

  bool _shouldRefreshCached(String domain, int cachedStatus) {
    return switch (refreshPolicy) {
      EvalCacheRefreshPolicy.none => false,
      EvalCacheRefreshPolicy.all => true,
      EvalCacheRefreshPolicy.notFound => cachedStatus == 404,
      EvalCacheRefreshPolicy.tmdb => domain == 'tmdb',
      EvalCacheRefreshPolicy.bgm => domain == 'bgm',
      EvalCacheRefreshPolicy.fanart => domain == 'fanart',
    };
  }

  bool _hasTmdbCredential(http.BaseRequest request) {
    final queryKey = (request.url.queryParameters['api_key'] ?? '').trim();
    if (queryKey.isNotEmpty) return true;
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == 'authorization') {
        final v = entry.value.trim();
        if (v.toLowerCase().startsWith('bearer ') && v.length > 7) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final method = request.method.toUpperCase();
    final cacheable =
        method == 'GET' || (method == 'POST' && request is http.Request);
    if (!cacheable) {
      return _inner.send(request);
    }

    final reqBody = request is http.Request ? request.body : null;
    final keyInfo = buildCanonicalRequestKey(
      method: method,
      uri: request.url,
      body: reqBody,
    );
    final domainStats = stats.of(keyInfo.domain);
    final memHit = _memCache[keyInfo.sha256Hex];
    if (memHit != null && !_shouldRefreshCached(keyInfo.domain, memHit.status)) {
      domainStats.cacheHits++;
      return http.StreamedResponse(
        Stream.value(memHit.bytes),
        memHit.status,
        headers: const {'content-type': 'application/json; charset=utf-8'},
        request: request,
        contentLength: memHit.bytes.length,
      );
    }

    final cacheFile = _cacheFileFor(keyInfo.sha256Hex);
    final cached = await _tryReadCacheAsync(cacheFile);
    if (cached != null &&
        !_shouldRefreshCached(keyInfo.domain, cached.status)) {
      domainStats.cacheHits++;
      final bytes = Uint8List.fromList(utf8.encode(cached.body));
      _putMemCache(keyInfo.sha256Hex, cached.status, bytes);
      return http.StreamedResponse(
        Stream.value(bytes),
        cached.status,
        headers: const {'content-type': 'application/json; charset=utf-8'},
        request: request,
        contentLength: bytes.length,
      );
    }

    domainStats.cacheMisses++;

    if (offlineSoft) {
      missedKeys.add(keyInfo.canonicalKey);
      final pathLower = request.url.path.toLowerCase();
      final isSearch =
          pathLower.contains('/search') || pathLower.contains('/v0/search');
      if (isSearch) {
        final emptyBody = keyInfo.domain == 'bgm'
            ? '{"data":[],"total":0}'
            : '{"page":1,"results":[],"total_pages":0,"total_results":0}';
        final bytes = utf8.encode(emptyBody);
        return http.StreamedResponse(
          Stream.value(bytes),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
          request: request,
          contentLength: bytes.length,
        );
      }
      final bytes = utf8.encode('{}');
      return http.StreamedResponse(
        Stream.value(bytes),
        404,
        headers: const {'content-type': 'application/json; charset=utf-8'},
        request: request,
        contentLength: bytes.length,
      );
    }

    if (offlineOnly) {
      throw EvalKeyRequiredException(
        service: keyInfo.domain,
        canonicalKey: keyInfo.canonicalKey,
      );
    }

    if (keyInfo.domain == 'tmdb' && !_hasTmdbCredential(request)) {
      throw EvalKeyRequiredException(
        service: 'tmdb',
        canonicalKey: keyInfo.canonicalKey,
      );
    }

    final gate = _gates.putIfAbsent(
      keyInfo.domain,
      () => _DomainGate(
        quota:
            _quotas[keyInfo.domain] ??
            const EvalDomainQuota(maxConcurrency: 2, maxRequestsPerSecond: 5.0),
        nowProvider: nowProvider,
      ),
    );

    final (response, bytes) = await _sendWithRateLimitAndRetry(
      request: request,
      domain: keyInfo.domain,
      gate: gate,
      domainStats: domainStats,
    );

    if (response.statusCode == 200 || response.statusCode == 404) {
      final bodyText = utf8.decode(bytes, allowMalformed: true);
      _putMemCache(
        keyInfo.sha256Hex,
        response.statusCode,
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
      _writeCacheAtomically(
        file: cacheFile,
        canonicalKey: keyInfo.canonicalKey,
        status: response.statusCode,
        body: bodyText,
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

  Future<(http.StreamedResponse, List<int>)> _sendWithRateLimitAndRetry({
    required http.BaseRequest request,
    required String domain,
    required _DomainGate gate,
    required EvalDomainStats domainStats,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..followRedirects = request.followRedirects;
      if (request is http.Request) {
        copy.bodyBytes = request.bodyBytes;
      }

      try {
        final (response, bytes) = await gate.run(() async {
          domainStats.networkRequests++;
          final resp = await _inner
              .send(copy)
              .timeout(const Duration(seconds: 12));
          final bodyBytes = await resp.stream
              .toBytes()
              .timeout(const Duration(seconds: 12));
          return (resp, bodyBytes);
        });

        if (response.statusCode == 429) {
          domainStats.http429Count++;
          final bodyText = utf8.decode(
            bytes.length > 512 ? bytes.sublist(0, 512) : bytes,
            allowMalformed: true,
          );
          final isQuota = _isQuotaExhausted429(response.headers, bodyText);
          if (isQuota) {
            domainStats.quotaExhausted = true;
            return (response, bytes);
          }
          if (attempt >= maxRetries) {
            domainStats.errorCount++;
            return (response, bytes);
          }
          final retrySec = _parseRetryAfterSeconds(response.headers);
          final backoff = retrySec != null
              ? Duration(seconds: retrySec.clamp(1, 30))
              : Duration(seconds: (1 << attempt).clamp(1, 30));
          domainStats.retryCount++;
          gate.applyCooldown(backoff);
          await Future<void>.delayed(backoff);
          continue;
        }

        if (response.statusCode >= 500 && attempt < maxRetries) {
          domainStats.retryCount++;
          await Future<void>.delayed(
            Duration(seconds: (1 << attempt).clamp(1, 16)),
          );
          continue;
        }

        return (response, bytes);
      } on Object catch (error) {
        final transient =
            error is SocketException ||
            error is HandshakeException ||
            error is HttpException ||
            error is http.ClientException ||
            error is TimeoutException;
        if (!transient || attempt >= maxRetries) {
          domainStats.errorCount++;
          throw _sanitizeError(error);
        }
        domainStats.retryCount++;
        // 代理空闲 Keep-Alive 断连等瞬态传输异常采用短阶梯重试，避免每次无意义空等 1~8 秒。
        const transientBackoffsMs = <int>[200, 600, 1500, 3000];
        final delayMs = attempt < transientBackoffsMs.length
            ? transientBackoffsMs[attempt]
            : transientBackoffsMs.last;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
  }

  void _putMemCache(String key, int status, Uint8List bytes) {
    if (_memCache.length >= _maxMemCacheEntries) {
      _memCache.remove(_memCache.keys.first);
    }
    _memCache[key] = (status: status, bytes: bytes);
  }

  static bool _isQuotaExhausted429(
    Map<String, String> headers,
    String bodyText,
  ) {
    final relayErr = _headerIgnoreCase(headers, 'x-konata-relay-error');
    if (relayErr == 'rate_limited') return false;
    final lower = bodyText.toLowerCase();
    return lower.contains('1027') ||
        lower.contains('quota_exceeded') ||
        (lower.contains('exceeded') && lower.contains('daily'));
  }

  static int? _parseRetryAfterSeconds(Map<String, String> headers) {
    final raw = _headerIgnoreCase(headers, 'retry-after');
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  static String? _headerIgnoreCase(Map<String, String> headers, String name) {
    final target = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == target) {
        return e.value.trim().toLowerCase();
      }
    }
    return null;
  }

  static Object _sanitizeError(Object error) {
    if (error is http.ClientException) {
      final safeMsg = NetworkErrorSanitizer.redactSecrets(error.message);
      final rawUri = error.uri?.toString();
      final safeUri = rawUri == null
          ? null
          : Uri.tryParse(NetworkErrorSanitizer.redactSecrets(rawUri));
      return http.ClientException(safeMsg, safeUri);
    }
    return error;
  }

  Future<({int status, String body})?> _tryReadCacheAsync(File file) async {
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final status = (decoded['status'] as num?)?.toInt();
      final body = decoded['body'];
      if (status == null || body is! String) return null;
      return (status: status, body: body);
    } catch (_) {
      return null;
    }
  }

  void _writeCacheAtomically({
    required File file,
    required String canonicalKey,
    required int status,
    required String body,
  }) {
    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    final payload = jsonEncode({
      'key': NetworkErrorSanitizer.redactSecrets(canonicalKey),
      'status': status,
      'fetchedAt': nowProvider().toUtc().toIso8601String(),
      'body': body,
    });
    final tmp = File('${file.path}.tmp.$pid.${_tmpSeq++}');
    try {
      tmp.writeAsStringSync(payload, flush: true);
      if (file.existsSync()) {
        file.deleteSync();
      }
      tmp.renameSync(file.path);
    } catch (_) {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

/// 单上游域并发信号量 + 速率令牌桶 + 全域 429 冷却闸门。
class _DomainGate {
  _DomainGate({required this.quota, required this.nowProvider});

  final EvalDomainQuota quota;
  final DateTime Function() nowProvider;

  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  DateTime _nextTokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _rateSerial = Future<void>.value();

  void applyCooldown(Duration duration) {
    final candidate = nowProvider().add(duration);
    if (candidate.isAfter(_cooldownUntil)) {
      _cooldownUntil = candidate;
    }
  }

  Future<T> run<T>(Future<T> Function() action) async {
    await _acquireConcurrency();
    try {
      await _acquireRateSlot();
      return await action();
    } finally {
      _releaseConcurrency();
    }
  }

  Future<void> _acquireConcurrency() async {
    final limit = quota.maxConcurrency < 1 ? 1 : quota.maxConcurrency;
    if (_active < limit) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void _releaseConcurrency() {
    if (_waiters.isEmpty) {
      if (_active > 0) _active--;
    } else {
      _waiters.removeFirst().complete();
    }
  }

  Future<void> _acquireRateSlot() {
    final intervalUs = quota.maxRequestsPerSecond <= 0
        ? 0
        : (1000000 / quota.maxRequestsPerSecond).ceil();
    final prev = _rateSerial;
    final done = Completer<void>();
    _rateSerial = done.future;

    return prev.then((_) async {
      try {
        while (true) {
          final now = nowProvider();
          var target = now;
          if (_cooldownUntil.isAfter(target)) {
            target = _cooldownUntil;
          }
          if (_nextTokenAt.isAfter(target)) {
            target = _nextTokenAt;
          }
          if (!target.isAfter(now)) {
            _nextTokenAt = now.add(Duration(microseconds: intervalUs));
            return;
          }
          await Future<void>.delayed(target.difference(now));
        }
      } finally {
        done.complete();
      }
    });
  }
}
