import 'dart:convert';

import 'package:konata_contracts/konata_contracts.dart';

import '../user_state/dao/scoped_prefs_dao.dart';
import '../user_state/user_state_database.dart';

/// 强类型分命名空间配置切片描述符（由各 Feature 自主声明并注册，避免全局超级配置大类）。
final class TypedPrefsSlice<T> {
  /// 创建强类型配置切片定义。
  const TypedPrefsSlice({
    required this.namespace,
    required this.schemaVersion,
    required this.syncPolicy,
    required this.defaultValue,
    required this.encode,
    required this.decode,
  });

  /// 配置命名空间唯一标识（例如 `feature_library.grid`）。
  final String namespace;

  /// 配置切片结构版本号。
  final int schemaVersion;

  /// 跨设备同步策略（`portable` 参与备份同步，`deviceLocal` 仅本机生效）。
  final SyncPolicy syncPolicy;

  /// 未写入或解码异常时回退的安全默认值。
  final T defaultValue;

  /// 将强类型配置值序列化为 JSON 字典（严禁包含密码、Token 等敏感凭据）。
  final Map<String, Object?> Function(T value) encode;

  /// 从 JSON 字典反序列化为强类型配置值（传入读取到的版本号以支持平滑演进）。
  final T Function(Map<String, Object?> json, int storedSchemaVersion) decode;
}

/// 便携配置单条跨设备同步快照。
final class PortablePrefEntry {
  /// 创建便携配置快照条目。
  const PortablePrefEntry({
    required this.namespace,
    required this.schemaVersion,
    required this.payload,
    required this.updatedAtMs,
    this.sourceDeviceId = '',
  });

  /// 配置命名空间。
  final String namespace;

  /// 配置切片版本号。
  final int schemaVersion;

  /// 已解析的 JSON 载荷字典。
  final Map<String, Object?> payload;

  /// 最近更新时间戳（UTC 毫秒）。
  final int updatedAtMs;

  /// 来源设备标识。
  final String sourceDeviceId;

  /// 序列化为跨设备传输字典。
  Map<String, Object?> toJson() => <String, Object?>{
    'namespace': namespace,
    'schemaVersion': schemaVersion,
    'payload': payload,
    'updatedAtMs': updatedAtMs,
    'sourceDeviceId': sourceDeviceId,
  };

  /// 从跨设备传输字典还原；结构非法时返回 `null`。
  static PortablePrefEntry? tryFromJson(Map<String, Object?> json) {
    final namespace = (json['namespace'] as String?)?.trim() ?? '';
    final rawPayload = json['payload'];
    if (namespace.isEmpty || rawPayload is! Map<Object?, Object?>) {
      return null;
    }
    final typedPayload = <String, Object?>{
      for (final entry in rawPayload.entries)
        if (entry.key is String) entry.key! as String: entry.value,
    };
    return PortablePrefEntry(
      namespace: namespace,
      schemaVersion: json['schemaVersion'] as int? ?? 1,
      payload: typedPayload,
      updatedAtMs: json['updatedAtMs'] as int? ?? 0,
      sourceDeviceId: json['sourceDeviceId'] as String? ?? '',
    );
  }
}

/// 分命名空间自治配置管理器（存入 `user_state.db` 的 `scoped_prefs` 表）。
///
/// 实现 [PrefsReadPort]，并内置 `SyncPolicy.portable` / `SyncPolicy.deviceLocal`
/// 隔离导出、纯函数合并预览与事务落地能力。
final class ScopedPrefsStore implements PrefsReadPort {
  /// 创建自治配置存储器。
  ScopedPrefsStore(
    this._userStateDb, {
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final UserStateDatabase _userStateDb;
  final int Function() _nowMs;

  /// 读取强类型配置切片；若未写入或数据损坏则安全返回 [TypedPrefsSlice.defaultValue]。
  T read<T>(TypedPrefsSlice<T> slice) {
    final record = _userStateDb.scopedPrefs.findByNamespace(slice.namespace);
    return _decodeSlice(slice, record);
  }

  /// 写入强类型配置切片并自动标记其声明的 [SyncPolicy]。
  void write<T>(
    TypedPrefsSlice<T> slice,
    T value, {
    String sourceDeviceId = '',
    int? updatedAtMs,
  }) {
    final jsonMap = slice.encode(value);
    _userStateDb.scopedPrefs.upsert(
      ScopedPrefRecord(
        namespace: slice.namespace,
        schemaVersion: slice.schemaVersion,
        syncPolicy: slice.syncPolicy,
        payloadJson: jsonEncode(jsonMap),
        updatedAtMs: updatedAtMs ?? _nowMs(),
        sourceDeviceId: sourceDeviceId,
      ),
    );
  }

  /// 响应式监听强类型配置切片变化。
  Stream<T> watch<T>(TypedPrefsSlice<T> slice) {
    return _userStateDb.scopedPrefs
        .watchNamespace(slice.namespace)
        .map((record) => _decodeSlice(slice, record));
  }

  /// 删除指定命名空间的配置切片。
  void delete(String namespace) {
    _userStateDb.scopedPrefs.delete(namespace);
  }

  @override
  Future<Map<String, Object?>?> readRawSlice(String namespace) async {
    final record = _userStateDb.scopedPrefs.findByNamespace(namespace);
    if (record == null) return null;
    return _tryDecodeObjectMap(record.payloadJson);
  }

  /// 导出全部允许跨设备同步的配置切片（严格过滤掉 `SyncPolicy.deviceLocal`）。
  List<PortablePrefEntry> exportPortableEntries() {
    final records = _userStateDb.scopedPrefs.listByPolicy(SyncPolicy.portable);
    final result = <PortablePrefEntry>[];
    for (final rec in records) {
      final map = _tryDecodeObjectMap(rec.payloadJson);
      if (map == null) continue;
      result.add(
        PortablePrefEntry(
          namespace: rec.namespace,
          schemaVersion: rec.schemaVersion,
          payload: map,
          updatedAtMs: rec.updatedAtMs,
          sourceDeviceId: rec.sourceDeviceId,
        ),
      );
    }
    return result;
  }

  /// 纯函数计算便携配置切片合并计划（按 `updatedAtMs` 较新优先，严禁覆盖本机 `deviceLocal` 项）。
  SyncMergePlan<List<PortablePrefEntry>> planPortableMerge({
    required List<PortablePrefEntry> localPortable,
    required List<PortablePrefEntry> remotePortable,
    Set<String> deviceLocalNamespaces = const <String>{},
  }) {
    final localByNs = <String, PortablePrefEntry>{
      for (final item in localPortable) item.namespace: item,
    };
    final toApply = <PortablePrefEntry>[];
    var insertCount = 0;
    var updateCount = 0;
    var skippedCount = 0;

    for (final remote in remotePortable) {
      if (deviceLocalNamespaces.contains(remote.namespace)) {
        skippedCount++;
        continue;
      }
      final local = localByNs[remote.namespace];
      if (local == null) {
        insertCount++;
        toApply.add(remote);
      } else if (remote.updatedAtMs > local.updatedAtMs) {
        updateCount++;
        toApply.add(remote);
      } else {
        skippedCount++;
      }
    }

    return SyncMergePlan<List<PortablePrefEntry>>(
      sliceId: 'prefs_slice',
      insertCount: insertCount,
      updateCount: updateCount,
      deleteCount: 0,
      skippedCount: skippedCount,
      planData: List<PortablePrefEntry>.unmodifiable(toApply),
      summaryLines: <String>[
        '配置切片合并：新增 $insertCount 项，更新 $updateCount 项，跳过 $skippedCount 项',
      ],
    );
  }

  /// 在单事务内原子应用便携配置合并计划（二次守卫绝不覆写已标注 `deviceLocal` 的本地项）。
  void applyPortableMergePlan(SyncMergePlan<List<PortablePrefEntry>> plan) {
    if (!plan.hasChanges) return;
    _userStateDb.engine.runTransaction((tx) {
      for (final entry in plan.planData) {
        final existing = _userStateDb.scopedPrefs.findByNamespace(
          entry.namespace,
        );
        if (existing != null && existing.syncPolicy == SyncPolicy.deviceLocal) {
          continue;
        }
        _userStateDb.scopedPrefs.upsertInTx(
          tx,
          ScopedPrefRecord(
            namespace: entry.namespace,
            schemaVersion: entry.schemaVersion,
            syncPolicy: SyncPolicy.portable,
            payloadJson: jsonEncode(entry.payload),
            updatedAtMs: entry.updatedAtMs,
            sourceDeviceId: entry.sourceDeviceId,
          ),
        );
      }
    });
  }

  T _decodeSlice<T>(TypedPrefsSlice<T> slice, ScopedPrefRecord? record) {
    if (record == null) {
      return slice.defaultValue;
    }
    final decoded = _tryDecodeObjectMap(record.payloadJson);
    if (decoded == null) {
      return slice.defaultValue;
    }
    try {
      return slice.decode(decoded, record.schemaVersion);
    } catch (_) {
      return slice.defaultValue;
    }
  }

  static Map<String, Object?>? _tryDecodeObjectMap(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<Object?, Object?>) return null;
      return <String, Object?>{
        for (final entry in decoded.entries)
          if (entry.key is String) entry.key! as String: entry.value,
      };
    } catch (_) {
      return null;
    }
  }
}
