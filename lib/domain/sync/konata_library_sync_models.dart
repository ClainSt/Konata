import '../models/episode.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/series_group.dart';
import '../models/work.dart';

/// 可跨设备同步与备份的媒体源元数据条目（严格不含密码，密码仅由各设备安全存储独立保管）。
class SyncMediaSourceEntry {
  /// 创建可同步媒体源条目。
  const SyncMediaSourceEntry({
    required this.id,
    required this.kind,
    required this.label,
    required this.location,
    this.username,
    this.createdAtMs,
  });

  /// 从领域实体 [MediaSource] 构造同步条目。
  factory SyncMediaSourceEntry.fromMediaSource(MediaSource source) {
    return SyncMediaSourceEntry(
      id: source.id,
      kind: source.kind,
      label: source.label,
      location: source.location,
      username: source.username,
      createdAtMs: source.createdAt?.millisecondsSinceEpoch,
    );
  }

  final String id;
  final MediaSourceKind kind;
  final String label;
  final String location;
  final String? username;
  final int? createdAtMs;

  /// 是否为带用户名的远程媒体源（在新设备首次导入时可能需要用户补填密码）。
  bool get isRemoteWithUsername =>
      kind != MediaSourceKind.local && (username?.trim().isNotEmpty ?? false);

  /// 生成用于跨设备媒体源去重对齐的归一化定位键。
  String get normalizedLocationKey => normalizeLocationKey(kind, location);

  /// 归一化媒体源协议与地址（消除尾斜杠、反斜杠与主机大小写差异）。
  static String normalizeLocationKey(MediaSourceKind kind, String rawLocation) {
    final trimmed = rawLocation.trim();
    if (kind == MediaSourceKind.local) {
      final slash = trimmed
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'/+$'), '');
      final lower = isWindowsAbsolutePath(slash) ? slash.toLowerCase() : slash;
      return '${kind.name}::$lower';
    }
    final normalized = trimmed
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri != null && uri.scheme.isNotEmpty && uri.host.isNotEmpty) {
      final portPart = uri.hasPort ? ':${uri.port}' : '';
      final pathPart = uri.path.replaceAll(RegExp(r'/+$'), '');
      return '${kind.name}::${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}$portPart$pathPart';
    }
    return '${kind.name}::${normalized.toLowerCase()}';
  }

  /// 判断路径是否为 Windows 盘符绝对路径（如 `D:\Anime` 或 `D:/Anime`）。
  static bool isWindowsAbsolutePath(String rawPath) {
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(rawPath.trim());
  }

  /// 还原为领域实体 [MediaSource]。
  MediaSource toMediaSource({String? overrideId}) {
    return MediaSource(
      id: overrideId ?? id,
      kind: kind,
      label: label,
      location: location,
      username: username,
      createdAt: createdAtMs != null && createdAtMs! > 0
          ? DateTime.fromMillisecondsSinceEpoch(createdAtMs!)
          : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'label': label,
    'location': location,
    if (username != null && username!.isNotEmpty) 'username': username,
    if (createdAtMs != null && createdAtMs! > 0) 'createdAtMs': createdAtMs,
  };

  factory SyncMediaSourceEntry.fromJson(Map<String, Object?> json) {
    final rawKind = (json['kind'] ?? '').toString();
    final kind = MediaSourceKind.values.firstWhere(
      (k) => k.name == rawKind,
      orElse: () => MediaSourceKind.local,
    );
    return SyncMediaSourceEntry(
      id: (json['id'] ?? '').toString(),
      kind: kind,
      label: (json['label'] ?? '').toString(),
      location: (json['location'] ?? '').toString(),
      username: json['username']?.toString(),
      createdAtMs: (json['createdAtMs'] as num?)?.toInt(),
    );
  }
}

/// 可跨设备同步与备份的系列编组条目。
class SyncSeriesGroupEntry {
  /// 创建可同步系列编组条目。
  const SyncSeriesGroupEntry({
    required this.id,
    required this.title,
    this.tmdbCollectionId,
    this.rootFolderHint,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  /// 从领域实体 [SeriesGroup] 构造同步条目。
  factory SyncSeriesGroupEntry.fromSeriesGroup(SeriesGroup group) {
    return SyncSeriesGroupEntry(
      id: group.id,
      title: group.title,
      tmdbCollectionId: group.tmdbCollectionId,
      rootFolderHint: group.rootFolderHint,
      createdAtMs: group.createdAt.millisecondsSinceEpoch,
      updatedAtMs: group.updatedAt.millisecondsSinceEpoch,
    );
  }

  final String id;
  final String title;
  final int? tmdbCollectionId;
  final String? rootFolderHint;
  final int createdAtMs;
  final int updatedAtMs;

  /// 还原为领域实体 [SeriesGroup]。
  SeriesGroup toSeriesGroup({String? overrideId}) {
    final now = DateTime.now();
    return SeriesGroup(
      id: overrideId ?? id,
      title: title,
      tmdbCollectionId: tmdbCollectionId,
      rootFolderHint: rootFolderHint,
      createdAt: createdAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(createdAtMs)
          : now,
      updatedAt: updatedAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(updatedAtMs)
          : now,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    if (tmdbCollectionId != null) 'tmdbCollectionId': tmdbCollectionId,
    if (rootFolderHint != null && rootFolderHint!.isNotEmpty)
      'rootFolderHint': rootFolderHint,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory SyncSeriesGroupEntry.fromJson(Map<String, Object?> json) {
    return SyncSeriesGroupEntry(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      tmdbCollectionId: (json['tmdbCollectionId'] as num?)?.toInt(),
      rootFolderHint: json['rootFolderHint']?.toString(),
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 可跨设备同步与备份的完整作品元数据条目（覆盖匹配、海报地址、评分、系列与全部人工锁）。
class SyncWorkEntry {
  /// 创建可同步完整作品条目。
  const SyncWorkEntry({
    required this.id,
    required this.canonicalWorkKey,
    this.secondaryWorkKeys = const <String>[],
    required this.title,
    this.tmdbId,
    this.tmdbMediaType,
    this.bangumiId,
    this.tvdbId,
    this.matchedSeason,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterPath,
    this.posterFallback,
    this.bangumiPosterPath,
    this.backdropPath,
    this.logoPath,
    this.voteAverage,
    this.bangumiScore,
    this.folderTmdbHint,
    this.isManualLocked = false,
    this.metadataLocked = false,
    this.posterLocked = false,
    this.backdropLocked = false,
    this.logoLocked = false,
    this.isHidden = false,
    this.keepHidden = false,
    this.scrapeStatus = ScrapeStatus.unmatched,
    this.reviewReason,
    this.seriesId,
    this.seriesOrder,
    this.seriesLabel,
    this.seriesLocked = false,
    required this.updatedAtMs,
    this.sourceDeviceId = '',
  });

  /// 从领域实体 [Work] 构造同步条目。
  factory SyncWorkEntry.fromWork({
    required Work work,
    required String canonicalWorkKey,
    required List<String> secondaryWorkKeys,
    required int updatedAtMs,
    required String sourceDeviceId,
  }) {
    return SyncWorkEntry(
      id: work.id,
      canonicalWorkKey: canonicalWorkKey,
      secondaryWorkKeys: secondaryWorkKeys,
      title: work.title,
      tmdbId: work.tmdbId,
      tmdbMediaType: work.tmdbMediaType,
      bangumiId: work.bangumiId,
      tvdbId: work.tvdbId,
      matchedSeason: work.matchedSeason,
      originalTitle: work.originalTitle,
      year: work.year,
      overview: work.overview,
      posterPath: work.posterPath,
      posterFallback: work.posterFallback,
      bangumiPosterPath: work.bangumiPosterPath,
      backdropPath: work.backdropPath,
      logoPath: work.logoPath,
      voteAverage: work.voteAverage,
      bangumiScore: work.bangumiScore,
      folderTmdbHint: work.folderTmdbHint,
      isManualLocked: work.isManualLocked,
      metadataLocked: work.metadataLocked,
      posterLocked: work.posterLocked,
      backdropLocked: work.backdropLocked,
      logoLocked: work.logoLocked,
      isHidden: work.isHidden,
      keepHidden: work.keepHidden,
      scrapeStatus: work.scrapeStatus,
      reviewReason: work.reviewReason,
      seriesId: work.seriesId,
      seriesOrder: work.seriesOrder,
      seriesLabel: work.seriesLabel,
      seriesLocked: work.seriesLocked,
      updatedAtMs: updatedAtMs,
      sourceDeviceId: sourceDeviceId,
    );
  }

  final String id;
  final String canonicalWorkKey;
  final List<String> secondaryWorkKeys;
  final String title;
  final int? tmdbId;
  final TmdbMediaType? tmdbMediaType;
  final int? bangumiId;
  final int? tvdbId;
  final int? matchedSeason;
  final String? originalTitle;
  final int? year;
  final String? overview;
  final String? posterPath;
  final String? posterFallback;
  final String? bangumiPosterPath;
  final String? backdropPath;
  final String? logoPath;
  final double? voteAverage;
  final double? bangumiScore;
  final int? folderTmdbHint;
  final bool isManualLocked;
  final bool metadataLocked;
  final bool posterLocked;
  final bool backdropLocked;
  final bool logoLocked;
  final bool isHidden;
  final bool keepHidden;
  final ScrapeStatus scrapeStatus;
  final String? reviewReason;
  final String? seriesId;
  final int? seriesOrder;
  final String? seriesLabel;
  final bool seriesLocked;
  final int updatedAtMs;
  final String sourceDeviceId;

  /// 全部可用于跨设备对齐的身份键。
  Iterable<String> get allWorkKeys sync* {
    if (canonicalWorkKey.isNotEmpty) yield canonicalWorkKey;
    yield* secondaryWorkKeys;
  }

  /// 复制并替换标识或关联字段。
  SyncWorkEntry copyWith({
    String? id,
    String? canonicalWorkKey,
    List<String>? secondaryWorkKeys,
    String? seriesId,
    bool clearSeriesId = false,
    bool? isManualLocked,
    bool? metadataLocked,
    bool? posterLocked,
    bool? backdropLocked,
    bool? logoLocked,
    bool? seriesLocked,
    int? updatedAtMs,
  }) {
    return SyncWorkEntry(
      id: id ?? this.id,
      canonicalWorkKey: canonicalWorkKey ?? this.canonicalWorkKey,
      secondaryWorkKeys: secondaryWorkKeys ?? this.secondaryWorkKeys,
      title: title,
      tmdbId: tmdbId,
      tmdbMediaType: tmdbMediaType,
      bangumiId: bangumiId,
      tvdbId: tvdbId,
      matchedSeason: matchedSeason,
      originalTitle: originalTitle,
      year: year,
      overview: overview,
      posterPath: posterPath,
      posterFallback: posterFallback,
      bangumiPosterPath: bangumiPosterPath,
      backdropPath: backdropPath,
      logoPath: logoPath,
      voteAverage: voteAverage,
      bangumiScore: bangumiScore,
      folderTmdbHint: folderTmdbHint,
      isManualLocked: isManualLocked ?? this.isManualLocked,
      metadataLocked: metadataLocked ?? this.metadataLocked,
      posterLocked: posterLocked ?? this.posterLocked,
      backdropLocked: backdropLocked ?? this.backdropLocked,
      logoLocked: logoLocked ?? this.logoLocked,
      isHidden: isHidden,
      keepHidden: keepHidden,
      scrapeStatus: scrapeStatus,
      reviewReason: reviewReason,
      seriesId: clearSeriesId ? null : (seriesId ?? this.seriesId),
      seriesOrder: seriesOrder,
      seriesLabel: seriesLabel,
      seriesLocked: seriesLocked ?? this.seriesLocked,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      sourceDeviceId: sourceDeviceId,
    );
  }

  /// 还原为领域实体 [Work]（当跨平台导入非本机盘符本地图片路径时自动回落至远程海报地址）。
  Work toWork({
    String? overrideId,
    String? overrideSeriesId,
    bool sanitizeWindowsLocalArtworkPaths = false,
  }) {
    String? cleanArt(String? raw, {String? fallback1, String? fallback2}) {
      if (raw == null || raw.isEmpty) return raw;
      if (sanitizeWindowsLocalArtworkPaths &&
          SyncMediaSourceEntry.isWindowsAbsolutePath(raw)) {
        if (fallback1 != null &&
            fallback1.isNotEmpty &&
            !SyncMediaSourceEntry.isWindowsAbsolutePath(fallback1)) {
          return fallback1;
        }
        if (fallback2 != null &&
            fallback2.isNotEmpty &&
            !SyncMediaSourceEntry.isWindowsAbsolutePath(fallback2)) {
          return fallback2;
        }
        return null;
      }
      return raw;
    }

    final safePosterFallback = cleanArt(posterFallback);
    final safeBangumiPoster = cleanArt(bangumiPosterPath);
    final safePoster = cleanArt(
      posterPath,
      fallback1: safePosterFallback,
      fallback2: safeBangumiPoster,
    );
    return Work(
      id: overrideId ?? id,
      tmdbId: tmdbId,
      tmdbMediaType: tmdbMediaType,
      bangumiId: bangumiId,
      tvdbId: tvdbId,
      matchedSeason: matchedSeason,
      title: title,
      originalTitle: originalTitle,
      year: year,
      overview: overview,
      posterPath: safePoster,
      posterFallback: safePosterFallback,
      bangumiPosterPath: safeBangumiPoster,
      backdropPath: cleanArt(backdropPath),
      logoPath: cleanArt(logoPath),
      voteAverage: voteAverage,
      bangumiScore: bangumiScore,
      folderTmdbHint: folderTmdbHint,
      isManualLocked: isManualLocked,
      metadataLocked: metadataLocked,
      posterLocked: posterLocked,
      backdropLocked: backdropLocked,
      logoLocked: logoLocked,
      isHidden: isHidden,
      keepHidden: keepHidden,
      scrapeStatus: scrapeStatus,
      reviewReason: reviewReason,
      seriesId: overrideSeriesId ?? seriesId,
      seriesOrder: seriesOrder,
      seriesLabel: seriesLabel,
      seriesLocked: seriesLocked,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'canonicalWorkKey': canonicalWorkKey,
    if (secondaryWorkKeys.isNotEmpty) 'secondaryWorkKeys': secondaryWorkKeys,
    'title': title,
    if (tmdbId != null) 'tmdbId': tmdbId,
    if (tmdbMediaType != null) 'tmdbMediaType': tmdbMediaType!.name,
    if (bangumiId != null) 'bangumiId': bangumiId,
    if (tvdbId != null) 'tvdbId': tvdbId,
    if (matchedSeason != null) 'matchedSeason': matchedSeason,
    if (originalTitle != null) 'originalTitle': originalTitle,
    if (year != null) 'year': year,
    if (overview != null) 'overview': overview,
    if (posterPath != null) 'posterPath': posterPath,
    if (posterFallback != null) 'posterFallback': posterFallback,
    if (bangumiPosterPath != null) 'bangumiPosterPath': bangumiPosterPath,
    if (backdropPath != null) 'backdropPath': backdropPath,
    if (logoPath != null) 'logoPath': logoPath,
    if (voteAverage != null) 'voteAverage': voteAverage,
    if (bangumiScore != null) 'bangumiScore': bangumiScore,
    if (folderTmdbHint != null) 'folderTmdbHint': folderTmdbHint,
    if (isManualLocked) 'isManualLocked': true,
    if (metadataLocked) 'metadataLocked': true,
    if (posterLocked) 'posterLocked': true,
    if (backdropLocked) 'backdropLocked': true,
    if (logoLocked) 'logoLocked': true,
    if (isHidden) 'isHidden': true,
    if (keepHidden) 'keepHidden': true,
    'scrapeStatus': scrapeStatus.name,
    if (reviewReason != null) 'reviewReason': reviewReason,
    if (seriesId != null) 'seriesId': seriesId,
    if (seriesOrder != null) 'seriesOrder': seriesOrder,
    if (seriesLabel != null) 'seriesLabel': seriesLabel,
    if (seriesLocked) 'seriesLocked': true,
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
  };

  factory SyncWorkEntry.fromJson(Map<String, Object?> json) {
    final rawType = json['tmdbMediaType']?.toString();
    final mediaType = rawType == TmdbMediaType.tv.name
        ? TmdbMediaType.tv
        : (rawType == TmdbMediaType.movie.name ? TmdbMediaType.movie : null);
    final rawStatus = (json['scrapeStatus'] ?? '').toString();
    final scrapeStatus = ScrapeStatus.values.firstWhere(
      (s) => s.name == rawStatus,
      orElse: () => ScrapeStatus.unmatched,
    );
    final rawSecondary = json['secondaryWorkKeys'];
    final secondary = rawSecondary is List
        ? rawSecondary
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return SyncWorkEntry(
      id: (json['id'] ?? '').toString(),
      canonicalWorkKey: (json['canonicalWorkKey'] ?? '').toString(),
      secondaryWorkKeys: secondary,
      title: (json['title'] ?? '').toString(),
      tmdbId: (json['tmdbId'] as num?)?.toInt(),
      tmdbMediaType: mediaType,
      bangumiId: (json['bangumiId'] as num?)?.toInt(),
      tvdbId: (json['tvdbId'] as num?)?.toInt(),
      matchedSeason: (json['matchedSeason'] as num?)?.toInt(),
      originalTitle: json['originalTitle']?.toString(),
      year: (json['year'] as num?)?.toInt(),
      overview: json['overview']?.toString(),
      posterPath: json['posterPath']?.toString(),
      posterFallback: json['posterFallback']?.toString(),
      bangumiPosterPath: json['bangumiPosterPath']?.toString(),
      backdropPath: json['backdropPath']?.toString(),
      logoPath: json['logoPath']?.toString(),
      voteAverage: (json['voteAverage'] as num?)?.toDouble(),
      bangumiScore: (json['bangumiScore'] as num?)?.toDouble(),
      folderTmdbHint: (json['folderTmdbHint'] as num?)?.toInt(),
      isManualLocked: json['isManualLocked'] == true,
      metadataLocked: json['metadataLocked'] == true,
      posterLocked: json['posterLocked'] == true,
      backdropLocked: json['backdropLocked'] == true,
      logoLocked: json['logoLocked'] == true,
      isHidden: json['isHidden'] == true,
      keepHidden: json['keepHidden'] == true,
      scrapeStatus: scrapeStatus,
      reviewReason: json['reviewReason']?.toString(),
      seriesId: json['seriesId']?.toString(),
      seriesOrder: (json['seriesOrder'] as num?)?.toInt(),
      seriesLabel: json['seriesLabel']?.toString(),
      seriesLocked: json['seriesLocked'] == true,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
    );
  }
}

/// 可跨设备同步与备份的逻辑剧集与特典条目。
class SyncEpisodeEntry {
  /// 创建可同步逻辑剧集条目。
  const SyncEpisodeEntry({
    required this.id,
    required this.workId,
    required this.seasonNumber,
    this.episodeNumber,
    this.episodeNumberEnd,
    this.category = EpisodeCategory.main,
    this.extraType,
    this.title,
    this.overview,
    this.stillPath,
  });

  /// 从领域实体 [Episode] 构造同步条目。
  factory SyncEpisodeEntry.fromEpisode(Episode ep) {
    return SyncEpisodeEntry(
      id: ep.id,
      workId: ep.workId,
      seasonNumber: ep.seasonNumber,
      episodeNumber: ep.episodeNumber,
      episodeNumberEnd: ep.episodeNumberEnd,
      category: ep.category,
      extraType: ep.extraType,
      title: ep.title,
      overview: ep.overview,
      stillPath: ep.stillPath,
    );
  }

  final String id;
  final String workId;
  final int seasonNumber;
  final int? episodeNumber;
  final int? episodeNumberEnd;
  final EpisodeCategory category;
  final ExtraKind? extraType;
  final String? title;
  final String? overview;
  final String? stillPath;

  /// 复制并替换主键或归属作品 ID。
  SyncEpisodeEntry copyWith({String? id, String? workId}) {
    return SyncEpisodeEntry(
      id: id ?? this.id,
      workId: workId ?? this.workId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeNumberEnd: episodeNumberEnd,
      category: category,
      extraType: extraType,
      title: title,
      overview: overview,
      stillPath: stillPath,
    );
  }

  /// 还原为领域实体 [Episode]。
  Episode toEpisode({
    String? overrideId,
    String? overrideWorkId,
    bool sanitizeWindowsLocalArtworkPaths = false,
  }) {
    final safeStill =
        (sanitizeWindowsLocalArtworkPaths &&
            stillPath != null &&
            SyncMediaSourceEntry.isWindowsAbsolutePath(stillPath!))
        ? null
        : stillPath;
    return Episode(
      id: overrideId ?? id,
      workId: overrideWorkId ?? workId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeNumberEnd: episodeNumberEnd,
      category: category,
      extraType: extraType,
      title: title,
      overview: overview,
      stillPath: safeStill,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'workId': workId,
    'seasonNumber': seasonNumber,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
    if (episodeNumberEnd != null) 'episodeNumberEnd': episodeNumberEnd,
    'category': category.name,
    if (extraType != null) 'extraType': extraType!.name,
    if (title != null) 'title': title,
    if (overview != null) 'overview': overview,
    if (stillPath != null) 'stillPath': stillPath,
  };

  factory SyncEpisodeEntry.fromJson(Map<String, Object?> json) {
    final rawCat = (json['category'] ?? '').toString();
    final category = EpisodeCategory.values.firstWhere(
      (c) => c.name == rawCat,
      orElse: () => EpisodeCategory.main,
    );
    final rawExtra = json['extraType']?.toString();
    ExtraKind? extraType;
    if (rawExtra != null && rawExtra.isNotEmpty) {
      for (final candidate in ExtraKind.values) {
        if (candidate.name == rawExtra) {
          extraType = candidate;
          break;
        }
      }
    }
    return SyncEpisodeEntry(
      id: (json['id'] ?? '').toString(),
      workId: (json['workId'] ?? '').toString(),
      seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 1,
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      episodeNumberEnd: (json['episodeNumberEnd'] as num?)?.toInt(),
      category: category,
      extraType: extraType,
      title: json['title']?.toString(),
      overview: json['overview']?.toString(),
      stillPath: json['stillPath']?.toString(),
    );
  }
}

/// 可跨设备同步与备份的物理文件变体与人工映射锁条目（仅存相对路径，零本机绝对盘符耦合）。
class SyncMediaVariantEntry {
  /// 创建可同步物理文件变体条目。
  const SyncMediaVariantEntry({
    required this.id,
    required this.workId,
    this.episodeId,
    required this.sourceId,
    required this.relativePath,
    required this.fileName,
    required this.fileSize,
    this.assetKind = AssetKind.video,
    this.releaseGroup,
    this.subtitleGroup,
    this.videoCodec,
    this.bitDepth,
    this.resolution,
    this.audioCodec,
    this.externalSubtitles = const <String>[],
    this.mappingLocked = false,
    this.workLocked = false,
    this.assetScope = SupplementaryAssetScope.workExclusive,
    this.scopeLocked = false,
  });

  /// 从领域实体 [MediaVariant] 构造同步条目。
  factory SyncMediaVariantEntry.fromMediaVariant(MediaVariant v) {
    return SyncMediaVariantEntry(
      id: v.id,
      workId: v.workId,
      episodeId: v.episodeId,
      sourceId: v.sourceId,
      relativePath: v.relativePath,
      fileName: v.fileName,
      fileSize: v.fileSize,
      assetKind: v.assetKind,
      releaseGroup: v.releaseGroup,
      subtitleGroup: v.subtitleGroup,
      videoCodec: v.videoCodec,
      bitDepth: v.bitDepth,
      resolution: v.resolution,
      audioCodec: v.audioCodec,
      externalSubtitles: v.externalSubtitles,
      mappingLocked: v.mappingLocked,
      workLocked: v.workLocked,
      assetScope: v.assetScope,
      scopeLocked: v.scopeLocked,
    );
  }

  final String id;
  final String workId;
  final String? episodeId;
  final String sourceId;
  final String relativePath;
  final String fileName;
  final int fileSize;
  final AssetKind assetKind;
  final String? releaseGroup;
  final String? subtitleGroup;
  final String? videoCodec;
  final String? bitDepth;
  final String? resolution;
  final String? audioCodec;
  final List<String> externalSubtitles;
  final bool mappingLocked;
  final bool workLocked;
  final SupplementaryAssetScope assetScope;
  final bool scopeLocked;

  /// 归一化 POSIX 相对路径（用于跨设备去重比较）。
  String get normalizedRelativePath => normalizeRelativePath(relativePath);

  /// 统一归一化相对路径为前斜杠无首尾斜杠形式。
  static String normalizeRelativePath(String raw) =>
      raw.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');

  /// 复制并替换关联标识。
  SyncMediaVariantEntry copyWith({
    String? id,
    String? workId,
    String? episodeId,
    bool clearEpisodeId = false,
    String? sourceId,
  }) {
    return SyncMediaVariantEntry(
      id: id ?? this.id,
      workId: workId ?? this.workId,
      episodeId: clearEpisodeId ? null : (episodeId ?? this.episodeId),
      sourceId: sourceId ?? this.sourceId,
      relativePath: relativePath,
      fileName: fileName,
      fileSize: fileSize,
      assetKind: assetKind,
      releaseGroup: releaseGroup,
      subtitleGroup: subtitleGroup,
      videoCodec: videoCodec,
      bitDepth: bitDepth,
      resolution: resolution,
      audioCodec: audioCodec,
      externalSubtitles: externalSubtitles,
      mappingLocked: mappingLocked,
      workLocked: workLocked,
      assetScope: assetScope,
      scopeLocked: scopeLocked,
    );
  }

  /// 还原为领域实体 [MediaVariant]。
  MediaVariant toMediaVariant({
    String? overrideId,
    String? overrideWorkId,
    String? overrideEpisodeId,
    bool clearEpisodeId = false,
    String? overrideSourceId,
  }) {
    return MediaVariant(
      id: overrideId ?? id,
      workId: overrideWorkId ?? workId,
      episodeId: clearEpisodeId ? null : (overrideEpisodeId ?? episodeId),
      sourceId: overrideSourceId ?? sourceId,
      relativePath: relativePath,
      fileName: fileName,
      fileSize: fileSize,
      assetKind: assetKind,
      releaseGroup: releaseGroup,
      subtitleGroup: subtitleGroup,
      videoCodec: videoCodec,
      bitDepth: bitDepth,
      resolution: resolution,
      audioCodec: audioCodec,
      externalSubtitles: externalSubtitles,
      mappingLocked: mappingLocked,
      workLocked: workLocked,
      assetScope: assetScope,
      scopeLocked: scopeLocked,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'workId': workId,
    if (episodeId != null && episodeId!.isNotEmpty) 'episodeId': episodeId,
    'sourceId': sourceId,
    'relativePath': relativePath,
    'fileName': fileName,
    'fileSize': fileSize,
    'assetKind': assetKind.name,
    if (releaseGroup != null) 'releaseGroup': releaseGroup,
    if (subtitleGroup != null) 'subtitleGroup': subtitleGroup,
    if (videoCodec != null) 'videoCodec': videoCodec,
    if (bitDepth != null) 'bitDepth': bitDepth,
    if (resolution != null) 'resolution': resolution,
    if (audioCodec != null) 'audioCodec': audioCodec,
    if (externalSubtitles.isNotEmpty) 'externalSubtitles': externalSubtitles,
    if (mappingLocked) 'mappingLocked': true,
    if (workLocked) 'workLocked': true,
    if (assetScope != SupplementaryAssetScope.workExclusive)
      'assetScope': assetScope.name,
    if (scopeLocked) 'scopeLocked': true,
  };

  factory SyncMediaVariantEntry.fromJson(Map<String, Object?> json) {
    final rawKind = (json['assetKind'] ?? '').toString();
    final assetKind = AssetKind.values.firstWhere(
      (k) => k.name == rawKind,
      orElse: () => AssetKind.video,
    );
    final rawScope = (json['assetScope'] ?? '').toString();
    final assetScope = SupplementaryAssetScope.values.firstWhere(
      (s) => s.name == rawScope,
      orElse: () => SupplementaryAssetScope.workExclusive,
    );
    final rawSubs = json['externalSubtitles'];
    final subs = rawSubs is List
        ? rawSubs
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return SyncMediaVariantEntry(
      id: (json['id'] ?? '').toString(),
      workId: (json['workId'] ?? '').toString(),
      episodeId: json['episodeId']?.toString(),
      sourceId: (json['sourceId'] ?? '').toString(),
      relativePath: (json['relativePath'] ?? '').toString(),
      fileName: (json['fileName'] ?? '').toString(),
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      assetKind: assetKind,
      releaseGroup: json['releaseGroup']?.toString(),
      subtitleGroup: json['subtitleGroup']?.toString(),
      videoCodec: json['videoCodec']?.toString(),
      bitDepth: json['bitDepth']?.toString(),
      resolution: json['resolution']?.toString(),
      audioCodec: json['audioCodec']?.toString(),
      externalSubtitles: subs,
      mappingLocked: json['mappingLocked'] == true,
      workLocked: json['workLocked'] == true,
      assetScope: assetScope,
      scopeLocked: json['scopeLocked'] == true,
    );
  }
}

/// 可跨设备同步与备份的媒体源忽略目录条目。
class SyncIgnoredFolderEntry {
  /// 创建忽略目录条目。
  const SyncIgnoredFolderEntry({
    required this.sourceId,
    required this.relativePath,
  });

  final String sourceId;
  final String relativePath;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'relativePath': relativePath,
  };

  factory SyncIgnoredFolderEntry.fromJson(Map<String, Object?> json) {
    return SyncIgnoredFolderEntry(
      sourceId: (json['sourceId'] ?? '').toString(),
      relativePath: (json['relativePath'] ?? '').toString(),
    );
  }
}

/// 完整已整理媒体库的可移植快照容器（含媒体源结构、系列编组、作品、剧集、物理文件映射与忽略目录）。
class SyncLibraryCatalog {
  /// 创建完整媒体库目录快照。
  const SyncLibraryCatalog({
    this.mediaSources = const <SyncMediaSourceEntry>[],
    this.seriesGroups = const <SyncSeriesGroupEntry>[],
    this.works = const <SyncWorkEntry>[],
    this.episodes = const <SyncEpisodeEntry>[],
    this.variants = const <SyncMediaVariantEntry>[],
    this.ignoredFolders = const <SyncIgnoredFolderEntry>[],
  });

  final List<SyncMediaSourceEntry> mediaSources;
  final List<SyncSeriesGroupEntry> seriesGroups;
  final List<SyncWorkEntry> works;
  final List<SyncEpisodeEntry> episodes;
  final List<SyncMediaVariantEntry> variants;
  final List<SyncIgnoredFolderEntry> ignoredFolders;

  /// 当前目录快照是否完全为空。
  bool get isEmpty =>
      mediaSources.isEmpty &&
      seriesGroups.isEmpty &&
      works.isEmpty &&
      episodes.isEmpty &&
      variants.isEmpty &&
      ignoredFolders.isEmpty;

  /// 当前目录快照是否包含可恢复的媒体库数据。
  bool get hasContent => !isEmpty;

  /// 包含的远程媒体源数量（WebDAV / SMB）。
  int get remoteSourceCount =>
      mediaSources.where((s) => s.kind != MediaSourceKind.local).length;

  /// 包含的本地磁盘媒体源数量。
  int get localSourceCount =>
      mediaSources.where((s) => s.kind == MediaSourceKind.local).length;

  Map<String, Object?> toJson() => <String, Object?>{
    'mediaSources': [for (final s in mediaSources) s.toJson()],
    'seriesGroups': [for (final g in seriesGroups) g.toJson()],
    'works': [for (final w in works) w.toJson()],
    'episodes': [for (final e in episodes) e.toJson()],
    'variants': [for (final v in variants) v.toJson()],
    'ignoredFolders': [for (final f in ignoredFolders) f.toJson()],
  };

  factory SyncLibraryCatalog.fromJson(Map<String, Object?> json) {
    List<T> parseList<T>(
      String key,
      T Function(Map<String, Object?> item) builder,
    ) {
      final raw = json[key];
      if (raw is! List) return const [];
      final out = <T>[];
      for (final item in raw) {
        if (item is Map) {
          out.add(builder(item.map((k, v) => MapEntry(k.toString(), v))));
        }
      }
      return out;
    }

    return SyncLibraryCatalog(
      mediaSources: parseList('mediaSources', SyncMediaSourceEntry.fromJson),
      seriesGroups: parseList('seriesGroups', SyncSeriesGroupEntry.fromJson),
      works: parseList('works', SyncWorkEntry.fromJson),
      episodes: parseList('episodes', SyncEpisodeEntry.fromJson),
      variants: parseList('variants', SyncMediaVariantEntry.fromJson),
      ignoredFolders: parseList(
        'ignoredFolders',
        SyncIgnoredFolderEntry.fromJson,
      ),
    );
  }
}
