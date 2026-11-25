import 'dart:typed_data';

import 'legacy_codepage_tables.dart';

/// 纯 Dart 完整 Shift-JIS / CP932 码表（覆盖全部 9604 个日文双字节汉字/假名/符号与半角片假名）。
///
/// 采用压缩二进制 UTF-16 查表结构，空载零堆内存占用，首次解码日文传统字幕或 CUE 时按需解压为
/// `Uint16List` 并实现 O(1) 索引查询。
class ShiftJisCp932Table {
  ShiftJisCp932Table._();

  /// 已收录的有效 Shift-JIS / CP932 双字节码位总数。
  static const int mappedEntryCount = 9604;

  static const int _trailCount = 188;

  static Uint16List get _table => LegacyCodePageTables.table(2);

  static int _leadIndex(int b1) {
    if (b1 >= 0x81 && b1 <= 0x9F) return b1 - 0x81;
    if (b1 >= 0xE0 && b1 <= 0xFC) return 31 + (b1 - 0xE0);
    return -1;
  }

  /// 按双字节首尾字节查询对应 Unicode 码位（未定义时返回 0）。
  static int lookup(int b1, int b2) {
    final leadIdx = _leadIndex(b1);
    if (leadIdx < 0) return 0;
    if (b2 < 0x40 || b2 > 0xFC || b2 == 0x7F) return 0;
    final trailIdx = b2 < 0x7F ? (b2 - 0x40) : (b2 - 0x41);
    final slot = leadIdx * _trailCount + trailIdx;
    if (slot < 0 || slot >= _table.length) return 0;
    return _table[slot];
  }

  /// 解码完整 Shift-JIS / CP932 字节流为 Unicode 字符串。
  static String decode(Uint8List bytes) {
    final out = StringBuffer();
    final table = _table;
    for (var i = 0; i < bytes.length; i++) {
      final b1 = bytes[i];
      if (b1 < 0x80) {
        out.writeCharCode(b1);
        continue;
      }
      if (b1 >= 0xA1 && b1 <= 0xDF) {
        // 半角片假名映射至 U+FF61..U+FF9F。
        out.writeCharCode(0xFF61 + (b1 - 0xA1));
        continue;
      }
      final leadIdx = _leadIndex(b1);
      if (leadIdx >= 0 && i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        if (b2 >= 0x40 && b2 <= 0xFC && b2 != 0x7F) {
          final trailIdx = b2 < 0x7F ? (b2 - 0x40) : (b2 - 0x41);
          final cp = table[leadIdx * _trailCount + trailIdx];
          out.writeCharCode(cp > 0 ? cp : 0xFFFD);
          i++;
          continue;
        }
      }
      out.writeCharCode(0xFFFD);
    }
    return out.toString();
  }
}
