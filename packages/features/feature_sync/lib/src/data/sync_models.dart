import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 本地 `.konata` 备份恢复策略。
enum KonataRestoreMode {
  /// 智能合并：保留两端最新状态、完播态与最大进度，不误清现有本地数据。
  smartMerge,

  /// 覆盖还原：以备份快照重建所选切片数据（仍保留同址媒体源凭据且不删除物理文件）。
  overwrite,
}

/// 跨设备同步通道标识常量。
abstract final class SyncChannelIds {
  /// 本地 `.konata` 备份恢复通道。
  static const String localBackup = 'local_backup';

  /// WebDAV 多设备分片同步通道。
  static const String webDav = 'webdav';
}

/// 跨设备同步与备份通用工具函数（确定性哈希、规范化身份键与凭据/路径脱敏）。
abstract final class SyncSanitizer {
  static final RegExp _nonWordPattern = RegExp(
    r'[\s\-_:：·•.,，。!！?？()（）\[\]【】/\\]+',
  );
  static final RegExp _windowsDrivePathPattern = RegExp(
    r'^[A-Za-z]:[\\/]',
  );
  static final RegExp _uncPathPattern = RegExp(r'^\\\\[^\\]+\\');
  static final RegExp _unixAbsoluteLocalPattern = RegExp(
    r'^/(?:Users|home|storage/emulated|data/user|var|tmp|opt|etc|mnt|media)/',
  );
  static final RegExp _urlUserInfoPasswordPattern = RegExp(
    r'^(https?://[^/\s:@]+:)([^/\s@]+)(@)',
    caseSensitive: false,
  );
  static final RegExp _authHeaderPattern = RegExp(
    r'^(?:Bearer|Basic|Digest)\s+\S+',
    caseSensitive: false,
  );

  /// 归一化标题用于跨端兜底匹配。
  static String normalizeTitleKey(String raw) {
    return raw.trim().toLowerCase().replaceAll(_nonWordPattern, '');
  }

  /// 计算基于 `WorkRecord` 的跨端主身份键。
  static String primaryWorkKeyFor(WorkRecord work) {
    if (work.tmdbId != null && work.tmdbMediaType != null) {
      final season = work.tmdbMediaType == TmdbMediaType.tv
          ? (work.matchedSeason ?? 1)
          : 0;
      return 'tmdb:${work.tmdbMediaType!.name}:${work.tmdbId}:s$season';
    }
    if (work.bangumiId != null) {
      return 'bgm:${work.bangumiId}';
    }
    final canonical = work.canonicalKey?.trim();
    if (canonical != null && canonical.isNotEmpty) {
      return canonical;
    }
    return 'title:${normalizeTitleKey(work.title)}:${work.year ?? 0}';
  }

  /// 计算基于 `WorkRecord` 的全部可匹配身份键列表。
  static List<String> allWorkKeysFor(WorkRecord work) {
    final keys = <String>[];
    void addUnique(String key) {
      final trimmed = key.trim();
      if (trimmed.isNotEmpty && !keys.contains(trimmed)) {
        keys.add(trimmed);
      }
    }

    addUnique(primaryWorkKeyFor(work));
    if (work.tmdbId != null && work.tmdbMediaType != null) {
      final season = work.tmdbMediaType == TmdbMediaType.tv
          ? (work.matchedSeason ?? 1)
          : 0;
      addUnique('tmdb:${work.tmdbMediaType!.name}:${work.tmdbId}:s$season');
    }
    if (work.bangumiId != null) {
      addUnique('bgm:${work.bangumiId}');
    }
    if (work.canonicalKey != null) {
      addUnique(work.canonicalKey!);
    }
    final titleKey = normalizeTitleKey(work.title);
    if (titleKey.isNotEmpty) {
      addUnique('title:$titleKey:${work.year ?? 0}');
    }
    return List<String>.unmodifiable(keys);
  }

  /// 生成单条播放记录的跨设备逻辑稳定键。
  static String buildPlaybackKey({
    required String canonicalWorkKey,
    required int seasonNumber,
    required int? episodeNumber,
    required bool isAudio,
    String? audioTrackHint,
  }) {
    if (isAudio) {
      final hint = normalizeTitleKey(audioTrackHint ?? '');
      final trackPart = episodeNumber == null ? '' : '::t$episodeNumber';
      return 'playback::$canonicalWorkKey::audio::$hint$trackPart';
    }
    final epPart = episodeNumber == null ? 'feature' : 'e$episodeNumber';
    return 'playback::$canonicalWorkKey::s$seasonNumber::$epPart';
  }

  /// 归一化媒体源位置键用于跨设备媒体源去重（保留本机已有源标识与安全存储密码）。
  static String normalizeSourceLocationKey(
    MediaSourceKind kind,
    String rawLocation,
  ) {
    final trimmed = rawLocation.trim();
    if (kind == MediaSourceKind.local) {
      final slash = trimmed
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'/+$'), '');
      final lower = _windowsDrivePathPattern.hasMatch(slash)
          ? slash.toLowerCase()
          : slash;
      return '${kind.name}::$lower';
    }
    final normalized = trimmed
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri != null && uri.scheme.isNotEmpty && uri.host.isNotEmpty) {
      final portPart = uri.hasPort ? ':${uri.port}' : '';
      final pathPart = uri.path.replaceAll(RegExp(r'/+$'), '');
      return '${kind.name}::${uri.scheme.toLowerCase()}://'
          '${uri.host.toLowerCase()}$portPart$pathPart';
    }
    return '${kind.name}::${normalized.toLowerCase()}';
  }

  /// 剥离 URL 内嵌用户密码片段，避免源地址携带明文密码进入备份或远端切片。
  static String stripUrlPassword(String rawLocation) {
    final trimmed = rawLocation.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasAuthority && uri.userInfo.contains(':')) {
      final userOnly = uri.userInfo.split(':').first;
      return uri.replace(userInfo: userOnly).toString();
    }
    return trimmed.replaceFirstMapped(
      _urlUserInfoPasswordPattern,
      (m) => '${m[1]}***${m[3]}',
    );
  }

  /// 判断任意字符串是否为本机绝对文件系统路径或本机自定义封面协议路径。
  static bool isLocalFilesystemPath(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('file://') ||
        lower.startsWith('cover://') ||
        lower.startsWith('content://') ||
        lower == 'konata://locked-empty') {
      return true;
    }
    if (_windowsDrivePathPattern.hasMatch(trimmed) ||
        _uncPathPattern.hasMatch(trimmed) ||
        _unixAbsoluteLocalPattern.hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  /// 清洗远程艺术图或剧照地址；若命中本机路径或内嵌密码则置空。
  static String? sanitizeRemotePath(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || isLocalFilesystemPath(trimmed)) {
      return null;
    }
    if (_urlUserInfoPasswordPattern.hasMatch(trimmed)) {
      return stripUrlPassword(trimmed);
    }
    return trimmed;
  }

  /// 判断字符串值是否疑似携带敏感凭据、授权头或本机绝对路径。
  static bool isUnsafePrefStringValue(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (isLocalFilesystemPath(trimmed)) return true;
    if (_urlUserInfoPasswordPattern.hasMatch(trimmed)) return true;
    if (_authHeaderPattern.hasMatch(trimmed)) return true;
    return false;
  }

  /// 归一化相对路径为不含首尾斜杠的正斜杠格式。
  static String normalizeRelativePath(String raw) {
    return raw.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
  }

  /// 生成按键排序后的确定性 JSON 字符串，保障同内容切片产出稳定一致的 `SHA-256`。
  static String canonicalJsonEncode(Object? value) {
    return jsonEncode(_canonicalizeValue(value));
  }

  /// 计算单个同步切片主体的确定性 `SHA-256` 十六进制摘要（忽略导出时间戳波动）。
  static String computeSliceDataSha256({
    required String sliceId,
    required int schemaVersion,
    required Map<String, Object?> data,
  }) {
    final encoded = canonicalJsonEncode(<String, Object?>{
      'sliceId': sliceId,
      'schemaVersion': schemaVersion,
      'data': data,
    });
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  /// 计算跨切片集合的确定性 `SHA-256` 十六进制摘要。
  static String computeMapSha256(Map<String, Object?> payload) {
    return sha256.convert(utf8.encode(canonicalJsonEncode(payload))).toString();
  }

  /// 将动态键值表安全规范化为 `Map<String, Object?>`。
  static Map<String, Object?> coerceStringKeyMap(Object? raw) {
    if (raw is! Map) return const <String, Object?>{};
    return <String, Object?>{
      for (final entry in raw.entries)
        if (entry.key != null) entry.key.toString(): entry.value,
    };
  }

  static Object? _canonicalizeValue(Object? value) {
    if (value is Map) {
      final sortedKeys = value.keys.map((k) => k.toString()).toList()..sort();
      final originalByKey = <String, Object?>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
      return <String, Object?>{
        for (final key in sortedKeys)
          key: _canonicalizeValue(originalByKey[key]),
      };
    }
    if (value is List) {
      return <Object?>[for (final item in value) _canonicalizeValue(item)];
    }
    return value;
  }
}

/// 跨数据库同步事务应用上下文实现（统一桥接 `library.db` 与 `user_state.db` 写事务句柄）。
final class DatabaseBundleSyncTransactionContext
    implements SyncTransactionContext {
  /// 创建双库同步事务上下文。
  const DatabaseBundleSyncTransactionContext({
    required this.localDeviceId,
    required this.appliedAtMs,
    this.libraryTx,
    this.userStateTx,
    this._extraHandles = const <String, Object?>{},
  });

  @override
  final String localDeviceId;

  @override
  final int appliedAtMs;

  /// `library.db` 活动事务句柄。
  final SqliteTransaction? libraryTx;

  /// `user_state.db` 活动事务句柄。
  final SqliteTransaction? userStateTx;

  final Map<String, Object?> _extraHandles;

  @override
  Object? rawHandleFor(String databaseName) {
    return switch (databaseName) {
      'library' => libraryTx,
      'user_state' => userStateTx,
      _ => _extraHandles[databaseName],
    };
  }
}

/// 本地 `.konata` 归档文件自描述信封（包含版本、设备来源、切片清单与 `SHA-256` 校验和）。
final class KonataBackupArchive {
  /// 当前 `.konata` 归档格式版本号。
  static const int currentSchemaVersion = 3;

  /// 当前 `.konata` 归档协议标识。
  static const String formatIdentifier = 'konata.sync.archive';

  /// 创建带完整校验信息的本地备份归档实体。
  const KonataBackupArchive({
    required this.schemaVersion,
    required this.format,
    required this.exportedAtMs,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.sliceIds,
    required this.slices,
    required this.payloadSha256,
  });

  /// 自动计算切片内容 `SHA-256` 校验和并构建归档信封。
  factory KonataBackupArchive.create({
    required int exportedAtMs,
    required String deviceId,
    required String deviceName,
    required String platform,
    required String appVersion,
    required List<SyncSlicePayload> slicePayloads,
  }) {
    final sliceIds = <String>[
      for (final payload in slicePayloads) payload.sliceId,
    ];
    final slicesMap = <String, Object?>{
      for (final payload in slicePayloads) payload.sliceId: payload.toJson(),
    };
    final digest = SyncSanitizer.computeMapSha256(slicesMap);
    return KonataBackupArchive(
      schemaVersion: currentSchemaVersion,
      format: formatIdentifier,
      exportedAtMs: exportedAtMs,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
      appVersion: appVersion,
      sliceIds: List<String>.unmodifiable(sliceIds),
      slices: Map<String, SyncSlicePayload>.unmodifiable(<String, SyncSlicePayload>{
        for (final payload in slicePayloads) payload.sliceId: payload,
      }),
      payloadSha256: digest,
    );
  }

  /// 归档格式版本号。
  final int schemaVersion;

  /// 归档协议格式标识。
  final String format;

  /// 导出时间（UTC 毫秒）。
  final int exportedAtMs;

  /// 来源设备标识。
  final String deviceId;

  /// 来源设备展示名。
  final String deviceName;

  /// 来源平台名。
  final String platform;

  /// 导出应用版本号。
  final String appVersion;

  /// 归档中包含的切片标识清单。
  final List<String> sliceIds;

  /// 按切片标识索引的切片载荷映射。
  final Map<String, SyncSlicePayload> slices;

  /// 切片集合的确定性 `SHA-256` 校验和。
  final String payloadSha256;

  /// 序列化为完整 JSON 字典。
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'format': format,
    'exportedAtMs': exportedAtMs,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'appVersion': appVersion,
    'sliceIds': sliceIds,
    'payloadSha256': payloadSha256,
    'slices': <String, Object?>{
      for (final entry in slices.entries) entry.key: entry.value.toJson(),
    },
  };

  /// 解析并强制校验归档格式与 `SHA-256` 完整性；损坏或篡改时抛出 [FormatException]。
  factory KonataBackupArchive.parseAndVerify(String rawJson) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (_) {
      throw const FormatException('备份文件不是有效的 JSON 格式');
    }
    if (decoded is! Map) {
      throw const FormatException('备份文件顶层结构无效');
    }
    final root = SyncSanitizer.coerceStringKeyMap(decoded);
    final schemaVersion = (root['schemaVersion'] as num?)?.toInt() ?? 0;
    if (schemaVersion <= 0 || schemaVersion > currentSchemaVersion) {
      throw FormatException('不支持的备份归档版本：$schemaVersion');
    }
    final format = (root['format'] ?? '').toString();
    if (format != formatIdentifier) {
      throw FormatException('备份归档类型不匹配：$format');
    }
    final rawSlices = root['slices'];
    if (rawSlices is! Map) {
      throw const FormatException('备份归档缺少有效切片集合');
    }

    final parsedSlices = <String, SyncSlicePayload>{};
    final rawSlicesForHash = <String, Object?>{};
    for (final entry in rawSlices.entries) {
      final sliceId = entry.key.toString().trim();
      final val = entry.value;
      if (sliceId.isEmpty || val is! Map) {
        throw const FormatException('备份归档中包含格式非法的切片条目');
      }
      final sliceMap = SyncSanitizer.coerceStringKeyMap(val);
      final payload = _parseSlicePayload(sliceId, sliceMap);
      parsedSlices[sliceId] = payload;
      rawSlicesForHash[sliceId] = payload.toJson();
    }

    final expectedHash = (root['payloadSha256'] ?? '').toString().trim();
    final recomputed = SyncSanitizer.computeMapSha256(rawSlicesForHash);
    if (expectedHash.isEmpty || expectedHash != recomputed) {
      throw const FormatException('备份文件完整性校验失败（SHA-256 不匹配，文件可能已损坏）');
    }

    final rawSliceIds = root['sliceIds'];
    final sliceIds = <String>[
      if (rawSliceIds is List)
        for (final item in rawSliceIds)
          if (item.toString().trim().isNotEmpty) item.toString().trim(),
      for (final key in parsedSlices.keys)
        if (!(rawSliceIds is List && rawSliceIds.contains(key))) key,
    ];

    return KonataBackupArchive(
      schemaVersion: schemaVersion,
      format: format,
      exportedAtMs: (root['exportedAtMs'] as num?)?.toInt() ?? 0,
      deviceId: (root['deviceId'] ?? '').toString(),
      deviceName: (root['deviceName'] ?? '').toString(),
      platform: (root['platform'] ?? '').toString(),
      appVersion: (root['appVersion'] ?? '').toString(),
      sliceIds: List<String>.unmodifiable(sliceIds),
      slices: Map<String, SyncSlicePayload>.unmodifiable(parsedSlices),
      payloadSha256: expectedHash,
    );
  }

  static SyncSlicePayload _parseSlicePayload(
    String expectedSliceId,
    Map<String, Object?> map,
  ) {
    final sliceId = (map['sliceId'] ?? expectedSliceId).toString().trim();
    if (sliceId.isEmpty) {
      throw const FormatException('切片缺少有效的 sliceId');
    }
    final rawData = map['data'];
    if (rawData is! Map) {
      throw FormatException('切片 `$sliceId` 缺少有效的 data 对象');
    }
    return SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: (map['schemaVersion'] as num?)?.toInt() ?? 1,
      exportedAtMs: (map['exportedAtMs'] as num?)?.toInt() ?? 0,
      sourceDeviceId: (map['sourceDeviceId'] ?? '').toString(),
      data: Map<String, Object?>.unmodifiable(
        SyncSanitizer.coerceStringKeyMap(rawData),
      ),
    );
  }
}

/// 单个切片在干跑预览或同步计划中的统计摘要。
final class KonataSlicePreview {
  /// 创建切片变更预览记录。
  const KonataSlicePreview({
    required this.sliceId,
    required this.displayName,
    required this.insertCount,
    required this.updateCount,
    required this.deleteCount,
    required this.skippedCount,
    this.summaryLines = const <String>[],
    this.remoteAvailable = true,
  });

  /// 切片标识。
  final String sliceId;

  /// 切片中文名称。
  final String displayName;

  /// 预计新增条目数。
  final int insertCount;

  /// 预计更新条目数。
  final int updateCount;

  /// 预计删除或墓碑条目数。
  final int deleteCount;

  /// 保留本地并跳过的条目数。
  final int skippedCount;

  /// 切片产出的中文摘要行。
  final List<String> summaryLines;

  /// 远端或归档中是否包含该切片。
  final bool remoteAvailable;

  /// 本切片是否存在实际写入变更。
  bool get hasChanges => insertCount > 0 || updateCount > 0 || deleteCount > 0;
}

/// `.konata` 导入恢复前干跑 `planMerge` 产出的全局预览报告。
final class KonataBackupPreviewReport {
  /// 创建干跑恢复预览报告。
  const KonataBackupPreviewReport({
    required this.exportedAt,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.archiveSliceIds,
    required this.slicePreviews,
    this.unrecognizedSliceIds = const <String>[],
  });

  /// 归档导出时间。
  final DateTime exportedAt;

  /// 来源设备标识。
  final String deviceId;

  /// 来源设备名称。
  final String deviceName;

  /// 来源平台名称。
  final String platform;

  /// 来源应用版本。
  final String appVersion;

  /// 归档自带的全部切片标识清单。
  final List<String> archiveSliceIds;

  /// 与本地已注册切片匹配并完成干跑计算的逐切片预览清单。
  final List<KonataSlicePreview> slicePreviews;

  /// 归档中有但本机当前未注册的外部切片标识列表。
  final List<String> unrecognizedSliceIds;

  /// 累计预计新增数量。
  int get totalInserts =>
      slicePreviews.fold<int>(0, (sum, item) => sum + item.insertCount);

  /// 累计预计更新数量。
  int get totalUpdates =>
      slicePreviews.fold<int>(0, (sum, item) => sum + item.updateCount);

  /// 累计预计删除数量。
  int get totalDeletes =>
      slicePreviews.fold<int>(0, (sum, item) => sum + item.deleteCount);

  /// 累计跳过数量。
  int get totalSkipped =>
      slicePreviews.fold<int>(0, (sum, item) => sum + item.skippedCount);

  /// 是否存在至少一项预计落盘变更。
  bool get hasAnyChanges => slicePreviews.any((item) => item.hasChanges);
}

/// 备份恢复或 WebDAV 多设备同步完成后的精确执行结果。
final class KonataSyncOutcome {
  /// 创建同步或恢复结果报告。
  const KonataSyncOutcome({
    required this.channel,
    required this.updatedSliceIds,
    required this.sliceOutcomes,
    this.downloadedShards = 0,
    this.uploadedShards = 0,
    this.skippedUnchangedDownloads = 0,
    this.skippedUnchangedUploads = 0,
    this.remoteDevicesMerged = 0,
  });

  /// 同步通道标识（`local_backup` / `webdav`）。
  final String channel;

  /// 本次实际有数据落盘变更的切片标识集合。
  final Set<String> updatedSliceIds;

  /// 逐切片合并执行统计清单。
  final List<KonataSlicePreview> sliceOutcomes;

  /// 本次实际从 WebDAV 下载的切片分片数。
  final int downloadedShards;

  /// 本次实际向 WebDAV 上传的切片分片数。
  final int uploadedShards;

  /// 按 `sha256` 一致跳过下载的未变切片数。
  final int skippedUnchangedDownloads;

  /// 按 `sha256` 一致跳过上传的未变切片数。
  final int skippedUnchangedUploads;

  /// 参与合并的远端设备数量。
  final int remoteDevicesMerged;

  /// 总新增条数。
  int get totalInserts =>
      sliceOutcomes.fold<int>(0, (sum, item) => sum + item.insertCount);

  /// 总更新条数。
  int get totalUpdates =>
      sliceOutcomes.fold<int>(0, (sum, item) => sum + item.updateCount);

  /// 总删除条数。
  int get totalDeletes =>
      sliceOutcomes.fold<int>(0, (sum, item) => sum + item.deleteCount);

  /// 生成面向用户与诊断日志的简体中文摘要。
  String toSummaryMessage() {
    final parts = <String>[];
    if (totalInserts > 0) parts.add('新增 $totalInserts 项');
    if (totalUpdates > 0) parts.add('更新 $totalUpdates 项');
    if (totalDeletes > 0) parts.add('删除 $totalDeletes 项');
    if (remoteDevicesMerged > 0) parts.add('合并 $remoteDevicesMerged 台设备');
    if (uploadedShards > 0) parts.add('上传 $uploadedShards 个切片');

    if (parts.isEmpty) {
      if (skippedUnchangedDownloads > 0 || skippedUnchangedUploads > 0) {
        return '所有切片校验一致，零无效传输';
      }
      return '两端数据已保持最新';
    }
    return parts.join(' · ');
  }
}

/// WebDAV 多设备分片同步配置（非敏感参数存 `ScopedPrefsStore`，密码严格存 `SecureStoragePort`）。
final class WebDavSyncConfig {
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

  /// 规范化定时同步间隔分钟数。
  static int normalizeIntervalMinutes(int minutes) => minutes <= 0 ? 0 : minutes;

  /// 将定时同步间隔格式化为中文标签。
  static String formatIntervalLabel(int minutes) {
    final normalized = normalizeIntervalMinutes(minutes);
    if (normalized == 0) return '关闭（仅手动或事件触发）';
    if (normalized % 60 == 0) {
      return '每 ${normalized ~/ 60} 小时';
    }
    return '每 $normalized 分钟';
  }

  /// 创建 WebDAV 同步配置实体。
  const WebDavSyncConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.remoteDir = defaultRemoteDir,
    this.username = '',
    this.password = '',
    this.autoSyncOnStartup = false,
    this.autoSyncOnPlaybackStop = false,
    this.autoSyncIntervalMinutes = 0,
    this.selectedSliceIds,
  });

  /// 是否启用 WebDAV 自动或一键同步。
  final bool enabled;

  /// WebDAV 服务基础地址。
  final String baseUrl;

  /// 远端同步工作目录。
  final String remoteDir;

  /// 可选登录用户名。
  final String username;

  /// 仅驻留内存与安全存储的登录密码（严禁落入偏好表与同步文件）。
  final String password;

  /// 是否在启动时自动同步。
  final bool autoSyncOnStartup;

  /// 是否在停播后静默上传进度。
  final bool autoSyncOnPlaybackStop;

  /// 后台定时同步周期（分钟，`0` 表示关闭）。
  final int autoSyncIntervalMinutes;

  /// 勾选参与同步的切片标识集合；为空时表示同步全部已注册切片。
  final Set<String>? selectedSliceIds;

  /// 服务器地址是否合法。
  bool get hasValidServerUrl {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.trim().isNotEmpty;
  }

  /// 归一化后的远端同步目录相对路径。
  String get normalizedRemoteDir {
    final trimmed = SyncSanitizer.normalizeRelativePath(remoteDir);
    return trimmed.isEmpty ? defaultRemoteDir : trimmed;
  }

  /// 基于 [availableSliceIds] 解析当前生效的勾选切片集合。
  Set<String> resolveActiveSliceIds(Iterable<String> availableSliceIds) {
    final available = availableSliceIds.toSet();
    final configured = selectedSliceIds;
    if (configured == null) return available;
    return configured.where(available.contains).toSet();
  }

  /// 复制并修改指定配置项。
  WebDavSyncConfig copyWith({
    bool? enabled,
    String? baseUrl,
    String? remoteDir,
    String? username,
    String? password,
    bool? autoSyncOnStartup,
    bool? autoSyncOnPlaybackStop,
    int? autoSyncIntervalMinutes,
    Set<String>? selectedSliceIds,
    bool clearSelectedSliceIds = false,
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
      selectedSliceIds: clearSelectedSliceIds
          ? null
          : (selectedSliceIds ?? this.selectedSliceIds),
    );
  }
}

/// WebDAV `manifest.json` 中单个设备单切片分片的水位描述条目。
final class WebDavSliceWatermark {
  /// 创建分片水位描述条目。
  const WebDavSliceWatermark({
    required this.sliceId,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.schemaVersion,
    required this.updatedAtMs,
    required this.shardPath,
    required this.sha256,
  });

  /// 切片稳定标识。
  final String sliceId;

  /// 来源设备标识。
  final String deviceId;

  /// 来源设备名称。
  final String deviceName;

  /// 来源平台名称。
  final String platform;

  /// 切片结构版本号。
  final int schemaVersion;

  /// 最近更新时间戳（UTC 毫秒）。
  final int updatedAtMs;

  /// 相对同步根目录的 `.json.gz` 路径（格式 `slices/<sliceId>_<deviceId>.json.gz`）。
  final String shardPath;

  /// 切片主体的确定性 `SHA-256` 校验和。
  final String sha256;

  /// 构造清单索引复合键。
  String get compositeKey => '$sliceId::$deviceId';

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'sliceId': sliceId,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'schemaVersion': schemaVersion,
    'updatedAtMs': updatedAtMs,
    'shardPath': shardPath,
    'sha256': sha256,
  };

  /// 从 JSON 字典还原分片水位条目。
  factory WebDavSliceWatermark.fromJson(Map<String, Object?> json) {
    return WebDavSliceWatermark(
      sliceId: (json['sliceId'] ?? '').toString().trim(),
      deviceId: (json['deviceId'] ?? '').toString().trim(),
      deviceName: (json['deviceName'] ?? '').toString(),
      platform: (json['platform'] ?? '').toString(),
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      shardPath: (json['shardPath'] ?? '').toString().trim(),
      sha256: (json['sha256'] ?? '').toString().trim(),
    );
  }
}

/// WebDAV 远端总清单（`manifest.json`）：按 `(sliceId, deviceId)` 索引切片分片，零写入锁冲突。
final class WebDavSyncManifest {
  /// 当前清单格式版本号。
  static const int currentSchemaVersion = 2;

  /// 创建远端同步清单。
  const WebDavSyncManifest({
    this.schemaVersion = currentSchemaVersion,
    this.slices = const <String, WebDavSliceWatermark>{},
  });

  /// 清单结构版本号。
  final int schemaVersion;

  /// 按 `<sliceId>::<deviceId>` 索引的全部切片分片水位。
  final Map<String, WebDavSliceWatermark> slices;

  /// 按切片与设备精确查找水位条目。
  WebDavSliceWatermark? findEntry(String sliceId, String deviceId) =>
      slices['$sliceId::$deviceId'];

  /// 返回除本机外属于指定切片的全部远端分片水位。
  List<WebDavSliceWatermark> remoteEntriesForSlice({
    required String sliceId,
    required String localDeviceId,
  }) {
    final result = <WebDavSliceWatermark>[
      for (final entry in slices.values)
        if (entry.sliceId == sliceId && entry.deviceId != localDeviceId) entry,
    ]..sort((a, b) => a.updatedAtMs.compareTo(b.updatedAtMs));
    return List<WebDavSliceWatermark>.unmodifiable(result);
  }

  /// 更新或追加指定分片水位并返回新清单。
  WebDavSyncManifest withEntry(WebDavSliceWatermark watermark) {
    final next = Map<String, WebDavSliceWatermark>.of(slices)
      ..[watermark.compositeKey] = watermark;
    return WebDavSyncManifest(schemaVersion: schemaVersion, slices: next);
  }

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'slices': <String, Object?>{
      for (final entry in slices.entries) entry.key: entry.value.toJson(),
    },
  };

  /// 从 JSON 字典解析清单（非法或无效条目自动跳过）。
  factory WebDavSyncManifest.fromJson(Map<String, Object?> json) {
    final rawSlices = json['slices'];
    final map = <String, WebDavSliceWatermark>{};
    if (rawSlices is Map) {
      for (final entry in rawSlices.entries) {
        if (entry.value is! Map) continue;
        final wm = WebDavSliceWatermark.fromJson(
          SyncSanitizer.coerceStringKeyMap(entry.value),
        );
        if (wm.sliceId.isNotEmpty &&
            wm.deviceId.isNotEmpty &&
            wm.shardPath.isNotEmpty) {
          map[wm.compositeKey] = wm;
        }
      }
    }
    return WebDavSyncManifest(
      schemaVersion:
          (json['schemaVersion'] as num?)?.toInt() ?? currentSchemaVersion,
      slices: Map<String, WebDavSliceWatermark>.unmodifiable(map),
    );
  }
}
