import 'dart:convert';
import 'dart:math' as math;

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
    this.mergeByField = false,
  });

  /// 配置命名空间唯一标识（例如 `feature_library.grid`）。
  final String namespace;

  /// 配置切片结构版本号。
  final int schemaVersion;

  /// 跨设备同步策略（`portable` 参与备份同步，`deviceLocal` 仅本机生效）。
  final SyncPolicy syncPolicy;

  /// 便携切片是否为独立字段记录修改版本。
  final bool mergeByField;

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

  /// 使用相同配置标识构造更新后的快照。
  PortablePrefEntry withPayload(
    Map<String, Object?> payload, {
    int? updatedAtMs,
    String? sourceDeviceId,
  }) => PortablePrefEntry(
    namespace: namespace,
    schemaVersion: schemaVersion,
    payload: payload,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    sourceDeviceId: sourceDeviceId ?? this.sourceDeviceId,
  );

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

typedef _FieldVersion = ({int time, String device, bool edited, bool deleted});

/// 逐字段同步规则。无字段版本的旧快照是基线，显式编辑优先于基线。
abstract final class FieldwisePortablePrefs {
  static const _versionsKey = '_konataFieldVersions';
  static const _maxTime = 9007199254740991;

  /// 是否包含逐字段同步信息。
  static bool tracksFields(PortablePrefEntry entry) =>
      entry.payload[_versionsKey] is Map;

  /// 取出业务配置，版本元数据仅供存储和同步使用。
  static Map<String, Object?> valuesOf(Map<String, Object?> payload) =>
      <String, Object?>{
        for (final field in payload.entries)
          if (field.key != _versionsKey) field.key: field.value,
      };

  /// 为本机产生的版本补全设备标识，同时保留已同步字段的原始作者。
  static PortablePrefEntry forDevice(PortablePrefEntry entry, String deviceId) {
    final identified = entry.sourceDeviceId.isEmpty
        ? entry.withPayload(entry.payload, sourceDeviceId: deviceId)
        : entry;
    if (!tracksFields(identified)) return identified;
    return identified.withPayload(
      _pack(valuesOf(identified.payload), _versions(identified)),
    );
  }

  /// 合并两个逐字段快照。显式删除也参加冲突比较。
  static PortablePrefEntry merge(
    PortablePrefEntry local,
    PortablePrefEntry remote,
  ) {
    final localVersions = _versions(local);
    final remoteVersions = _versions(remote);
    final values = <String, Object?>{};
    final versions = <String, _FieldVersion>{};
    for (final key in {...localVersions.keys, ...remoteVersions.keys}) {
      final a = localVersions[key];
      final b = remoteVersions[key];
      final comparison = a == null || b == null ? 0 : _compare(a, b);
      final useRemote =
          b != null &&
          (a == null ||
              comparison < 0 ||
              (comparison == 0 &&
                  _canonical(
                        remote.payload[key],
                      ).compareTo(_canonical(local.payload[key])) >
                      0));
      final winner = useRemote ? b : a!;
      versions[key] = winner;
      if (!winner.deleted) {
        values[key] = (useRemote ? remote : local).payload[key];
      }
    }
    final rowWinner = local.updatedAtMs != remote.updatedAtMs
        ? (local.updatedAtMs > remote.updatedAtMs ? local : remote)
        : (local.sourceDeviceId.compareTo(remote.sourceDeviceId) >= 0
              ? local
              : remote);
    return rowWinner.withPayload(_pack(values, versions));
  }

  /// 显式覆盖还原将备份视为本机的新编辑，并标记备份中缺失的本机字段。
  static PortablePrefEntry restore(
    PortablePrefEntry? local,
    PortablePrefEntry backup, {
    required int now,
    required String deviceId,
  }) {
    final values = valuesOf(backup.payload);
    final keys = {
      ..._versions(backup).keys,
      if (local != null) ..._versions(local).keys,
    };
    final time = _nextTime(now, [?local, backup]);
    return backup.withPayload(
      _pack(values, {
        for (final key in keys)
          key: (
            time: time,
            device: deviceId,
            edited: true,
            deleted: !values.containsKey(key),
          ),
      }),
      updatedAtMs: time,
      sourceDeviceId: deviceId,
    );
  }

  static PortablePrefEntry? _edit(
    PortablePrefEntry previous,
    Map<String, Object?> before,
    Map<String, Object?> after,
    int now,
    String device,
  ) {
    final values = valuesOf(previous.payload);
    final versions = _versions(previous);
    final time = _nextTime(now, [previous]);
    var changed = false;
    for (final key in {...before.keys, ...after.keys}) {
      final exists = after.containsKey(key);
      if (exists == before.containsKey(key) &&
          _canonical(before[key]) == _canonical(after[key])) {
        continue;
      }
      changed = true;
      if (exists) {
        values[key] = after[key];
      } else {
        values.remove(key);
      }
      versions[key] = (
        time: time,
        device: device,
        edited: true,
        deleted: !exists,
      );
    }
    if (!changed) return null;
    return previous.withPayload(
      _pack(values, versions),
      updatedAtMs: time,
      sourceDeviceId: device,
    );
  }

  static Map<String, _FieldVersion> _versions(PortablePrefEntry entry) {
    final raw = entry.payload[_versionsKey];
    final result = <String, _FieldVersion>{
      for (final key in entry.payload.keys)
        if (key != _versionsKey)
          key: (
            time: entry.updatedAtMs.clamp(0, _maxTime),
            device: entry.sourceDeviceId,
            edited: false,
            deleted: false,
          ),
    };
    if (raw is Map) {
      for (final version in raw.entries) {
        if ((version.key, version.value)
            case (
              final String key,
              [
                final int time,
                final String device,
                final bool edited,
                final bool deleted,
              ],
            )
            when key != _versionsKey &&
                time >= 0 &&
                time <= _maxTime &&
                entry.payload.containsKey(key) != deleted) {
          result[key] = (
            time: time,
            device: device.isEmpty ? entry.sourceDeviceId : device,
            edited: edited,
            deleted: deleted,
          );
        }
      }
    }
    return result;
  }

  static Map<String, Object?> _pack(
    Map<String, Object?> values,
    Map<String, _FieldVersion> versions,
  ) => {
    ...values,
    _versionsKey: {
      for (final entry in versions.entries)
        entry.key: [
          entry.value.time,
          entry.value.device,
          entry.value.edited,
          entry.value.deleted,
        ],
    },
  };

  static int _nextTime(int now, List<PortablePrefEntry> entries) {
    var time = now.clamp(0, _maxTime);
    for (final entry in entries) {
      time = math.max(time, entry.updatedAtMs.clamp(0, _maxTime - 1) + 1);
      for (final version in _versions(entry).values) {
        time = math.max(time, math.min(version.time + 1, _maxTime));
      }
    }
    return time;
  }

  static int _compare(_FieldVersion a, _FieldVersion b) {
    if (a.edited != b.edited) return a.edited ? 1 : -1;
    if (a.time != b.time) return a.time.compareTo(b.time);
    final device = a.device.compareTo(b.device);
    if (device != 0) return device;
    if (a.deleted != b.deleted) return a.deleted ? 1 : -1;
    return 0;
  }

  static String _canonical(Object? value) => jsonEncode(_ordered(value));

  static Object? _ordered(Object? value) => switch (value) {
    Map<String, Object?>() => {
      for (final key in value.keys.toList()..sort()) key: _ordered(value[key]),
    },
    List<Object?>() => value.map(_ordered).toList(growable: false),
    _ => value,
  };
}

/// 分命名空间自治配置管理器（存入 `user_state.db` 的 `scoped_prefs` 表）。
///
/// 实现 [PrefsReadPort]，并内置 `SyncPolicy.portable` / `SyncPolicy.deviceLocal`
/// 隔离导出、纯函数合并预览与事务落地能力。
final class ScopedPrefsStore implements PrefsReadPort {
  /// 创建自治配置存储器。
  ScopedPrefsStore(this._userStateDb, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

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
    if (slice.mergeByField && slice.syncPolicy == SyncPolicy.portable) {
      _userStateDb.engine.runTransaction((tx) {
        final dao = _userStateDb.scopedPrefs;
        final current = dao.findByNamespace(slice.namespace);
        final previous = PortablePrefEntry(
          namespace: slice.namespace,
          schemaVersion: slice.schemaVersion,
          payload: current == null
              ? const {}
              : _tryDecodeObjectMap(current.payloadJson) ?? const {},
          updatedAtMs: current?.updatedAtMs ?? 0,
          sourceDeviceId: current?.sourceDeviceId ?? '',
        );
        final edited = FieldwisePortablePrefs._edit(
          previous,
          slice.encode(_decodeSlice(slice, current)),
          jsonMap,
          updatedAtMs ?? _nowMs(),
          sourceDeviceId,
        );
        if (edited == null) return;
        dao.upsertInTx(
          tx,
          ScopedPrefRecord(
            namespace: edited.namespace,
            schemaVersion: edited.schemaVersion,
            syncPolicy: slice.syncPolicy,
            payloadJson: jsonEncode(edited.payload),
            updatedAtMs: edited.updatedAtMs,
            sourceDeviceId: edited.sourceDeviceId,
          ),
        );
      });
      return;
    }
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
    final payload = _tryDecodeObjectMap(record.payloadJson);
    return payload == null ? null : FieldwisePortablePrefs.valuesOf(payload);
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
      return slice.decode(
        FieldwisePortablePrefs.valuesOf(decoded),
        record.schemaVersion,
      );
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
