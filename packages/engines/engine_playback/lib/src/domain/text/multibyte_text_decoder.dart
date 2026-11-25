import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'big5_cp950_table.dart';
import 'gbk_cp936_table.dart';
import 'legacy_codepage_tables.dart';
import 'shift_jis_cp932_table.dart';

/// 传统东亚多字节文本编码类型（全仓唯一，供字幕、CUE 与 LRC 共用）。
enum LegacyTextEncoding {
  /// 日文 Shift-JIS / CP932。
  shiftJis,

  /// 简体中文 GB18030 / GBK / CP936。
  gbk,

  /// 繁体中文 Big5 / CP950。
  big5,
}

/// 可选外部代码页解码桥接签名（由基础设施层按需注入 Win32 `MultiByteToWideChar` 高精桥接）。
typedef LegacyCodePageDecoder =
    String? Function(List<int> bytes, LegacyTextEncoding encoding);

/// 多字符集探测结果枚举。
enum DetectedTextCharset {
  /// 无 BOM UTF-8。
  utf8,

  /// 含 BOM UTF-8。
  utf8Bom,

  /// UTF-16 小端序。
  utf16Le,

  /// UTF-16 大端序。
  utf16Be,

  /// 日文 CP932 / Shift-JIS。
  cp932ShiftJis,

  /// 简体中文 GB18030 / GBK。
  gb18030Gbk,

  /// 繁体中文 Big5。
  big5,
}

/// 纯字节解码结果（同时保留探测到的源字符集与是否携带 BOM）。
class DecodedTextResult {
  /// 创建解码结果。
  const DecodedTextResult({
    required this.text,
    required this.charset,
    this.hadBom = false,
  });

  /// 规范化后的 Unicode 文本。
  final String text;

  /// 命中的源字符集。
  final DetectedTextCharset charset;

  /// 原始字节流是否带有 BOM 字节序标记。
  final bool hadBom;
}

/// 全仓唯一纯字节多字符集探测与解码器（UTF-8 / UTF-16LE/BE / CP932 / GB18030 / Big5）。
///
/// 统一服务外挂字幕、CUE 分轨表与 LRC 同步歌词，严禁通过篡改 `libmpv` 全局 `sub-codepage`
/// 造成副字幕槽乱码污染。
class MultibyteTextDecoder {
  MultibyteTextDecoder._();

  /// 将原始字节精准探测并解码为 Unicode 字符串与字符集元数据。
  static DecodedTextResult decodeWithInfo(
    Uint8List bytes, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    final unicode = decodeUnicode(bytes);
    if (unicode != null) return unicode;
    final encoding = detectLegacyEncoding(bytes);
    return _tryPlatformDecode(bytes, encoding, legacyDecoder) ??
        _decodeLegacy(bytes, encoding);
  }

  /// 异步文本入口只在确实需要传统代码页时调用宿主加载资产。
  static Future<DecodedTextResult> decodeWithInfoAsync(
    Uint8List bytes, {
    LegacyCodePageDecoder? legacyDecoder,
    bool offload = false,
  }) async {
    final unicode = offload
        ? await Isolate.run(() => decodeUnicode(bytes))
        : decodeUnicode(bytes);
    if (unicode != null) return unicode;
    final encoding = detectLegacyEncoding(bytes);
    final platform = _tryPlatformDecode(bytes, encoding, legacyDecoder);
    if (platform != null) return platform;
    final archive = await LegacyCodePageTables.prepare();
    if (!offload) return _decodeLegacy(bytes, encoding);
    return Isolate.run(() {
      LegacyCodePageTables.usePrepared(archive);
      return _decodeLegacy(bytes, encoding);
    });
  }

  /// 读取 UTF 编码文本，确实需要传统代码页时返回空值。
  static DecodedTextResult? decodeUnicode(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const DecodedTextResult(
        text: '',
        charset: DetectedTextCharset.utf8,
      );
    }

    // 1. 优先识别显式 BOM 标记（UTF-8 / UTF-16LE / UTF-16BE）。
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return DecodedTextResult(
        text: utf8.decode(bytes.sublist(3), allowMalformed: true),
        charset: DetectedTextCharset.utf8Bom,
        hadBom: true,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return DecodedTextResult(
        text: _decodeUtf16(bytes.sublist(2), littleEndian: true),
        charset: DetectedTextCharset.utf16Le,
        hadBom: true,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return DecodedTextResult(
        text: _decodeUtf16(bytes.sublist(2), littleEndian: false),
        charset: DetectedTextCharset.utf16Be,
        hadBom: true,
      );
    }

    // 2. 检测无 BOM 的 UTF-16LE / UTF-16BE（基于奇偶空字节统计特征）。
    final bomlessUtf16 = _detectBomlessUtf16(bytes);
    if (bomlessUtf16 != null) {
      return DecodedTextResult(
        text: _decodeUtf16(
          bytes,
          littleEndian: bomlessUtf16 == DetectedTextCharset.utf16Le,
        ),
        charset: bomlessUtf16,
      );
    }

    // 3. 严格 UTF-8 校验（零替换字符通过即直接返回）。
    try {
      final strictUtf8 = utf8.decode(bytes, allowMalformed: false);
      return DecodedTextResult(
        text: strictUtf8,
        charset: DetectedTextCharset.utf8,
      );
    } on FormatException {
      return null;
    }
  }

  static DecodedTextResult? _tryPlatformDecode(
    Uint8List bytes,
    LegacyTextEncoding legacy,
    LegacyCodePageDecoder? decoder,
  ) {
    final text = decoder?.call(bytes, legacy);
    if (text == null || text.isEmpty) return null;
    return DecodedTextResult(text: text, charset: _toDetectedCharset(legacy));
  }

  static DecodedTextResult _decodeLegacy(
    Uint8List bytes,
    LegacyTextEncoding legacy,
  ) {
    return switch (legacy) {
      LegacyTextEncoding.shiftJis => DecodedTextResult(
        text: _decodeShiftJisPureDart(bytes),
        charset: DetectedTextCharset.cp932ShiftJis,
      ),
      LegacyTextEncoding.gbk => DecodedTextResult(
        text: _decodeGbkPureDart(bytes),
        charset: DetectedTextCharset.gb18030Gbk,
      ),
      LegacyTextEncoding.big5 => DecodedTextResult(
        text: _decodeBig5PureDart(bytes),
        charset: DetectedTextCharset.big5,
      ),
    };
  }

  /// 将原始字节解码为 Unicode 字符串（便捷入口）。
  static String decodeBytes(
    Uint8List bytes, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    return decodeWithInfo(bytes, legacyDecoder: legacyDecoder).text;
  }

  /// 基于字节区间与独占双字节序列统计区分 Shift-JIS、GB18030/GBK 与 Big5。
  static LegacyTextEncoding detectLegacyEncoding(List<int> bytes) {
    var sjisScore = 0;
    var sjisExclusive = 0;
    var gbkScore = 0;
    var gbkExclusive = 0;
    var big5Score = 0;
    var big5Exclusive = 0;

    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b < 0x80) continue;

      // 1. GB18030 独占四字节序列：0x81..0xFE + 0x30..0x39 + 0x81..0xFE + 0x30..0x39。
      if (b >= 0x81 && b <= 0xFE && i + 3 < bytes.length) {
        final b2 = bytes[i + 1];
        final b3 = bytes[i + 2];
        final b4 = bytes[i + 3];
        if (b2 >= 0x30 &&
            b2 <= 0x39 &&
            b3 >= 0x81 &&
            b3 <= 0xFE &&
            b4 >= 0x30 &&
            b4 <= 0x39) {
          gbkExclusive += 10;
          gbkScore += 10;
          i += 3;
          continue;
        }
      }

      // 2. 孤立 Shift-JIS 半角片假名 (0xA1..0xDF)：仅在到达流尾或后接非多字节尾字节 (<0x40) 时判定，
      //    严禁抢占合法的 GB2312/GBK 双高字节一级汉字区间 (0xB0..0xDF + 0xA1..0xFE)。
      if (b >= 0xA1 && b <= 0xDF) {
        final next = (i + 1 < bytes.length) ? bytes[i + 1] : -1;
        if (next < 0 || next < 0x40) {
          sjisExclusive += 3;
          sjisScore += 3;
          continue;
        }
      }

      if (i + 1 >= bytes.length) break;
      final b2 = bytes[i + 1];

      // 3. Shift-JIS 独占首字节区 0x81..0x9F（后接 0x40..0x7E 或 0x80..0xFC）。
      if (b >= 0x81 &&
          b <= 0x9F &&
          ((b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0x80 && b2 <= 0xFC))) {
        final isKana =
            (b == 0x82 && b2 >= 0x9F && b2 <= 0xF1) ||
            (b == 0x83 && b2 >= 0x40 && b2 <= 0x96 && b2 != 0x7F);
        final weight = isKana ? 8 : 3;
        sjisExclusive += weight;
        sjisScore += weight;
        i++;
        continue;
      }

      // 4. Big5 高频低尾字节特征区：首字节 0xA1..0xC6 / 0xC9..0xF9 + 尾字节 0x40..0x7E
      //    （GB2312 常用汉字尾字节均 >= 0xA1，几乎不落入低尾区）。
      if (b >= 0xA1 && b <= 0xA3 && b2 >= 0x40 && b2 <= 0x7E) {
        big5Exclusive += 4;
        big5Score += 4;
        i++;
        continue;
      }
      if (b >= 0xA4 && b <= 0xC6 && b2 >= 0x40 && b2 <= 0x7E) {
        big5Exclusive += 5;
        big5Score += 5;
        i++;
        continue;
      }
      if (b >= 0xC9 && b <= 0xF9 && b2 >= 0x40 && b2 <= 0x7E) {
        big5Exclusive += 3;
        big5Score += 3;
        i++;
        continue;
      }

      // 5. GB2312/GBK 核心双高字节汉字区 (0xA1..0xF7 + 0xA1..0xFE)。
      if (b >= 0xA1 && b <= 0xF7 && b2 >= 0xA1 && b2 <= 0xFE) {
        if (b >= 0xB0 && b <= 0xD7) {
          gbkScore += 4;
        } else if (b >= 0xD8) {
          gbkScore += 3;
        } else {
          gbkScore += 2;
        }
        if (b >= 0xA4 && b <= 0xC6) {
          big5Score += 1;
        }
        if (b >= 0xE0 && b <= 0xEF && b2 <= 0xFC) {
          sjisScore += 1;
        }
        i++;
        continue;
      }

      // 6. Shift-JIS 第二汉字段 0xE0..0xEF（后接低尾字节 0x40..0x7E 或 0x80..0xA0）。
      if (b >= 0xE0 &&
          b <= 0xEF &&
          ((b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0x80 && b2 <= 0xA0))) {
        sjisScore += 3;
        i++;
      }
    }

    final totalSjis = sjisScore + sjisExclusive;
    final totalGbk = gbkScore + gbkExclusive;
    final totalBig5 = big5Score + big5Exclusive;

    if (big5Exclusive > 0 && totalBig5 > totalGbk && totalBig5 >= totalSjis) {
      return LegacyTextEncoding.big5;
    }
    if (sjisExclusive > 0 && totalSjis >= totalGbk && totalSjis >= totalBig5) {
      return LegacyTextEncoding.shiftJis;
    }
    if (totalGbk >= totalSjis && totalGbk >= totalBig5) {
      return LegacyTextEncoding.gbk;
    }
    if (totalBig5 > totalSjis) {
      return LegacyTextEncoding.big5;
    }
    return LegacyTextEncoding.shiftJis;
  }

  static DetectedTextCharset _toDetectedCharset(LegacyTextEncoding legacy) {
    return switch (legacy) {
      LegacyTextEncoding.shiftJis => DetectedTextCharset.cp932ShiftJis,
      LegacyTextEncoding.gbk => DetectedTextCharset.gb18030Gbk,
      LegacyTextEncoding.big5 => DetectedTextCharset.big5,
    };
  }

  static DetectedTextCharset? _detectBomlessUtf16(Uint8List bytes) {
    if (bytes.length < 4 || bytes.length.isOdd) return null;
    final sampleLen = bytes.length < 512 ? bytes.length : 512;
    final pairs = sampleLen ~/ 2;
    var evenZeros = 0;
    var oddZeros = 0;
    for (var i = 0; i + 1 < sampleLen; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] != 0) evenZeros++;
      if (bytes[i + 1] == 0 && bytes[i] != 0) oddZeros++;
    }
    if (oddZeros >= 2 && oddZeros * 4 >= pairs && evenZeros * 4 < oddZeros) {
      return DetectedTextCharset.utf16Le;
    }
    if (evenZeros >= 2 && evenZeros * 4 >= pairs && oddZeros * 4 < evenZeros) {
      return DetectedTextCharset.utf16Be;
    }
    return null;
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final len = bytes.length & ~1;
    if (len == 0) return '';
    final codeUnits = Uint16List(len ~/ 2);
    final data = ByteData.sublistView(bytes, 0, len);
    final endian = littleEndian ? Endian.little : Endian.big;
    for (var i = 0; i < codeUnits.length; i++) {
      codeUnits[i] = data.getUint16(i * 2, endian);
    }
    return String.fromCharCodes(codeUnits);
  }

  static String _decodeShiftJisPureDart(Uint8List bytes) {
    return ShiftJisCp932Table.decode(bytes);
  }

  static String _decodeGbkPureDart(Uint8List bytes) {
    return GbkCp936Table.decode(bytes);
  }

  /// 纯 Dart 完整 Big5 / CP950 双字节解码（覆盖全部 13,053 标准繁体汉字及全角符号/假名，双端零平台差异）。
  static String _decodeBig5PureDart(Uint8List bytes) {
    final out = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      final b1 = bytes[i];
      if (b1 < 0x80) {
        out.writeCharCode(b1);
        continue;
      }
      if (i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        if ((b1 >= 0x81 && b1 <= 0xFE) &&
            ((b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0xA1 && b2 <= 0xFE))) {
          final codePoint = Big5Cp950Table.lookup(b1, b2);
          if (codePoint > 0) {
            out.writeCharCode(codePoint);
          } else {
            out.writeCharCode(0xFFFD);
          }
          i++;
          continue;
        }
      }
      out.writeCharCode(0xFFFD);
    }
    return out.toString();
  }
}
