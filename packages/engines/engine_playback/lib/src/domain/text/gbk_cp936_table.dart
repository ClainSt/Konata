import 'dart:typed_data';

import 'legacy_codepage_tables.dart';

/// 纯 Dart 完整 GBK / CP936 码表（覆盖全部 21791 个标准简繁汉字与符号码位）。
///
/// 采用压缩二进制 UTF-16 查表结构，空载零堆内存占用，首次解码 GBK 文本时按需解压为
/// `Uint16List` 并实现 O(1) 索引查询，彻底替代体量臃肿的外部多字符集映射表依赖。
class GbkCp936Table {
  GbkCp936Table._();

  /// 已收录的有效 GBK / CP936 双字节码位总数。
  static const int mappedEntryCount = 21791;

  static const int _leadMin = 0x81;
  static const int _leadMax = 0xFE;
  static const int _trailCount = 190;

  static Uint16List get _table => LegacyCodePageTables.table(0);

  /// 按双字节首尾字节查询对应 Unicode 码位（未定义时返回 0）。
  static int lookup(int b1, int b2) {
    if (b1 < _leadMin || b1 > _leadMax) return 0;
    if (b2 < 0x40 || b2 > 0xFE || b2 == 0x7F) return 0;
    final trailIdx = b2 < 0x7F ? (b2 - 0x40) : (b2 - 0x41);
    final slot = (b1 - _leadMin) * _trailCount + trailIdx;
    if (slot < 0 || slot >= _table.length) return 0;
    return _table[slot];
  }

  /// 解码完整 GBK / CP936 字节流为 Unicode 字符串。
  static String decode(Uint8List bytes) {
    final out = StringBuffer();
    final table = _table;
    for (var i = 0; i < bytes.length; i++) {
      final b1 = bytes[i];
      if (b1 < 0x80) {
        out.writeCharCode(b1);
        continue;
      }
      if (b1 == 0x80) {
        // CP936 欧元符号单字节扩展。
        out.writeCharCode(0x20AC);
        continue;
      }
      if (i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        if (b1 >= _leadMin &&
            b1 <= _leadMax &&
            b2 >= 0x40 &&
            b2 <= 0xFE &&
            b2 != 0x7F) {
          final trailIdx = b2 < 0x7F ? (b2 - 0x40) : (b2 - 0x41);
          final cp = table[(b1 - _leadMin) * _trailCount + trailIdx];
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
