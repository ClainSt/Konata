import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/logging/diagnostic_event.dart';
import '../../domain/models/network_config.dart';
import '../../domain/sync/bangumi_sync_models.dart';
import '../logging/diagnostics_log_store.dart';
import 'priority_http_scheduler.dart';
import 'tmdb_http_client.dart';

/// Bangumi 个人令牌失效或权限不足异常（401 / 403，停止自动重试并引导用户重新填写令牌）。
class BangumiAuthException implements Exception {
  /// 创建鉴权异常。
  const BangumiAuthException(this.message, {this.statusCode = 401});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

/// 单条目用户分集收藏查询结果。
class BangumiSubjectEpisodeCollectionResult {
  /// 创建条目分集收藏查询结果。
  const BangumiSubjectEpisodeCollectionResult({
    required this.isCollected,
    required this.episodes,
  });

  /// 当前账号是否已收藏该条目（`404` 表示尚未加入收藏，写入章节前需先建收藏）。
  final bool isCollected;

  /// 条目下的全部章节与用户观看状态。
  final List<BangumiRemoteEpisodeProgress> episodes;
}

/// Bangumi 官方 v0 PAT 鉴权进度同步客户端。
///
/// 安全约束：所有携带 `Authorization: Bearer <PAT>` 的请求严格只直连官方 `api.bgm.tv`，
/// 绝不向任何第三方社区镜像转发用户个人访问令牌。
class BangumiSyncClient {
  /// 创建 Bangumi 进度同步客户端。
  BangumiSyncClient({required TmdbHttpClient httpClient, this._logStore})
    : _http = httpClient;

  static const String _userAgent =
      'ClainSt/Konata (+https://github.com/ClainSt/Konata)';
  static const String _bucketKey = 'bangumi_sync';

  final TmdbHttpClient _http;
  final DiagnosticsLogStore? _logStore;

  Uri _officialUri(String subPath, [Map<String, String>? query]) {
    final base = Uri.parse('${TmdbNetworkConfig.defaultBangumiApiBase}$subPath');
    return query == null ? base : base.replace(queryParameters: query);
  }

  /// 统一发送携带 PAT 的官方请求并校验 401/403 与非预期状态码。
  Future<http.Response> _sendAuthed({
    required String method,
    required String subPath,
    required String personalAccessToken,
    required String actionLabel,
    Map<String, String>? query,
    Object? jsonBody,
    RequestPriority priority = RequestPriority.background,
    bool allow404 = false,
    bool logAuthFailure = false,
  }) async {
    final pat = personalAccessToken.trim();
    if (pat.isEmpty) {
      throw const BangumiAuthException('请先填写 Bangumi 个人访问令牌（PAT）');
    }
    final resp = await _http.sendWithFallback(
      method: method,
      primaryUri: _officialUri(subPath, query),
      headers: <String, String>{
        'User-Agent': _userAgent,
        'Accept': 'application/json',
        'Authorization': 'Bearer $pat',
      },
      body: jsonBody == null ? null : jsonEncode(jsonBody),
      priority: priority,
      bucketKey: _bucketKey,
    );
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      if (logAuthFailure) {
        _logStore?.logEvent(
          subsystem: DiagnosticSubsystem.bangumi,
          severity: DiagnosticSeverity.warn,
          code: 'BGM_AUTH_401',
          message: 'Bangumi PAT 校验被拒绝（HTTP ${resp.statusCode}）',
          source:
              'lib/infrastructure/network/bangumi_sync_client.dart:_sendAuthed',
          context: <String, Object?>{'httpStatus': resp.statusCode},
        );
      }
      throw BangumiAuthException(
        'Bangumi 令牌无效或已过期（HTTP ${resp.statusCode}），请重新生成后填写',
        statusCode: resp.statusCode,
      );
    }
    if (allow404 && resp.statusCode == 404) {
      return resp;
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('$actionLabel失败（HTTP ${resp.statusCode}）');
    }
    return resp;
  }

  Map<String, Object?> _decodeJsonObject(http.Response resp, String label) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      throw FormatException('$label返回了非 JSON 响应内容');
    }
    if (decoded is! Map) {
      throw FormatException('$label返回格式异常');
    }
    return decoded.map((k, v) => MapEntry(k.toString(), v));
  }

  /// 校验个人访问令牌有效性并返回当前 Bangumi 账号公开资料（`GET /v0/me`）。
  Future<BangumiUserProfile> verifyToken(String personalAccessToken) async {
    final resp = await _sendAuthed(
      method: 'GET',
      subPath: '/me',
      personalAccessToken: personalAccessToken,
      actionLabel: 'Bangumi 账号验证',
      priority: RequestPriority.interactive,
      logAuthFailure: true,
    );
    return BangumiUserProfile.fromJson(_decodeJsonObject(resp, 'Bangumi /v0/me'));
  }

  /// 分页拉取当前用户在指定 Bangumi 条目下的全部分集观看状态（`GET /v0/users/-/collections/{id}/episodes`）。
  Future<BangumiSubjectEpisodeCollectionResult> fetchSubjectEpisodes({
    required int subjectId,
    required String personalAccessToken,
    RequestPriority priority = RequestPriority.background,
  }) async {
    const pageSize = 100;
    var offset = 0;
    final all = <BangumiRemoteEpisodeProgress>[];

    while (true) {
      final resp = await _sendAuthed(
        method: 'GET',
        subPath: '/users/-/collections/$subjectId/episodes',
        query: <String, String>{
          'limit': pageSize.toString(),
          'offset': offset.toString(),
        },
        personalAccessToken: personalAccessToken,
        actionLabel: '拉取 Bangumi 条目 #$subjectId 分集进度',
        priority: priority,
        allow404: true,
      );
      if (resp.statusCode == 404) {
        return const BangumiSubjectEpisodeCollectionResult(
          isCollected: false,
          episodes: <BangumiRemoteEpisodeProgress>[],
        );
      }
      final decoded = _decodeJsonObject(resp, 'Bangumi 分集进度');
      final total = (decoded['total'] as num?)?.toInt() ?? 0;
      final data = decoded['data'];
      if (data is! List || data.isEmpty) break;

      for (final item in data) {
        if (item is! Map) continue;
        final epRaw = item['episode'];
        if (epRaw is! Map) continue;
        final epId = (epRaw['id'] as num?)?.toInt() ?? 0;
        if (epId <= 0) continue;
        all.add(
          BangumiRemoteEpisodeProgress(
            episodeId: epId,
            episodeType: (epRaw['type'] as num?)?.toInt() ?? 0,
            sort: (epRaw['sort'] as num?)?.toDouble() ?? 0.0,
            ep: (epRaw['ep'] as num?)?.toDouble(),
            name: (epRaw['name'] ?? '').toString(),
            nameCn: (epRaw['name_cn'] ?? '').toString(),
            watchStatus: (item['type'] as num?)?.toInt() ?? 0,
          ),
        );
      }

      offset += data.length;
      if (offset >= total || data.length < pageSize || offset >= 1000) break;
    }

    return BangumiSubjectEpisodeCollectionResult(
      isCollected: true,
      episodes: all,
    );
  }

  /// 创建或更新条目的用户收藏状态（`POST /v0/users/-/collections/{subject_id}`，如 `3=在看`、`2=看过`）。
  Future<void> upsertSubjectCollection({
    required int subjectId,
    required int collectionType,
    required String personalAccessToken,
    RequestPriority priority = RequestPriority.background,
  }) async {
    await _sendAuthed(
      method: 'POST',
      subPath: '/users/-/collections/$subjectId',
      personalAccessToken: personalAccessToken,
      jsonBody: <String, Object?>{'type': collectionType},
      actionLabel: '更新 Bangumi 条目 #$subjectId 收藏状态',
      priority: priority,
    );
  }

  /// 批量更新指定条目下多个章节的观看状态（单次 `PATCH`，避免逐集请求触发限流）。
  Future<void> patchEpisodesStatus({
    required int subjectId,
    required List<int> episodeIds,
    required int watchStatus,
    required String personalAccessToken,
    RequestPriority priority = RequestPriority.background,
  }) async {
    if (episodeIds.isEmpty) return;
    await _sendAuthed(
      method: 'PATCH',
      subPath: '/users/-/collections/$subjectId/episodes',
      personalAccessToken: personalAccessToken,
      jsonBody: <String, Object?>{
        'episode_id': episodeIds,
        'type': watchStatus,
      },
      actionLabel: '批量上报 Bangumi 条目 #$subjectId 章节进度',
      priority: priority,
    );
  }

  /// 更新单个章节的观看状态（`PUT /v0/users/-/collections/-/episodes/{episode_id}`）。
  Future<void> putSingleEpisodeStatus({
    required int episodeId,
    required int watchStatus,
    required String personalAccessToken,
    RequestPriority priority = RequestPriority.background,
  }) async {
    await _sendAuthed(
      method: 'PUT',
      subPath: '/users/-/collections/-/episodes/$episodeId',
      personalAccessToken: personalAccessToken,
      jsonBody: <String, Object?>{'type': watchStatus},
      actionLabel: '上报 Bangumi 单集 #$episodeId 进度',
      priority: priority,
    );
  }
}
