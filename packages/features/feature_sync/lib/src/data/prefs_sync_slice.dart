import 'dart:convert';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'sync_models.dart';

/// 偏好设置同步切片贡献者（`sliceId: 'prefs_slice'`）。
///
/// 基于 `ScopedPrefsStore` 按白名单/黑名单双层规则过滤敏感凭据与本机绝对路径键，
/// 按切片声明进行整份或逐字段合并，并保留本机专用配置。
final class PrefsSyncSlice
    implements SyncSliceContributor<List<PortablePrefEntry>> {
  /// 创建绑定持久化存储器的偏好同步切片实例。
  const PrefsSyncSlice({
    required UserStateDatabase this._userStateDb,
    required ScopedPrefsStore this._scopedPrefs,
    this._allowedNamespaces,
    this._extraBlockedNamespaces = const <String>{},
    this._nowMs,
  });

  /// 创建仅用于元数据声明与纯函数合并规划的未绑定切片实例。
  const PrefsSyncSlice.unbound({
    this._allowedNamespaces,
    this._extraBlockedNamespaces = const <String>{},
  }) : _userStateDb = null,
       _scopedPrefs = null,
       _nowMs = null;

  /// 切片稳定唯一标识。
  static const String id = 'prefs_slice';

  /// 标准便携偏好命名空间参考白名单（各业务模块声明为 `SyncPolicy.portable` 的配置域）。
  static const Set<String> knownPortableNamespaces = <String>{
    'appearance',
    'network',
    'feature_library.view_state',
    'feature_detail.display',
    'feature_sources.source_metadata',
    'feature_scan_viewer.gallery',
    'playback_video',
    'playback_audio',
    'lyrics',
  };

  /// 严禁导出或跨设备覆盖的敏感/本机专用命名空间黑名单。
  static const Set<String> blockedNamespaces = <String>{
    'sync_webdav',
    'sync.device',
    'secrets',
    'credentials',
    'auth',
    'tracker_bangumi_secret',
  };

  static const Set<String> _blockedKeyTokens = <String>{
    'password',
    'passwd',
    'pwd',
    'secret',
    'token',
    'pat',
    'apikey',
    'api_key',
    'clientkey',
    'client_key',
    'credential',
    'authorization',
    'authheader',
    'privatekey',
    'private_key',
    'cookie',
    'sessionid',
    'session_id',
    'localpath',
    'local_path',
    'filepath',
    'file_path',
    'dirpath',
    'dir_path',
    'executablepath',
    'executable_path',
    'mpvpath',
    'mpv_path',
    'externalplayerpath',
    'external_player_path',
    'shaderpath',
    'shader_path',
    'customcoverpath',
    'custom_cover_path',
    'rootpath',
    'root_path',
    'dbpath',
    'db_path',
    'cachepath',
    'cache_path',
    'logpath',
    'log_path',
    'absolutepath',
    'absolute_path',
  };

  static final RegExp _sensitiveNamespacePattern = RegExp(
    r'(?:password|passwd|secret|token|pat|api_?key|credential|private_?key|device_?local|local_?path)',
    caseSensitive: false,
  );

  final UserStateDatabase? _userStateDb;
  final ScopedPrefsStore? _scopedPrefs;
  final Set<String>? _allowedNamespaces;
  final Set<String> _extraBlockedNamespaces;
  final int Function()? _nowMs;

  @override
  String get sliceId => id;

  @override
  String get displayName => '偏好设置';

  @override
  int get schemaVersion => 2;

  /// 旧版快照可作为逐字段版本启用前的基线。
  bool canReadVersion(int version) => version == 1 || version == schemaVersion;

  /// 判断指定命名空间是否允许参与跨设备备份与同步。
  bool isNamespaceAllowed(String namespace) {
    final trimmed = namespace.trim();
    if (trimmed.isEmpty) return false;
    if (blockedNamespaces.contains(trimmed) ||
        _extraBlockedNamespaces.contains(trimmed)) {
      return false;
    }
    if (trimmed.startsWith('sync_webdav.')) return false;
    if (_sensitiveNamespacePattern.hasMatch(trimmed)) return false;
    final allowlist = _allowedNamespaces;
    if (allowlist != null && !allowlist.contains(trimmed)) {
      return false;
    }
    return true;
  }

  /// 判断载荷键名是否属于敏感凭据或本机路径键。
  static bool isBlockedPayloadKey(String rawKey) {
    final normalized = rawKey.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    if (DiagnosticTextSanitizer.isSensitiveKey(normalized)) {
      return true;
    }
    final compact = normalized.replaceAll('-', '_');
    for (final token in _blockedKeyTokens) {
      if (compact == token || compact.contains(token)) {
        return true;
      }
    }
    return false;
  }

  /// 递归过滤偏好字典中的敏感凭据与本机绝对路径值，返回安全不可变副本。
  static Map<String, Object?> sanitizePayloadMap(Map<String, Object?> raw) {
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      final key = entry.key.trim();
      if (key.isEmpty || isBlockedPayloadKey(key)) {
        continue;
      }
      final sanitizedValue = _sanitizeValue(entry.value);
      if (sanitizedValue != null) {
        result[key] = sanitizedValue;
      } else if (entry.value == null) {
        result[key] = null;
      }
    }
    return Map<String, Object?>.unmodifiable(result);
  }

  static Object? _sanitizeValue(Object? value) {
    if (value == null || value is bool || value is int || value is double) {
      return value;
    }
    if (value is String) {
      if (SyncSanitizer.isUnsafePrefStringValue(value)) {
        return null;
      }
      return value;
    }
    if (value is List) {
      final out = <Object?>[];
      for (final item in value) {
        final cleaned = _sanitizeValue(item);
        if (cleaned != null) {
          out.add(cleaned);
        }
      }
      return List<Object?>.unmodifiable(out);
    }
    if (value is Map) {
      final typed = SyncSanitizer.coerceStringKeyMap(value);
      return sanitizePayloadMap(typed);
    }
    return null;
  }

  @override
  Future<SyncSlicePayload> exportSlice({required String localDeviceId}) async {
    final store = _scopedPrefs;
    if (store == null) {
      throw StateError('PrefsSyncSlice 未绑定 ScopedPrefsStore，无法执行导出');
    }
    final rawEntries = store.exportPortableEntries();
    final safeEntries = <PortablePrefEntry>[];
    for (final entry in rawEntries) {
      if (!isNamespaceAllowed(entry.namespace)) continue;
      final sanitized = sanitizePayloadMap(entry.payload);
      if (entry.payload.isNotEmpty && sanitized.isEmpty) {
        continue;
      }
      safeEntries.add(
        FieldwisePortablePrefs.forDevice(
          entry.withPayload(sanitized),
          localDeviceId,
        ),
      );
    }
    safeEntries.sort((a, b) => a.namespace.compareTo(b.namespace));

    final now = _nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    return SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      exportedAtMs: now,
      sourceDeviceId: localDeviceId,
      data: <String, Object?>{
        'entries': <Map<String, Object?>>[
          for (final item in safeEntries) item.toJson(),
        ],
      },
    );
  }

  @override
  SyncMergePlan<List<PortablePrefEntry>> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final localEntries = _parseEntries(local);
    final remoteEntries = _parseEntries(remote);

    final localByNs = <String, PortablePrefEntry>{
      for (final item in localEntries) item.namespace: item,
    };

    final toApply = <PortablePrefEntry>[];
    var insertCount = 0;
    var updateCount = 0;
    var skippedCount = 0;

    for (final rawRemote in remoteEntries) {
      if (!isNamespaceAllowed(rawRemote.namespace)) {
        skippedCount++;
        continue;
      }
      final sanitizedPayload = sanitizePayloadMap(rawRemote.payload);
      if (rawRemote.payload.isNotEmpty && sanitizedPayload.isEmpty) {
        skippedCount++;
        continue;
      }
      final candidate = rawRemote.withPayload(sanitizedPayload);

      final localMatch = localByNs[candidate.namespace];
      if (localMatch == null) {
        insertCount++;
        toApply.add(candidate);
        continue;
      }

      if (_tracksFields(localMatch, candidate)) {
        final merged = FieldwisePortablePrefs.merge(localMatch, candidate);
        if (_samePayload(localMatch, merged)) {
          skippedCount++;
        } else {
          updateCount++;
          toApply.add(merged);
        }
        continue;
      }

      if (_samePayload(localMatch, candidate)) {
        skippedCount++;
        continue;
      }

      final remoteWins = candidate.updatedAtMs != localMatch.updatedAtMs
          ? candidate.updatedAtMs > localMatch.updatedAtMs
          : candidate.sourceDeviceId.compareTo(localMatch.sourceDeviceId) > 0;
      if (remoteWins) {
        updateCount++;
        toApply.add(candidate);
      } else {
        skippedCount++;
      }
    }

    return SyncMergePlan<List<PortablePrefEntry>>(
      sliceId: sliceId,
      insertCount: insertCount,
      updateCount: updateCount,
      deleteCount: 0,
      skippedCount: skippedCount,
      planData: List<PortablePrefEntry>.unmodifiable(toApply),
      summaryLines: <String>[
        '偏好设置：新增 $insertCount 项，更新 $updateCount 项，跳过 $skippedCount 项',
      ],
    );
  }

  /// 生成覆盖还原计划：以备份快照中的安全偏好覆盖同命名空间配置，并将本地多余便携命名空间重置为空。
  SyncMergePlan<List<PortablePrefEntry>> planOverwrite({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
    required String localDeviceId,
  }) {
    final localEntries = _parseEntries(local);
    final remoteEntries = _parseEntries(remote);
    final now = _nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    final localByNs = <String, PortablePrefEntry>{
      for (final item in localEntries) item.namespace: item,
    };

    final toApply = <PortablePrefEntry>[];
    final seenRemoteNs = <String>{};
    var insertCount = 0;
    var updateCount = 0;
    var deleteCount = 0;
    var skippedCount = 0;

    for (final rawRemote in remoteEntries) {
      if (!isNamespaceAllowed(rawRemote.namespace)) {
        skippedCount++;
        continue;
      }
      final sanitizedPayload = sanitizePayloadMap(rawRemote.payload);
      if (rawRemote.payload.isNotEmpty && sanitizedPayload.isEmpty) {
        skippedCount++;
        continue;
      }
      seenRemoteNs.add(rawRemote.namespace);
      final entry = rawRemote.withPayload(sanitizedPayload);
      final previous = localByNs[entry.namespace];
      if (previous != null) {
        updateCount++;
      } else {
        insertCount++;
      }
      toApply.add(
        _tracksFields(previous, entry)
            ? FieldwisePortablePrefs.restore(
                previous,
                entry,
                now: now,
                deviceId: localDeviceId,
              )
            : entry,
      );
    }

    for (final localEntry in localEntries) {
      if (!isNamespaceAllowed(localEntry.namespace) ||
          seenRemoteNs.contains(localEntry.namespace)) {
        continue;
      }
      deleteCount++;
      final empty = localEntry.withPayload(
        const {},
        updatedAtMs: now,
        sourceDeviceId: localDeviceId,
      );
      toApply.add(
        FieldwisePortablePrefs.tracksFields(localEntry)
            ? FieldwisePortablePrefs.restore(
                localEntry,
                empty,
                now: now,
                deviceId: localDeviceId,
              )
            : empty,
      );
    }

    return SyncMergePlan<List<PortablePrefEntry>>(
      sliceId: sliceId,
      insertCount: insertCount,
      updateCount: updateCount,
      deleteCount: deleteCount,
      skippedCount: skippedCount,
      planData: List<PortablePrefEntry>.unmodifiable(toApply),
      summaryLines: <String>[
        '偏好设置（覆盖还原）：新增 $insertCount 项，覆盖 $updateCount 项，清空 $deleteCount 项',
      ],
    );
  }

  @override
  SyncApplyCompletion applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<List<PortablePrefEntry>> plan,
  ) {
    if (!plan.hasChanges || plan.planData.isEmpty) {
      return SyncApplyCompletion.completed;
    }
    final db = _userStateDb;
    final store = _scopedPrefs;
    if (db == null || store == null) {
      throw StateError('PrefsSyncSlice 未绑定数据库实例，无法应用合并计划');
    }

    final handle = tx.rawHandleFor('user_state');
    if (handle is! SqliteTransaction) {
      throw StateError('偏好同步缺少宿主写事务');
    }
    _applyInTransaction(db, handle, plan.planData, tx.localDeviceId);
    return SyncApplyCompletion.completed;
  }

  void _applyInTransaction(
    UserStateDatabase db,
    SqliteTransaction tx,
    List<PortablePrefEntry> entries,
    String localDeviceId,
  ) {
    for (final entry in entries) {
      if (!isNamespaceAllowed(entry.namespace)) continue;
      final existing = db.scopedPrefs.findByNamespace(entry.namespace);
      if (existing != null && existing.syncPolicy == SyncPolicy.deviceLocal) {
        continue;
      }
      var next = entry.withPayload(sanitizePayloadMap(entry.payload));
      if (existing != null) {
        Map<String, Object?> raw = const {};
        try {
          raw = SyncSanitizer.coerceStringKeyMap(
            jsonDecode(existing.payloadJson),
          );
        } on FormatException {
          // 损坏的本机旧配置不参与合并，由已校验的同步快照恢复。
        }
        final current = PortablePrefEntry(
          namespace: existing.namespace,
          schemaVersion: existing.schemaVersion,
          payload: sanitizePayloadMap(raw),
          updatedAtMs: existing.updatedAtMs,
          sourceDeviceId: existing.sourceDeviceId,
        );
        if (_tracksFields(current, next)) {
          // 规划至落盘之间的本机修改也进入同一次版本比较。
          next = FieldwisePortablePrefs.merge(
            FieldwisePortablePrefs.forDevice(current, localDeviceId),
            next,
          );
        }
      }
      db.scopedPrefs.upsertInTx(
        tx,
        ScopedPrefRecord(
          namespace: entry.namespace,
          schemaVersion: next.schemaVersion,
          syncPolicy: SyncPolicy.portable,
          payloadJson: jsonEncode(next.payload),
          updatedAtMs: next.updatedAtMs,
          sourceDeviceId: next.sourceDeviceId,
        ),
      );
    }
  }

  static bool _tracksFields(PortablePrefEntry? a, PortablePrefEntry b) =>
      FieldwisePortablePrefs.tracksFields(b) ||
      (a != null && FieldwisePortablePrefs.tracksFields(a));

  static bool _samePayload(PortablePrefEntry a, PortablePrefEntry b) =>
      SyncSanitizer.canonicalJsonEncode(a.payload) ==
      SyncSanitizer.canonicalJsonEncode(b.payload);

  List<PortablePrefEntry> _parseEntries(SyncSlicePayload snapshot) {
    final rawList = snapshot.data['entries'];
    if (rawList is! List) return const <PortablePrefEntry>[];
    final result = <PortablePrefEntry>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final parsed = PortablePrefEntry.tryFromJson(
        SyncSanitizer.coerceStringKeyMap(item),
      );
      if (parsed != null && isNamespaceAllowed(parsed.namespace)) {
        final entry = snapshot.schemaVersion == 1
            ? parsed.withPayload(
                FieldwisePortablePrefs.valuesOf(parsed.payload),
              )
            : parsed;
        result.add(
          FieldwisePortablePrefs.forDevice(entry, snapshot.sourceDeviceId),
        );
      }
    }
    return result;
  }
}
