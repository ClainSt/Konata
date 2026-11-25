import 'dart:typed_data';

import 'legacy_codepage_tables.dart';

/// 标准完整 Big5 / CP950 纯 Dart 双字节码表（惰性解压为 `Uint16List`，应用空闲零常驻内存）。
///
/// 覆盖范围：
/// - 首字节 `0x81..0xFE`（126 组）× 尾字节 `0x40..0x7E`、`0xA1..0xFE`（157 槽）；
/// - 有效双字节映射总计 13752 个（含标准 Big5 常用与次常用汉字 `0xA440..0xC67E` 与
///   `0xC940..0xF9D5` 全部 13053 个汉字码位，以及全角标点、假名与符号）。
abstract final class Big5Cp950Table {
  /// 标准完整 CP950 码表覆盖的有效双字节总数。
  static const int totalMappedCount = 13752;

  /// 标准 Big5 汉字区间（`0xA440..0xC67E` 与 `0xC940..0xF9D5`）覆盖汉字总数。
  static const int standardHanziCount = 13053;

  static const int _leadStart = 0x81;
  static const int _leadEnd = 0xFE;
  static const int _trailSpan = 157;

  static Uint16List get _cachedTable => LegacyCodePageTables.table(1);

  /// 按双字节码位 O(1) 查询对应 Unicode BMP 码点；未定义码位返回 `0`。
  static int lookup(int b1, int b2) {
    if (b1 < _leadStart || b1 > _leadEnd) return 0;
    final int trailIdx;
    if (b2 >= 0x40 && b2 <= 0x7E) {
      trailIdx = b2 - 0x40;
    } else if (b2 >= 0xA1 && b2 <= 0xFE) {
      trailIdx = 63 + (b2 - 0xA1);
    } else {
      return 0;
    }
    return _cachedTable[(b1 - _leadStart) * _trailSpan + trailIdx];
  }

  /// 暴露只读懒加载码表以便契约单测核验全量码位覆盖率。
  static Uint16List ensureTableForVerification() => _cachedTable;
}
