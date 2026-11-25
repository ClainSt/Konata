import 'dart:math' as math;

import 'package:engine_sources/engine_sources.dart'
    show SourceLocationValidator;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'sync_models.dart';

/// 可跨设备同步的媒体源元数据条目（严格不含密码）。
final class SyncLibrarySourceItem {
  /// 创建可同步媒体源条目。
  const SyncLibrarySourceItem({
    required this.id,
    required this.kind,
    required this.label,
    required this.location,
    this.canonicalKey,
    this.username,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 从存储层 [MediaSourceRecord] 构建同步条目并清洗潜在内嵌密码。
  factory SyncLibrarySourceItem.fromRecord(
    MediaSourceRecord rec, {
    String fallbackDeviceId = '',
  }) {
    final safeLocation = _safeLocation(rec.kind, rec.location);
    return SyncLibrarySourceItem(
      id: rec.id.value,
      canonicalKey: rec.kind == MediaSourceKind.cloudDrive
          ? null
          : rec.canonicalKey,
      kind: rec.kind,
      label: rec.label,
      location: safeLocation,
      username: rec.kind == MediaSourceKind.cloudDrive ? null : rec.username,
      createdAtMs: rec.createdAtMs,
      updatedAtMs: rec.updatedAtMs,
      sourceDeviceId: rec.sourceDeviceId.isEmpty
          ? fallbackDeviceId
          : rec.sourceDeviceId,
      deletedAtMs: rec.deletedAtMs,
    );
  }

  static String _safeLocation(MediaSourceKind kind, String location) {
    if (kind == MediaSourceKind.cloudDrive) {
      final checked = SourceLocationValidator.validate(kind, location);
      if (!checked.isValid) throw const FormatException('云盘同步地址无效或含凭据');
      return checked.normalizedLocation;
    }
    return kind == MediaSourceKind.local
        ? location
        : SyncSanitizer.stripUrlPassword(location);
  }

  final String id;
  final String? canonicalKey;
  final MediaSourceKind kind;
  final String label;
  final String location;
  final String? username;
  final int createdAtMs;
  final int updatedAtMs;
  final String sourceDeviceId;
  final int? deletedAtMs;

  bool get isDeleted => deletedAtMs != null;
  int get effectiveTimestampMs =>
      deletedAtMs != null ? math.max(deletedAtMs!, updatedAtMs) : updatedAtMs;

  String get normalizedLocationKey =>
      SyncSanitizer.normalizeSourceLocationKey(kind, location);

  MediaSourceRecord toRecord({String? overrideId}) => MediaSourceRecord(
    id: SourceId.trusted(overrideId ?? id),
    canonicalKey: canonicalKey,
    kind: kind,
    label: label,
    location: location,
    username: username,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs,
    sourceDeviceId: sourceDeviceId,
    deletedAtMs: deletedAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (kind != MediaSourceKind.cloudDrive && canonicalKey != null)
      'canonicalKey': canonicalKey,
    'kind': kind.name,
    'label': label,
    'location': _safeLocation(kind, location),
    if (kind != MediaSourceKind.cloudDrive &&
        username != null &&
        username!.isNotEmpty)
      'username': username,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
    if (deletedAtMs != null) 'deletedAtMs': deletedAtMs,
  };

  static SyncLibrarySourceItem? tryFromJson(Map<String, Object?> json) {
    final id = (json['id'] ?? '').toString().trim();
    final location = (json['location'] ?? '').toString().trim();
    if (id.isEmpty || location.isEmpty) return null;
    final rawKind = (json['kind'] ?? '').toString();
    final kind = MediaSourceKind.values.firstWhere(
      (k) => k.name == rawKind,
      orElse: () => throw const FormatException('同步包含未知媒体源类型'),
    );
    return SyncLibrarySourceItem(
      id: id,
      canonicalKey: kind == MediaSourceKind.cloudDrive
          ? null
          : json['canonicalKey']?.toString(),
      kind: kind,
      label: (json['label'] ?? '').toString(),
      location: _safeLocation(kind, location),
      username: kind == MediaSourceKind.cloudDrive
          ? null
          : json['username']?.toString(),
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// 可跨设备同步的系列合集编组条目。
final class SyncLibrarySeriesItem {
  /// 创建可同步系列编组条目。
  const SyncLibrarySeriesItem({
    required this.id,
    required this.title,
    this.canonicalKey,
    this.tmdbCollectionId,
    this.rootFolderHint,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  factory SyncLibrarySeriesItem.fromRecord(
    SeriesGroupRecord rec, {
    String fallbackDeviceId = '',
  }) {
    final safeHint =
        rec.rootFolderHint != null &&
            SyncSanitizer.isLocalFilesystemPath(rec.rootFolderHint!)
        ? null
        : rec.rootFolderHint;
    return SyncLibrarySeriesItem(
      id: rec.id.value,
      canonicalKey: rec.canonicalKey,
      title: rec.title,
      tmdbCollectionId: rec.tmdbCollectionId,
      rootFolderHint: safeHint,
      createdAtMs: rec.createdAtMs,
      updatedAtMs: rec.updatedAtMs,
      sourceDeviceId: rec.sourceDeviceId.isEmpty
          ? fallbackDeviceId
          : rec.sourceDeviceId,
      deletedAtMs: rec.deletedAtMs,
    );
  }

  final String id;
  final String? canonicalKey;
  final String title;
  final int? tmdbCollectionId;
  final String? rootFolderHint;
  final int createdAtMs;
  final int updatedAtMs;
  final String sourceDeviceId;
  final int? deletedAtMs;

  bool get isDeleted => deletedAtMs != null;
  int get effectiveTimestampMs =>
      deletedAtMs != null ? math.max(deletedAtMs!, updatedAtMs) : updatedAtMs;

  SeriesGroupRecord toRecord({String? overrideId}) => SeriesGroupRecord(
    id: SeriesGroupId.trusted(overrideId ?? id),
    canonicalKey: canonicalKey,
    title: title,
    tmdbCollectionId: tmdbCollectionId,
    rootFolderHint: rootFolderHint,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs,
    sourceDeviceId: sourceDeviceId,
    deletedAtMs: deletedAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (canonicalKey != null) 'canonicalKey': canonicalKey,
    'title': title,
    if (tmdbCollectionId != null) 'tmdbCollectionId': tmdbCollectionId,
    if (rootFolderHint != null && rootFolderHint!.isNotEmpty)
      'rootFolderHint': rootFolderHint,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
    if (deletedAtMs != null) 'deletedAtMs': deletedAtMs,
  };

  static SyncLibrarySeriesItem? tryFromJson(Map<String, Object?> json) {
    final id = (json['id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    final rawHint = json['rootFolderHint']?.toString();
    final safeHint =
        rawHint != null && SyncSanitizer.isLocalFilesystemPath(rawHint)
        ? null
        : rawHint;
    return SyncLibrarySeriesItem(
      id: id,
      canonicalKey: json['canonicalKey']?.toString(),
      title: (json['title'] ?? '').toString(),
      tmdbCollectionId: (json['tmdbCollectionId'] as num?)?.toInt(),
      rootFolderHint: safeHint,
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// 可跨设备同步的完整作品条目（严守 `ArtworkRef.localCustom -> null` 序列化铁律）。
final class SyncLibraryWorkItem {
  /// 创建可同步作品条目。
  const SyncLibraryWorkItem({
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
    this.posterRef,
    this.posterFallback,
    this.bangumiPosterPath,
    this.backdropRef,
    this.portraitBackdropRef,
    this.logoRef,
    this.voteAverage,
    this.bangumiScore,
    this.folderTmdbHint,
    this.isManualLocked = false,
    this.metadataLocked = false,
    this.isHidden = false,
    this.keepHidden = false,
    this.scrapeStatus = ScrapeStatus.unmatched,
    this.reviewReason,
    this.seriesId,
    this.seriesOrder,
    this.seriesLabel,
    this.seriesLocked = false,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 从 [WorkRecord] 构建同步作品条目并自动剔除本机自定义艺术图绝对路径。
  factory SyncLibraryWorkItem.fromRecord(
    WorkRecord rec, {
    String fallbackDeviceId = '',
  }) {
    final primaryKey = SyncSanitizer.primaryWorkKeyFor(rec);
    final secondaryKeys = SyncSanitizer.allWorkKeysFor(
      rec,
    ).where((k) => k != primaryKey).toList(growable: false);

    // 通过 `toSyncJson()` -> `tryFromJson()` 确保任意 `LocalCustomArtworkRef` 归零为 `null`。
    final safePosterRef = ArtworkRef.tryFromJson(rec.posterRef?.toSyncJson());
    final safeBackdropRef = ArtworkRef.tryFromJson(
      rec.backdropRef?.toSyncJson(),
    );
    final safePortraitBackdropRef = ArtworkRef.tryFromJson(
      rec.portraitBackdropRef?.toSyncJson(),
    );
    final safeLogoRef = ArtworkRef.tryFromJson(rec.logoRef?.toSyncJson());

    return SyncLibraryWorkItem(
      id: rec.id.value,
      canonicalWorkKey: primaryKey,
      secondaryWorkKeys: secondaryKeys,
      title: rec.title,
      tmdbId: rec.tmdbId,
      tmdbMediaType: rec.tmdbMediaType,
      bangumiId: rec.bangumiId,
      tvdbId: rec.tvdbId,
      matchedSeason: rec.matchedSeason,
      originalTitle: rec.originalTitle,
      year: rec.year,
      overview: rec.overview,
      posterRef: safePosterRef,
      posterFallback: SyncSanitizer.sanitizeRemotePath(rec.posterFallback),
      bangumiPosterPath: SyncSanitizer.sanitizeRemotePath(
        rec.bangumiPosterPath,
      ),
      backdropRef: safeBackdropRef,
      portraitBackdropRef: safePortraitBackdropRef,
      logoRef: safeLogoRef,
      voteAverage: rec.voteAverage,
      bangumiScore: rec.bangumiScore,
      folderTmdbHint: rec.folderTmdbHint,
      isManualLocked: rec.isManualLocked,
      metadataLocked: rec.metadataLocked,
      isHidden: rec.isHidden,
      keepHidden: rec.keepHidden,
      scrapeStatus: rec.scrapeStatus,
      reviewReason: rec.reviewReason,
      seriesId: rec.seriesId?.value,
      seriesOrder: rec.seriesOrder,
      seriesLabel: rec.seriesLabel,
      seriesLocked: rec.seriesLocked,
      updatedAtMs: rec.updatedAtMs,
      sourceDeviceId: rec.sourceDeviceId.isEmpty
          ? fallbackDeviceId
          : rec.sourceDeviceId,
      deletedAtMs: rec.deletedAtMs,
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
  final ArtworkRef? posterRef;
  final String? posterFallback;
  final String? bangumiPosterPath;
  final ArtworkRef? backdropRef;
  final ArtworkRef? portraitBackdropRef;
  final ArtworkRef? logoRef;
  final double? voteAverage;
  final double? bangumiScore;
  final int? folderTmdbHint;
  final bool isManualLocked;
  final bool metadataLocked;
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
  final int? deletedAtMs;

  bool get isDeleted => deletedAtMs != null;
  int get effectiveTimestampMs =>
      deletedAtMs != null ? math.max(deletedAtMs!, updatedAtMs) : updatedAtMs;

  Iterable<String> get allWorkKeys sync* {
    if (canonicalWorkKey.isNotEmpty) yield canonicalWorkKey;
    yield* secondaryWorkKeys;
  }

  SyncLibraryWorkItem copyWith({
    String? id,
    String? seriesId,
    bool clearSeriesId = false,
  }) {
    return SyncLibraryWorkItem(
      id: id ?? this.id,
      canonicalWorkKey: canonicalWorkKey,
      secondaryWorkKeys: secondaryWorkKeys,
      title: title,
      tmdbId: tmdbId,
      tmdbMediaType: tmdbMediaType,
      bangumiId: bangumiId,
      tvdbId: tvdbId,
      matchedSeason: matchedSeason,
      originalTitle: originalTitle,
      year: year,
      overview: overview,
      posterRef: posterRef,
      posterFallback: posterFallback,
      bangumiPosterPath: bangumiPosterPath,
      backdropRef: backdropRef,
      portraitBackdropRef: portraitBackdropRef,
      logoRef: logoRef,
      voteAverage: voteAverage,
      bangumiScore: bangumiScore,
      folderTmdbHint: folderTmdbHint,
      isManualLocked: isManualLocked,
      metadataLocked: metadataLocked,
      isHidden: isHidden,
      keepHidden: keepHidden,
      scrapeStatus: scrapeStatus,
      reviewReason: reviewReason,
      seriesId: clearSeriesId ? null : (seriesId ?? this.seriesId),
      seriesOrder: seriesOrder,
      seriesLabel: seriesLabel,
      seriesLocked: seriesLocked,
      updatedAtMs: updatedAtMs,
      sourceDeviceId: sourceDeviceId,
      deletedAtMs: deletedAtMs,
    );
  }

  WorkRecord toRecord({
    String? overrideId,
    String? overrideSeriesId,
    ArtworkRef? preservePosterRef,
    ArtworkRef? preserveBackdropRef,
    ArtworkRef? preservePortraitBackdropRef,
    ArtworkRef? preserveLogoRef,
  }) {
    return WorkRecord(
      id: WorkId.trusted(overrideId ?? id),
      canonicalKey: canonicalWorkKey,
      tmdbId: tmdbId,
      tmdbMediaType: tmdbMediaType,
      bangumiId: bangumiId,
      tvdbId: tvdbId,
      matchedSeason: matchedSeason,
      title: title,
      originalTitle: originalTitle,
      year: year,
      overview: overview,
      posterRef: preservePosterRef ?? posterRef,
      posterFallback: posterFallback,
      bangumiPosterPath: bangumiPosterPath,
      backdropRef: preserveBackdropRef ?? backdropRef,
      portraitBackdropRef: preservePortraitBackdropRef ?? portraitBackdropRef,
      logoRef: preserveLogoRef ?? logoRef,
      voteAverage: voteAverage,
      bangumiScore: bangumiScore,
      folderTmdbHint: folderTmdbHint,
      isManualLocked: isManualLocked,
      metadataLocked: metadataLocked,
      isHidden: isHidden,
      keepHidden: keepHidden,
      scrapeStatus: scrapeStatus,
      reviewReason: reviewReason,
      seriesId: (overrideSeriesId ?? seriesId)?.isNotEmpty == true
          ? SeriesGroupId.trusted(overrideSeriesId ?? seriesId!)
          : null,
      seriesOrder: seriesOrder,
      seriesLabel: seriesLabel,
      seriesLocked: seriesLocked,
      updatedAtMs: updatedAtMs,
      sourceDeviceId: sourceDeviceId,
      deletedAtMs: deletedAtMs,
    );
  }

  /// 序列化为跨设备同步 JSON（`LocalCustomArtworkRef` 一律序列化为 `null`）。
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
    'posterRef': posterRef?.toSyncJson(),
    if (posterFallback != null) 'posterFallback': posterFallback,
    if (bangumiPosterPath != null) 'bangumiPosterPath': bangumiPosterPath,
    'backdropRef': backdropRef?.toSyncJson(),
    'portraitBackdropRef': portraitBackdropRef?.toSyncJson(),
    'logoRef': logoRef?.toSyncJson(),
    if (voteAverage != null) 'voteAverage': voteAverage,
    if (bangumiScore != null) 'bangumiScore': bangumiScore,
    if (folderTmdbHint != null) 'folderTmdbHint': folderTmdbHint,
    if (isManualLocked) 'isManualLocked': true,
    if (metadataLocked) 'metadataLocked': true,
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
    if (deletedAtMs != null) 'deletedAtMs': deletedAtMs,
  };

  static SyncLibraryWorkItem? tryFromJson(Map<String, Object?> json) {
    final id = (json['id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
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
        ? <String>[
            for (final item in rawSecondary)
              if (item.toString().trim().isNotEmpty) item.toString().trim(),
          ]
        : const <String>[];

    ArtworkRef? parseSyncArtwork(Object? raw) {
      if (raw is! Map) return null;
      final parsed = ArtworkRef.tryFromJson(
        SyncSanitizer.coerceStringKeyMap(raw),
      );
      if (parsed is LocalCustomArtworkRef) {
        return null;
      }
      return parsed;
    }

    return SyncLibraryWorkItem(
      id: id,
      canonicalWorkKey: (json['canonicalWorkKey'] ?? '').toString().trim(),
      secondaryWorkKeys: List<String>.unmodifiable(secondary),
      title: (json['title'] ?? '').toString(),
      tmdbId: (json['tmdbId'] as num?)?.toInt(),
      tmdbMediaType: mediaType,
      bangumiId: (json['bangumiId'] as num?)?.toInt(),
      tvdbId: (json['tvdbId'] as num?)?.toInt(),
      matchedSeason: (json['matchedSeason'] as num?)?.toInt(),
      originalTitle: json['originalTitle']?.toString(),
      year: (json['year'] as num?)?.toInt(),
      overview: json['overview']?.toString(),
      posterRef: parseSyncArtwork(json['posterRef']),
      posterFallback: SyncSanitizer.sanitizeRemotePath(
        json['posterFallback']?.toString(),
      ),
      bangumiPosterPath: SyncSanitizer.sanitizeRemotePath(
        json['bangumiPosterPath']?.toString(),
      ),
      backdropRef: parseSyncArtwork(json['backdropRef']),
      portraitBackdropRef: parseSyncArtwork(json['portraitBackdropRef']),
      logoRef: parseSyncArtwork(json['logoRef']),
      voteAverage: (json['voteAverage'] as num?)?.toDouble(),
      bangumiScore: (json['bangumiScore'] as num?)?.toDouble(),
      folderTmdbHint: (json['folderTmdbHint'] as num?)?.toInt(),
      isManualLocked: json['isManualLocked'] == true,
      metadataLocked: json['metadataLocked'] == true,
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
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// 可跨设备同步的逻辑剧集与特典条目。
final class SyncLibraryEpisodeItem {
  /// 创建可同步剧集条目。
  const SyncLibraryEpisodeItem({
    required this.id,
    required this.workId,
    required this.seasonNumber,
    this.canonicalKey,
    this.episodeNumber,
    this.episodeNumberEnd,
    this.category = EpisodeCategory.main,
    this.extraType,
    this.title,
    this.overview,
    this.stillPath,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  factory SyncLibraryEpisodeItem.fromRecord(
    EpisodeRecord rec, {
    String fallbackDeviceId = '',
  }) {
    return SyncLibraryEpisodeItem(
      id: rec.id.value,
      canonicalKey: rec.canonicalKey,
      workId: rec.workId.value,
      seasonNumber: rec.seasonNumber,
      episodeNumber: rec.episodeNumber,
      episodeNumberEnd: rec.episodeNumberEnd,
      category: rec.category,
      extraType: rec.extraType,
      title: rec.title,
      overview: rec.overview,
      stillPath: SyncSanitizer.sanitizeRemotePath(rec.stillPath),
      updatedAtMs: rec.updatedAtMs,
      sourceDeviceId: rec.sourceDeviceId.isEmpty
          ? fallbackDeviceId
          : rec.sourceDeviceId,
      deletedAtMs: rec.deletedAtMs,
    );
  }

  final String id;
  final String? canonicalKey;
  final String workId;
  final int seasonNumber;
  final int? episodeNumber;
  final int? episodeNumberEnd;
  final EpisodeCategory category;
  final ExtraKind? extraType;
  final String? title;
  final String? overview;
  final String? stillPath;
  final int updatedAtMs;
  final String sourceDeviceId;
  final int? deletedAtMs;

  bool get isDeleted => deletedAtMs != null;
  int get effectiveTimestampMs =>
      deletedAtMs != null ? math.max(deletedAtMs!, updatedAtMs) : updatedAtMs;

  SyncLibraryEpisodeItem copyWith({String? id, String? workId}) {
    return SyncLibraryEpisodeItem(
      id: id ?? this.id,
      canonicalKey: canonicalKey,
      workId: workId ?? this.workId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeNumberEnd: episodeNumberEnd,
      category: category,
      extraType: extraType,
      title: title,
      overview: overview,
      stillPath: stillPath,
      updatedAtMs: updatedAtMs,
      sourceDeviceId: sourceDeviceId,
      deletedAtMs: deletedAtMs,
    );
  }

  EpisodeRecord toRecord({String? overrideId, String? overrideWorkId}) =>
      EpisodeRecord(
        id: EpisodeId.trusted(overrideId ?? id),
        canonicalKey: canonicalKey,
        workId: WorkId.trusted(overrideWorkId ?? workId),
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        episodeNumberEnd: episodeNumberEnd,
        category: category,
        extraType: extraType,
        title: title,
        overview: overview,
        stillPath: stillPath,
        updatedAtMs: updatedAtMs,
        sourceDeviceId: sourceDeviceId,
        deletedAtMs: deletedAtMs,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (canonicalKey != null) 'canonicalKey': canonicalKey,
    'workId': workId,
    'seasonNumber': seasonNumber,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
    if (episodeNumberEnd != null) 'episodeNumberEnd': episodeNumberEnd,
    'category': category.name,
    if (extraType != null) 'extraType': extraType!.name,
    if (title != null) 'title': title,
    if (overview != null) 'overview': overview,
    if (stillPath != null) 'stillPath': stillPath,
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
    if (deletedAtMs != null) 'deletedAtMs': deletedAtMs,
  };

  static SyncLibraryEpisodeItem? tryFromJson(Map<String, Object?> json) {
    final id = (json['id'] ?? '').toString().trim();
    final workId = (json['workId'] ?? '').toString().trim();
    if (id.isEmpty || workId.isEmpty) return null;
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
    return SyncLibraryEpisodeItem(
      id: id,
      canonicalKey: json['canonicalKey']?.toString(),
      workId: workId,
      seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 1,
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      episodeNumberEnd: (json['episodeNumberEnd'] as num?)?.toInt(),
      category: category,
      extraType: extraType,
      title: json['title']?.toString(),
      overview: json['overview']?.toString(),
      stillPath: SyncSanitizer.sanitizeRemotePath(
        json['stillPath']?.toString(),
      ),
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// 可跨设备同步的物理文件变体与人工映射锁条目。
final class SyncLibraryVariantItem {
  /// 创建可同步物理文件变体条目。
  const SyncLibraryVariantItem({
    required this.id,
    required this.workId,
    required this.sourceId,
    required this.relativePath,
    required this.fileName,
    required this.fileSize,
    this.remoteFileId,
    this.canonicalKey,
    this.episodeId,
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
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  factory SyncLibraryVariantItem.fromRecord(
    MediaVariantRecord rec, {
    String fallbackDeviceId = '',
  }) {
    return SyncLibraryVariantItem(
      id: rec.id.value,
      canonicalKey: rec.canonicalKey,
      workId: rec.workId.value,
      episodeId: rec.episodeId?.value,
      sourceId: rec.sourceId.value,
      relativePath: SyncSanitizer.normalizeRelativePath(rec.relativePath),
      fileName: rec.fileName,
      fileSize: rec.fileSize,
      remoteFileId: rec.remoteFileId,
      assetKind: rec.assetKind,
      releaseGroup: rec.releaseGroup,
      subtitleGroup: rec.subtitleGroup,
      videoCodec: rec.videoCodec,
      bitDepth: rec.bitDepth,
      resolution: rec.resolution,
      audioCodec: rec.audioCodec,
      externalSubtitles: rec.externalSubtitles,
      mappingLocked: rec.mappingLocked,
      workLocked: rec.workLocked,
      assetScope: rec.assetScope,
      scopeLocked: rec.scopeLocked,
      updatedAtMs: rec.updatedAtMs,
      sourceDeviceId: rec.sourceDeviceId.isEmpty
          ? fallbackDeviceId
          : rec.sourceDeviceId,
      deletedAtMs: rec.deletedAtMs,
    );
  }

  final String id;
  final String? canonicalKey;
  final String workId;
  final String? episodeId;
  final String sourceId;
  final String relativePath;
  final String fileName;
  final int fileSize;
  final String? remoteFileId;
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
  final int updatedAtMs;
  final String sourceDeviceId;
  final int? deletedAtMs;

  bool get isDeleted => deletedAtMs != null;
  int get effectiveTimestampMs =>
      deletedAtMs != null ? math.max(deletedAtMs!, updatedAtMs) : updatedAtMs;

  String get normalizedRelativePath =>
      SyncSanitizer.normalizeRelativePath(relativePath);

  SyncLibraryVariantItem copyWith({
    String? id,
    String? workId,
    String? episodeId,
    bool clearEpisodeId = false,
    String? sourceId,
  }) {
    return SyncLibraryVariantItem(
      id: id ?? this.id,
      canonicalKey: canonicalKey,
      workId: workId ?? this.workId,
      episodeId: clearEpisodeId ? null : (episodeId ?? this.episodeId),
      sourceId: sourceId ?? this.sourceId,
      relativePath: relativePath,
      fileName: fileName,
      fileSize: fileSize,
      remoteFileId: remoteFileId,
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
      updatedAtMs: updatedAtMs,
      sourceDeviceId: sourceDeviceId,
      deletedAtMs: deletedAtMs,
    );
  }

  MediaVariantRecord toRecord() => MediaVariantRecord(
    id: VariantId.trusted(id),
    canonicalKey: canonicalKey,
    workId: WorkId.trusted(workId),
    episodeId: episodeId != null && episodeId!.isNotEmpty
        ? EpisodeId.trusted(episodeId!)
        : null,
    sourceId: SourceId.trusted(sourceId),
    relativePath: relativePath,
    fileName: fileName,
    fileSize: fileSize,
    remoteFileId: remoteFileId,
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
    updatedAtMs: updatedAtMs,
    sourceDeviceId: sourceDeviceId,
    deletedAtMs: deletedAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (canonicalKey != null) 'canonicalKey': canonicalKey,
    'workId': workId,
    if (episodeId != null && episodeId!.isNotEmpty) 'episodeId': episodeId,
    'sourceId': sourceId,
    'relativePath': relativePath,
    'fileName': fileName,
    'fileSize': fileSize,
    if (remoteFileId != null && remoteFileId!.isNotEmpty)
      'remoteFileId': remoteFileId,
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
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
    if (deletedAtMs != null) 'deletedAtMs': deletedAtMs,
  };

  static SyncLibraryVariantItem? tryFromJson(Map<String, Object?> json) {
    final id = (json['id'] ?? '').toString().trim();
    final workId = (json['workId'] ?? '').toString().trim();
    final sourceId = (json['sourceId'] ?? '').toString().trim();
    if (id.isEmpty || workId.isEmpty || sourceId.isEmpty) return null;
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
        ? <String>[
            for (final item in rawSubs)
              if (item.toString().trim().isNotEmpty) item.toString().trim(),
          ]
        : const <String>[];
    return SyncLibraryVariantItem(
      id: id,
      canonicalKey: json['canonicalKey']?.toString(),
      workId: workId,
      episodeId: json['episodeId']?.toString(),
      sourceId: sourceId,
      relativePath: SyncSanitizer.normalizeRelativePath(
        (json['relativePath'] ?? '').toString(),
      ),
      fileName: (json['fileName'] ?? '').toString(),
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      remoteFileId:
          json['remoteFileId'] is String &&
              (json['remoteFileId'] as String).isNotEmpty
          ? json['remoteFileId'] as String
          : null,
      assetKind: assetKind,
      releaseGroup: json['releaseGroup']?.toString(),
      subtitleGroup: json['subtitleGroup']?.toString(),
      videoCodec: json['videoCodec']?.toString(),
      bitDepth: json['bitDepth']?.toString(),
      resolution: json['resolution']?.toString(),
      audioCodec: json['audioCodec']?.toString(),
      externalSubtitles: List<String>.unmodifiable(subs),
      mappingLocked: json['mappingLocked'] == true,
      workLocked: json['workLocked'] == true,
      assetScope: assetScope,
      scopeLocked: json['scopeLocked'] == true,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// 可跨设备同步的忽略目录条目。
final class SyncLibraryIgnoredFolderItem {
  /// 创建忽略目录条目。
  const SyncLibraryIgnoredFolderItem({
    required this.id,
    required this.sourceId,
    required this.relativePath,
    this.canonicalKey,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  factory SyncLibraryIgnoredFolderItem.fromRecord(
    IgnoredFolderRecord rec, {
    String fallbackDeviceId = '',
  }) {
    return SyncLibraryIgnoredFolderItem(
      id: rec.id,
      canonicalKey: rec.canonicalKey,
      sourceId: rec.sourceId.value,
      relativePath: SyncSanitizer.normalizeRelativePath(rec.relativePath),
      createdAtMs: rec.createdAtMs,
      updatedAtMs: rec.updatedAtMs,
      sourceDeviceId: rec.sourceDeviceId.isEmpty
          ? fallbackDeviceId
          : rec.sourceDeviceId,
      deletedAtMs: rec.deletedAtMs,
    );
  }

  final String id;
  final String? canonicalKey;
  final String sourceId;
  final String relativePath;
  final int createdAtMs;
  final int updatedAtMs;
  final String sourceDeviceId;
  final int? deletedAtMs;

  bool get isDeleted => deletedAtMs != null;
  int get effectiveTimestampMs =>
      deletedAtMs != null ? math.max(deletedAtMs!, updatedAtMs) : updatedAtMs;

  SyncLibraryIgnoredFolderItem copyWith({String? id, String? sourceId}) {
    return SyncLibraryIgnoredFolderItem(
      id: id ?? this.id,
      canonicalKey: canonicalKey,
      sourceId: sourceId ?? this.sourceId,
      relativePath: relativePath,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      sourceDeviceId: sourceDeviceId,
      deletedAtMs: deletedAtMs,
    );
  }

  IgnoredFolderRecord toRecord() => IgnoredFolderRecord(
    id: id,
    canonicalKey: canonicalKey,
    sourceId: SourceId.trusted(sourceId),
    relativePath: relativePath,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs,
    sourceDeviceId: sourceDeviceId,
    deletedAtMs: deletedAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (canonicalKey != null) 'canonicalKey': canonicalKey,
    'sourceId': sourceId,
    'relativePath': relativePath,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
    if (deletedAtMs != null) 'deletedAtMs': deletedAtMs,
  };

  static SyncLibraryIgnoredFolderItem? tryFromJson(Map<String, Object?> json) {
    final id = (json['id'] ?? '').toString().trim();
    final sourceId = (json['sourceId'] ?? '').toString().trim();
    final rel = SyncSanitizer.normalizeRelativePath(
      (json['relativePath'] ?? '').toString(),
    );
    if (id.isEmpty || sourceId.isEmpty || rel.isEmpty) return null;
    return SyncLibraryIgnoredFolderItem(
      id: id,
      canonicalKey: json['canonicalKey']?.toString(),
      sourceId: sourceId,
      relativePath: rel,
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// 完整媒体库目录切片合并执行计划。
final class LibraryCatalogMergePlan {
  /// 创建媒体库目录合并计划。
  const LibraryCatalogMergePlan({
    required this.sourcesToUpsert,
    required this.seriesToUpsert,
    required this.worksToUpsert,
    required this.episodesToUpsert,
    required this.variantsToUpsert,
    required this.ignoredFoldersToUpsert,
    this.clearExistingBeforeApply = false,
  });

  final List<SyncLibrarySourceItem> sourcesToUpsert;
  final List<SyncLibrarySeriesItem> seriesToUpsert;
  final List<SyncLibraryWorkItem> worksToUpsert;
  final List<SyncLibraryEpisodeItem> episodesToUpsert;
  final List<SyncLibraryVariantItem> variantsToUpsert;
  final List<SyncLibraryIgnoredFolderItem> ignoredFoldersToUpsert;

  /// 是否在写入前以软删除清理现有本地目录（仅覆盖还原模式使用，仍保留复用媒体源与密码）。
  final bool clearExistingBeforeApply;
}

/// 媒体库目录与整理状态同步切片贡献者（`sliceId: 'library_catalog_slice'`）。
///
/// 基于 `WorkDao` 与 `library.db` 全表集合，完整支持全量作品目录直通、合集编组、
/// 标签、人工锁定态与软删除墓碑同步；严格执行 `ArtworkRef.localCustom -> null` 序列化铁律。
final class LibraryCatalogSyncSlice
    implements SyncSliceContributor<LibraryCatalogMergePlan> {
  /// 创建绑定 `library.db` 的媒体库目录同步切片实例。
  const LibraryCatalogSyncSlice({
    required LibraryDatabase this._libraryDb,
    this._nowMs,
  });

  /// 创建仅用于元数据声明与纯函数合并规划的未绑定切片实例。
  const LibraryCatalogSyncSlice.unbound() : _libraryDb = null, _nowMs = null;

  /// 切片稳定唯一标识。
  static const String id = 'library_catalog_slice';

  final LibraryDatabase? _libraryDb;
  final int Function()? _nowMs;

  @override
  String get sliceId => id;

  @override
  String get displayName => '媒体库与整理元数据';

  @override
  int get schemaVersion => 1;

  @override
  Future<SyncSlicePayload> exportSlice({required String localDeviceId}) async {
    final db = _libraryDb;
    if (db == null) {
      throw StateError('LibraryCatalogSyncSlice 未绑定 LibraryDatabase，无法执行导出');
    }

    final sources = db.mediaSources.listAll(includeDeleted: true);
    final series = db.seriesGroups.listAll(includeDeleted: true);
    final works = db.works.listAllWithTombstones();
    final variants = db.mediaVariants.listAll(includeDeleted: true);

    final episodes = <EpisodeRecord>[];
    for (final work in works) {
      episodes.addAll(db.episodes.listByWork(work.id, includeDeleted: true));
    }

    final ignored = <IgnoredFolderRecord>[];
    for (final src in sources) {
      ignored.addAll(
        db.ignoredFolders.listBySource(src.id, includeDeleted: true),
      );
    }

    final syncSources = <SyncLibrarySourceItem>[
      for (final s in sources)
        SyncLibrarySourceItem.fromRecord(s, fallbackDeviceId: localDeviceId),
    ]..sort((a, b) => a.id.compareTo(b.id));

    final syncSeries = <SyncLibrarySeriesItem>[
      for (final g in series)
        SyncLibrarySeriesItem.fromRecord(g, fallbackDeviceId: localDeviceId),
    ]..sort((a, b) => a.id.compareTo(b.id));

    final syncWorks = <SyncLibraryWorkItem>[
      for (final w in works)
        SyncLibraryWorkItem.fromRecord(w, fallbackDeviceId: localDeviceId),
    ]..sort((a, b) => a.id.compareTo(b.id));

    final syncEpisodes = <SyncLibraryEpisodeItem>[
      for (final e in episodes)
        SyncLibraryEpisodeItem.fromRecord(e, fallbackDeviceId: localDeviceId),
    ]..sort((a, b) => a.id.compareTo(b.id));

    final syncVariants = <SyncLibraryVariantItem>[
      for (final v in variants)
        SyncLibraryVariantItem.fromRecord(v, fallbackDeviceId: localDeviceId),
    ]..sort((a, b) => a.id.compareTo(b.id));

    final syncIgnored = <SyncLibraryIgnoredFolderItem>[
      for (final f in ignored)
        SyncLibraryIgnoredFolderItem.fromRecord(
          f,
          fallbackDeviceId: localDeviceId,
        ),
    ]..sort((a, b) => a.id.compareTo(b.id));

    final now = _nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    return SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      exportedAtMs: now,
      sourceDeviceId: localDeviceId,
      data: <String, Object?>{
        'mediaSources': <Map<String, Object?>>[
          for (final s in syncSources) s.toJson(),
        ],
        'seriesGroups': <Map<String, Object?>>[
          for (final g in syncSeries) g.toJson(),
        ],
        'works': <Map<String, Object?>>[for (final w in syncWorks) w.toJson()],
        'episodes': <Map<String, Object?>>[
          for (final e in syncEpisodes) e.toJson(),
        ],
        'variants': <Map<String, Object?>>[
          for (final v in syncVariants) v.toJson(),
        ],
        'ignoredFolders': <Map<String, Object?>>[
          for (final f in syncIgnored) f.toJson(),
        ],
      },
    );
  }

  @override
  SyncMergePlan<LibraryCatalogMergePlan> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final localCatalog = _parseCatalog(local.data);
    final remoteCatalog = _parseCatalog(remote.data);

    var insertCount = 0;
    var updateCount = 0;
    var deleteCount = 0;
    var skippedCount = 0;

    // 1. 媒体源按 ID -> 归一化协议地址 去重合并，守护本机已有媒体源 ID。
    final localSourceById = <String, SyncLibrarySourceItem>{
      for (final s in localCatalog.sources) s.id: s,
    };
    final localSourceByLoc = <String, SyncLibrarySourceItem>{
      for (final s in localCatalog.sources) s.normalizedLocationKey: s,
    };
    final sourceRemap = <String, String>{};
    final sourcesToUpsert = <SyncLibrarySourceItem>[];

    for (final src in remoteCatalog.sources) {
      final matched =
          localSourceById[src.id] ??
          localSourceByLoc[src.normalizedLocationKey];
      if (matched != null &&
          (matched.kind == MediaSourceKind.cloudDrive ||
              src.kind == MediaSourceKind.cloudDrive) &&
          matched.normalizedLocationKey != src.normalizedLocationKey) {
        throw const FormatException('云盘媒体源身份冲突，拒绝合并');
      }
      if (matched == null) {
        sourceRemap[src.id] = src.id;
        localSourceById[src.id] = src;
        localSourceByLoc[src.normalizedLocationKey] = src;
        if (!src.isDeleted) {
          insertCount++;
        } else {
          skippedCount++;
        }
        sourcesToUpsert.add(src);
        continue;
      }
      sourceRemap[src.id] = matched.id;
      final merged = _mergeSource(matched, src);
      if (_sourceChanged(matched, merged)) {
        if (!matched.isDeleted && merged.isDeleted) {
          deleteCount++;
        } else {
          updateCount++;
        }
        sourcesToUpsert.add(merged);
        localSourceById[merged.id] = merged;
      } else {
        skippedCount++;
      }
    }

    // 2. 系列编组按 ID -> TMDB Collection -> 归一化标题 去重合并。
    final localSeriesById = <String, SyncLibrarySeriesItem>{
      for (final g in localCatalog.series) g.id: g,
    };
    final localSeriesByCollection = <int, SyncLibrarySeriesItem>{
      for (final g in localCatalog.series)
        if (g.tmdbCollectionId != null) g.tmdbCollectionId!: g,
    };
    final localSeriesByTitle = <String, SyncLibrarySeriesItem>{
      for (final g in localCatalog.series)
        if (SyncSanitizer.normalizeTitleKey(g.title).isNotEmpty)
          SyncSanitizer.normalizeTitleKey(g.title): g,
    };
    final seriesRemap = <String, String>{};
    final seriesToUpsert = <SyncLibrarySeriesItem>[];

    for (final group in remoteCatalog.series) {
      final titleKey = SyncSanitizer.normalizeTitleKey(group.title);
      final matched =
          localSeriesById[group.id] ??
          (group.tmdbCollectionId != null
              ? localSeriesByCollection[group.tmdbCollectionId!]
              : null) ??
          (titleKey.isNotEmpty ? localSeriesByTitle[titleKey] : null);
      if (matched == null) {
        seriesRemap[group.id] = group.id;
        localSeriesById[group.id] = group;
        if (!group.isDeleted) {
          insertCount++;
        } else {
          skippedCount++;
        }
        seriesToUpsert.add(group);
        continue;
      }
      seriesRemap[group.id] = matched.id;
      final merged = _mergeSeries(matched, group);
      if (_seriesChanged(matched, merged)) {
        if (!matched.isDeleted && merged.isDeleted) {
          deleteCount++;
        } else {
          updateCount++;
        }
        seriesToUpsert.add(merged);
        localSeriesById[merged.id] = merged;
      } else {
        skippedCount++;
      }
    }

    // 3. 作品按跨源强身份聚类与 ID 合并（涵盖标题、匹配、标签、合集与全部锁）。
    final aliasUnion = _CatalogWorkAliasUnion();
    for (final w in localCatalog.works) {
      aliasUnion.registerKeys(w.allWorkKeys);
    }
    for (final w in remoteCatalog.works) {
      aliasUnion.registerKeys(w.allWorkKeys);
    }

    final localWorkById = <String, SyncLibraryWorkItem>{
      for (final w in localCatalog.works) w.id: w,
    };
    final localWorkByCluster = <String, SyncLibraryWorkItem>{};
    for (final w in localCatalog.works) {
      final cluster = aliasUnion.resolveGroupKey(
        w.allWorkKeys,
        w.canonicalWorkKey,
      );
      if (cluster.isNotEmpty) {
        localWorkByCluster.putIfAbsent(cluster, () => w);
      }
    }
    final workRemap = <String, String>{};
    final worksToUpsert = <SyncLibraryWorkItem>[];
    final droppedRemoteWorkIds = <String>{};

    for (final remoteWork in remoteCatalog.works) {
      final remappedSeriesId = remoteWork.seriesId == null
          ? null
          : (seriesRemap[remoteWork.seriesId!] ?? remoteWork.seriesId);
      final incoming = remoteWork.copyWith(
        seriesId: remappedSeriesId,
        clearSeriesId: remappedSeriesId == null,
      );
      final cluster = aliasUnion.resolveGroupKey(
        incoming.allWorkKeys,
        incoming.canonicalWorkKey,
      );
      final matched =
          localWorkById[incoming.id] ??
          (cluster.isNotEmpty ? localWorkByCluster[cluster] : null);

      if (matched == null) {
        workRemap[incoming.id] = incoming.id;
        localWorkById[incoming.id] = incoming;
        if (cluster.isNotEmpty) {
          localWorkByCluster[cluster] = incoming;
        }
        if (incoming.isDeleted) {
          droppedRemoteWorkIds.add(incoming.id);
          skippedCount++;
        } else {
          insertCount++;
        }
        worksToUpsert.add(incoming);
        continue;
      }

      workRemap[incoming.id] = matched.id;
      final merged = _mergeWork(matched, incoming);
      if (merged.isDeleted) {
        droppedRemoteWorkIds.add(incoming.id);
      }
      if (_workChanged(matched, merged)) {
        if (!matched.isDeleted && merged.isDeleted) {
          deleteCount++;
        } else if (matched.isDeleted && !merged.isDeleted) {
          insertCount++;
        } else {
          updateCount++;
        }
        worksToUpsert.add(merged);
        localWorkById[merged.id] = merged;
      } else {
        skippedCount++;
      }
    }

    // 4. 逻辑剧集与特典对齐合并。
    final localEpById = <String, SyncLibraryEpisodeItem>{
      for (final e in localCatalog.episodes) e.id: e,
    };
    final localEpBySlot = <String, SyncLibraryEpisodeItem>{
      for (final e in localCatalog.episodes) _episodeSlotKey(e.workId, e): e,
    };
    final episodeRemap = <String, String>{};
    final episodesToUpsert = <SyncLibraryEpisodeItem>[];

    for (final ep in remoteCatalog.episodes) {
      final targetWorkId = workRemap[ep.workId];
      if (targetWorkId == null) continue;
      final incoming = ep.copyWith(workId: targetWorkId);
      final slotKey = _episodeSlotKey(targetWorkId, incoming);
      final existingById = localEpById[incoming.id];
      final matched =
          (existingById != null && existingById.workId == targetWorkId)
          ? existingById
          : localEpBySlot[slotKey];

      if (matched == null) {
        final safeId = localEpById.containsKey(incoming.id)
            ? '$targetWorkId::${incoming.id}'
            : incoming.id;
        final created = incoming.copyWith(id: safeId);
        episodeRemap[ep.id] = safeId;
        localEpById[safeId] = created;
        localEpBySlot[slotKey] = created;
        if (!created.isDeleted && !droppedRemoteWorkIds.contains(ep.workId)) {
          insertCount++;
        } else {
          skippedCount++;
        }
        episodesToUpsert.add(created);
        continue;
      }

      episodeRemap[ep.id] = matched.id;
      final merged = _mergeEpisode(matched, incoming);
      if (_episodeChanged(matched, merged)) {
        if (!matched.isDeleted && merged.isDeleted) {
          deleteCount++;
        } else {
          updateCount++;
        }
        episodesToUpsert.add(merged);
        localEpById[merged.id] = merged;
      } else {
        skippedCount++;
      }
    }

    // 5. 物理文件变体与人工映射锁对齐合并。
    final localVarById = <String, SyncLibraryVariantItem>{
      for (final v in localCatalog.variants) v.id: v,
    };
    final localVarByPath = <String, SyncLibraryVariantItem>{
      for (final v in localCatalog.variants)
        '${v.sourceId}::${v.normalizedRelativePath.toLowerCase()}': v,
    };
    final variantsToUpsert = <SyncLibraryVariantItem>[];

    for (final v in remoteCatalog.variants) {
      final targetWorkId = workRemap[v.workId];
      final targetSourceId = sourceRemap[v.sourceId];
      if (targetWorkId == null || targetSourceId == null) continue;
      final targetEpId = v.episodeId == null
          ? null
          : (episodeRemap[v.episodeId!] ?? v.episodeId);
      final incoming = v.copyWith(
        workId: targetWorkId,
        episodeId: targetEpId,
        clearEpisodeId: targetEpId == null,
        sourceId: targetSourceId,
      );
      final pathKey =
          '$targetSourceId::${incoming.normalizedRelativePath.toLowerCase()}';
      final existingById = localVarById[incoming.id];
      final matched =
          (existingById != null && existingById.sourceId == targetSourceId)
          ? existingById
          : localVarByPath[pathKey];

      if (matched == null) {
        final safeId = localVarById.containsKey(incoming.id)
            ? '$targetSourceId::${incoming.id}'
            : incoming.id;
        final created = incoming.copyWith(id: safeId);
        localVarById[safeId] = created;
        localVarByPath[pathKey] = created;
        if (!created.isDeleted && !droppedRemoteWorkIds.contains(v.workId)) {
          insertCount++;
        } else {
          skippedCount++;
        }
        variantsToUpsert.add(created);
        continue;
      }

      if (matched.remoteFileId != null &&
          incoming.remoteFileId != null &&
          matched.remoteFileId != incoming.remoteFileId) {
        throw const FormatException('远端文件标识冲突，拒绝合并');
      }
      final merged = _mergeVariant(matched, incoming);
      if (_variantChanged(matched, merged)) {
        if (!matched.isDeleted && merged.isDeleted) {
          deleteCount++;
        } else {
          updateCount++;
        }
        variantsToUpsert.add(merged);
        localVarById[merged.id] = merged;
      } else {
        skippedCount++;
      }
    }

    // 6. 忽略目录合并。
    final localIgnoredByKey = <String, SyncLibraryIgnoredFolderItem>{
      for (final f in localCatalog.ignoredFolders)
        '${f.sourceId}::${f.relativePath.toLowerCase()}': f,
    };
    final ignoredToUpsert = <SyncLibraryIgnoredFolderItem>[];

    for (final f in remoteCatalog.ignoredFolders) {
      final targetSourceId = sourceRemap[f.sourceId];
      if (targetSourceId == null) continue;
      final incoming = f.copyWith(sourceId: targetSourceId);
      final key = '$targetSourceId::${incoming.relativePath.toLowerCase()}';
      final matched = localIgnoredByKey[key];
      if (matched == null) {
        localIgnoredByKey[key] = incoming;
        if (!incoming.isDeleted) {
          insertCount++;
        } else {
          skippedCount++;
        }
        ignoredToUpsert.add(incoming);
        continue;
      }
      final pickIncoming =
          incoming.effectiveTimestampMs > matched.effectiveTimestampMs;
      if (pickIncoming && matched.deletedAtMs != incoming.deletedAtMs) {
        final next = incoming.copyWith(
          id: matched.id,
          sourceId: matched.sourceId,
        );
        if (!matched.isDeleted && next.isDeleted) {
          deleteCount++;
        } else {
          updateCount++;
        }
        ignoredToUpsert.add(next);
        localIgnoredByKey[key] = next;
      } else {
        skippedCount++;
      }
    }

    return SyncMergePlan<LibraryCatalogMergePlan>(
      sliceId: sliceId,
      insertCount: insertCount,
      updateCount: updateCount,
      deleteCount: deleteCount,
      skippedCount: skippedCount,
      planData: LibraryCatalogMergePlan(
        sourcesToUpsert: List<SyncLibrarySourceItem>.unmodifiable(
          sourcesToUpsert,
        ),
        seriesToUpsert: List<SyncLibrarySeriesItem>.unmodifiable(
          seriesToUpsert,
        ),
        worksToUpsert: List<SyncLibraryWorkItem>.unmodifiable(worksToUpsert),
        episodesToUpsert: List<SyncLibraryEpisodeItem>.unmodifiable(
          episodesToUpsert,
        ),
        variantsToUpsert: List<SyncLibraryVariantItem>.unmodifiable(
          variantsToUpsert,
        ),
        ignoredFoldersToUpsert: List<SyncLibraryIgnoredFolderItem>.unmodifiable(
          ignoredToUpsert,
        ),
      ),
      summaryLines: <String>[
        '媒体库目录：新增 $insertCount 项，更新 $updateCount 项，删除 $deleteCount 项，跳过 $skippedCount 项',
      ],
    );
  }

  /// 生成覆盖还原计划：以备份快照完整重建媒体库目录，同时按同址规则保留本机媒体源标识与安全凭据。
  SyncMergePlan<LibraryCatalogMergePlan> planOverwrite({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final localCatalog = _parseCatalog(local.data);
    final remoteCatalog = _parseCatalog(remote.data);

    final localSourceById = <String, SyncLibrarySourceItem>{
      for (final s in localCatalog.sources) s.id: s,
    };
    final localSourceByLoc = <String, SyncLibrarySourceItem>{
      for (final s in localCatalog.sources) s.normalizedLocationKey: s,
    };

    final sourceRemap = <String, String>{};
    final sourcesToUpsert = <SyncLibrarySourceItem>[];
    for (final src in remoteCatalog.sources) {
      final matched =
          localSourceById[src.id] ??
          localSourceByLoc[src.normalizedLocationKey];
      if (matched != null &&
          (matched.kind == MediaSourceKind.cloudDrive ||
              src.kind == MediaSourceKind.cloudDrive) &&
          matched.normalizedLocationKey != src.normalizedLocationKey) {
        throw const FormatException('云盘媒体源身份冲突，拒绝合并');
      }
      final targetId = matched?.id ?? src.id;
      sourceRemap[src.id] = targetId;
      sourcesToUpsert.add(
        SyncLibrarySourceItem(
          id: targetId,
          canonicalKey: src.canonicalKey,
          kind: src.kind,
          label: src.label,
          location: src.location,
          username: src.username,
          createdAtMs: src.createdAtMs,
          updatedAtMs: src.updatedAtMs,
          sourceDeviceId: src.sourceDeviceId,
          deletedAtMs: src.deletedAtMs,
        ),
      );
    }

    final variantsToUpsert = <SyncLibraryVariantItem>[
      for (final v in remoteCatalog.variants)
        v.copyWith(sourceId: sourceRemap[v.sourceId] ?? v.sourceId),
    ];
    final ignoredToUpsert = <SyncLibraryIgnoredFolderItem>[
      for (final f in remoteCatalog.ignoredFolders)
        f.copyWith(sourceId: sourceRemap[f.sourceId] ?? f.sourceId),
    ];

    final activeInsertCount =
        sourcesToUpsert.where((s) => !s.isDeleted).length +
        remoteCatalog.series.where((s) => !s.isDeleted).length +
        remoteCatalog.works.where((w) => !w.isDeleted).length +
        remoteCatalog.episodes.where((e) => !e.isDeleted).length +
        variantsToUpsert.where((v) => !v.isDeleted).length +
        ignoredToUpsert.where((f) => !f.isDeleted).length;

    return SyncMergePlan<LibraryCatalogMergePlan>(
      sliceId: sliceId,
      insertCount: activeInsertCount,
      updateCount: 0,
      deleteCount: 0,
      skippedCount: 0,
      planData: LibraryCatalogMergePlan(
        sourcesToUpsert: List<SyncLibrarySourceItem>.unmodifiable(
          sourcesToUpsert,
        ),
        seriesToUpsert: List<SyncLibrarySeriesItem>.unmodifiable(
          remoteCatalog.series,
        ),
        worksToUpsert: List<SyncLibraryWorkItem>.unmodifiable(
          remoteCatalog.works,
        ),
        episodesToUpsert: List<SyncLibraryEpisodeItem>.unmodifiable(
          remoteCatalog.episodes,
        ),
        variantsToUpsert: List<SyncLibraryVariantItem>.unmodifiable(
          variantsToUpsert,
        ),
        ignoredFoldersToUpsert: List<SyncLibraryIgnoredFolderItem>.unmodifiable(
          ignoredToUpsert,
        ),
        clearExistingBeforeApply: true,
      ),
      summaryLines: <String>['媒体库目录（覆盖还原）：恢复 $activeInsertCount 条有效记录'],
    );
  }

  @override
  Future<void> applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<LibraryCatalogMergePlan> plan,
  ) {
    final data = plan.planData;
    final hasAnyWork =
        plan.hasChanges ||
        data.sourcesToUpsert.isNotEmpty ||
        data.seriesToUpsert.isNotEmpty ||
        data.worksToUpsert.isNotEmpty ||
        data.episodesToUpsert.isNotEmpty ||
        data.variantsToUpsert.isNotEmpty ||
        data.ignoredFoldersToUpsert.isNotEmpty ||
        data.clearExistingBeforeApply;
    if (!hasAnyWork) {
      return Future<void>.value();
    }
    final db = _libraryDb;
    if (db == null) {
      throw StateError('LibraryCatalogSyncSlice 未绑定 LibraryDatabase，无法应用合并计划');
    }

    final handle = tx.rawHandleFor('library');
    if (handle is SqliteTransaction) {
      _applyInTransaction(db, handle, tx, data);
    } else {
      db.engine.runTransaction(
        (innerTx) => _applyInTransaction(db, innerTx, tx, data),
      );
    }
    return Future<void>.value();
  }

  void _applyInTransaction(
    LibraryDatabase db,
    SqliteTransaction libTx,
    SyncTransactionContext txCtx,
    LibraryCatalogMergePlan data,
  ) {
    if (data.clearExistingBeforeApply) {
      final keepSourceIds = <String>{
        for (final s in data.sourcesToUpsert) s.id,
      };
      for (final v in db.mediaVariants.listAll()) {
        db.mediaVariants.upsertInTx(
          libTx,
          MediaVariantRecord(
            id: v.id,
            canonicalKey: v.canonicalKey,
            workId: v.workId,
            episodeId: v.episodeId,
            sourceId: v.sourceId,
            relativePath: v.relativePath,
            fileName: v.fileName,
            fileSize: v.fileSize,
            remoteFileId: v.remoteFileId,
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
            updatedAtMs: txCtx.appliedAtMs,
            sourceDeviceId: txCtx.localDeviceId,
            deletedAtMs: txCtx.appliedAtMs,
          ),
        );
      }
      for (final w in db.works.listAll()) {
        for (final ep in db.episodes.listByWork(w.id)) {
          db.episodes.upsertInTx(
            libTx,
            EpisodeRecord(
              id: ep.id,
              canonicalKey: ep.canonicalKey,
              workId: ep.workId,
              seasonNumber: ep.seasonNumber,
              episodeNumber: ep.episodeNumber,
              episodeNumberEnd: ep.episodeNumberEnd,
              category: ep.category,
              extraType: ep.extraType,
              title: ep.title,
              overview: ep.overview,
              stillPath: ep.stillPath,
              updatedAtMs: txCtx.appliedAtMs,
              sourceDeviceId: txCtx.localDeviceId,
              deletedAtMs: txCtx.appliedAtMs,
            ),
          );
        }
        db.works.upsertInTx(
          libTx,
          WorkRecord(
            id: w.id,
            canonicalKey: w.canonicalKey,
            tmdbId: w.tmdbId,
            tmdbMediaType: w.tmdbMediaType,
            bangumiId: w.bangumiId,
            tvdbId: w.tvdbId,
            matchedSeason: w.matchedSeason,
            title: w.title,
            originalTitle: w.originalTitle,
            year: w.year,
            overview: w.overview,
            posterRef: w.posterRef,
            posterFallback: w.posterFallback,
            bangumiPosterPath: w.bangumiPosterPath,
            backdropRef: w.backdropRef,
            portraitBackdropRef: w.portraitBackdropRef,
            logoRef: w.logoRef,
            voteAverage: w.voteAverage,
            bangumiScore: w.bangumiScore,
            folderTmdbHint: w.folderTmdbHint,
            isManualLocked: w.isManualLocked,
            metadataLocked: w.metadataLocked,
            isHidden: w.isHidden,
            keepHidden: w.keepHidden,
            scrapeStatus: w.scrapeStatus,
            reviewReason: w.reviewReason,
            seriesId: w.seriesId,
            seriesOrder: w.seriesOrder,
            seriesLabel: w.seriesLabel,
            seriesLocked: w.seriesLocked,
            updatedAtMs: txCtx.appliedAtMs,
            sourceDeviceId: txCtx.localDeviceId,
            deletedAtMs: txCtx.appliedAtMs,
          ),
        );
      }
      for (final g in db.seriesGroups.listAll()) {
        db.seriesGroups.upsertInTx(
          libTx,
          SeriesGroupRecord(
            id: g.id,
            canonicalKey: g.canonicalKey,
            title: g.title,
            tmdbCollectionId: g.tmdbCollectionId,
            rootFolderHint: g.rootFolderHint,
            createdAtMs: g.createdAtMs,
            updatedAtMs: txCtx.appliedAtMs,
            sourceDeviceId: txCtx.localDeviceId,
            deletedAtMs: txCtx.appliedAtMs,
          ),
        );
      }
      for (final s in db.mediaSources.listAll()) {
        if (!keepSourceIds.contains(s.id.value)) {
          db.mediaSources.upsertInTx(
            libTx,
            MediaSourceRecord(
              id: s.id,
              canonicalKey: s.canonicalKey,
              kind: s.kind,
              label: s.label,
              location: s.location,
              username: s.username,
              createdAtMs: s.createdAtMs,
              updatedAtMs: txCtx.appliedAtMs,
              sourceDeviceId: txCtx.localDeviceId,
              deletedAtMs: txCtx.appliedAtMs,
            ),
          );
        }
      }
    }

    // 严格按外键依赖顺序写入：media_sources -> series_groups -> works -> episodes -> media_variants -> ignored_folders。
    for (final src in data.sourcesToUpsert) {
      db.mediaSources.upsertInTx(libTx, src.toRecord());
    }
    for (final group in data.seriesToUpsert) {
      db.seriesGroups.upsertInTx(libTx, group.toRecord());
    }
    for (final work in data.worksToUpsert) {
      final existing = db.works.findById(
        WorkId.trusted(work.id),
        includeDeleted: true,
      );
      final preservePoster =
          !data.clearExistingBeforeApply &&
              work.posterRef == null &&
              existing?.posterRef is LocalCustomArtworkRef
          ? existing!.posterRef
          : null;
      final preserveBackdrop =
          !data.clearExistingBeforeApply &&
              work.backdropRef == null &&
              existing?.backdropRef is LocalCustomArtworkRef
          ? existing!.backdropRef
          : null;
      final preservePortraitBackdrop =
          !data.clearExistingBeforeApply &&
              work.portraitBackdropRef == null &&
              existing?.portraitBackdropRef is LocalCustomArtworkRef
          ? existing!.portraitBackdropRef
          : null;
      final preserveLogo =
          !data.clearExistingBeforeApply &&
              work.logoRef == null &&
              existing?.logoRef is LocalCustomArtworkRef
          ? existing!.logoRef
          : null;
      db.works.upsertInTx(
        libTx,
        work.toRecord(
          preservePosterRef: preservePoster,
          preserveBackdropRef: preserveBackdrop,
          preservePortraitBackdropRef: preservePortraitBackdrop,
          preserveLogoRef: preserveLogo,
        ),
      );
    }
    for (final ep in data.episodesToUpsert) {
      db.episodes.upsertInTx(libTx, ep.toRecord());
    }
    for (final v in data.variantsToUpsert) {
      db.mediaVariants.upsertInTx(libTx, v.toRecord());
    }
    for (final folder in data.ignoredFoldersToUpsert) {
      db.ignoredFolders.upsertInTx(libTx, folder.toRecord());
    }
  }

  static _ParsedCatalog _parseCatalog(Map<String, Object?> data) {
    List<T> parseList<T>(
      String key,
      T? Function(Map<String, Object?> item) parser,
    ) {
      final raw = data[key];
      if (raw is! List) return const [];
      final out = <T>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final parsed = parser(SyncSanitizer.coerceStringKeyMap(item));
        if (parsed != null) out.add(parsed);
      }
      return out;
    }

    return _ParsedCatalog(
      sources: parseList('mediaSources', SyncLibrarySourceItem.tryFromJson),
      series: parseList('seriesGroups', SyncLibrarySeriesItem.tryFromJson),
      works: parseList('works', SyncLibraryWorkItem.tryFromJson),
      episodes: parseList('episodes', SyncLibraryEpisodeItem.tryFromJson),
      variants: parseList('variants', SyncLibraryVariantItem.tryFromJson),
      ignoredFolders: parseList(
        'ignoredFolders',
        SyncLibraryIgnoredFolderItem.tryFromJson,
      ),
    );
  }

  static SyncLibrarySourceItem _mergeSource(
    SyncLibrarySourceItem local,
    SyncLibrarySourceItem remote,
  ) {
    if (local.isDeleted || remote.isDeleted) {
      if (remote.effectiveTimestampMs > local.effectiveTimestampMs) {
        return SyncLibrarySourceItem(
          id: local.id,
          canonicalKey: remote.canonicalKey ?? local.canonicalKey,
          kind: remote.kind,
          label: remote.label,
          location: remote.location,
          username: remote.username,
          createdAtMs: local.createdAtMs > 0
              ? local.createdAtMs
              : remote.createdAtMs,
          updatedAtMs: remote.updatedAtMs,
          sourceDeviceId: remote.sourceDeviceId,
          deletedAtMs: remote.deletedAtMs,
        );
      }
      return local;
    }
    if (remote.updatedAtMs > local.updatedAtMs) {
      return SyncLibrarySourceItem(
        id: local.id,
        canonicalKey: remote.canonicalKey ?? local.canonicalKey,
        kind: local.kind,
        label: remote.label.isNotEmpty ? remote.label : local.label,
        location: local.location,
        username: remote.username ?? local.username,
        createdAtMs: local.createdAtMs > 0
            ? local.createdAtMs
            : remote.createdAtMs,
        updatedAtMs: remote.updatedAtMs,
        sourceDeviceId: remote.sourceDeviceId,
      );
    }
    return local;
  }

  static SyncLibrarySeriesItem _mergeSeries(
    SyncLibrarySeriesItem local,
    SyncLibrarySeriesItem remote,
  ) {
    if (local.isDeleted || remote.isDeleted) {
      if (remote.effectiveTimestampMs > local.effectiveTimestampMs) {
        return SyncLibrarySeriesItem(
          id: local.id,
          canonicalKey: remote.canonicalKey ?? local.canonicalKey,
          title: remote.title.isNotEmpty ? remote.title : local.title,
          tmdbCollectionId: remote.tmdbCollectionId ?? local.tmdbCollectionId,
          rootFolderHint: remote.rootFolderHint ?? local.rootFolderHint,
          createdAtMs: local.createdAtMs > 0
              ? local.createdAtMs
              : remote.createdAtMs,
          updatedAtMs: remote.updatedAtMs,
          sourceDeviceId: remote.sourceDeviceId,
          deletedAtMs: remote.deletedAtMs,
        );
      }
      return local;
    }
    if (remote.updatedAtMs > local.updatedAtMs) {
      return SyncLibrarySeriesItem(
        id: local.id,
        canonicalKey: remote.canonicalKey ?? local.canonicalKey,
        title: remote.title.isNotEmpty ? remote.title : local.title,
        tmdbCollectionId: remote.tmdbCollectionId ?? local.tmdbCollectionId,
        rootFolderHint: remote.rootFolderHint ?? local.rootFolderHint,
        createdAtMs: local.createdAtMs > 0
            ? local.createdAtMs
            : remote.createdAtMs,
        updatedAtMs: remote.updatedAtMs,
        sourceDeviceId: remote.sourceDeviceId,
      );
    }
    return local;
  }

  static SyncLibraryWorkItem _mergeWork(
    SyncLibraryWorkItem local,
    SyncLibraryWorkItem remote,
  ) {
    if (local.isDeleted && remote.isDeleted) {
      return remote.effectiveTimestampMs > local.effectiveTimestampMs
          ? remote.copyWith(id: local.id)
          : local;
    }
    if (local.isDeleted || remote.isDeleted) {
      final tomb = local.isDeleted ? local : remote;
      final active = local.isDeleted ? remote : local;
      if (tomb.effectiveTimestampMs >= active.effectiveTimestampMs) {
        return tomb.copyWith(id: local.id);
      }
      return active.copyWith(id: local.id);
    }

    final bool incomingWins;
    if (remote.updatedAtMs != local.updatedAtMs) {
      incomingWins = remote.updatedAtMs > local.updatedAtMs;
    } else if (remote.scrapeStatus != local.scrapeStatus) {
      incomingWins = remote.scrapeStatus == ScrapeStatus.matched;
    } else {
      incomingWins = _workRichness(remote) > _workRichness(local);
    }
    final winner = incomingWins ? remote : local;
    final loser = incomingWins ? local : remote;

    String? pickNonEmpty(String? a, String? b) =>
        (a != null && a.trim().isNotEmpty) ? a : b;

    ArtworkRef? pickArtwork(ArtworkRef? a, ArtworkRef? b) {
      if (a != null && b != null) {
        if (a.locked != b.locked) return a.locked ? a : b;
        return a;
      }
      return a ?? b;
    }

    final mergedKeys = <String>[
      winner.canonicalWorkKey,
      ...winner.secondaryWorkKeys,
      loser.canonicalWorkKey,
      ...loser.secondaryWorkKeys,
    ];
    final primaryKey = _pickPreferredWorkKey(mergedKeys);
    final secondaryKeys = <String>{
      for (final k in mergedKeys)
        if (k.isNotEmpty && k != primaryKey) k,
    }.toList(growable: false);

    return SyncLibraryWorkItem(
      id: local.id,
      canonicalWorkKey: primaryKey,
      secondaryWorkKeys: secondaryKeys,
      title: winner.title.trim().isNotEmpty ? winner.title : loser.title,
      tmdbId: winner.tmdbId ?? loser.tmdbId,
      tmdbMediaType: winner.tmdbMediaType ?? loser.tmdbMediaType,
      bangumiId: winner.bangumiId ?? loser.bangumiId,
      tvdbId: winner.tvdbId ?? loser.tvdbId,
      matchedSeason: winner.matchedSeason ?? loser.matchedSeason,
      originalTitle: pickNonEmpty(winner.originalTitle, loser.originalTitle),
      year: winner.year ?? loser.year,
      overview: pickNonEmpty(winner.overview, loser.overview),
      posterRef: pickArtwork(winner.posterRef, loser.posterRef),
      posterFallback: pickNonEmpty(winner.posterFallback, loser.posterFallback),
      bangumiPosterPath: pickNonEmpty(
        winner.bangumiPosterPath,
        loser.bangumiPosterPath,
      ),
      backdropRef: pickArtwork(winner.backdropRef, loser.backdropRef),
      portraitBackdropRef: pickArtwork(
        winner.portraitBackdropRef,
        loser.portraitBackdropRef,
      ),
      logoRef: pickArtwork(winner.logoRef, loser.logoRef),
      voteAverage: winner.voteAverage ?? loser.voteAverage,
      bangumiScore: winner.bangumiScore ?? loser.bangumiScore,
      folderTmdbHint: winner.folderTmdbHint ?? loser.folderTmdbHint,
      isManualLocked: local.isManualLocked || remote.isManualLocked,
      metadataLocked: local.metadataLocked || remote.metadataLocked,
      isHidden: winner.isHidden,
      keepHidden: winner.keepHidden,
      scrapeStatus:
          winner.scrapeStatus == ScrapeStatus.unmatched &&
              loser.scrapeStatus != ScrapeStatus.unmatched
          ? loser.scrapeStatus
          : winner.scrapeStatus,
      reviewReason: winner.scrapeStatus == ScrapeStatus.matched
          ? null
          : pickNonEmpty(winner.reviewReason, loser.reviewReason),
      seriesId: pickNonEmpty(winner.seriesId, loser.seriesId),
      seriesOrder: winner.seriesOrder ?? loser.seriesOrder,
      seriesLabel: pickNonEmpty(winner.seriesLabel, loser.seriesLabel),
      seriesLocked: local.seriesLocked || remote.seriesLocked,
      updatedAtMs: math.max(local.updatedAtMs, remote.updatedAtMs),
      sourceDeviceId: winner.sourceDeviceId.isNotEmpty
          ? winner.sourceDeviceId
          : loser.sourceDeviceId,
    );
  }

  static SyncLibraryEpisodeItem _mergeEpisode(
    SyncLibraryEpisodeItem local,
    SyncLibraryEpisodeItem remote,
  ) {
    if (local.isDeleted || remote.isDeleted) {
      if (remote.effectiveTimestampMs > local.effectiveTimestampMs) {
        return remote.copyWith(id: local.id, workId: local.workId);
      }
      return local;
    }
    final newer = remote.updatedAtMs >= local.updatedAtMs ? remote : local;
    final older = identical(newer, remote) ? local : remote;
    String? pickNonEmpty(String? a, String? b) =>
        (a != null && a.trim().isNotEmpty) ? a : b;
    return SyncLibraryEpisodeItem(
      id: local.id,
      canonicalKey: newer.canonicalKey ?? older.canonicalKey,
      workId: local.workId,
      seasonNumber: local.seasonNumber,
      episodeNumber: local.episodeNumber ?? remote.episodeNumber,
      episodeNumberEnd: local.episodeNumberEnd ?? remote.episodeNumberEnd,
      category: local.category,
      extraType: local.extraType ?? remote.extraType,
      title: pickNonEmpty(newer.title, older.title),
      overview: pickNonEmpty(newer.overview, older.overview),
      stillPath: pickNonEmpty(newer.stillPath, older.stillPath),
      updatedAtMs: math.max(local.updatedAtMs, remote.updatedAtMs),
      sourceDeviceId: newer.sourceDeviceId,
    );
  }

  static SyncLibraryVariantItem _mergeVariant(
    SyncLibraryVariantItem local,
    SyncLibraryVariantItem remote,
  ) {
    if (local.isDeleted || remote.isDeleted) {
      if (remote.effectiveTimestampMs > local.effectiveTimestampMs) {
        return SyncLibraryVariantItem(
          id: local.id,
          canonicalKey: remote.canonicalKey ?? local.canonicalKey,
          workId: local.workId,
          episodeId: local.episodeId,
          sourceId: local.sourceId,
          relativePath: local.relativePath,
          fileName: local.fileName,
          fileSize: local.fileSize,
          remoteFileId: local.remoteFileId ?? remote.remoteFileId,
          assetKind: local.assetKind,
          releaseGroup: local.releaseGroup,
          subtitleGroup: local.subtitleGroup,
          videoCodec: local.videoCodec,
          bitDepth: local.bitDepth,
          resolution: local.resolution,
          audioCodec: local.audioCodec,
          externalSubtitles: local.externalSubtitles,
          mappingLocked: local.mappingLocked,
          workLocked: local.workLocked,
          assetScope: local.assetScope,
          scopeLocked: local.scopeLocked,
          updatedAtMs: remote.updatedAtMs,
          sourceDeviceId: remote.sourceDeviceId,
          deletedAtMs: remote.deletedAtMs,
        );
      }
      return local;
    }
    final useRemoteMapping = remote.mappingLocked && !local.mappingLocked;
    final useRemoteWork = remote.workLocked && !local.workLocked;
    final useRemoteScope = remote.scopeLocked && !local.scopeLocked;
    return SyncLibraryVariantItem(
      id: local.id,
      canonicalKey: remote.canonicalKey ?? local.canonicalKey,
      workId: useRemoteWork ? remote.workId : local.workId,
      episodeId: useRemoteMapping
          ? (remote.episodeId ?? local.episodeId)
          : (local.episodeId ?? remote.episodeId),
      sourceId: local.sourceId,
      relativePath: local.relativePath,
      fileName: local.fileName.isNotEmpty ? local.fileName : remote.fileName,
      fileSize: local.fileSize > 0 ? local.fileSize : remote.fileSize,
      remoteFileId: local.remoteFileId ?? remote.remoteFileId,
      assetKind: local.assetKind,
      releaseGroup: local.releaseGroup ?? remote.releaseGroup,
      subtitleGroup: local.subtitleGroup ?? remote.subtitleGroup,
      videoCodec: local.videoCodec ?? remote.videoCodec,
      bitDepth: local.bitDepth ?? remote.bitDepth,
      resolution: local.resolution ?? remote.resolution,
      audioCodec: local.audioCodec ?? remote.audioCodec,
      externalSubtitles: local.externalSubtitles.isNotEmpty
          ? local.externalSubtitles
          : remote.externalSubtitles,
      mappingLocked: local.mappingLocked || remote.mappingLocked,
      workLocked: local.workLocked || remote.workLocked,
      assetScope: useRemoteScope ? remote.assetScope : local.assetScope,
      scopeLocked: local.scopeLocked || remote.scopeLocked,
      updatedAtMs: math.max(local.updatedAtMs, remote.updatedAtMs),
      sourceDeviceId: remote.sourceDeviceId.isNotEmpty
          ? remote.sourceDeviceId
          : local.sourceDeviceId,
    );
  }

  static String _episodeSlotKey(String workId, SyncLibraryEpisodeItem ep) {
    if (ep.category == EpisodeCategory.main && ep.episodeNumber != null) {
      return '$workId::main::s${ep.seasonNumber}::e${ep.episodeNumber}::${ep.episodeNumberEnd ?? ''}';
    }
    if (ep.category == EpisodeCategory.extra) {
      return '$workId::extra::${ep.extraType?.name ?? ''}::${ep.episodeNumber ?? ''}::${SyncSanitizer.normalizeTitleKey(ep.title ?? '')}';
    }
    return '$workId::single::${ep.category.name}::${SyncSanitizer.normalizeTitleKey(ep.title ?? '')}';
  }

  static int _workRichness(SyncLibraryWorkItem w) {
    var score = 0;
    if (w.scrapeStatus == ScrapeStatus.matched) score += 8;
    if (w.tmdbId != null) score += 4;
    if (w.bangumiId != null) score += 4;
    if (w.isManualLocked || w.metadataLocked) score += 3;
    if (w.posterRef != null) score += 2;
    if (w.backdropRef != null) score += 2;
    if (w.portraitBackdropRef != null) score += 1;
    if (w.logoRef != null) score += 2;
    if (w.overview != null && w.overview!.isNotEmpty) score += 1;
    if (w.seriesId != null && w.seriesId!.isNotEmpty) score += 1;
    return score;
  }

  static String _pickPreferredWorkKey(List<String> keys) {
    for (final k in keys) {
      if (k.startsWith('tmdb:')) return k;
    }
    for (final k in keys) {
      if (k.startsWith('bgm:')) return k;
    }
    return keys.isEmpty ? '' : keys.first;
  }

  static bool _sourceChanged(SyncLibrarySourceItem a, SyncLibrarySourceItem b) {
    return a.label != b.label ||
        a.location != b.location ||
        a.username != b.username ||
        a.deletedAtMs != b.deletedAtMs;
  }

  static bool _seriesChanged(SyncLibrarySeriesItem a, SyncLibrarySeriesItem b) {
    return a.title != b.title ||
        a.tmdbCollectionId != b.tmdbCollectionId ||
        a.rootFolderHint != b.rootFolderHint ||
        a.deletedAtMs != b.deletedAtMs;
  }

  static bool _workChanged(SyncLibraryWorkItem a, SyncLibraryWorkItem b) {
    return a.tmdbId != b.tmdbId ||
        a.tmdbMediaType != b.tmdbMediaType ||
        a.bangumiId != b.bangumiId ||
        a.tvdbId != b.tvdbId ||
        a.matchedSeason != b.matchedSeason ||
        a.title != b.title ||
        a.originalTitle != b.originalTitle ||
        a.year != b.year ||
        a.overview != b.overview ||
        a.posterRef != b.posterRef ||
        a.posterFallback != b.posterFallback ||
        a.bangumiPosterPath != b.bangumiPosterPath ||
        a.backdropRef != b.backdropRef ||
        a.portraitBackdropRef != b.portraitBackdropRef ||
        a.logoRef != b.logoRef ||
        a.voteAverage != b.voteAverage ||
        a.bangumiScore != b.bangumiScore ||
        a.isManualLocked != b.isManualLocked ||
        a.metadataLocked != b.metadataLocked ||
        a.isHidden != b.isHidden ||
        a.keepHidden != b.keepHidden ||
        a.scrapeStatus != b.scrapeStatus ||
        a.reviewReason != b.reviewReason ||
        a.seriesId != b.seriesId ||
        a.seriesOrder != b.seriesOrder ||
        a.seriesLabel != b.seriesLabel ||
        a.seriesLocked != b.seriesLocked ||
        a.deletedAtMs != b.deletedAtMs;
  }

  static bool _episodeChanged(
    SyncLibraryEpisodeItem a,
    SyncLibraryEpisodeItem b,
  ) {
    return a.episodeNumber != b.episodeNumber ||
        a.episodeNumberEnd != b.episodeNumberEnd ||
        a.extraType != b.extraType ||
        a.title != b.title ||
        a.overview != b.overview ||
        a.stillPath != b.stillPath ||
        a.deletedAtMs != b.deletedAtMs;
  }

  static bool _variantChanged(
    SyncLibraryVariantItem a,
    SyncLibraryVariantItem b,
  ) {
    if (a.workId != b.workId ||
        a.episodeId != b.episodeId ||
        a.fileName != b.fileName ||
        a.fileSize != b.fileSize ||
        a.remoteFileId != b.remoteFileId ||
        a.releaseGroup != b.releaseGroup ||
        a.subtitleGroup != b.subtitleGroup ||
        a.videoCodec != b.videoCodec ||
        a.bitDepth != b.bitDepth ||
        a.resolution != b.resolution ||
        a.audioCodec != b.audioCodec ||
        a.mappingLocked != b.mappingLocked ||
        a.workLocked != b.workLocked ||
        a.assetScope != b.assetScope ||
        a.scopeLocked != b.scopeLocked ||
        a.deletedAtMs != b.deletedAtMs) {
      return true;
    }
    if (a.externalSubtitles.length != b.externalSubtitles.length) return true;
    for (var i = 0; i < a.externalSubtitles.length; i++) {
      if (a.externalSubtitles[i] != b.externalSubtitles[i]) return true;
    }
    return false;
  }
}

final class _ParsedCatalog {
  const _ParsedCatalog({
    required this.sources,
    required this.series,
    required this.works,
    required this.episodes,
    required this.variants,
    required this.ignoredFolders,
  });

  final List<SyncLibrarySourceItem> sources;
  final List<SyncLibrarySeriesItem> series;
  final List<SyncLibraryWorkItem> works;
  final List<SyncLibraryEpisodeItem> episodes;
  final List<SyncLibraryVariantItem> variants;
  final List<SyncLibraryIgnoredFolderItem> ignoredFolders;
}

final class _CatalogWorkAliasUnion {
  final Map<String, String> _parent = <String, String>{};

  void registerKeys(Iterable<String> keys) {
    final strong = <String>[
      for (final k in keys)
        if (k.startsWith('tmdb:') || k.startsWith('bgm:')) k,
    ];
    if (strong.length < 2) return;
    for (var i = 1; i < strong.length; i++) {
      _union(strong.first, strong[i]);
    }
  }

  String resolveGroupKey(Iterable<String> keys, String fallback) {
    for (final k in keys) {
      if (k.startsWith('tmdb:') || k.startsWith('bgm:')) {
        return _parent.containsKey(k) ? _find(k) : k;
      }
    }
    return fallback;
  }

  void _union(String a, String b) {
    _parent.putIfAbsent(a, () => a);
    _parent.putIfAbsent(b, () => b);
    final ra = _find(a);
    final rb = _find(b);
    if (ra == rb) return;
    if (_rank(ra) <= _rank(rb)) {
      _parent[rb] = ra;
    } else {
      _parent[ra] = rb;
    }
  }

  String _find(String x) {
    final p = _parent[x];
    if (p == null || p == x) return x;
    final root = _find(p);
    _parent[x] = root;
    return root;
  }

  int _rank(String key) {
    if (key.startsWith('tmdb:')) return 0;
    if (key.startsWith('bgm:')) return 1;
    return 2;
  }
}
