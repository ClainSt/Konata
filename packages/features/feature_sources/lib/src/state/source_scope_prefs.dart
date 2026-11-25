import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 单个媒体源在本地配置切片中保存的最近扫描时间元数据。
class SourceScopeMetadata {
  /// 创建媒体源扩展元数据。
  const SourceScopeMetadata({this.lastScannedAtMs});

  /// 从 JSON 字典解码媒体源扩展元数据。
  factory SourceScopeMetadata.fromJson(Map<String, Object?> json) {
    final rawScanned = json['lastScannedAtMs'];
    final scannedAtMs = rawScanned is int
        ? rawScanned
        : int.tryParse('${rawScanned ?? ''}');
    return SourceScopeMetadata(lastScannedAtMs: scannedAtMs);
  }

  /// 最近一次扫库完成时间戳（UTC 毫秒）。
  final int? lastScannedAtMs;

  /// 转为最近扫描本地时间对象。
  DateTime? get lastScannedAt => lastScannedAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastScannedAtMs!);

  /// 复制更新指定字段。
  SourceScopeMetadata copyWith({
    int? lastScannedAtMs,
    bool clearLastScannedAt = false,
  }) {
    return SourceScopeMetadata(
      lastScannedAtMs: clearLastScannedAt
          ? null
          : (lastScannedAtMs ?? this.lastScannedAtMs),
    );
  }

  /// 编码为可持久化 JSON 字典。
  Map<String, Object?> toJson() => <String, Object?>{
    if (lastScannedAtMs != null) 'lastScannedAtMs': lastScannedAtMs,
  };
}

/// 媒体源扫描时间配置切片存取辅助类（零 `Riverpod`）。
abstract final class SourceScopePrefs {
  /// 持久化媒体源最近扫描时间的强类型配置切片定义。
  static final TypedPrefsSlice<Map<String, SourceScopeMetadata>> slice =
      TypedPrefsSlice<Map<String, SourceScopeMetadata>>(
        namespace: 'feature_sources.source_metadata',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: const <String, SourceScopeMetadata>{},
        encode: (value) => <String, Object?>{
          'sources': <String, Object?>{
            for (final entry in value.entries) entry.key: entry.value.toJson(),
          },
        },
        decode: (json, schemaVersion) {
          final rawSources = json['sources'];
          if (rawSources is! Map) {
            return const <String, SourceScopeMetadata>{};
          }
          final decoded = <String, SourceScopeMetadata>{};
          for (final entry in rawSources.entries) {
            final key = entry.key;
            final val = entry.value;
            if (key is String && val is Map) {
              decoded[key] = SourceScopeMetadata.fromJson(
                Map<String, Object?>.from(val),
              );
            }
          }
          return Map<String, SourceScopeMetadata>.unmodifiable(decoded);
        },
      );

  /// 读取指定媒体源最近一次扫库时间。
  static DateTime? readLastScannedAt(ScopedPrefsStore? store, String sourceId) {
    if (store == null) return null;
    final map = store.read(slice);
    return map[sourceId]?.lastScannedAt;
  }

  /// 记录指定媒体源最近一次扫库完成时间戳。
  static void writeLastScannedAtMs(
    ScopedPrefsStore? store,
    String sourceId,
    int timestampMs,
  ) {
    if (store == null) return;
    final next = Map<String, SourceScopeMetadata>.of(store.read(slice));
    final current = next[sourceId] ?? const SourceScopeMetadata();
    next[sourceId] = current.copyWith(lastScannedAtMs: timestampMs);
    store.write(slice, Map<String, SourceScopeMetadata>.unmodifiable(next));
  }

  /// 清理已移除媒体源的扩展配置条目。
  static void removeSourceMetadata(ScopedPrefsStore? store, String sourceId) {
    if (store == null) return;
    final next = Map<String, SourceScopeMetadata>.of(store.read(slice));
    if (next.remove(sourceId) != null) {
      store.write(slice, Map<String, SourceScopeMetadata>.unmodifiable(next));
    }
  }
}
