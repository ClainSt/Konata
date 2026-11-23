import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/work.dart';

/// 跨设备稳定作品身份键解析器。
///
/// 将不同设备上主键 `workId` 与本地磁盘路径完全不同的同一部动画，
/// 映射到确定性的跨端身份键（优先 TMDB 强身份，次选 Bangumi 强身份，末选归一化标题年份），
/// 并同时产出辅助关联键，确保一端仅绑定 Bangumi、另一端同时绑定 TMDB+Bangumi 时仍能准确对齐。
abstract final class CanonicalWorkIdentity {
  static final RegExp _nonWordPattern = RegExp(
    r'[\s\-_:：·•.,，。!！?？()（）\[\]【】/\\]+',
  );

  /// 为指定作品生成主跨端身份键。
  static String primaryKeyFor(Work work) {
    if (work.tmdbId != null && work.tmdbMediaType != null) {
      final season = work.tmdbMediaType == TmdbMediaType.tv
          ? (work.matchedSeason ?? 1)
          : 0;
      return 'tmdb:${work.tmdbMediaType!.name}:${work.tmdbId}:s$season';
    }
    if (work.bangumiId != null) {
      return 'bgm:${work.bangumiId}';
    }
    return 'title:${normalizeTitleKey(work.title)}:${work.year ?? 0}';
  }

  /// 为指定作品生成全部可匹配身份键集合（含主身份键与可选 Bangumi/标题辅助键）。
  static List<String> allKeysFor(Work work) {
    final keys = <String>[];
    void addUnique(String key) {
      if (key.isNotEmpty && !keys.contains(key)) {
        keys.add(key);
      }
    }

    addUnique(primaryKeyFor(work));
    if (work.bangumiId != null) {
      addUnique('bgm:${work.bangumiId}');
    }
    if (work.tmdbId != null && work.tmdbMediaType != null) {
      final season = work.tmdbMediaType == TmdbMediaType.tv
          ? (work.matchedSeason ?? 1)
          : 0;
      addUnique('tmdb:${work.tmdbMediaType!.name}:${work.tmdbId}:s$season');
    }
    final titleKey = normalizeTitleKey(work.title);
    if (titleKey.isNotEmpty) {
      addUnique('title:$titleKey:${work.year ?? 0}');
    }
    return keys;
  }

  /// 构建单条播放进度在跨设备同步与墓碑表中的稳定逻辑键。
  static String playbackKey({
    required String canonicalWorkKey,
    required int seasonNumber,
    required int? episodeNumber,
    required bool isAudio,
    String? audioTrackHint,
  }) {
    if (isAudio) {
      final hint = normalizeTitleKey(audioTrackHint ?? '');
      return 'playback::$canonicalWorkKey::audio::$hint';
    }
    final epPart = episodeNumber == null ? 'feature' : 'e$episodeNumber';
    return 'playback::$canonicalWorkKey::s$seasonNumber::$epPart';
  }

  /// 归一化标题字符串用于跨端兜底对齐。
  static String normalizeTitleKey(String raw) {
    return raw.trim().toLowerCase().replaceAll(_nonWordPattern, '');
  }
}

/// 可跨设备同步与备份的单集/单曲播放进度记录（不含物理磁盘路径与媒体源密码）。
class SyncPlaybackEntry {
  /// 创建可移植播放进度条目。
  const SyncPlaybackEntry({
    required this.playbackKey,
    required this.canonicalWorkKey,
    this.secondaryWorkKeys = const <String>[],
    required this.seasonNumber,
    this.episodeNumber,
    required this.isAudio,
    required this.episodeTitle,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.isCompleted,
    required this.playedAtMs,
    required this.updatedAtMs,
    this.sourceDeviceId = '',
  });

  /// 逻辑播放主键（由 [CanonicalWorkIdentity.playbackKey] 生成）。
  final String playbackKey;

  /// 所属作品主跨端身份键。
  final String canonicalWorkKey;

  /// 所属作品辅助跨端身份键列表（用于跨源补齐关联）。
  final List<String> secondaryWorkKeys;

  /// 季号。
  final int seasonNumber;

  /// 集号（独立剧场版/未编号单作可为空）。
  final int? episodeNumber;

  /// 是否为 CD 音频记录。
  final bool isAudio;

  /// 剧集或曲目标题。
  final String episodeTitle;

  /// 当前播放秒数。
  final int positionSeconds;

  /// 总时长秒数。
  final int durationSeconds;

  /// 是否已看完/听完。
  final bool isCompleted;

  /// 最近播放时间（UTC 毫秒）。
  final int playedAtMs;

  /// 最近状态更新时间（UTC 毫秒，用于冲突合并裁决）。
  final int updatedAtMs;

  /// 最近写入该条目的设备标识。
  final String sourceDeviceId;

  /// 返回全部可用于匹配本地作品的身份键（主身份键 + 辅助身份键）。
  Iterable<String> get allWorkKeys sync* {
    yield canonicalWorkKey;
    yield* secondaryWorkKeys;
  }

  /// 复制并替换指定字段。
  SyncPlaybackEntry copyWith({
    String? playbackKey,
    String? canonicalWorkKey,
    List<String>? secondaryWorkKeys,
    int? seasonNumber,
    int? episodeNumber,
    bool? isAudio,
    String? episodeTitle,
    int? positionSeconds,
    int? durationSeconds,
    bool? isCompleted,
    int? playedAtMs,
    int? updatedAtMs,
    String? sourceDeviceId,
  }) {
    return SyncPlaybackEntry(
      playbackKey: playbackKey ?? this.playbackKey,
      canonicalWorkKey: canonicalWorkKey ?? this.canonicalWorkKey,
      secondaryWorkKeys: secondaryWorkKeys ?? this.secondaryWorkKeys,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      isAudio: isAudio ?? this.isAudio,
      episodeTitle: episodeTitle ?? this.episodeTitle,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      isCompleted: isCompleted ?? this.isCompleted,
      playedAtMs: playedAtMs ?? this.playedAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      sourceDeviceId: sourceDeviceId ?? this.sourceDeviceId,
    );
  }

  /// 序列化为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'playbackKey': playbackKey,
    'canonicalWorkKey': canonicalWorkKey,
    if (secondaryWorkKeys.isNotEmpty) 'secondaryWorkKeys': secondaryWorkKeys,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'isAudio': isAudio,
    'episodeTitle': episodeTitle,
    'positionSeconds': positionSeconds,
    'durationSeconds': durationSeconds,
    'isCompleted': isCompleted,
    'playedAtMs': playedAtMs,
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
  };

  /// 从 JSON 解析。
  factory SyncPlaybackEntry.fromJson(Map<String, Object?> json) {
    final rawSecondary = json['secondaryWorkKeys'];
    final secondary = rawSecondary is List
        ? [for (final e in rawSecondary) e.toString()]
        : const <String>[];
    final playedAt = (json['playedAtMs'] as num?)?.toInt() ?? 0;
    final updatedAt = (json['updatedAtMs'] as num?)?.toInt() ?? playedAt;
    return SyncPlaybackEntry(
      playbackKey: (json['playbackKey'] ?? '').toString(),
      canonicalWorkKey: (json['canonicalWorkKey'] ?? '').toString(),
      secondaryWorkKeys: secondary,
      seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 1,
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      isAudio: json['isAudio'] == true,
      episodeTitle: (json['episodeTitle'] ?? '').toString(),
      positionSeconds: (json['positionSeconds'] as num?)?.toInt() ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      isCompleted: json['isCompleted'] == true,
      playedAtMs: playedAt,
      updatedAtMs: updatedAt,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
    );
  }
}

/// 可跨设备同步与备份的作品人工整理状态（仅含强身份绑定、锁定、隐藏与系列标签，不含物理路径）。
class SyncWorkOverrideEntry {
  /// 创建作品整理状态条目。
  const SyncWorkOverrideEntry({
    required this.canonicalWorkKey,
    this.secondaryWorkKeys = const <String>[],
    required this.title,
    this.tmdbId,
    this.tmdbMediaType,
    this.bangumiId,
    this.matchedSeason,
    this.isManualLocked = false,
    this.metadataLocked = false,
    this.isHidden = false,
    this.keepHidden = false,
    this.seriesTitle,
    this.seriesOrder,
    this.seriesLabel,
    this.seriesLocked = false,
    required this.updatedAtMs,
    this.sourceDeviceId = '',
  });

  final String canonicalWorkKey;
  final List<String> secondaryWorkKeys;
  final String title;
  final int? tmdbId;
  final TmdbMediaType? tmdbMediaType;
  final int? bangumiId;
  final int? matchedSeason;
  final bool isManualLocked;
  final bool metadataLocked;
  final bool isHidden;
  final bool keepHidden;
  final String? seriesTitle;
  final int? seriesOrder;
  final String? seriesLabel;
  final bool seriesLocked;
  final int updatedAtMs;
  final String sourceDeviceId;

  /// 返回主身份键与全部辅助身份键。
  Iterable<String> get allWorkKeys sync* {
    yield canonicalWorkKey;
    yield* secondaryWorkKeys;
  }

  /// 序列化为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'canonicalWorkKey': canonicalWorkKey,
    if (secondaryWorkKeys.isNotEmpty) 'secondaryWorkKeys': secondaryWorkKeys,
    'title': title,
    if (tmdbId != null) 'tmdbId': tmdbId,
    if (tmdbMediaType != null) 'tmdbMediaType': tmdbMediaType!.name,
    if (bangumiId != null) 'bangumiId': bangumiId,
    if (matchedSeason != null) 'matchedSeason': matchedSeason,
    'isManualLocked': isManualLocked,
    'metadataLocked': metadataLocked,
    'isHidden': isHidden,
    'keepHidden': keepHidden,
    if (seriesTitle != null) 'seriesTitle': seriesTitle,
    if (seriesOrder != null) 'seriesOrder': seriesOrder,
    if (seriesLabel != null) 'seriesLabel': seriesLabel,
    'seriesLocked': seriesLocked,
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
  };

  /// 从 JSON 解析。
  factory SyncWorkOverrideEntry.fromJson(Map<String, Object?> json) {
    final rawSecondary = json['secondaryWorkKeys'];
    final secondary = rawSecondary is List
        ? [for (final e in rawSecondary) e.toString()]
        : const <String>[];
    final rawType = json['tmdbMediaType']?.toString();
    TmdbMediaType? mediaType;
    if (rawType != null) {
      for (final item in TmdbMediaType.values) {
        if (item.name == rawType) {
          mediaType = item;
          break;
        }
      }
    }
    return SyncWorkOverrideEntry(
      canonicalWorkKey: (json['canonicalWorkKey'] ?? '').toString(),
      secondaryWorkKeys: secondary,
      title: (json['title'] ?? '').toString(),
      tmdbId: (json['tmdbId'] as num?)?.toInt(),
      tmdbMediaType: mediaType,
      bangumiId: (json['bangumiId'] as num?)?.toInt(),
      matchedSeason: (json['matchedSeason'] as num?)?.toInt(),
      isManualLocked: json['isManualLocked'] == true,
      metadataLocked: json['metadataLocked'] == true,
      isHidden: json['isHidden'] == true,
      keepHidden: json['keepHidden'] == true,
      seriesTitle: json['seriesTitle']?.toString(),
      seriesOrder: (json['seriesOrder'] as num?)?.toInt(),
      seriesLabel: json['seriesLabel']?.toString(),
      seriesLocked: json['seriesLocked'] == true,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
    );
  }
}

/// 跨设备同步删除墓碑条目。
class SyncTombstoneEntry {
  /// 创建删除墓碑条目。
  const SyncTombstoneEntry({
    required this.entityKey,
    required this.entityType,
    required this.deletedAtMs,
    required this.deviceId,
  });

  final String entityKey;
  final String entityType;
  final int deletedAtMs;
  final String deviceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'entityKey': entityKey,
    'entityType': entityType,
    'deletedAtMs': deletedAtMs,
    'deviceId': deviceId,
  };

  factory SyncTombstoneEntry.fromJson(Map<String, Object?> json) {
    return SyncTombstoneEntry(
      entityKey: (json['entityKey'] ?? '').toString(),
      entityType: (json['entityType'] ?? 'playback').toString(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt() ?? 0,
      deviceId: (json['deviceId'] ?? '').toString(),
    );
  }
}

/// 可安全备份与同步的非敏感偏好键值包（严格白名单，严禁包含任何密钥、PAT 或密码）。
class SyncPreferencesBundle {
  /// 允许参与备份与跨设备同步的非敏感偏好键白名单。
  static const Set<String> portableKeysAllowlist = <String>{
    'konata_v2_theme_mode',
    'konata_v2_window_material',
    'konata_v2_ambient_canvas_enabled',
    'konata.detail.show_title_text',
    'konata.detail.show_title_logo',
    'konata.detail.show_overview',
    'konata.detail.show_raw_video_filename',
    'konata.detail.show_cd_tab',
    'konata.detail.show_scan_tab',
    'konata.playback.preferences.v1',
    'konata_v2_tmdb_backup_api',
    'konata_v2_tmdb_backup_image',
    'konata_v2_bangumi_backup_api',
    'konata_v2_bangumi_backup_image',
    'konata_v2_fanart_backup_api',
    'konata_v2_fanart_backup_image',
    'konata_v2_proxy_mode',
    'konata_v2_proxy_url',
  };

  /// 创建非敏感偏好包。
  const SyncPreferencesBundle({
    this.values = const <String, Object?>{},
    this.updatedAtMs = 0,
  });

  /// 白名单过滤后的安全键值表（仅允许 `bool`、`int`、`double`、`String`）。
  final Map<String, Object?> values;

  /// 最近一次偏好包更新时间戳（UTC 毫秒）。
  final int updatedAtMs;

  /// 判断任意键是否属于允许同步的非敏感键。
  static bool isPortableKey(String key) => portableKeysAllowlist.contains(key);

  /// 过滤输入字典，仅保留安全白名单中的基础标量值。
  factory SyncPreferencesBundle.sanitized(
    Map<String, Object?> raw, {
    int updatedAtMs = 0,
  }) {
    final safe = <String, Object?>{};
    for (final entry in raw.entries) {
      if (!isPortableKey(entry.key)) continue;
      final v = entry.value;
      if (v is bool || v is int || v is double || v is String) {
        safe[entry.key] = v;
      }
    }
    return SyncPreferencesBundle(
      values: Map<String, Object?>.unmodifiable(safe),
      updatedAtMs: updatedAtMs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'updatedAtMs': updatedAtMs,
    'values': values,
  };

  factory SyncPreferencesBundle.fromJson(Map<String, Object?> json) {
    final rawValues = json['values'];
    final map = <String, Object?>{};
    if (rawValues is Map) {
      for (final e in rawValues.entries) {
        map[e.key.toString()] = e.value;
      }
    }
    return SyncPreferencesBundle.sanitized(
      map,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 本地 `.konata` 备份文件与 WebDAV 设备分片共用的统一带校验信封。
class KonataSyncSnapshotEnvelope {
  /// 当前备份与分片协议版本号。
  static const int currentFormatVersion = 1;

  /// 备份信封固定 Schema 标识。
  static const String schemaIdentifier = 'konata.sync.snapshot.v1';

  /// 创建带完整数据载荷的快照信封。
  const KonataSyncSnapshotEnvelope({
    required this.formatVersion,
    required this.schema,
    required this.exportedAtMs,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.playbackEntries,
    required this.workOverrides,
    required this.tombstones,
    required this.preferences,
    required this.payloadSha256,
  });

  final int formatVersion;
  final String schema;
  final int exportedAtMs;
  final String deviceId;
  final String deviceName;
  final String platform;
  final String appVersion;
  final List<SyncPlaybackEntry> playbackEntries;
  final List<SyncWorkOverrideEntry> workOverrides;
  final List<SyncTombstoneEntry> tombstones;
  final SyncPreferencesBundle preferences;
  final String payloadSha256;

  /// 自动计算规范化载荷 SHA-256 校验和并构造不可变信封。
  factory KonataSyncSnapshotEnvelope.create({
    required int exportedAtMs,
    required String deviceId,
    required String deviceName,
    required String platform,
    required String appVersion,
    required List<SyncPlaybackEntry> playbackEntries,
    required List<SyncWorkOverrideEntry> workOverrides,
    required List<SyncTombstoneEntry> tombstones,
    required SyncPreferencesBundle preferences,
  }) {
    final payload = _buildPayloadMap(
      playbackEntries: playbackEntries,
      workOverrides: workOverrides,
      tombstones: tombstones,
      preferences: preferences,
    );
    final digest = computePayloadSha256(payload);
    return KonataSyncSnapshotEnvelope(
      formatVersion: currentFormatVersion,
      schema: schemaIdentifier,
      exportedAtMs: exportedAtMs,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
      appVersion: appVersion,
      playbackEntries: playbackEntries,
      workOverrides: workOverrides,
      tombstones: tombstones,
      preferences: preferences,
      payloadSha256: digest,
    );
  }

  /// 计算载荷对象的确定性 SHA-256 十六进制摘要。
  static String computePayloadSha256(Map<String, Object?> payload) {
    final encoded = utf8.encode(jsonEncode(payload));
    return sha256.convert(encoded).toString();
  }

  static Map<String, Object?> _buildPayloadMap({
    required List<SyncPlaybackEntry> playbackEntries,
    required List<SyncWorkOverrideEntry> workOverrides,
    required List<SyncTombstoneEntry> tombstones,
    required SyncPreferencesBundle preferences,
  }) {
    return <String, Object?>{
      'playbackEntries': [for (final e in playbackEntries) e.toJson()],
      'workOverrides': [for (final e in workOverrides) e.toJson()],
      'tombstones': [for (final e in tombstones) e.toJson()],
      'preferences': preferences.toJson(),
    };
  }

  /// 序列化完整信封为 JSON 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': formatVersion,
    'schema': schema,
    'exportedAtMs': exportedAtMs,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'appVersion': appVersion,
    'payloadSha256': payloadSha256,
    'payload': _buildPayloadMap(
      playbackEntries: playbackEntries,
      workOverrides: workOverrides,
      tombstones: tombstones,
      preferences: preferences,
    ),
  };

  /// 解析并强制校验信封格式与 SHA-256 完整性（损坏或篡改时抛出 [FormatException]）。
  factory KonataSyncSnapshotEnvelope.parseAndVerify(String rawJson) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (_) {
      throw const FormatException('备份文件不是有效的 JSON 格式');
    }
    if (decoded is! Map) {
      throw const FormatException('备份文件顶层结构无效');
    }
    final root = decoded.map((k, v) => MapEntry(k.toString(), v));
    final formatVersion = (root['formatVersion'] as num?)?.toInt() ?? 0;
    if (formatVersion <= 0 || formatVersion > currentFormatVersion) {
      throw FormatException('不支持的备份格式版本：v$formatVersion');
    }
    final schema = (root['schema'] ?? '').toString();
    if (schema != schemaIdentifier) {
      throw FormatException('备份文件类型不匹配：$schema');
    }
    final rawPayload = root['payload'];
    if (rawPayload is! Map) {
      throw const FormatException('备份文件缺少有效的数据载荷');
    }
    final payloadMap = rawPayload.map((k, v) => MapEntry(k.toString(), v));
    final playbackList = <SyncPlaybackEntry>[];
    final rawPlaybacks = payloadMap['playbackEntries'];
    if (rawPlaybacks is List) {
      for (final item in rawPlaybacks) {
        if (item is Map) {
          playbackList.add(
            SyncPlaybackEntry.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
    }
    final overrideList = <SyncWorkOverrideEntry>[];
    final rawOverrides = payloadMap['workOverrides'];
    if (rawOverrides is List) {
      for (final item in rawOverrides) {
        if (item is Map) {
          overrideList.add(
            SyncWorkOverrideEntry.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
    }
    final tombstoneList = <SyncTombstoneEntry>[];
    final rawTombstones = payloadMap['tombstones'];
    if (rawTombstones is List) {
      for (final item in rawTombstones) {
        if (item is Map) {
          tombstoneList.add(
            SyncTombstoneEntry.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
    }
    final rawPrefs = payloadMap['preferences'];
    final prefs = rawPrefs is Map
        ? SyncPreferencesBundle.fromJson(
            rawPrefs.map((k, v) => MapEntry(k.toString(), v)),
          )
        : const SyncPreferencesBundle();

    final expectedHash = (root['payloadSha256'] ?? '').toString().trim();
    final recomputed = computePayloadSha256(
      _buildPayloadMap(
        playbackEntries: playbackList,
        workOverrides: overrideList,
        tombstones: tombstoneList,
        preferences: prefs,
      ),
    );
    if (expectedHash.isEmpty || expectedHash != recomputed) {
      throw const FormatException('备份文件完整性校验失败（SHA-256 不匹配，文件可能已损坏）');
    }

    return KonataSyncSnapshotEnvelope(
      formatVersion: formatVersion,
      schema: schema,
      exportedAtMs: (root['exportedAtMs'] as num?)?.toInt() ?? 0,
      deviceId: (root['deviceId'] ?? '').toString(),
      deviceName: (root['deviceName'] ?? '').toString(),
      platform: (root['platform'] ?? '').toString(),
      appVersion: (root['appVersion'] ?? '').toString(),
      playbackEntries: playbackList,
      workOverrides: overrideList,
      tombstones: tombstoneList,
      preferences: prefs,
      payloadSha256: expectedHash,
    );
  }
}

/// WebDAV 多设备分片目录中的单个设备水位描述符。
class WebDavSyncDeviceWatermark {
  /// 创建设备水位描述符。
  const WebDavSyncDeviceWatermark({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.updatedAtMs,
    required this.shardPath,
    required this.shardSha256,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final int updatedAtMs;
  final String shardPath;
  final String shardSha256;

  Map<String, Object?> toJson() => <String, Object?>{
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'updatedAtMs': updatedAtMs,
    'shardPath': shardPath,
    'shardSha256': shardSha256,
  };

  factory WebDavSyncDeviceWatermark.fromJson(Map<String, Object?> json) {
    return WebDavSyncDeviceWatermark(
      deviceId: (json['deviceId'] ?? '').toString(),
      deviceName: (json['deviceName'] ?? '').toString(),
      platform: (json['platform'] ?? '').toString(),
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      shardPath: (json['shardPath'] ?? '').toString(),
      shardSha256: (json['shardSha256'] ?? '').toString(),
    );
  }
}

/// WebDAV 远端同步清单（`manifest.json`）：索引各活跃设备独立分片，避免多端并发写锁竞争。
class WebDavSyncManifest {
  /// 创建远端同步清单。
  const WebDavSyncManifest({
    this.schemaVersion = 1,
    this.devices = const <String, WebDavSyncDeviceWatermark>{},
  });

  final int schemaVersion;
  final Map<String, WebDavSyncDeviceWatermark> devices;

  WebDavSyncManifest withDevice(WebDavSyncDeviceWatermark watermark) {
    final next = Map<String, WebDavSyncDeviceWatermark>.of(devices)
      ..[watermark.deviceId] = watermark;
    return WebDavSyncManifest(schemaVersion: schemaVersion, devices: next);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'devices': <String, Object?>{
      for (final e in devices.entries) e.key: e.value.toJson(),
    },
  };

  factory WebDavSyncManifest.fromJson(Map<String, Object?> json) {
    final rawDevices = json['devices'];
    final map = <String, WebDavSyncDeviceWatermark>{};
    if (rawDevices is Map) {
      for (final entry in rawDevices.entries) {
        if (entry.value is Map) {
          final wm = WebDavSyncDeviceWatermark.fromJson(
            (entry.value as Map).map((k, v) => MapEntry(k.toString(), v)),
          );
          if (wm.deviceId.isNotEmpty) {
            map[wm.deviceId] = wm;
          }
        }
      }
    }
    return WebDavSyncManifest(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      devices: map,
    );
  }
}

/// 本地 `.konata` 备份恢复策略。
enum KonataBackupRestoreMode {
  /// 智能合并（推荐）：保留两端进度取最新并合并已看状态，不丢弃现有本地数据。
  smartMerge,

  /// 覆盖还原：以备份快照为主覆盖已有播放记录与偏好设置。
  overwrite,
}

/// 备份、恢复与 WebDAV 多设备同步共用的可选数据范围配置。
class KonataSyncDataScope {
  /// 创建数据范围配置（默认全选三类可移植数据）。
  const KonataSyncDataScope({
    this.includePlaybacks = true,
    this.includeWorkOverrides = true,
    this.includePreferences = true,
  });

  /// 全量范围常量。
  static const KonataSyncDataScope all = KonataSyncDataScope();

  /// 是否包含观看进度、播放历史与删除记录。
  final bool includePlaybacks;

  /// 是否包含作品人工整理锁、隐藏状态与系列归组标签。
  final bool includeWorkOverrides;

  /// 是否包含便携非敏感偏好设置（外观、显示、播放与网络镜像，不含密码与密钥）。
  final bool includePreferences;

  /// 是否至少勾选了一项数据。
  bool get hasAnySelected =>
      includePlaybacks || includeWorkOverrides || includePreferences;

  /// 复制并修改指定勾选开关。
  KonataSyncDataScope copyWith({
    bool? includePlaybacks,
    bool? includeWorkOverrides,
    bool? includePreferences,
  }) {
    return KonataSyncDataScope(
      includePlaybacks: includePlaybacks ?? this.includePlaybacks,
      includeWorkOverrides: includeWorkOverrides ?? this.includeWorkOverrides,
      includePreferences: includePreferences ?? this.includePreferences,
    );
  }

  /// 生成便于日志与界面展示的简明中文范围描述。
  String describeLabel() {
    final parts = <String>[
      if (includePlaybacks) '观看进度',
      if (includeWorkOverrides) '作品整理',
      if (includePreferences) '偏好设置',
    ];
    return parts.isEmpty ? '未选择' : parts.join('、');
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is KonataSyncDataScope &&
            other.includePlaybacks == includePlaybacks &&
            other.includeWorkOverrides == includeWorkOverrides &&
            other.includePreferences == includePreferences);
  }

  @override
  int get hashCode =>
      Object.hash(includePlaybacks, includeWorkOverrides, includePreferences);
}

/// 导入备份前的干跑预检摘要。
class KonataBackupPreview {
  /// 创建干跑预检摘要。
  const KonataBackupPreview({
    required this.exportedAt,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.playbackCount,
    required this.workOverrideCount,
    required this.tombstoneCount,
    required this.preferenceCount,
  });

  final DateTime exportedAt;
  final String deviceName;
  final String platform;
  final String appVersion;
  final int playbackCount;
  final int workOverrideCount;
  final int tombstoneCount;
  final int preferenceCount;
}

/// 备份恢复或 WebDAV 多设备同步的执行结果统计报告。
class KonataSyncOutcome {
  /// 创建同步结果报告。
  const KonataSyncOutcome({
    required this.playbacksUpdated,
    required this.playbacksSkippedUnmatched,
    required this.workOverridesApplied,
    required this.tombstonesApplied,
    required this.preferencesRestored,
    this.remoteDevicesMerged = 0,
    this.uploadedShard = false,
  });

  final int playbacksUpdated;
  final int playbacksSkippedUnmatched;
  final int workOverridesApplied;
  final int tombstonesApplied;
  final int preferencesRestored;
  final int remoteDevicesMerged;
  final bool uploadedShard;

  /// 生成用于 Toast 与设置页展示的简明中文摘要。
  String toSummaryMessage() {
    final parts = <String>[];
    if (playbacksUpdated > 0) parts.add('更新 $playbacksUpdated 条观看进度');
    if (workOverridesApplied > 0) parts.add('同步 $workOverridesApplied 项作品整理');
    if (tombstonesApplied > 0) parts.add('应用 $tombstonesApplied 条删除记录');
    if (preferencesRestored > 0) parts.add('恢复 $preferencesRestored 项偏好');
    if (remoteDevicesMerged > 0) parts.add('合并 $remoteDevicesMerged 台远端设备');
    if (parts.isEmpty) {
      return uploadedShard ? '两端数据已一致，已刷新本机云端分片' : '无需变更，数据已保持最新';
    }
    return parts.join(' · ');
  }
}

/// WebDAV 多设备同步持久化配置（密码仅存于安全存储，严禁写入明文偏好或日志）。
class WebDavSyncConfig {
  /// 默认远端同步子目录名。
  static const String defaultRemoteDir = 'konata-sync';

  /// 可选的后台定时同步间隔预设（分钟；`0` 表示关闭定时轮询）。
  static const List<int> allowedAutoSyncIntervalsMinutes = <int>[
    0,
    3,
    5,
    10,
    15,
    30,
    60,
    120,
  ];

  /// 规范化定时同步间隔（负值归零，避免非法定时器周期）。
  static int normalizeIntervalMinutes(int minutes) => minutes <= 0 ? 0 : minutes;

  /// 将定时同步分钟数格式化为简洁中文下拉标签。
  static String formatIntervalLabel(int minutes) {
    final normalized = normalizeIntervalMinutes(minutes);
    if (normalized == 0) return '关闭（仅手动或事件触发）';
    if (normalized % 60 == 0) {
      final hours = normalized ~/ 60;
      return '每 $hours 小时';
    }
    return '每 $normalized 分钟';
  }

  /// 创建 WebDAV 同步配置。
  const WebDavSyncConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.remoteDir = defaultRemoteDir,
    this.username = '',
    this.password = '',
    this.autoSyncOnStartup = false,
    this.autoSyncOnPlaybackStop = false,
    this.autoSyncIntervalMinutes = 0,
    this.syncScope = KonataSyncDataScope.all,
  });

  final bool enabled;
  final String baseUrl;
  final String remoteDir;
  final String username;
  final String password;
  final bool autoSyncOnStartup;
  final bool autoSyncOnPlaybackStop;

  /// 后台定时同步周期（分钟，`0` 表示关闭定时同步）。
  final int autoSyncIntervalMinutes;

  /// WebDAV 多设备同步包含的数据范围。
  final KonataSyncDataScope syncScope;

  /// 是否已配置有效的 WebDAV 同步服务器地址。
  bool get hasValidServerUrl {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.trim().isNotEmpty;
  }

  /// 归一化后的远端同步子目录相对路径（去除首尾斜杠）。
  String get normalizedRemoteDir {
    final trimmed = remoteDir
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed.isEmpty ? defaultRemoteDir : trimmed;
  }

  WebDavSyncConfig copyWith({
    bool? enabled,
    String? baseUrl,
    String? remoteDir,
    String? username,
    String? password,
    bool? autoSyncOnStartup,
    bool? autoSyncOnPlaybackStop,
    int? autoSyncIntervalMinutes,
    KonataSyncDataScope? syncScope,
  }) {
    return WebDavSyncConfig(
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      remoteDir: remoteDir ?? this.remoteDir,
      username: username ?? this.username,
      password: password ?? this.password,
      autoSyncOnStartup: autoSyncOnStartup ?? this.autoSyncOnStartup,
      autoSyncOnPlaybackStop:
          autoSyncOnPlaybackStop ?? this.autoSyncOnPlaybackStop,
      autoSyncIntervalMinutes: normalizeIntervalMinutes(
        autoSyncIntervalMinutes ?? this.autoSyncIntervalMinutes,
      ),
      syncScope: syncScope ?? this.syncScope,
    );
  }
}
