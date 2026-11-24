import 'dart:convert';

import 'package:konata_contracts/konata_contracts.dart';

/// SQLite 行值与强类型领域字段之间的纯函数编解码辅助工具。
abstract final class SqliteRowCodec {
  /// 将 SQLite 整数（`0`/`1`）解码为布尔值。
  static bool decodeBool(Object? raw) => (raw as int? ?? 0) != 0;

  /// 将布尔值编码为 SQLite 整数。
  static int encodeBool(bool value) => value ? 1 : 0;

  /// 按名称解析枚举值；匹配失败时返回 [fallback]。
  static T decodeEnum<T extends Enum>(
    List<T> values,
    Object? raw,
    T fallback,
  ) {
    final name = raw as String?;
    if (name == null) return fallback;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  /// 按名称解析可空枚举值。
  static T? decodeNullableEnum<T extends Enum>(List<T> values, Object? raw) {
    final name = raw as String?;
    if (name == null || name.isEmpty) return null;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  /// 将字符串列表编码为紧凑 JSON 数组文本。
  static String encodeStringList(List<String> values) => jsonEncode(values);

  /// 将 JSON 数组文本安全解码为不可变字符串列表。
  static List<String> decodeStringList(Object? raw) {
    final text = raw as String?;
    if (text == null || text.isEmpty) return const <String>[];
    final decoded = jsonDecode(text);
    if (decoded is! List<Object?>) return const <String>[];
    return List<String>.unmodifiable(
      decoded.whereType<String>(),
    );
  }

  /// 将 [ArtworkRef] 序列化为数据库 JSON 文本（完整保留本地自定义路径）。
  static String? encodeArtworkRef(ArtworkRef? ref) {
    if (ref == null) return null;
    return jsonEncode(ref.toLocalJson());
  }

  /// 从数据库 JSON 文本还原 [ArtworkRef]。
  static ArtworkRef? decodeArtworkRef(Object? raw) {
    final text = raw as String?;
    if (text == null || text.isEmpty) return null;
    final decoded = jsonDecode(text);
    if (decoded is! Map<Object?, Object?>) return null;
    final typed = <String, Object?>{
      for (final entry in decoded.entries)
        if (entry.key is String) entry.key! as String: entry.value,
    };
    return ArtworkRef.tryFromJson(typed);
  }
}
