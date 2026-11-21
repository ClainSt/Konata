import 'dart:convert';
import 'dart:developer' as developer;

import '../../domain/models/fanart_models.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/work.dart';
import 'priority_http_scheduler.dart';
import 'tmdb_http_client.dart';
import 'tmdb_service.dart';

/// Fanart.tv 内置中继健康状态枚举（供设置页状态条与「编辑标题徽标」弹窗精准提示）。
enum FanartRelayStatus {
  /// 中继或直连通道正常可用。
  healthy,

  /// 单 IP 触发频率限流（HTTP 429 + `rate_limited`），短暂退避后自动恢复。
  rateLimited,

  /// 免费中继今日额度耗尽或不可用（HTTP 429/1027 或连续 503/401），已自动熔断并降级文字兜底。
  quotaExhausted,
}

/// Fanart.tv 内置中继健康与熔断快照。
class FanartRelayHealthSnapshot {
  /// 创建健康快照。
  const FanartRelayHealthSnapshot({
    this.status = FanartRelayStatus.healthy,
    this.cooldownUntil,
    this.message,
  });

  /// 正常态常量。
  static const FanartRelayHealthSnapshot ok = FanartRelayHealthSnapshot();

  /// 当前健康状态。
  final FanartRelayStatus status;

  /// 熔断或限流冷却截止时间（正常态为 `null`）。
  final DateTime? cooldownUntil;

  /// 面向用户的简体中文状态与引导说明。
  final String? message;

  /// 当前是否处于异常降级态。
  bool get isDegraded => status != FanartRelayStatus.healthy;
}

/// Fanart.tv 内置无状态中继熔断与健康注册表（由 Riverpod 托管生命周期）。
///
/// 精准区分两类故障：
/// - 频率限流（`429` + `rate_limited`）：遵守 `Retry-After` 短时退避；
/// - 免费额度耗尽（`429` 非 JSON / 含 `1027`）或连续 2 次 `503`/`401`/`403`：
///   自动熔断至次日 UTC 00:00 与 6 小时后的较早时刻，彻底避免老版本持续轰炸中继。
class FanartCircuitBreaker {
  /// 创建熔断器实例。
  FanartCircuitBreaker({
    this.maxQuotaCooldown = const Duration(hours: 6),
    this.failureThreshold = 2,
  });

  /// 额度耗尽或服务端拒绝时的单次最大熔断上限（与次日 UTC 00:00 取较短者）。
  final Duration maxQuotaCooldown;

  /// 连续 503/401/403 触发熔断的阈值次数。
  final int failureThreshold;

  int _consecutiveFailures = 0;
  FanartRelayStatus _status = FanartRelayStatus.healthy;
  DateTime? _openUntil;
  String? _message;

  /// 读取当前生效的健康快照（到期自动自愈回健康态）。
  FanartRelayHealthSnapshot snapshot([DateTime? now]) {
    final until = _openUntil;
    if (until != null) {
      final current = now ?? DateTime.now();
      if (!current.isBefore(until)) {
        reset();
      }
    }
    return FanartRelayHealthSnapshot(
      status: _status,
      cooldownUntil: _openUntil,
      message: _message,
    );
  }

  /// 当前内置中继通道是否处于熔断或限流冷却窗口内。
  bool isOpen([DateTime? now]) => snapshot(now).isDegraded;

  /// 记录单 IP 频率限流（遵守服务端建议退避时长，最短 60 秒）。
  void recordRateLimited({Duration retryAfter = const Duration(seconds: 60), DateTime? now}) {
    final current = now ?? DateTime.now();
    final safeWait = retryAfter < const Duration(seconds: 60)
        ? const Duration(seconds: 60)
        : (retryAfter > const Duration(minutes: 30)
              ? const Duration(minutes: 30)
              : retryAfter);
    _status = FanartRelayStatus.rateLimited;
    _openUntil = current.add(safeWait);
    _message =
        '内置 Fanart.tv 中继当前请求频繁，已暂缓请求并使用风格化文字兜底；可在「刮削与网络」填写个人 Key 获得更高配额。';
  }

  /// 记录 Cloudflare 免费日额度耗尽（立即熔断至次日 UTC 00:00 或 6 小时取较短者）。
  void recordQuotaExhausted([DateTime? now]) {
    final current = now ?? DateTime.now();
    _status = FanartRelayStatus.quotaExhausted;
    _openUntil = _computeQuotaCooldownUntil(current);
    _message =
        '内置 Fanart.tv 中继今日免费额度已达上限，当前已自动使用风格化文字兜底；可在「刮削与网络」填入个人 Key 或高级自定义 API Key 直连恢复。';
  }

  /// 记录内置中继返回一次认证拒绝或服务不可用（连续达到阈值后熔断）。
  void recordRelayUnavailable([DateTime? now]) {
    _consecutiveFailures++;
    if (_consecutiveFailures >= failureThreshold) {
      final current = now ?? DateTime.now();
      _status = FanartRelayStatus.quotaExhausted;
      _openUntil = _computeQuotaCooldownUntil(current);
      _message =
          '内置 Fanart.tv 中继暂时不可用，已自动熔断并降级为风格化文字兜底；可在「刮削与网络」高级设置中填写自定义 API Key 直连。';
    }
  }

  /// 请求恢复正常时清零失败计数与冷却窗口。
  void recordSuccess() {
    reset();
  }

  /// 手动重置熔断状态（例如用户在设置页更新密钥或网络配置后）。
  void reset() {
    _consecutiveFailures = 0;
    _status = FanartRelayStatus.healthy;
    _openUntil = null;
    _message = null;
  }

  DateTime _computeQuotaCooldownUntil(DateTime now) {
    final utc = now.toUtc();
    final nextUtcMidnight = DateTime.utc(utc.year, utc.month, utc.day + 1);
    final capped = now.add(maxQuotaCooldown);
    final localMidnight = nextUtcMidnight.toLocal();
    return localMidnight.isBefore(capped) ? localMidnight : capped;
  }
}

/// Fanart.tv v3 透明标题徽标（ClearLogo）业务客户端。
///
/// 路由规则：
/// - 高级设置填写了自定义 `api-key`：官方 `webservice.fanart.tv/v3` 优先 + 备用镜像回退，
///   使用 `api-key`（及可选 `client-key`）HTTP Header 直连认证；
/// - 未填写自定义 `api-key` 且配置了内置或自填 Cloudflare Workers 中继地址：
///   直连无状态中继 `/fanart/v3/{tv|movies}/{id}`，客户端零 Project Key 暴露，仅透传合法 `client-key`。
class FanartService {
  /// 创建 Fanart.tv 服务实例。
  FanartService({
    required TmdbHttpClient httpClient,
    FanartCircuitBreaker? circuitBreaker,
    DateTime Function()? nowProvider,
  }) : _http = httpClient,
       _circuitBreaker = circuitBreaker ?? FanartCircuitBreaker(),
       _now = nowProvider ?? DateTime.now;

  final TmdbHttpClient _http;
  final FanartCircuitBreaker _circuitBreaker;
  final DateTime Function() _now;

  static const String _fanartBucketKey = 'fanart';
  static final RegExp _clientKeyPattern = RegExp(r'^[A-Za-z0-9]{16,64}$');

  /// 当前网络配置下是否具备可用查询通道（自定义 `api-key` 或有效无状态中继）。
  bool get isConfigured => _http.config.isFanartAvailable;

  /// 当前是否正通过无状态中继通道运行（未填写自定义 `api-key`）。
  bool get isUsingRelay =>
      !_http.config.hasCustomFanartApiKey &&
      _http.config.normalizedFanartBackupApiBase.isNotEmpty;

  /// 当前内置中继熔断与健康快照。
  FanartRelayHealthSnapshot get healthSnapshot =>
      _circuitBreaker.snapshot(_now());

  /// 校验用户输入的个人 `client-key` 是否满足安全字符集格式。
  static bool isValidClientKeyFormat(String raw) =>
      _clientKeyPattern.hasMatch(raw.trim());

  /// 拼接 Cloudflare Workers 无状态中继路径，统一归一化为 `<base>/fanart/v3/{segment}/{id}`。
  static String buildRelayEndpointUrl(
    String rawBase, {
    required String segment,
    required int id,
  }) {
    final trimmed = rawBase.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.endsWith('/fanart/v3')) {
      return '$trimmed/$segment/$id';
    }
    if (trimmed.endsWith('/fanart')) {
      return '$trimmed/v3/$segment/$id';
    }
    if (trimmed.endsWith('/v3')) {
      return '$trimmed/$segment/$id';
    }
    return '$trimmed/fanart/v3/$segment/$id';
  }

  /// 拼接直连官方或备用 Fanart.tv v3 路径（`<base>/v3/{segment}/{id}`）。
  static String buildDirectEndpointUrl(
    String rawBase, {
    required String segment,
    required int id,
  }) {
    final trimmed = rawBase.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.endsWith('/v3')) {
      return '$trimmed/$segment/$id';
    }
    return '$trimmed/v3/$segment/$id';
  }

  /// 按媒体类型拉取透明标题徽标候选集（电影传 `tmdbId`，剧集传 `tvdbId`）。
  Future<FanartArtworkResult> fetchLogos({
    required TmdbMediaType mediaType,
    int? tmdbId,
    int? tvdbId,
    RequestPriority priority = RequestPriority.background,
    bool bypassCircuitBreaker = false,
  }) async {
    final config = _http.config;
    if (!config.isFanartAvailable) {
      return const FanartArtworkResult();
    }
    if (isUsingRelay && !bypassCircuitBreaker && _circuitBreaker.isOpen(_now())) {
      return const FanartArtworkResult(authRejected: true);
    }

    final int? targetId = mediaType == TmdbMediaType.movie ? tmdbId : tvdbId;
    if (targetId == null || targetId <= 0) {
      return const FanartArtworkResult();
    }

    final segment = mediaType == TmdbMediaType.movie ? 'movies' : 'tv';
    final ({Uri primary, Uri? backup, Map<String, String> headers}) route;
    try {
      route = _buildRequestRoute(config, segment: segment, id: targetId);
    } catch (_) {
      return const FanartArtworkResult();
    }

    final httpResponse = await _dispatchWithQuotaGuard(
      route: route,
      segment: segment,
      targetId: targetId,
      priority: priority,
      hasClientKey: config.hasFanartClientKey,
    );
    if (httpResponse == null) {
      return const FanartArtworkResult(authRejected: true);
    }

    if (httpResponse.statusCode == 404) {
      if (isUsingRelay) _circuitBreaker.recordSuccess();
      return const FanartArtworkResult(notFound: true);
    }
    if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) {
      final relayReason = _extractHeader(
        httpResponse.headers,
        'x-konata-relay-error',
      );
      if (isUsingRelay && relayReason != 'client_key_invalid') {
        _circuitBreaker.recordRelayUnavailable(_now());
      }
      return const FanartArtworkResult(authRejected: true);
    }
    if (httpResponse.statusCode == 503) {
      if (isUsingRelay) {
        _circuitBreaker.recordRelayUnavailable(_now());
      }
      return const FanartArtworkResult(authRejected: true);
    }
    if (httpResponse.statusCode != 200) {
      throw StateError('Fanart.tv 请求失败: HTTP ${httpResponse.statusCode}');
    }

    if (isUsingRelay) _circuitBreaker.recordSuccess();
    try {
      final decoded = jsonDecode(utf8.decode(httpResponse.bodyBytes));
      if (decoded is! Map) {
        return const FanartArtworkResult();
      }
      final map = decoded.map((k, v) => MapEntry(k.toString(), v));
      final logos = parseAndSortLogos(map, mediaType: mediaType);
      return FanartArtworkResult(logos: logos);
    } catch (error) {
      developer.log(
        '解析 Fanart.tv 透明徽标响应失败',
        name: 'konata.fanart_service',
        error: error,
      );
      return const FanartArtworkResult();
    }
  }

  /// 解析并按语言优先级、高清档位与社区点赞数排序 Fanart.tv 透明徽标候选列表。
  static List<FanartLogoCandidate> parseAndSortLogos(
    Map<String, Object?> json, {
    required TmdbMediaType mediaType,
  }) {
    final kinds = mediaType == TmdbMediaType.movie
        ? const [FanartLogoKind.hdMovieLogo, FanartLogoKind.movieLogo]
        : const [FanartLogoKind.hdTvLogo, FanartLogoKind.clearLogo];

    final parsed = <FanartLogoCandidate>[];
    final seenUrls = <String>{};

    for (final kind in kinds) {
      final rawList = json[kind.jsonKey];
      if (rawList is! List) continue;
      for (final item in rawList) {
        if (item is! Map) continue;
        final rawUrl = item['url']?.toString().trim() ?? '';
        if (rawUrl.isEmpty) continue;
        final normalizedUrl = _normalizeFanartUrl(rawUrl);
        if (!seenUrls.add(normalizedUrl)) continue;
        final id = item['id']?.toString().trim() ?? normalizedUrl;
        final lang = _normalizeFanartLang(item['lang']?.toString());
        final likes = _parseInt(item['likes']);
        parsed.add(
          FanartLogoCandidate(
            id: id,
            url: normalizedUrl,
            kind: kind,
            lang: lang,
            likes: likes,
          ),
        );
      }
    }

    parsed.sort((a, b) {
      final langCmp = fanartLanguageRank(a.lang).compareTo(
        fanartLanguageRank(b.lang),
      );
      if (langCmp != 0) return langCmp;
      final qualityCmp = b.kind.qualityRank.compareTo(a.kind.qualityRank);
      if (qualityCmp != 0) return qualityCmp;
      return b.likes.compareTo(a.likes);
    });
    return List<FanartLogoCandidate>.unmodifiable(parsed.take(24));
  }

  /// 语言排序与 TMDB 严格保持一致（0:中文, 2:日文, 3:英文, 4:无语言, 5:其他）。
  static int fanartLanguageRank(String? lang) {
    final normalized = _normalizeFanartLang(lang);
    return TmdbService.logoLanguageRank(normalized, null);
  }

  /// 检测 HTTP 429 响应是否属于 Cloudflare 免费日额度耗尽（如 Error 1027 或非 JSON 错误页）。
  static bool isCloudflareQuotaExhaustedResponse({
    required int statusCode,
    required Map<String, String> headers,
    required String bodyText,
  }) {
    if (statusCode != 429) return false;
    final relayError = _extractHeader(headers, 'x-konata-relay-error');
    if (relayError == 'rate_limited') return false;
    final lower = bodyText.toLowerCase();
    if (lower.contains('1027') ||
        lower.contains('quota_exceeded') ||
        lower.contains('exceeded') && lower.contains('daily')) {
      return true;
    }
    final contentType = (_extractHeader(headers, 'content-type') ?? '')
        .toLowerCase();
    return !contentType.contains('application/json');
  }

  Future<({int statusCode, Map<String, String> headers, List<int> bodyBytes})?>
  _dispatchWithQuotaGuard({
    required ({Uri primary, Uri? backup, Map<String, String> headers}) route,
    required String segment,
    required int targetId,
    required RequestPriority priority,
    required bool hasClientKey,
  }) async {
    try {
      final resp = await _http.getWithFallback(
        route.primary,
        backupUri: route.backup,
        headers: route.headers,
        priority: priority,
        dedupeKey: 'fanart:$segment:$targetId:${hasClientKey ? 1 : 0}',
        bucketKey: _fanartBucketKey,
      );
      return (
        statusCode: resp.statusCode,
        headers: resp.headers,
        bodyBytes: resp.bodyBytes,
      );
    } on RateLimitedHttpException catch (e) {
      if (isUsingRelay) {
        final isQuota =
            e.isQuotaExhausted ||
            (e.bodySnippet != null &&
                isCloudflareQuotaExhaustedResponse(
                  statusCode: 429,
                  headers: e.headers,
                  bodyText: e.bodySnippet!,
                ));
        if (isQuota) {
          _circuitBreaker.recordQuotaExhausted(_now());
        } else {
          _circuitBreaker.recordRateLimited(
            retryAfter: e.retryAfter,
            now: _now(),
          );
        }
      }
      return null;
    }
  }

  ({Uri primary, Uri? backup, Map<String, String> headers}) _buildRequestRoute(
    TmdbNetworkConfig config, {
    required String segment,
    required int id,
  }) {
    final headers = <String, String>{'Accept': 'application/json'};
    final clientKey = config.fanartClientKey.trim();
    if (clientKey.isNotEmpty && isValidClientKeyFormat(clientKey)) {
      headers['client-key'] = clientKey;
    }

    if (config.hasCustomFanartApiKey) {
      headers['api-key'] = config.effectiveFanartApiKey;
      final primary = Uri.parse(
        buildDirectEndpointUrl(
          TmdbNetworkConfig.defaultFanartApiBase,
          segment: segment,
          id: id,
        ),
      );
      final backupRaw = config.fanartBackupApiBase.trim().replaceAll(
        RegExp(r'/+$'),
        '',
      );
      final backup = backupRaw.isNotEmpty
          ? Uri.tryParse(
              buildDirectEndpointUrl(backupRaw, segment: segment, id: id),
            )
          : null;
      return (primary: primary, backup: backup, headers: headers);
    }

    final relayBase = config.normalizedFanartBackupApiBase;
    if (relayBase.isEmpty) {
      throw StateError('未配置 Fanart.tv 中继地址或自定义 API Key');
    }
    return (
      primary: Uri.parse(
        buildRelayEndpointUrl(relayBase, segment: segment, id: id),
      ),
      backup: null,
      headers: headers,
    );
  }

  static String? _extractHeader(Map<String, String> headers, String key) {
    final lower = key.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry.value.trim().toLowerCase();
      }
    }
    return null;
  }

  static String _normalizeFanartUrl(String raw) {
    if (raw.startsWith('http://assets.fanart.tv/')) {
      return raw.replaceFirst('http://', 'https://');
    }
    return raw;
  }

  static String? _normalizeFanartLang(String? raw) {
    final trimmed = (raw ?? '').trim().toLowerCase();
    if (trimmed.isEmpty || trimmed == '00' || trimmed == 'null') {
      return null;
    }
    return trimmed;
  }

  static int _parseInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString().trim() ?? '') ?? 0;
  }
}
