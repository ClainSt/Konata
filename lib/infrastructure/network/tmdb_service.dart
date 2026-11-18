import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/models/network_config.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/search_query_sanitizer.dart';
import '../cache/artwork_cache.dart';
import '../cache/photos_storage.dart';
import 'priority_http_scheduler.dart';
import 'tmdb_http_client.dart';

/// TMDB API 强类型业务客户端（支持 v3 Key / v4 Bearer 双凭证、详情聚合与图片缓存）。
class TmdbService {
  /// 创建 TMDB 服务实例。
  TmdbService({required TmdbHttpClient httpClient, this._artworkCache})
    : _http = httpClient;

  final TmdbHttpClient _http;
  final ArtworkCache? _artworkCache;

  /// 在指定的优先级通道检索 TMDB 候选（支持通过 [mediaTypeFilter] 限定仅查 `/search/tv` 或 `/search/movie`）。
  Future<List<TmdbSearchResult>> searchAnime(
    String query, {
    int? year,
    String language = 'zh-CN',
    bool includeAdult = false,
    TmdbMediaType? mediaTypeFilter,
    RequestPriority priority = RequestPriority.interactive,
  }) async {
    final sanitized = SearchQuerySanitizer.sanitize(query);
    final trimmed = sanitized.isNotEmpty ? sanitized : query.trim();
    if (trimmed.isEmpty) return const [];

    final tvParams = <String, String>{
      'query': trimmed,
      'language': language,
      'include_adult': includeAdult.toString(),
      if (year != null) 'first_air_date_year': year.toString(),
    };
    final movieParams = <String, String>{
      'query': trimmed,
      'language': language,
      'include_adult': includeAdult.toString(),
      if (year != null) 'primary_release_year': year.toString(),
    };

    final merged = <TmdbSearchResult>[];
    if (mediaTypeFilter == TmdbMediaType.tv) {
      final tvBody = await _getJson('/search/tv', tvParams, priority: priority);
      _parseSearchList(tvBody, TmdbMediaType.tv, merged);
      return merged;
    }
    if (mediaTypeFilter == TmdbMediaType.movie) {
      final movieBody = await _getJson(
        '/search/movie',
        movieParams,
        priority: priority,
      );
      _parseSearchList(movieBody, TmdbMediaType.movie, merged);
      return merged;
    }

    final results = await Future.wait([
      _getJson('/search/tv', tvParams, priority: priority),
      _getJson('/search/movie', movieParams, priority: priority),
    ]);

    _parseSearchList(results[0], TmdbMediaType.tv, merged);
    _parseSearchList(results[1], TmdbMediaType.movie, merged);
    return merged;
  }

  /// 一次性拉取作品详情、别名、多语言翻译、演职员表与季列表。
  Future<TmdbWorkDetail?> getWorkDetail(
    int tmdbId,
    TmdbMediaType mediaType, {
    RequestPriority priority = RequestPriority.background,
    bool includeEnglishImages = false,
  }) async {
    final segment = mediaType == TmdbMediaType.tv ? 'tv' : 'movie';
    final json = await _getJson('/$segment/$tmdbId', {
      'language': 'zh-CN',
      'append_to_response': 'alternative_titles,translations,images',
      'include_image_language': includeEnglishImages
          ? 'zh,ja,en,null'
          : 'zh,ja,null',
    }, priority: priority);
    if (json == null || json['id'] == null) return null;

    final title = _pickString(json, ['name', 'title']) ?? '';
    final original = _pickString(json, ['original_name', 'original_title']);
    final year = _parseYear(json['first_air_date'] ?? json['release_date']);

    final aliases = <String>{};
    if (original != null && original.isNotEmpty) aliases.add(original);
    _collectAliases(json, aliases);

    final seasons = <TmdbSeasonSummary>[];
    final rawSeasons = json['seasons'];
    if (mediaType == TmdbMediaType.tv && rawSeasons is List) {
      for (final item in rawSeasons) {
        if (item is! Map) continue;
        final sNum = (item['season_number'] as num?)?.toInt();
        if (sNum == null || sNum < 0) continue;
        seasons.add(
          TmdbSeasonSummary(
            seasonNumber: sNum,
            name: (item['name'] ?? 'Season $sNum').toString(),
            episodeCount: (item['episode_count'] as num?)?.toInt() ?? 0,
            airDate: item['air_date']?.toString(),
            posterPath: item['poster_path']?.toString(),
          ),
        );
      }
    }

    final logoPath = _selectBestLogoPath(
      json,
      tmdbId: tmdbId,
      mediaType: mediaType,
    );
    final voteAverage = (json['vote_average'] as num?)?.toDouble();
    final candidatePosters = _extractImageOptions(json, 'posters');
    final candidateBackdrops = _extractImageOptions(json, 'backdrops');
    final candidateLogos = _extractImageOptions(json, 'logos');
    final preferredBackdrop =
        candidateBackdrops.isNotEmpty &&
            (candidateBackdrops.first.width ?? 0) >= 1920
        ? candidateBackdrops.first.filePath
        : json['backdrop_path']?.toString();
    final rawCollection = json['belongs_to_collection'];
    int? collectionId;
    String? collectionName;
    if (rawCollection is Map) {
      collectionId = (rawCollection['id'] as num?)?.toInt();
      final rawName = rawCollection['name']?.toString().trim();
      if (rawName != null && rawName.isNotEmpty) {
        collectionName = rawName;
      }
    }
    final detailGenres = _parseDetailGenreIds(json);

    return TmdbWorkDetail(
      tmdbId: (json['id'] as num).toInt(),
      mediaType: mediaType,
      title: title.isNotEmpty ? title : (original ?? 'TMDB #$tmdbId'),
      originalTitle: original,
      year: year,
      overview: json['overview']?.toString(),
      posterPath: json['poster_path']?.toString(),
      backdropPath: preferredBackdrop,
      logoPath: logoPath,
      voteAverage: voteAverage,
      aliases: aliases.toList(growable: false),
      seasons: seasons,
      candidatePosters: candidatePosters,
      candidateBackdrops: candidateBackdrops,
      candidateLogos: candidateLogos,
      collectionId: collectionId,
      collectionName: collectionName,
      genreIds: detailGenres,
    );
  }

  /// 拉取单季完整详情（包含季标题、简介、单季专属海报与分集列表）。
  Future<TmdbSeasonDetail?> getSeasonDetail(
    int tmdbId,
    int seasonNumber, {
    RequestPriority priority = RequestPriority.background,
  }) async {
    final json = await _getJson('/tv/$tmdbId/season/$seasonNumber', const {
      'language': 'zh-CN',
    }, priority: priority);
    if (json == null) return null;

    final list = <TmdbEpisodeDetail>[];
    final rawEpisodes = json['episodes'];
    if (rawEpisodes is List) {
      for (final item in rawEpisodes) {
        if (item is! Map) continue;
        final epNum = (item['episode_number'] as num?)?.toInt();
        if (epNum == null) continue;
        list.add(
          TmdbEpisodeDetail(
            seasonNumber: seasonNumber,
            episodeNumber: epNum,
            title: (item['name'] ?? '第 $epNum 集').toString(),
            overview: item['overview']?.toString(),
            stillPath: item['still_path']?.toString(),
            airDate: item['air_date']?.toString(),
          ),
        );
      }
    }

    return TmdbSeasonDetail(
      seasonNumber: seasonNumber,
      name: (json['name'] ?? 'Season $seasonNumber').toString(),
      overview: json['overview']?.toString(),
      airDate: json['air_date']?.toString(),
      posterPath: json['poster_path']?.toString(),
      episodes: list,
    );
  }

  /// 拉取单季分集列表与剧照路径。
  Future<List<TmdbEpisodeDetail>> getSeasonEpisodes(
    int tmdbId,
    int seasonNumber, {
    RequestPriority priority = RequestPriority.background,
  }) async {
    final detail = await getSeasonDetail(
      tmdbId,
      seasonNumber,
      priority: priority,
    );
    return detail?.episodes ?? const [];
  }

  /// 按目标像素宽度或显式档位选择 TMDB 图片（或加载自定义 URL / 本地文件）拉取并写入隔离缓存。
  Future<Uint8List> fetchImageBytes(
    String imagePath, {
    TmdbImageSize? size,
    int? targetWidth,
    String? ownerWorkId,
    PhotoSubfolder? subfolder,
    RequestPriority priority = RequestPriority.interactive,
  }) async {
    final trimmed = imagePath.trim();
    if (trimmed.isEmpty) return Uint8List(0);

    // 1. 支持自定义 HTTP/HTTPS 图片链接（含官方域名 -> 备用图片镜像自动回退）
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final cacheKey = 'url:$trimmed';
      final cached = await _artworkCache?.read(
        cacheKey,
        owner: ownerWorkId,
        subfolder: subfolder,
      );
      if (cached != null) return cached;
      final primaryUri = Uri.parse(trimmed);
      final backupUri = _resolveBackupImageUrl(primaryUri);
      final response = await _http.getWithFallback(
        primaryUri,
        backupUri: backupUri,
        priority: priority,
      );
      if (response.statusCode != 200) {
        throw StateError('图片加载失败: HTTP ${response.statusCode}');
      }
      await _artworkCache?.write(
        cacheKey,
        response.bodyBytes,
        owner: ownerWorkId,
        subfolder: subfolder,
      );
      return response.bodyBytes;
    }

    // 2. 支持本地磁盘图片（如 `C:\...` 或 `file:///...`）
    final localPath = trimmed.startsWith('file://')
        ? Uri.parse(trimmed).toFilePath()
        : trimmed;
    final isWindowsAbs = RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(localPath);
    if (isWindowsAbs || !localPath.startsWith('/')) {
      final localFile = File(localPath);
      if (await localFile.exists()) {
        return localFile.readAsBytes();
      }
    } else if (await File(localPath).exists()) {
      return File(localPath).readAsBytes();
    }

    // 3. 标准 TMDB 相对路径（官方优先 + 备用地址自动回退，并按尺寸档位与质量隔离缓存）
    final effectiveSize = resolveImageSize(size: size, targetWidth: targetWidth);
    final normalizedPath = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    final cacheKey = ArtworkCache.buildSizedKey(effectiveSize, normalizedPath);

    final cached = await _artworkCache?.read(
      cacheKey,
      minimumQuality: effectiveSize.qualityRank,
      owner: ownerWorkId,
      subfolder: subfolder,
    );
    if (cached != null) return cached;

    final primaryUri = Uri.parse(
      '${TmdbNetworkConfig.defaultImageBase}/${effectiveSize.apiSegment}$normalizedPath',
    );
    final backupBase = _http.config.normalizedTmdbBackupImageBase;
    final backupUri = backupBase.isNotEmpty
        ? Uri.tryParse('$backupBase/${effectiveSize.apiSegment}$normalizedPath')
        : null;
    final response = await _http.getWithFallback(
      primaryUri,
      backupUri: backupUri,
      priority: priority,
    );
    if (response.statusCode != 200) {
      throw StateError('图片加载失败: HTTP ${response.statusCode}');
    }
    final bytes = response.bodyBytes;
    await _artworkCache?.write(
      cacheKey,
      bytes,
      owner: ownerWorkId,
      quality: effectiveSize.qualityRank,
      subfolder: subfolder,
    );
    return bytes;
  }

  Uri? _resolveBackupImageUrl(Uri primary) {
    final host = primary.host.toLowerCase();
    if (host == 'lain.bgm.tv') {
      final backupBase = _http.config.normalizedBangumiBackupImageBase;
      if (backupBase.isEmpty) return null;
      return Uri.tryParse(
        '$backupBase${primary.path}${primary.hasQuery ? '?${primary.query}' : ''}',
      );
    }
    if (host == 'image.tmdb.org') {
      final backupBase = _http.config.normalizedTmdbBackupImageBase;
      if (backupBase.isEmpty) return null;
      const officialPrefix = '/t/p';
      final suffix = primary.path.startsWith(officialPrefix)
          ? primary.path.substring(officialPrefix.length)
          : primary.path;
      return Uri.tryParse(
        '$backupBase$suffix${primary.hasQuery ? '?${primary.query}' : ''}',
      );
    }
    return null;
  }

  /// 根据显式尺寸档位或目标渲染像素宽度解析 TMDB 图片档位。
  static TmdbImageSize resolveImageSize({
    TmdbImageSize? size,
    int? targetWidth,
  }) {
    if (size != null) return size;
    if (targetWidth == null || targetWidth <= 0) return TmdbImageSize.w500;
    if (targetWidth <= 360) return TmdbImageSize.w342;
    if (targetWidth <= 540) return TmdbImageSize.w500;
    if (targetWidth <= 900) return TmdbImageSize.w780;
    if (targetWidth <= 1360) return TmdbImageSize.w1280;
    return TmdbImageSize.original;
  }

  Future<Map<String, Object?>?> _getJson(
    String path,
    Map<String, String> query, {
    required RequestPriority priority,
  }) async {
    final primaryBase = Uri.parse('${TmdbNetworkConfig.defaultApiBase}$path');
    final finalQuery = <String, String>{...primaryBase.queryParameters, ...query};
    final headers = <String, String>{};

    switch (_http.config.credentialKind) {
      case TmdbCredentialKind.v3ApiKey:
        finalQuery['api_key'] = _http.config.credential.trim();
      case TmdbCredentialKind.v4BearerToken:
        headers['Authorization'] = 'Bearer ${_http.config.credential.trim()}';
      case TmdbCredentialKind.none:
        break;
    }

    final primaryUri = primaryBase.replace(queryParameters: finalQuery);
    final backupRaw = _http.config.normalizedTmdbBackupApiBase;
    final backupUri = backupRaw.isNotEmpty
        ? Uri.tryParse('$backupRaw$path')?.replace(queryParameters: finalQuery)
        : null;

    final response = await _http.getWithFallback(
      primaryUri,
      backupUri: backupUri,
      headers: headers,
      priority: priority,
      dedupeKey: '$path?${Uri(queryParameters: query).query}',
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('TMDB 请求失败: HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return null;
    return decoded.map((k, v) => MapEntry(k.toString(), v));
  }

  List<int> _parseGenreIdList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final g in raw)
        if (g is num) g.toInt(),
    ];
  }

  List<int> _parseDetailGenreIds(Map<String, Object?> json) {
    final direct = _parseGenreIdList(json['genre_ids']);
    if (direct.isNotEmpty) return direct;
    final rawGenres = json['genres'];
    if (rawGenres is! List) return const [];
    return [
      for (final g in rawGenres)
        if (g is Map && g['id'] is num) (g['id'] as num).toInt(),
    ];
  }

  void _parseSearchList(
    Map<String, Object?>? body,
    TmdbMediaType type,
    List<TmdbSearchResult> out,
  ) {
    final raw = body?['results'];
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final id = (item['id'] as num?)?.toInt();
      if (id == null) continue;
      final title = _pickString(item, ['name', 'title']) ?? '';
      final original = _pickString(item, ['original_name', 'original_title']);
      out.add(
        TmdbSearchResult(
          tmdbId: id,
          mediaType: type,
          title: title.isNotEmpty ? title : (original ?? 'TMDB #$id'),
          originalTitle: original,
          year: _parseYear(item['first_air_date'] ?? item['release_date']),
          overview: item['overview']?.toString(),
          posterPath: item['poster_path']?.toString(),
          backdropPath: item['backdrop_path']?.toString(),
          genreIds: _parseGenreIdList(item['genre_ids']),
        ),
      );
    }
  }

  void _collectAliases(Map<String, Object?> json, Set<String> out) {
    final alt = json['alternative_titles'];
    if (alt is Map) {
      final list = alt['results'] ?? alt['titles'];
      if (list is List) {
        for (final item in list) {
          if (item is Map && item['title'] != null) {
            final t = item['title'].toString().trim();
            if (t.isNotEmpty) out.add(t);
          }
        }
      }
    }
    final trans = json['translations'];
    if (trans is Map && trans['translations'] is List) {
      for (final item in trans['translations'] as List) {
        if (item is! Map) continue;
        final iso = item['iso_639_1']?.toString();
        if (iso != 'zh' && iso != 'ja' && iso != 'en') continue;
        final data = item['data'];
        if (data is Map) {
          final t = _pickString(data, ['name', 'title']);
          if (t != null && t.isNotEmpty) out.add(t);
        }
      }
    }
  }

  /// 已知被社区误上传到 TV 主条目、实际属于同名剧场版副标题的透明 Logo 纠偏映射表。
  ///
  /// 键为 TV 条目 TMDB ID，值为 `{误挂路径: 实际所属剧场版 TMDB ID}`。
  static const Map<int, Map<String, int>> tmdbMistaggedTvLogoTargets = {
    // 《加速世界》TV (43167) 名下被误传的《INFINITE∞BURST》剧场版 (381873) 标题徽标
    43167: {'/wsQCRIHeVQJlO0MgU2oA3z6hgQd.png': 381873},
  };

  static String? _selectBestLogoPath(
    Map<String, Object?> json, {
    int? tmdbId,
    TmdbMediaType? mediaType,
  }) {
    final images = json['images'];
    if (images is! Map) return null;
    final logos = images['logos'];
    if (logos is! List || logos.isEmpty) return null;

    final mistaggedForTv = mediaType == TmdbMediaType.tv && tmdbId != null
        ? tmdbMistaggedTvLogoTargets[tmdbId]
        : null;

    int langPriority(String? iso) {
      if (iso == 'zh') return 0;
      if (iso == 'ja') return 1;
      if (iso == null || iso.isEmpty) return 2;
      return 3;
    }

    Map<dynamic, dynamic>? best;
    var bestLangRank = 99;
    var bestVote = -1.0;

    for (final item in logos) {
      if (item is! Map) continue;
      final path = item['file_path']?.toString();
      if (path == null || path.isEmpty) continue;
      if (mistaggedForTv != null && mistaggedForTv.containsKey(path)) {
        continue;
      }
      // 优先选择有投票背书的透明 PNG
      final isPng = path.toLowerCase().endsWith('.png');
      final voteCount = (item['vote_count'] as num?)?.toInt();
      final rank = langPriority(item['iso_639_1']?.toString());
      final vote = ((item['vote_average'] as num?)?.toDouble() ?? 0.0) +
          (isPng ? 0.5 : 0.0) +
          ((voteCount ?? 1) > 0 ? 0.25 : 0.0);
      if (rank < bestLangRank || (rank == bestLangRank && vote > bestVote)) {
        bestLangRank = rank;
        bestVote = vote;
        best = item;
      }
    }
    return best?['file_path']?.toString();
  }

  static List<TmdbArtworkImage> _extractImageOptions(
    Map<String, Object?> json,
    String key,
  ) {
    final images = json['images'];
    if (images is! Map) return const [];
    final list = images[key];
    if (list is! List || list.isEmpty) return const [];

    final parsed = <TmdbArtworkImage>[];
    for (final item in list) {
      if (item is! Map) continue;
      final path = item['file_path']?.toString();
      if (path == null || path.isEmpty) continue;
      parsed.add(
        TmdbArtworkImage(
          filePath: path,
          isoLanguage: item['iso_639_1']?.toString(),
          width: (item['width'] as num?)?.toInt(),
          height: (item['height'] as num?)?.toInt(),
          voteAverage: (item['vote_average'] as num?)?.toDouble(),
          voteCount: (item['vote_count'] as num?)?.toInt(),
        ),
      );
    }

    int langScore(String? iso) {
      if (iso == 'zh') return 0;
      if (iso == 'ja') return 1;
      if (iso == null || iso.isEmpty) return 2;
      if (iso == 'en') return 3;
      return 4;
    }

    parsed.sort((a, b) {
      if (key == 'backdrops') {
        final aFullHd = (a.width ?? 0) >= 1920 ? 0 : 1;
        final bFullHd = (b.width ?? 0) >= 1920 ? 0 : 1;
        if (aFullHd != bFullHd) return aFullHd.compareTo(bFullHd);
      }
      final lc = langScore(a.isoLanguage).compareTo(langScore(b.isoLanguage));
      if (lc != 0) return lc;
      return (b.voteAverage ?? 0).compareTo(a.voteAverage ?? 0);
    });
    return parsed.take(24).toList(growable: false);
  }

  static String? _pickString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k]?.toString().trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  static int? _parseYear(Object? raw) {
    if (raw == null) return null;
    final m = RegExp(r'(19|20)\d{2}').firstMatch(raw.toString());
    return m == null ? null : int.tryParse(m.group(0)!);
  }
}
