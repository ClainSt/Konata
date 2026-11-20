import 'dart:convert';

import '../../domain/models/network_config.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/search_query_sanitizer.dart';
import 'priority_http_scheduler.dart';
import 'tmdb_http_client.dart';

/// Bangumi 官方在线 API 服务（官方地址优先 + 社区镜像自动回退；严格只拉取条目/单集/关联元数据，不请求角色与声优接口）。
class BangumiService {
  /// 创建 Bangumi 在线服务实例。
  BangumiService({required TmdbHttpClient httpClient}) : _http = httpClient;

  static const Map<String, String> _bgmHeaders = {
    'User-Agent': 'ClainSt/Konata (+https://github.com/ClainSt/Konata)',
    'Accept': 'application/json',
  };
  static const int _maxMemoEntries = 240;
  static const String _bangumiBucketKey = 'bangumi';

  final TmdbHttpClient _http;
  final Map<String, Future<Object?>> _memo = {};

  (Uri, Uri?) _endpoints(String subPath, [Map<String, String>? query]) {
    final primaryBase = Uri.parse('${TmdbNetworkConfig.defaultBangumiApiBase}$subPath');
    final primary = query == null
        ? primaryBase
        : primaryBase.replace(queryParameters: query);

    final backupRaw = _http.config.normalizedBangumiBackupApiBase;
    Uri? backup;
    if (backupRaw.isNotEmpty) {
      final parsed = Uri.tryParse('$backupRaw$subPath');
      if (parsed != null) {
        backup = query == null ? parsed : parsed.replace(queryParameters: query);
      }
    }
    return (primary, backup);
  }

  /// 按关键词搜索 Bangumi 动画条目（`type: [2]`；发送前自动净化连字符消除 `-word` 排除陷阱）。
  Future<List<BangumiSubjectCandidate>> searchSubjects(
    String keyword, {
    RequestPriority priority = RequestPriority.background,
  }) async {
    final sanitized = SearchQuerySanitizer.sanitize(keyword);
    final trimmed = sanitized.isNotEmpty ? sanitized : keyword.trim();
    if (trimmed.isEmpty) return const [];

    final key = 'search:${trimmed.toLowerCase()}';
    final rawList = await _memoized(key, () async {
      final (primaryUri, backupUri) = _endpoints('/search/subjects');
      final response = await _http.postWithFallback(
        primaryUri,
        backupUri: backupUri,
        headers: _bgmHeaders,
        body: jsonEncode({
          'keyword': trimmed,
          'filter': {
            'type': [2],
          },
        }),
        priority: priority,
        dedupeKey: 'bgm:$key',
        bucketKey: _bangumiBucketKey,
      );
      if (response.statusCode != 200) {
        // 重定向（镜像迁址时 POST 不会被自动跟随）与服务端错误均视为检索失败而非“无结果”，
        // 交由调用方重试，避免整批作品静默丢失 Bangumi 匹配。
        if (response.statusCode >= 500 ||
            response.statusCode == 429 ||
            (response.statusCode >= 300 && response.statusCode < 400)) {
          throw StateError('Bangumi 搜索失败: HTTP ${response.statusCode}');
        }
        return const <Map<String, Object?>>[];
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return const <Map<String, Object?>>[];
      final data = decoded['data'];
      if (data is! List) return const <Map<String, Object?>>[];
      return data
          .whereType<Map>()
          .take(10)
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList(growable: false);
    });

    if (rawList is! List<Map<String, Object?>>) return const [];
    return [for (final row in rawList) _parseSubject(row)];
  }

  /// 多级渐进回退搜索 Bangumi（净化原词 -> 剥离第X部分/季后缀 -> 核心主词/副标题），按 `id` 去重合并。
  Future<List<BangumiSubjectCandidate>> searchSubjectsProgressive(
    String rawQuery, {
    RequestPriority priority = RequestPriority.interactive,
  }) async {
    final tiers = SearchQuerySanitizer.buildBangumiFallbackQueries(rawQuery);
    if (tiers.isEmpty) return const [];

    final merged = <int, BangumiSubjectCandidate>{};
    void collect(List<BangumiSubjectCandidate> hits) {
      for (final item in hits) {
        if (item.id > 0) merged.putIfAbsent(item.id, () => item);
      }
    }

    final firstHits = await searchSubjects(tiers.first, priority: priority);
    collect(firstHits);

    if (tiers.length >= 2) {
      final baseClean = SearchQuerySanitizer.sanitize(tiers[1]).toLowerCase();
      final hasExactBase = merged.values.any((item) {
        final cn = SearchQuerySanitizer.sanitize(item.nameCn).toLowerCase();
        final orig = SearchQuerySanitizer.sanitize(item.name).toLowerCase();
        return cn == baseClean || orig == baseClean;
      });
      if (merged.isEmpty || merged.length < 3 || !hasExactBase) {
        final secondHits = await searchSubjects(tiers[1], priority: priority);
        collect(secondHits);
      }
    }

    if (tiers.length > 2 && merged.length < 2) {
      for (final term in tiers.skip(2)) {
        final extraHits = await searchSubjects(term, priority: priority);
        collect(extraHits);
        if (merged.length >= 8) break;
      }
    }

    return merged.values.toList(growable: false);
  }

  /// 拉取单个 Bangumi 条目完整信息（含 `infobox` 别名、开播日期、封面大图与简介）。
  Future<BangumiSubjectCandidate?> getSubjectDetail(
    int subjectId, {
    RequestPriority priority = RequestPriority.background,
  }) async {
    if (subjectId <= 0) return null;
    final key = 'subject:$subjectId';
    final raw = await _memoized(key, () async {
      final (primaryUri, backupUri) = _endpoints('/subjects/$subjectId');
      final response = await _http.getWithFallback(
        primaryUri,
        backupUri: backupUri,
        headers: _bgmHeaders,
        priority: priority,
        dedupeKey: 'bgm:$key',
        bucketKey: _bangumiBucketKey,
      );
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) {
        throw StateError('Bangumi 条目拉取失败: HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    });

    if (raw is! Map<String, Object?> || raw['id'] == null) return null;
    return _parseSubject(raw);
  }

  /// 拉取指定 Bangumi 条目的分集标题与集号映射（`type=0` 正片，`type=1` SP，`null` 全部）。
  Future<List<BangumiEpisodeEntry>> getSubjectEpisodes(
    int subjectId, {
    int? type = 0,
    int limit = 100,
    RequestPriority priority = RequestPriority.background,
  }) async {
    if (subjectId <= 0) return const [];
    final key = 'episodes:$subjectId:${type ?? 'all'}:$limit';
    final raw = await _memoized(key, () async {
      final query = <String, String>{
        'subject_id': subjectId.toString(),
        'limit': limit.toString(),
        if (type != null) 'type': type.toString(),
      };
      final (primaryUri, backupUri) = _endpoints('/episodes', query);
      final response = await _http.getWithFallback(
        primaryUri,
        backupUri: backupUri,
        headers: _bgmHeaders,
        priority: priority,
        dedupeKey: 'bgm:$key',
        bucketKey: _bangumiBucketKey,
      );
      if (response.statusCode == 404) return const <Map<String, Object?>>[];
      if (response.statusCode != 200) return const <Map<String, Object?>>[];
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return const <Map<String, Object?>>[];
      final data = decoded['data'];
      if (data is! List) return const <Map<String, Object?>>[];
      return data
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList(growable: false);
    });

    if (raw is! List<Map<String, Object?>>) return const [];
    final out = <BangumiEpisodeEntry>[];
    for (final row in raw) {
      final id = (row['id'] as num?)?.toInt();
      if (id == null) continue;
      out.add(
        BangumiEpisodeEntry(
          id: id,
          ep: (row['ep'] as num?)?.toDouble(),
          sort: (row['sort'] as num?)?.toDouble(),
          type: (row['type'] as num?)?.toInt() ?? 0,
          name: (row['name'] ?? '').toString().trim(),
          nameCn: (row['name_cn'] ?? '').toString().trim(),
          airDate: _parseFullDate(row['airdate']),
        ),
      );
    }
    return out;
  }

  /// 查询关联条目列表（前传 / 续集 / 剧场版 / 番外篇等，用于分期分割识别与系列编组）。
  Future<List<BangumiRelatedSubject>> getRelatedSubjects(
    int subjectId, {
    RequestPriority priority = RequestPriority.background,
  }) async {
    if (subjectId <= 0) return const [];
    final key = 'related:$subjectId';
    final raw = await _memoized(key, () async {
      final (primaryUri, backupUri) = _endpoints('/subjects/$subjectId/subjects');
      final response = await _http.getWithFallback(
        primaryUri,
        backupUri: backupUri,
        headers: _bgmHeaders,
        priority: priority,
        dedupeKey: 'bgm:$key',
        bucketKey: _bangumiBucketKey,
      );
      if (response.statusCode != 200) return const <BangumiRelatedSubject>[];
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) return const <BangumiRelatedSubject>[];
      final items = <BangumiRelatedSubject>[];
      for (final item in decoded.whereType<Map>()) {
        final relation = (item['relation'] ?? '').toString().trim();
        final id = (item['id'] as num?)?.toInt();
        if (id != null && id > 0 && relation.isNotEmpty) {
          items.add(
            BangumiRelatedSubject(
              id: id,
              relation: relation,
              name: (item['name'] ?? '').toString().trim(),
              nameCn: (item['name_cn'] ?? '').toString().trim(),
            ),
          );
        }
      }
      return List<BangumiRelatedSubject>.unmodifiable(items);
    });
    return raw is List<BangumiRelatedSubject> ? raw : const [];
  }

  /// 查询续集条目 ID 列表（用于分割放送识别，不查询任何角色或制作人员接口）。
  Future<List<int>> getSequelSubjectIds(
    int subjectId, {
    RequestPriority priority = RequestPriority.background,
  }) async {
    final related = await getRelatedSubjects(subjectId, priority: priority);
    return [
      for (final item in related)
        if (item.relation == '续集') item.id,
    ];
  }

  /// 将 Bangumi 原始 JSON 对象解析为纯领域 `BangumiSubjectCandidate`。
  static BangumiSubjectCandidate parseSubjectJson(Map<String, Object?> row) =>
      _parseSubject(row);

  static BangumiSubjectCandidate _parseSubject(Map<String, Object?> row) {
    final id = (row['id'] as num?)?.toInt() ?? 0;
    final name = (row['name'] ?? '').toString().trim();
    final nameCn = (row['name_cn'] ?? '').toString().trim();
    final title = nameCn.isNotEmpty ? nameCn : name;

    final aliases = <String>[];
    final seenAlias = <String>{};
    void addAlias(String v) {
      final t = v.trim();
      if (t.isEmpty) return;
      if (seenAlias.add(t.toLowerCase())) aliases.add(t);
    }

    if (name.isNotEmpty) addAlias(name);
    if (nameCn.isNotEmpty) addAlias(nameCn);

    var airDate = _parseFullDate(row['date']);
    var year = _parseYear(row['date']);
    final platform = (row['platform'] ?? '').toString().trim();
    final platformLower = platform.toLowerCase();
    var isSpecialFormat = platformLower == 'ova' || platformLower == 'oad';

    final tags = row['tags'];
    if (!isSpecialFormat && tags is List) {
      for (final t in tags.whereType<Map>()) {
        final tName = (t['name'] ?? '').toString().trim().toLowerCase();
        if (tName == 'ova' || tName == 'oad') {
          isSpecialFormat = true;
          break;
        }
      }
    }

    final infobox = row['infobox'];
    if (infobox is List) {
      for (final item in infobox.whereType<Map>()) {
        final key = (item['key'] ?? '').toString().trim().toLowerCase();
        final value = item['value'];
        if (const {'别名', '中文名', 'alias', 'aliases'}.contains(key)) {
          if (value is String) {
            addAlias(value);
          } else if (value is List) {
            for (final v in value.whereType<Map>()) {
              final text = (v['v'] ?? '').toString();
              addAlias(text);
            }
          }
        } else if (key.contains('放送开始') ||
            key.contains('上映年度') ||
            key.contains('发售日')) {
          year ??= _parseYear(value);
          airDate ??= _parseFullDate(value);
        }
      }
    }

    if (!isSpecialFormat) {
      final ovaWord = RegExp(
        r'(?<![a-z0-9])(?:ova|oad)(?![a-z0-9])',
        caseSensitive: false,
      );
      isSpecialFormat = ovaWord.hasMatch(title) || aliases.any(ovaWord.hasMatch);
    }

    final eps =
        (row['total_episodes'] as num?)?.toInt() ??
        (row['eps'] as num?)?.toInt();
    double? score;
    final rating = row['rating'];
    if (rating is Map) {
      final rawScore = (rating['score'] as num?)?.toDouble();
      if (rawScore != null && rawScore > 0) {
        score = rawScore;
      }
    }

    return BangumiSubjectCandidate(
      id: id,
      name: name,
      nameCn: nameCn,
      year: year,
      airDate: airDate,
      totalEpisodes: eps,
      summary: _nonEmpty(row['summary']?.toString()),
      posterUrl: _extractPosterUrl(row['images']),
      score: score,
      aliases: List.unmodifiable(aliases),
      platform: platform.isEmpty ? null : platform,
      isSpecialFormat: isSpecialFormat,
    );
  }

  static String? _extractPosterUrl(Object? images) {
    if (images is! Map) return null;
    for (final key in const ['large', 'common', 'medium']) {
      final url = images[key]?.toString().trim();
      if (url != null && url.startsWith('https://')) {
        return url;
      }
    }
    return null;
  }

  static String? _parseFullDate(Object? raw) {
    if (raw == null) return null;
    final m = RegExp(
      r'((?:19|20)\d{2})\D+(\d{1,2})\D+(\d{1,2})',
    ).firstMatch(raw.toString());
    if (m == null) return null;
    final y = m.group(1)!;
    final mo = m.group(2)!.padLeft(2, '0');
    final d = m.group(3)!.padLeft(2, '0');
    return '$y-$mo-$d';
  }

  static int? _parseYear(Object? raw) {
    if (raw == null) return null;
    final m = RegExp(r'(19|20)\d{2}').firstMatch(raw.toString());
    return m == null ? null : int.tryParse(m.group(0)!);
  }

  static String? _nonEmpty(String? raw) {
    final trimmed = raw?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  Future<Object?> _memoized(String key, Future<Object?> Function() load) {
    if (_memo.containsKey(key)) return _memo[key]!;
    if (_memo.length >= _maxMemoEntries) {
      _memo.remove(_memo.keys.first);
    }
    final future = load().catchError((Object e) {
      _memo.remove(key);
      throw e;
    });
    _memo[key] = future;
    return future;
  }
}
