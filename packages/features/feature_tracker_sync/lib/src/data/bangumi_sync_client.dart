import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:konata_contracts/konata_contracts.dart';

import 'bangumi_sync_models.dart';

/// Bangumi 官方 API 直连客户端。
///
/// 安全约束：所有请求固定直连官方地址 `https://api.bgm.tv`，绝不使用第三方中转站，
/// 并在异常与日志输出前自动剥离 Bearer PAT 凭据。
final class BangumiSyncClient {
  /// 创建 Bangumi 官方直连客户端。
  ///
  /// 生产环境通过 [httpClientPort] 复用统一连接池与代理设置；单元测试可注入 [httpClient]。
  BangumiSyncClient({
    KonataHttpClientPort? httpClientPort,
    http.Client? httpClient,
    this._diagnosticLog,
    this._userAgent = defaultUserAgent,
  }) : _httpClientPort = httpClientPort,
       _rawHttpClient = httpClient ?? (httpClientPort == null ? http.Client() : null),
       _ownsRawClient = httpClientPort == null && httpClient == null;

  /// Bangumi 官方 API 根地址。
  static const String officialApiBase = KonataNetworkConfig.defaultBangumiApiBase;

  /// 默认请求标识头。
  static const String defaultUserAgent =
      'Konata/3.0 (https://github.com/clainst/Konata)';

  final KonataHttpClientPort? _httpClientPort;
  final http.Client? _rawHttpClient;
  final bool _ownsRawClient;
  final DiagnosticLogPort? _diagnosticLog;
  final String _userAgent;

  /// 验证 PAT 有效性并获取当前登录 Bangumi 账号信息（`GET /v0/me`）。
  Future<BangumiUserProfile> verifyToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw const BangumiAuthException(
        statusCode: 401,
        message: 'Bangumi PAT 不能为空',
      );
    }

    final response = await _sendJson(
      method: 'GET',
      path: '/v0/me',
      token: trimmed,
    );
    final payload = _decodeJsonMap(response.bodyText, tokenToRedact: trimmed);
    final id = _asInt(payload['id']);
    final username = (payload['username'] ?? '').toString().trim();
    final nickname = (payload['nickname'] ?? '').toString().trim();
    if (id == null || (username.isEmpty && nickname.isEmpty)) {
      throw const BangumiApiException(
        message: 'Bangumi 用户信息响应格式无效',
        retryable: false,
      );
    }

    String? avatarUrl;
    final avatar = payload['avatar'];
    if (avatar is Map) {
      avatarUrl = (avatar['large'] ?? avatar['medium'] ?? avatar['small'])
          ?.toString()
          .trim();
      if (avatarUrl != null && avatarUrl.isEmpty) {
        avatarUrl = null;
      }
    }

    return BangumiUserProfile(
      id: id,
      username: username,
      nickname: nickname.isEmpty ? username : nickname,
      avatarUrl: avatarUrl,
    );
  }

  /// 查询当前用户对指定条目的收藏状态；未收藏时返回 `null`。
  Future<BangumiCollectionType?> fetchUserSubjectCollection({
    required String token,
    required int subjectId,
  }) async {
    final response = await _sendJson(
      method: 'GET',
      path: '/v0/users/-/collections/$subjectId',
      token: token,
      allowNotFound: true,
    );
    if (response.statusCode == 404) {
      return null;
    }
    final payload = _decodeJsonMap(response.bodyText, tokenToRedact: token);
    return BangumiCollectionType.fromApiValue(_asInt(payload['type']));
  }

  /// 创建或更新当前用户对指定条目的收藏状态。
  Future<void> upsertUserSubjectCollection({
    required String token,
    required int subjectId,
    required BangumiCollectionType type,
  }) async {
    await _sendJson(
      method: 'POST',
      path: '/v0/users/-/collections/$subjectId',
      token: token,
      jsonBody: <String, Object?>{'type': type.apiValue},
    );
  }

  /// 拉取指定条目下的分集列表与用户当前观看进度。
  Future<List<BangumiRemoteEpisodeProgress>> fetchSubjectEpisodes({
    required String token,
    required int subjectId,
    int? type,
    int pageSize = 100,
  }) async {
    final results = <BangumiRemoteEpisodeProgress>[];
    var offset = 0;
    const maxPages = 30;

    for (var page = 0; page < maxPages; page++) {
      final queryParams = <String, String>{
        'limit': '$pageSize',
        'offset': '$offset',
        if (type != null) 'type': '$type',
      };
      final response = await _sendJson(
        method: 'GET',
        path: '/v0/users/-/collections/$subjectId/episodes',
        queryParameters: queryParams,
        token: token,
      );
      final payload = _decodeJsonMap(response.bodyText, tokenToRedact: token);
      final data = payload['data'];
      if (data is! List) {
        break;
      }

      var fetchedCount = 0;
      for (final item in data) {
        if (item is! Map) {
          continue;
        }
        final epRaw = item['episode'];
        final epMap = epRaw is Map ? epRaw : item;
        final epId = _asInt(epMap['id']);
        if (epId == null) {
          continue;
        }
        fetchedCount++;
        final statusInt = _asInt(item['type']) ?? _asInt(epMap['status']);
        results.add(
          BangumiRemoteEpisodeProgress(
            episodeId: epId,
            type: _asInt(epMap['type']) ?? 0,
            sort: _asDouble(epMap['sort']) ?? 0,
            ep: _asDouble(epMap['ep']) ?? _asDouble(epMap['sort']) ?? 0,
            status: BangumiEpisodeWatchStatus.fromApiValue(statusInt),
            name: (epMap['name_cn'] ?? epMap['name'] ?? '').toString().trim(),
          ),
        );
      }

      final total = _asInt(payload['total']);
      offset += fetchedCount;
      if (fetchedCount < pageSize || (total != null && offset >= total)) {
        break;
      }
    }

    return results;
  }

  /// 更新单个 Bangumi 剧集的观看状态（`PUT /v0/users/-/collections/-/episodes/{episode_id}`）。
  Future<void> setEpisodeStatus({
    required String token,
    required int episodeId,
    required BangumiEpisodeWatchStatus status,
  }) async {
    await _sendJson(
      method: 'PUT',
      path: '/v0/users/-/collections/-/episodes/$episodeId',
      token: token,
      jsonBody: <String, Object?>{'type': status.apiValue},
    );
  }

  /// 批量更新指定条目下多个 Bangumi 剧集的观看状态（`PATCH /v0/users/-/collections/{subject_id}/episodes`）。
  Future<void> patchSubjectEpisodes({
    required String token,
    required int subjectId,
    required List<int> episodeIds,
    required BangumiEpisodeWatchStatus status,
  }) async {
    if (episodeIds.isEmpty) {
      return;
    }
    await _sendJson(
      method: 'PATCH',
      path: '/v0/users/-/collections/$subjectId/episodes',
      token: token,
      jsonBody: <String, Object?>{
        'episode_id': episodeIds,
        'type': status.apiValue,
      },
    );
  }

  /// 释放测试注入的内部连接客户端资源。
  void close() {
    if (_ownsRawClient) {
      _rawHttpClient?.close();
    }
  }

  Future<_BangumiHttpResult> _sendJson({
    required String method,
    required String path,
    required String token,
    Map<String, String>? queryParameters,
    Map<String, Object?>? jsonBody,
    bool allowNotFound = false,
  }) async {
    final trimmedToken = token.trim();
    if (trimmedToken.isEmpty) {
      throw const BangumiAuthException(
        statusCode: 401,
        message: 'Bangumi PAT 为空，请重新绑定',
      );
    }

    final base = Uri.parse(officialApiBase);
    final uri = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: path,
      queryParameters: queryParameters,
    );

    final encodedBody = jsonBody == null ? null : jsonEncode(jsonBody);
    final headers = <String, String>{
      'Authorization': 'Bearer $trimmedToken',
      'User-Agent': _userAgent,
      'Accept': 'application/json',
      if (encodedBody != null) 'Content-Type': 'application/json; charset=utf-8',
    };

    try {
      final result = await _performRequest(
        method: method,
        uri: uri,
        headers: headers,
        encodedBody: encodedBody,
      );

      if (result.statusCode == 401 || result.statusCode == 403) {
        final msg = result.statusCode == 401
            ? 'Bangumi PAT 无效或已过期（401），请重新绑定'
            : 'Bangumi PAT 权限不足（403），请检查访问权限后重新绑定';
        _logError(
          code: 'BGM_AUTH_FAILED',
          message: msg,
          tokenToRedact: trimmedToken,
          context: <String, Object?>{
            'statusCode': result.statusCode,
            'path': path,
          },
        );
        throw BangumiAuthException(
          statusCode: result.statusCode,
          message: msg,
        );
      }

      if (allowNotFound && result.statusCode == 404) {
        return result;
      }

      if (result.statusCode < 200 || result.statusCode >= 300) {
        final detail = _extractServerMessage(
          result.bodyText,
          tokenToRedact: trimmedToken,
        );
        final retryable =
            result.statusCode == 429 ||
            result.statusCode >= 500 ||
            result.statusCode == 408;
        final msg = detail.isEmpty
            ? 'Bangumi 接口返回状态码 ${result.statusCode}'
            : 'Bangumi 接口失败（${result.statusCode}）：$detail';
        _logError(
          code: 'BGM_HTTP_ERROR',
          message: msg,
          tokenToRedact: trimmedToken,
          context: <String, Object?>{
            'statusCode': result.statusCode,
            'retryable': retryable,
            'path': path,
          },
        );
        throw BangumiApiException(
          statusCode: result.statusCode,
          message: msg,
          retryable: retryable,
        );
      }

      return result;
    } on BangumiAuthException {
      rethrow;
    } on BangumiApiException {
      rethrow;
    } catch (error, stackTrace) {
      final redacted = _sanitize(error.toString(), tokenToRedact: trimmedToken);
      _logError(
        code: 'BGM_TRANSPORT_ERROR',
        message: 'Bangumi 请求网络异常：$redacted',
        error: error,
        stackTrace: stackTrace,
        tokenToRedact: trimmedToken,
        context: <String, Object?>{'path': path},
      );
      throw BangumiApiException(
        message: 'Bangumi 网络连接失败：$redacted',
        retryable: true,
      );
    }
  }

  Future<_BangumiHttpResult> _performRequest({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required String? encodedBody,
  }) async {
    final rawClient = _rawHttpClient;
    if (rawClient != null) {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (encodedBody != null) {
        req.bodyBytes = utf8.encode(encodedBody);
      }
      final streamed = await rawClient
          .send(req)
          .timeout(const Duration(seconds: 15));
      final bytes = await streamed.stream.toBytes();
      return _BangumiHttpResult(
        statusCode: streamed.statusCode,
        bodyText: utf8.decode(bytes, allowMalformed: true),
      );
    }

    final port = _httpClientPort!;
    final KonataHttpResponse res;
    if (method == 'GET') {
      // 严禁传入备用域名，确保追番凭据仅送往 Bangumi 官方服务。
      res = await port.getWithFallback(
        uri,
        backupUri: null,
        headers: headers,
        priority: RequestPriority.interactive,
        bucketKey: 'bangumi_tracker',
        timeoutOverride: const Duration(seconds: 15),
      );
    } else {
      res = await port.sendWithFallback(
        method: method,
        primaryUri: uri,
        backupUri: null,
        headers: headers,
        body: encodedBody == null ? null : Uint8List.fromList(utf8.encode(encodedBody)),
        priority: RequestPriority.interactive,
        bucketKey: 'bangumi_tracker',
        timeoutOverride: const Duration(seconds: 15),
      );
    }
    return _BangumiHttpResult(
      statusCode: res.statusCode,
      bodyText: utf8.decode(res.bodyBytes, allowMalformed: true),
    );
  }

  Map<String, Object?> _decodeJsonMap(
    String rawBody, {
    required String tokenToRedact,
  }) {
    if (rawBody.trim().isEmpty) {
      return const <String, Object?>{};
    }
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
      return const <String, Object?>{};
    } catch (error) {
      final safe = _sanitize(error.toString(), tokenToRedact: tokenToRedact);
      throw BangumiApiException(
        message: 'Bangumi 返回体解析失败：$safe',
        retryable: false,
      );
    }
  }

  String _extractServerMessage(
    String bodyText, {
    required String tokenToRedact,
  }) {
    if (bodyText.trim().isEmpty) {
      return '';
    }
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map) {
        final msg = (decoded['description'] ??
                decoded['message'] ??
                decoded['title'] ??
                '')
            .toString()
            .trim();
        return _sanitize(msg, tokenToRedact: tokenToRedact);
      }
    } catch (_) {
      // 忽略非 JSON 错误正文解析失败，回退纯文本脱敏。
    }
    final snippet = bodyText.trim();
    final clipped = snippet.length > 120 ? snippet.substring(0, 120) : snippet;
    return _sanitize(clipped, tokenToRedact: tokenToRedact);
  }

  String _sanitize(String raw, {required String tokenToRedact}) {
    var result = raw;
    if (tokenToRedact.isNotEmpty) {
      result = result.replaceAll(tokenToRedact, '[REDACTED]');
    }
    result = NetworkErrorSanitizer.redactSecrets(result);
    return DiagnosticTextSanitizer.redactSecrets(result);
  }

  void _logError({
    required String code,
    required String message,
    required String tokenToRedact,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    final log = _diagnosticLog;
    if (log == null) {
      return;
    }
    final safeMsg = _sanitize(message, tokenToRedact: tokenToRedact);
    final safeErr = error == null
        ? safeMsg
        : _sanitize(error.toString(), tokenToRedact: tokenToRedact);
    log.logError(
      subsystem: DiagnosticSubsystem.tracker,
      code: code,
      message: safeMsg,
      error: safeErr,
      stackTrace: stackTrace,
      severity: DiagnosticSeverity.warn,
      source: 'BangumiSyncClient',
      context: context,
    );
  }

  static int? _asInt(Object? raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  static double? _asDouble(Object? raw) {
    if (raw is double) {
      return raw;
    }
    if (raw is num) {
      return raw.toDouble();
    }
    return double.tryParse(raw?.toString() ?? '');
  }
}

final class _BangumiHttpResult {
  const _BangumiHttpResult({
    required this.statusCode,
    required this.bodyText,
  });

  final int statusCode;
  final String bodyText;
}
